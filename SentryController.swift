import Foundation
import AppKit
import Combine
import CoreVideo

/// The state machine. Consumes frames, produces one of a small number of
/// decisions, and is the only thing in the app allowed to call `Locker`.
@MainActor
final class SentryController: ObservableObject {

    @Published private(set) var state: SentryState = .disarmed
    @Published private(set) var lastLiveness = LivenessReport()
    @Published private(set) var lastSimilarity: Float = 0
    @Published private(set) var isEnrolled = false
    @Published var policy: Policy = PolicyStore.load()

    private let capture = CaptureEngine()
    private let analyzer = FaceAnalyzer()
    private let liveness = LivenessEngine()
    private let identity: IdentityEngine
    private let power = PowerAssertion()

    private var lastFaceSeen: Date?
    private var strangerSince: Date?
    private var spoofSince: Date?
    private var darkSince: Date?
    private var enrolling: EnrollmentSession?
    private var observers: [NSObjectProtocol] = []

    init() {
        let template = EnrollmentStore.load()
        let embedder: FaceEmbedder = (try? CoreMLFaceEmbedder(modelName: "FaceEmbedder"))
            ?? FeaturePrintEmbedder()
        identity = IdentityEngine(embedder: embedder, template: template)
        isEnrolled = identity.isEnrolled
        if !isEnrolled { state = .notEnrolled }

        capture.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame) }
        }
        capture.onFailure = { message in
            EventLog.shared.record("capture.failure", message)
        }
        observeScreenLock()
    }

    // MARK: - Arming

    func requestArm() async {
        guard isEnrolled else { return }
        guard await AuthGate.authenticate(for: .arm) else { return }
        arm()
    }

    func requestDisarm() async {
        guard await AuthGate.authenticate(for: .disarm) else {
            EventLog.shared.record("disarm.denied", "Authentication failed or cancelled.")
            return
        }
        disarm()
    }

    private func arm() {
        liveness.reset()
        lastFaceSeen = nil
        strangerSince = nil; spoofSince = nil; darkSince = nil
        state = .searching(since: Date())
        if policy.holdSystemAwake { power.hold() }
        capture.start(cadence: .burst(onSeconds: policy.idleBurstOn,
                                      everySeconds: policy.idleBurstEvery))
        EventLog.shared.record("armed", "VAKT is watching.")
    }

    private func disarm() {
        capture.stop()
        power.release()
        liveness.reset()
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
            session.consume(frame: frame, analyzer: analyzer, liveness: liveness, identity: identity)
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
            // The interesting case. The face matches. Is it made of skin?
            switch report.verdict {
            case .live:
                spoofSince = nil
                lastFaceSeen = Date()
                state = .ownerPresent

            case .spoofSuspected:
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
                    self.lastFaceSeen = Date()
                    self.state = .searching(since: Date())
                    EventLog.shared.record("rearm", "Screen unlocked by the owner.")
                }
            })
    }

    // MARK: - Enrollment

    func beginEnrollment() async {
        guard await AuthGate.authenticate(for: .enroll) else { return }
        liveness.reset()
        enrolling = EnrollmentSession(embedderIdentifier: identity.embedderIdentifier())
        if !isArmed {
            if policy.holdSystemAwake { power.hold() }
            state = .verifying
            capture.start(cadence: .continuous)
        } else {
            capture.setCadence(.continuous)
        }
        EventLog.shared.record("enroll.begin", "Capturing owner template.")
    }

    var enrollmentProgress: Double { enrolling?.progress ?? 0 }

    private func finishEnrollment(_ session: EnrollmentSession) {
        enrolling = nil
        let template = OwnerTemplate(embedderIdentifier: session.embedderIdentifier,
                                     vectors: session.vectors,
                                     createdAt: Date(),
                                     updatedAt: Date())
        if EnrollmentStore.save(template) {
            identity.updateTemplate(template)
            isEnrolled = true
            EventLog.shared.record("enroll.done", "\(template.vectors.count) vectors stored.")
            arm()
        } else {
            EventLog.shared.record("enroll.failed", "Keychain write rejected.")
            disarm()
        }
    }

    func forgetEnrollment() async {
        guard await AuthGate.authenticate(for: .forget) else { return }
        EnrollmentStore.delete()
        identity.updateTemplate(nil)
        isEnrolled = false
        disarm()
        state = .notEnrolled
        EventLog.shared.record("enroll.deleted", "Owner template removed.")
    }
}

/// Collects a spread of embeddings. Only frames that pass liveness are accepted,
/// so you cannot accidentally enrol a photo of yourself.
final class EnrollmentSession {
    let embedderIdentifier: String
    private(set) var vectors: [[Float]] = []
    private let target = 18
    private var lastAccepted: CFTimeInterval = 0

    init(embedderIdentifier: String) { self.embedderIdentifier = embedderIdentifier }

    var progress: Double { min(1, Double(vectors.count) / Double(target)) }
    var isComplete: Bool { vectors.count >= target }

    func consume(frame: CaptureEngine.Frame,
                 analyzer: FaceAnalyzer,
                 liveness: LivenessEngine,
                 identity: IdentityEngine) {
        let samples = analyzer.analyze(pixelBuffer: frame.pixelBuffer)
        guard let s = samples.max(by: { $0.interocular < $1.interocular }) else { return }
        let report = liveness.ingest(s)
        guard report.verdict == .live,
              s.captureQuality >= 0.45,
              s.time - lastAccepted > 0.35,
              let v = try? identity.embed(pixelBuffer: frame.pixelBuffer, face: s.observation)
        else { return }

        // Skip near-duplicates so the template covers real pose variety.
        if let closest = vectors.map({ VectorMath.cosine(v, $0) }).max(), closest > 0.985 { return }

        vectors.append(v)
        lastAccepted = s.time
    }
}
