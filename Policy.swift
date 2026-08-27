import Foundation

enum SentryState: Equatable {
    case disarmed
    case notEnrolled
    /// Armed, camera sampling, no face in view.
    case searching(since: Date)
    /// A face is in view but liveness / identity has not converged yet.
    case verifying
    /// You are there and alive. The happy path.
    case ownerPresent
    /// You were there and are not any more. Counting down to a lock.
    case awaitingReturn(since: Date)
    case locked(reason: LockReason)
}

enum LockReason: String, Equatable, Codable {
    case ownerAbsent      = "You left and did not come back."
    case strangerPresent  = "A face that is not yours was in front of the camera."
    case spoofSuspected   = "A face matched, but it never moved like a living one."
    case screenReplay     = "A face matched and moved, but its geometry is flat — a screen, not a head."
    case heldDevice       = "The face and everything behind it moved together — something is being held up to the camera."
    case cameraObstructed = "The camera was covered while VAKT was armed."
    case secondFace       = "A second face appeared behind you."
    case manual           = "Locked from the menu."
}

struct Policy: Codable, Equatable {
    /// How long you can be out of frame before the screen locks.
    /// Long enough to lean out to grab something, short enough to matter.
    var absenceGrace: TimeInterval = 25

    /// A stranger gets a much shorter rope than an empty chair.
    var strangerGrace: TimeInterval = 2

    /// How long a "matching but never moving" face is tolerated before we call
    /// it a photo. Generous, because a person reading quietly barely moves.
    var spoofGrace: TimeInterval = 8

    /// Lock if the lens goes dark while armed. Covering the camera is an attack,
    /// not an accident.
    var lockOnObstruction = true
    var obstructionLuma: Double = 0.045
    var obstructionGrace: TimeInterval = 6

    /// Lock when someone else's face appears next to yours (shoulder surfing).
    /// Off by default: it fires a lot in an open-plan office.
    var lockOnSecondFace = false

    /// Keep the machine awake while armed, so agents keep running.
    var holdSystemAwake = true

    /// Re-arm automatically after you unlock the Mac yourself.
    var rearmAfterUnlock = true

    /// How long an authenticated unlock suppresses the *spoof-shaped* locks —
    /// still face, flat geometry, held device.
    ///
    /// Touch ID or your password is a far stronger presence signal than anything
    /// the camera infers, and re-locking seconds after you proved who you are is
    /// the worst failure this app has: it happened twice in 18 seconds with the
    /// identity match at 0.88 and 0.90. Absence and strangers are unaffected.
    var trustAfterUnlock: TimeInterval = 90

    /// Start watching as soon as VAKT launches, without asking.
    ///
    /// Arming is the only gated action that does not weaken anything — it turns
    /// protection *on*, using a template only you enrolled — so the automatic
    /// path needs no authentication. Disarming still does.
    var armAtLaunch = false

    /// Lock when the face's geometry looks flat.
    ///
    /// Off by default, and that is a judgement about evidence rather than about
    /// the idea. The homography check is sound on synthetic data — a plane scores
    /// zero at every angle — but on real Vision landmarks it locked the owner's
    /// screen once already, and an unvalidated heuristic that locks you out is
    /// worse than one that misses an attack. It keeps measuring and logging, so
    /// there is real data to calibrate against; turn it on once the `Depth`
    /// reading in the menu is comfortably above the floor while you work.
    var lockOnPlanarReplay = false

    /// Ask GitHub once a day whether there is a newer release. The only network
    /// traffic VAKT ever makes; nothing about what the camera sees is sent.
    var checkForUpdates = true

    /// Install a downloaded update without asking.
    ///
    /// Off by default on purpose: this build is signed ad-hoc, so a downloaded
    /// bundle cannot be tied cryptographically to the same author as the running
    /// one. Replacing the binary that guards your Mac deserves one deliberate
    /// click; with this on, the download installs itself and VAKT relaunches.
    var installUpdatesAutomatically = false

    /// Duty cycle while nothing is in frame.
    var idleBurstOn: Double = 2.5
    var idleBurstEvery: Double = 9
}

extension Policy {
    /// Decode field by field, keeping the default for anything absent.
    ///
    /// Swift's synthesised decoder throws on a missing key even when the property
    /// has a default value, so every field added to this struct made a stored
    /// policy undecodable — and `PolicyStore.load()` then silently handed back a
    /// fresh `Policy()`. Users lost their settings on every upgrade that touched
    /// this file, with no error anywhere. Verified: a policy saved with
    /// `absenceGrace = 35` came back as 25.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        var policy = Policy()

        func take<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? box.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? current
        }

        policy.absenceGrace = take(.absenceGrace, policy.absenceGrace)
        policy.strangerGrace = take(.strangerGrace, policy.strangerGrace)
        policy.spoofGrace = take(.spoofGrace, policy.spoofGrace)
        policy.lockOnObstruction = take(.lockOnObstruction, policy.lockOnObstruction)
        policy.obstructionLuma = take(.obstructionLuma, policy.obstructionLuma)
        policy.obstructionGrace = take(.obstructionGrace, policy.obstructionGrace)
        policy.lockOnSecondFace = take(.lockOnSecondFace, policy.lockOnSecondFace)
        policy.holdSystemAwake = take(.holdSystemAwake, policy.holdSystemAwake)
        policy.rearmAfterUnlock = take(.rearmAfterUnlock, policy.rearmAfterUnlock)
        policy.armAtLaunch = take(.armAtLaunch, policy.armAtLaunch)
        policy.trustAfterUnlock = take(.trustAfterUnlock, policy.trustAfterUnlock)
        policy.lockOnPlanarReplay = take(.lockOnPlanarReplay, policy.lockOnPlanarReplay)
        policy.checkForUpdates = take(.checkForUpdates, policy.checkForUpdates)
        policy.installUpdatesAutomatically = take(.installUpdatesAutomatically,
                                                 policy.installUpdatesAutomatically)
        policy.idleBurstOn = take(.idleBurstOn, policy.idleBurstOn)
        policy.idleBurstEvery = take(.idleBurstEvery, policy.idleBurstEvery)

        self = policy
    }
}

struct PolicyStore {
    private static let key = "vakt.policy.v1"

    static func load() -> Policy {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(Policy.self, from: data) else { return Policy() }
        return p
    }

    /// Guard call sites with `AuthGate` — loosening the policy is a privilege
    /// change, not a preference.
    static func save(_ p: Policy) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
