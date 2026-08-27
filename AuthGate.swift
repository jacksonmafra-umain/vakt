import Foundation
import AppKit
import LocalAuthentication

/// Every state change that weakens protection goes through here.
///
/// `.deviceOwnerAuthentication` means: Touch ID if the Mac has it and it is
/// working, otherwise the login password (and Apple Watch, where the user has
/// that enabled). That is exactly the "digital ou senha" requirement — we do not
/// use `.deviceOwnerAuthenticationWithBiometrics`, because that would lock you
/// out on a Mac without Touch ID or with a wet finger.
///
/// There is a third case beyond "authorised" and "refused": a Mac where no
/// authentication is possible at all, because the account has no login password.
/// Collapsing that into "refused" is a trap — every control becomes a silent
/// no-op, and an armed VAKT can then neither be disarmed nor quit from its own
/// menu while the LaunchAgent keeps relaunching it. So callers get told which
/// case they are in and decide: refuse to *weaken* nothing (there is nothing to
/// protect if VAKT cannot arm), but never refuse to *unwind*.
enum AuthGate {

    enum Action: String {
        case disarm      = "disarm VAKT"
        case arm         = "arm VAKT"
        case enroll      = "enrol your face"
        case forget      = "delete your enrolled face"
        case changeRules = "change VAKT's rules"
        case quit        = "quit VAKT"
    }

    enum Outcome: Equatable {
        /// The user proved who they are.
        case authorised
        /// The prompt appeared and the user failed or cancelled it.
        case refused
        /// No prompt is possible on this Mac. Carries a reason for the user.
        case unavailable(String)
    }

    enum Availability: Equatable {
        /// Biometry is set up, with the login password as fallback.
        case biometry(name: String)
        /// No biometry, but the login password works. Perfectly usable.
        case passwordOnly
        case unavailable(String)

        var reason: String? {
            if case .unavailable(let r) = self { return r }
            return nil
        }

        /// What the menu says under Settings so the user knows what to expect.
        var summary: String {
            switch self {
            case .biometry(let name): return "\(name) or your login password"
            case .passwordOnly:       return "your login password"
            case .unavailable(let r): return r
            }
        }
    }

    /// Checked on demand rather than cached: the user can enrol a fingerprint, or
    /// set a password, without restarting VAKT.
    static var availability: Availability {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(explain(error))
        }

        var biometryError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError) {
            switch context.biometryType {
            case .touchID: return .biometry(name: "Touch ID")
            case .opticID: return .biometry(name: "Optic ID")
            case .faceID:  return .biometry(name: "Face ID")
            default:       return .biometry(name: "biometrics")
            }
        }
        return .passwordOnly
    }

    static func authenticate(for action: Action) async -> Outcome {
        if let reason = availability.reason { return .unavailable(reason) }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        // Do not let one unlock silently authorise a second action minutes later.
        context.touchIDAuthenticationAllowableReuseDuration = 0

        // The Touch ID sheet belongs to whichever app is frontmost. For a
        // menu-bar-only app that is usually *not* us, so the prompt would appear
        // behind the user's editor and look like nothing happened.
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "VAKT needs to confirm it is you to \(action.rawValue).") { ok, error in
                if ok { continuation.resume(returning: .authorised); return }
                // Distinguish "the Mac cannot ask" from "the user said no", even
                // when it only surfaces at evaluation time.
                switch LAError.Code(rawValue: (error as? NSError)?.code ?? 0) {
                case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled, .notInteractive:
                    continuation.resume(returning: .unavailable(explain(error as NSError?)))
                default:
                    continuation.resume(returning: .refused)
                }
            }
        }
    }

    private static func explain(_ error: NSError?) -> String {
        switch LAError.Code(rawValue: error?.code ?? 0) {
        case .passcodeNotSet:
            return "This Mac has no login password. Set one in System Settings › "
                 + "Users & Groups — VAKT cannot protect its own controls without it."
        case .biometryNotEnrolled:
            return "No fingerprint is enrolled and the login password is unavailable."
        case .biometryNotAvailable:
            return "Biometrics and the login password are both unavailable on this Mac."
        case .notInteractive:
            return "Authentication cannot be shown right now."
        default:
            return error?.localizedDescription ?? "Authentication is unavailable on this Mac."
        }
    }
}
