import Foundation
import AppKit
import Combine
import CoreVideo
import AVFoundation

/// The state machine. Consumes frames, produces one of a small number of
/// decisions, and is the only thing in the app allowed to call `Locker`.
@MainActor
final class SentryController: ObservableObject {

    @Published private(set) var state: SentryState = .disarmed
    @Published private(set) var lastLiveness = LivenessReport()
    @Published private(set) var lastSimilarity: Float = 0
    @Published private(set) var lastScene = SceneMotionEngine.Report()
    @Published private(set) var isEnrolled = false
    @Published var policy: Policy = PolicyStore.load()

    /// Set when this Mac cannot authenticate at all, so the UI can say why the
    /// controls are refusing rather than appearing broken.
    @Published private(set) var authIssue: String?

    /// Set when the camera VAKT is willing to use is unavailable or refused.
    @Published private(set) var cameraIssue: String?

    /// Non-nil exactly while the enrolment window should be showing progress.
    @Published private(set) var enrollmentStatus: EnrollmentStatus?

    struct EnrollmentStatus: Equatable {
        var captured = 0
        var target = 18
        var feedback: EnrollmentFeedback = .noFace
        var livenessScore: Double = 0
        var blinkObserved = false
        var quality: Float = 0
        var progress: Double { target > 0 ? min(1, Double(captured) / Double(target)) : 0 }
    }

    private let capture = CaptureEngine()
    private let analyzer = FaceAnalyzer()
    private let liveness = LivenessEngine()
    private let sceneMotion = SceneMotionEngine()
    private let identity: IdentityEngine
    private let power = PowerAssertion()

    private var lastFaceSeen: Date?
    private var strangerSince: Date?
    private var spoofSince: Date?
    private var darkSince: Date?
    private var unlockedByOwnerAt: Date?
    private var enrolling: EnrollmentSession?
    private var wasArmedBeforeEnrollment = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let template = EnrollmentStore.load()
        let embedder: FaceEmbedder = (try? CoreMLFaceEmbedder(modelName: "FaceEmbedder"))
            ?? FeaturePrintEmbedder()
        identity = IdentityEngine(embedder: embedder, template: template)
        isEnrolled = identity.isEnrolled
        if !isEnrolled { state = .notEnrolled }

        // Watch only through the sensor the template was captured on. A virtual
        // camera can feed synthetic video that no optical signal can question.
        capture.pinnedDeviceUniqueID = template?.cameraUniqueID

