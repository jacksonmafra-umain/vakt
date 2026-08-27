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

    /// Duty cycle while nothing is in frame.
    var idleBurstOn: Double = 2.5
    var idleBurstEvery: Double = 9
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
