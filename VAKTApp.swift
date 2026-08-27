import SwiftUI
import AppKit

@main
struct VAKTApp: App {
    @StateObject private var sentry = SentryController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sentry: sentry)
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

    var body: some View {
        Image(systemName: symbol)
            .task {
                guard needsEnrollment, !offered else { return }
                offered = true
                openWindow(id: EnrollmentWindow.id)
            }
    }
}