        capture.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame) }
        }
        capture.onFailure = { [weak self] message in
            EventLog.shared.record("capture.failure", message)
            Task { @MainActor in
                self?.cameraIssue = message
                // A watcher that cannot see is not watching. Say so rather than
                // sitting in `searching` forever.
                if self?.isArmed == true { self?.disarmBecauseBlind() }
            }
        }
        observeScreenLock()

        // Starting at login is only half of "do not make me remember": the app
        // would come up disarmed and wait for a decision nobody makes.
        if isEnrolled, policy.armAtLaunch, case .success = capture.selectDevice() {
            EventLog.shared.record("arm.atLaunch", "Armed automatically at launch.")
            arm()
        }
    }

    // MARK: - Arming

    func requestArm() async {
        guard isEnrolled else { return }
        // Fail before asking for Touch ID: nothing here is worth authenticating
        // if the sensor of record is missing.
        if case .failure(let problem) = capture.selectDevice() {
            cameraIssue = problem.message
            EventLog.shared.record("arm.camera.refused", problem.message)
            return
        }
        cameraIssue = nil
        switch await AuthGate.authenticate(for: .arm) {
        case .authorised:
            authIssue = nil
            arm()
        case .refused:
            EventLog.shared.record("arm.denied", "Authentication failed or cancelled.")
        case .unavailable(let reason):
            // Refuse to arm: VAKT would be a guard whose own off switch is
            // unguarded, and that is worse than not arming.
            authIssue = reason
            EventLog.shared.record("arm.unavailable", reason)
        }
    }

    func requestDisarm() async {
        switch await AuthGate.authenticate(for: .disarm) {
        case .authorised:
            authIssue = nil
            disarm()
        case .refused:
            EventLog.shared.record("disarm.denied", "Authentication failed or cancelled.")
        case .unavailable(let reason):
            // Unwinding is never blocked. Refusing here would leave an armed app
            // that cannot be stopped from its own menu.
            authIssue = reason
            EventLog.shared.record("disarm.unauthenticated", reason)
            disarm()
        }
    }

    private func arm() {
        liveness.reset()
        sceneMotion.reset()
        lastFaceSeen = nil
        strangerSince = nil; spoofSince = nil; darkSince = nil
        state = .searching(since: Date())
        if policy.holdSystemAwake { power.hold() }
        capture.start(cadence: .burst(onSeconds: policy.idleBurstOn,
                                      everySeconds: policy.idleBurstEvery))
        EventLog.shared.record("armed", "VAKT is watching.")
    }

    /// The camera failed or was refused while armed. Stop pretending to watch.
    private func disarmBecauseBlind() {
        EventLog.shared.record("disarmed.blind", cameraIssue ?? "The camera is unavailable.")
        disarm()
    }

    private func disarm() {
        capture.stop()
        power.release()
        liveness.reset()
        sceneMotion.reset()
        state = isEnrolled ? .disarmed : .notEnrolled
        EventLog.shared.record("disarmed", "VAKT stopped watching.")
    }

    var isArmed: Bool {
        switch state {
        case .disarmed, .notEnrolled: return false
        default: return true
        }
    }

    // MARK: - Frame handling

    private func handle(frame: CaptureEngine.Frame) {
        guard isArmed else { return }

        if let session = enrolling {
            let result = session.consume(frame: frame, analyzer: analyzer,
                                         liveness: liveness, identity: identity)
            if let report = result.liveness { lastLiveness = report }
            enrollmentStatus = EnrollmentStatus(captured: session.vectors.count,
                                                target: session.target,
                                                feedback: result.feedback,
                                                livenessScore: result.liveness?.score ?? 0,
                                                blinkObserved: result.liveness?.blinkObserved ?? false,
                                                quality: result.quality)
            if session.isComplete { finishEnrollment(session) }
            return
        }

        // 1. Is the lens covered?
        if policy.lockOnObstruction && frame.luma < policy.obstructionLuma {
            let since = darkSince ?? Date()
            darkSince = since
            if Date().timeIntervalSince(since) >= policy.obstructionGrace {
                lock(.cameraObstructed); return
            }
        } else {
            darkSince = nil
        }

        // 2. Faces?
        let samples = analyzer.analyze(pixelBuffer: frame.pixelBuffer)
        guard !samples.isEmpty else { handleNoFace(); return }

        capture.setCadence(.continuous)

        // Largest face wins: the person actually sitting at the machine.
        let primary = samples.max { $0.interocular < $1.interocular }!
        let report = liveness.ingest(primary)
        lastLiveness = report
        let scene = sceneMotion.ingest(pixelBuffer: frame.pixelBuffer, sample: primary)
        lastScene = scene

        let decision = identity.match(pixelBuffer: frame.pixelBuffer, sample: primary)
        if decision.similarity > 0 { lastSimilarity = decision.similarity }

        if policy.lockOnSecondFace, samples.count > 1 {
            lock(.secondFace); return
        }

        switch decision.outcome {
        case .stranger:
            let since = strangerSince ?? Date()
            strangerSince = since
            spoofSince = nil
            state = .verifying
            if Date().timeIntervalSince(since) >= policy.strangerGrace {
                lock(.strangerPresent, liveness: report.score, similarity: decision.similarity)
            }

        case .owner:
            strangerSince = nil

            // A video of you deforms and blinks like you do, so the liveness
            // score alone will call it live. What it cannot fake is depth: on a
            // panel every landmark moves under one homography.
            // Depth already proven means the thing in frame is a head, so any
            // background agreement is the camera moving, not a device held up.
            // Three ways to be told "that is not a living head", and all three
            // are inferences about a person who is sitting still. None of them
            // outranks a Touch ID unlock from a moment ago.
            if let unlocked = unlockedByOwnerAt,
               Date().timeIntervalSince(unlocked) < policy.trustAfterUnlock {
                spoofSince = nil
                lastFaceSeen = Date()
                state = .ownerPresent
                return
            }

            if scene.heldObjectSuspected && !report.depthConfirmed {
                let since = spoofSince ?? Date()
                spoofSince = since
                state = .verifying
                if Date().timeIntervalSince(since) >= policy.spoofGrace {
                    lock(.heldDevice, liveness: report.score, similarity: decision.similarity)
                }
                return
            }

            if report.planarReplaySuspected {
                let since = spoofSince ?? Date()
                spoofSince = since
                state = .verifying
                if Date().timeIntervalSince(since) >= policy.spoofGrace {
                    lock(.screenReplay, liveness: report.score, similarity: decision.similarity)
                }
                return
            }

            // The interesting case. The face matches. Is it made of skin?
            switch report.verdict {
            case .live:
                spoofSince = nil
                lastFaceSeen = Date()
                state = .ownerPresent

            case .spoofSuspected:
                // Proven depth means there is a head in front of the camera, so
                // "it never moved like a living one" is simply wrong — a still
                // person, not a photograph.
                if report.depthConfirmed {
                    spoofSince = nil
                    lastFaceSeen = Date()
                    state = .ownerPresent
                    break
                }
                let since = spoofSince ?? Date()
                spoofSince = since
                state = .verifying
                if Date().timeIntervalSince(since) >= policy.spoofGrace {
                    lock(.spoofSuspected, liveness: report.score, similarity: decision.similarity)
                }

            case .undecided:
                // Still filling the window. Do not extend presence on an
                // unproven face — a photo must not be able to hold the session
                // open just by existing.
                state = .verifying
            }

        case .inconclusive:
            state = .verifying
        }
    }

    private func handleNoFace() {
        liveness.decay()
        sceneMotion.reset()
        strangerSince = nil; spoofSince = nil
        capture.setCadence(.burst(onSeconds: policy.idleBurstOn,
                                  everySeconds: policy.idleBurstEvery))

        guard let last = lastFaceSeen else {
            if case .searching = state {} else { state = .searching(since: Date()) }
            return
        }
        let gone = Date().timeIntervalSince(last)
        if gone >= policy.absenceGrace {
            lock(.ownerAbsent)
        } else {
            state = .awaitingReturn(since: last)
        }
    }

    // MARK: - Locking

    func lockManually() { lock(.manual) }

    private func lock(_ reason: LockReason,
                      liveness score: Double? = nil,
                      similarity: Float? = nil) {
        EventLog.shared.record("lock", reason.rawValue, liveness: score, similarity: similarity)
        Locker.lockNow()
        state = .locked(reason: reason)
        self.liveness.reset()
        sceneMotion.reset()
        lastFaceSeen = nil
        strangerSince = nil; spoofSince = nil; darkSince = nil
        capture.setCadence(.burst(onSeconds: policy.idleBurstOn,
                                  everySeconds: policy.idleBurstEvery))
    }

    /// When *you* unlock the Mac with Touch ID or your password, that is an
    /// authenticated presence signal. Trust it and go back to watching.
    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isArmed, self.policy.rearmAfterUnlock else { return }
                    self.unlockedByOwnerAt = Date()
                    self.lastFaceSeen = Date()
                    self.state = .searching(since: Date())
                    EventLog.shared.record("rearm", "Screen unlocked by the owner.")
                }
            })
    }

    // MARK: - Enrollment

    @discardableResult
    func beginEnrollment() async -> Bool {
        switch await AuthGate.authenticate(for: .enroll) {
        case .authorised:
            authIssue = nil
        case .refused:
            return false
        case .unavailable(let reason):
            // Enrolling would write a template that nothing can later protect.
            authIssue = reason
            EventLog.shared.record("enroll.unavailable", reason)
            return false
        }
        liveness.reset()
        wasArmedBeforeEnrollment = isArmed
        let session = EnrollmentSession(embedderIdentifier: identity.embedderIdentifier())
        enrolling = session
        enrollmentStatus = EnrollmentStatus(target: session.target)
        if !isArmed {
            if policy.holdSystemAwake { power.hold() }
            state = .verifying
            capture.start(cadence: .continuous)
        } else {
            capture.setCadence(.continuous)
        }
        EventLog.shared.record("enroll.begin", "Capturing owner template.")
        return true
    }

    /// Bailing out of enrolment leaves the app exactly as it was before, rather
    /// than half-armed with the camera still on.
    func cancelEnrollment() {
        guard enrolling != nil else { return }
        enrolling = nil
        enrollmentStatus = nil
        liveness.reset()
        if wasArmedBeforeEnrollment {
            capture.setCadence(.burst(onSeconds: policy.idleBurstOn,
                                      everySeconds: policy.idleBurstEvery))
            state = .searching(since: Date())
        } else {
            disarm()
        }
        EventLog.shared.record("enroll.cancelled", "Enrolment stopped before completion.")
    }

    var isEnrolling: Bool { enrolling != nil }

    /// The live capture session, for the enrolment preview layer.
    var previewSession: AVCaptureSession { capture.previewSession }

    var enrollmentProgress: Double { enrolling?.progress ?? 0 }

    private func finishEnrollment(_ session: EnrollmentSession) {
        enrolling = nil
        enrollmentStatus = nil
        let template = OwnerTemplate(embedderIdentifier: session.embedderIdentifier,
                                     vectors: session.vectors,
                                     createdAt: Date(),
                                     updatedAt: Date(),
                                     cameraUniqueID: capture.activeDeviceUniqueID)
        if EnrollmentStore.save(template) {
            identity.updateTemplate(template)
            capture.pinnedDeviceUniqueID = template.cameraUniqueID
            isEnrolled = true
            EventLog.shared.record("enroll.done", "\(template.vectors.count) vectors stored.")
            // Deliberately does not arm. Arming straight out of enrolment locked
            // the screen seconds later, before anyone had a chance to read the
            // liveness numbers — arming is a decision, not a side effect.
            disarm()
        } else {
            EventLog.shared.record("enroll.failed", "Keychain write rejected.")
            disarm()
        }
    }

    func forgetEnrollment() async {
        switch await AuthGate.authenticate(for: .forget) {
        case .authorised:
            authIssue = nil
        case .refused:
            return
        case .unavailable(let reason):
            // Deleting your own template is an unwind, not a weakening: without
            // this escape hatch a Mac that cannot authenticate keeps a template
            // it can never use or remove.
            authIssue = reason
            EventLog.shared.record("enroll.delete.unauthenticated", reason)
        }
        EnrollmentStore.delete()
        identity.updateTemplate(nil)
        isEnrolled = false
        disarm()
        state = .notEnrolled
        EventLog.shared.record("enroll.deleted", "Owner template removed.")
    }
}

