import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while VAKT is armed, so that locking the screen because
/// you walked away does not also stop whatever your agents are doing.
///
/// `PreventUserIdleSystemSleep` stops idle *system* sleep. The display is still
/// allowed to sleep, which is what you want: dark screen, machine running.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    func hold(reason: String = "VAKT is armed; background work must continue") {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        isHeld = (result == kIOReturnSuccess)
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
        id = 0
    }

    deinit { release() }
}
