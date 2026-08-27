import SwiftUI

@main
struct VAKTApp: App {
    @StateObject private var sentry = SentryController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sentry: sentry)
        } label: {
            Image(systemName: symbol)
        }
        .menuBarExtraStyle(.window)

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