/// Why a frame was or was not folded into the template. Surfaced in the
/// enrolment window: silent rejection looks like a broken camera.
enum EnrollmentFeedback: Equatable {
    case noFace
    case tooFar
    case lowQuality
    case notLive
    case tooSimilar
    case accepted

    var message: String {
        switch self {
        case .noFace:     return "No face in frame. Sit in front of the camera."
        case .tooFar:     return "Too far away. Move closer."
        case .lowQuality: return "The image is too blurry or too dark."
        case .notLive:    return "Confirming you are a living face — blink, and move your head a little."
        case .tooSimilar: return "Captured. Now change angle slightly: left, right, up, down."
        case .accepted:   return "Captured."
        }
    }
}

/// Collects a spread of embeddings. Only frames that pass liveness are accepted,
/// so you cannot accidentally enrol a photo of yourself.
final class EnrollmentSession {
    let embedderIdentifier: String
    private(set) var vectors: [[Float]] = []
    let target = 18
    private var lastAccepted: CFTimeInterval = 0

    init(embedderIdentifier: String) { self.embedderIdentifier = embedderIdentifier }

    var progress: Double { min(1, Double(vectors.count) / Double(target)) }
    var isComplete: Bool { vectors.count >= target }

    struct Result {
        let feedback: EnrollmentFeedback
        let liveness: LivenessReport?
        let quality: Float
    }

