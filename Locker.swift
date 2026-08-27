import Foundation
import AppKit

/// Locks the screen without putting the machine to sleep.
///
/// This matters for your case: the agents must keep running while the screen is
/// locked. Locking the *screen* never suspends processes; what would suspend
/// them is system idle sleep, which `PowerAssertion` holds off separately.
enum Locker {

    private static var lastLock: Date = .distantPast
    /// Avoid re-firing the lock every second while the screen is already locked.
    private static let debounce: TimeInterval = 10

    static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    @discardableResult
    static func lockNow() -> Bool {
        guard Date().timeIntervalSince(lastLock) > debounce else { return true }
        guard !isScreenLocked else { return true }
        lastLock = Date()

        if lockViaLoginFramework() { return true }
        return lockViaCGSession()
    }

    /// `SACLockScreenImmediate` is private API. It is the fastest and cleanest
    /// path and is what most third-party lock utilities use. It will not pass
    /// App Store review — irrelevant for a personal build, but keep the
    /// `CGSession` fallback so the app still works if the symbol ever moves.
    private static func lockViaLoginFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias Fn = @convention(c) () -> Int32
        return unsafeBitCast(sym, to: Fn.self)() == 0
    }

    /// Public fallback: switch to the login window via fast user switching.
    private static func lockViaCGSession() -> Bool {
        let url = URL(fileURLWithPath:
            "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let p = Process()
        p.executableURL = url
        p.arguments = ["-suspend"]
        do { try p.run() } catch { return false }
        return true
    }
}
