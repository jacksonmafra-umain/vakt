import SwiftUI
import AppKit

/// Two bundles with the same identifier — the copy in `/Applications` and a build
/// from Xcode — each get their own status item, their own camera session and their
/// own opinion about locking the screen. `KeepAlive` in the LaunchAgent makes it
/// worse by relaunching one of them whenever it dies. Whoever started first wins;
/// the newcomer leaves quietly.
final class SingleInstance {
    static func enforce() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let mine = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let mineLaunched = mine.launchDate ?? Date()
        let anyOlder = others.contains { ($0.launchDate ?? .distantPast) < mineLaunched }
        guard anyOlder else { return }

        EventLog.shared.record("launch.duplicate",
                               "Another VAKT is already running; this copy is exiting.",
                               synchronously: true)
        exit(0)
    }
}

/// Launch-time work lives here, not in a view. A `.task` attached to the
/// `MenuBarExtra` label looked like a fine place for it until the label grew a
/// second modifier, at which point the task stopped running with no error —
/// taking first-run enrolment and update checks with it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        poller = Task { @MainActor in
            while !Task.isCancelled {
                let policy = PolicyStore.load()
                let updater = Updater.shared
                updater.installsAutomatically = policy.installUpdatesAutomatically
                if policy.checkForUpdates {
                    await updater.checkIfDue(interval: 86_400)
                    if policy.installUpdatesAutomatically,
                       case .available(let release) = updater.state {
                        await updater.download(release)
                    }
                }
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        poller?.cancel()
    }
}

@main
struct VAKTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var sentry = SentryController()
    @StateObject private var updater = Updater.shared

    init() {
        SingleInstance.enforce()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sentry: sentry, updater: updater)
        } label: {
            MenuBarLabel(symbol: symbol, needsEnrollment: !sentry.isEnrolled)
        }
        .menuBarExtraStyle(.window)

        // The only real window the app has. `LSUIElement` keeps it out of the
        // Dock, so it is opened explicitly from the menu.
        Window("Enrol your face", id: EnrollmentWindow.id) {
            EnrollmentView(sentry: sentry)
        }
        .windowResizability(.contentSize)
        // Without this the window opens wherever AppKit last cascaded to, which
        // for a Dock-less app can be off-screen entirely.
        .defaultPosition(.center)

        Window("About VAKT", id: AboutWindow.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(sentry: sentry)
        }
    }

    private var symbol: String {
        switch sentry.state {
        case .notEnrolled, .disarmed: return "eye.slash"
        case .ownerPresent:           return "eye.fill"
        case .locked:                 return "lock.fill"
        default:                      return "eye"
        }
    }
}

enum EnrollmentWindow {
    static let id = "enrolment"
}

enum AboutWindow {
    static let id = "about"
}

/// The status item's label is the only view that exists from launch, so it is
/// also where the first-run window is opened from: with no template there is
/// nothing VAKT can do, and a menu-bar-only app has no other way to say so.
private struct MenuBarLabel: View {
    let symbol: String
    let needsEnrollment: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var offered = false

    /// Keep this view trivial. Anything more than the image and one task and the
    /// task stops firing.
    var body: some View {
        Image(systemName: symbol)
            .task {
                guard needsEnrollment, !offered else { return }
                offered = true
                openWindow(id: EnrollmentWindow.id)
            }
    }
}