    @discardableResult
    func consume(frame: CaptureEngine.Frame,
                 analyzer: FaceAnalyzer,
                 liveness: LivenessEngine,
                 identity: IdentityEngine) -> Result {
        let samples = analyzer.analyze(pixelBuffer: frame.pixelBuffer)
        guard let s = samples.max(by: { $0.interocular < $1.interocular }) else {
            return Result(feedback: .noFace, liveness: nil, quality: 0)
        }
        let report = liveness.ingest(s)

        func result(_ f: EnrollmentFeedback) -> Result {
            Result(feedback: f, liveness: report, quality: s.captureQuality)
        }

        guard s.interocular >= 30 else { return result(.tooFar) }
        guard s.captureQuality >= FaceQuality.minimum else { return result(.lowQuality) }
        guard report.verdict == .live else { return result(.notLive) }
        // Rate-limit: consecutive frames of one pose are near-identical anyway.
        guard s.time - lastAccepted > 0.35 else { return result(.tooSimilar) }
        guard let v = try? identity.embed(pixelBuffer: frame.pixelBuffer, face: s.observation) else {
            return result(.lowQuality)
        }

        // Skip near-duplicates so the template covers real pose variety.
        if let closest = vectors.map({ VectorMath.cosine(v, $0) }).max(), closest > 0.985 {
            return result(.tooSimilar)
        }

        vectors.append(v)
        lastAccepted = s.time
        return result(.accepted)
    }
}
