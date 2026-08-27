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
enum AuthGate {

    enum Action: String {
        case disarm      = "disarm VAKT"
        case arm         = "arm VAKT"
        case enroll      = "enrol your face"
        case forget      = "delete your enrolled face"
        case changeRules = "change VAKT's rules"
        case quit        = "quit VAKT"
    }

    static func authenticate(for action: Action) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        // Do not let one unlock silently authorise a second action minutes later.
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        // The Touch ID sheet belongs to whichever app is frontmost. For a
        // menu-bar-only app that is usually *not* us, so the prompt would appear
        // behind the user's editor and look like nothing happened.
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "VAKT needs to confirm it is you to \(action.rawValue).") { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}
