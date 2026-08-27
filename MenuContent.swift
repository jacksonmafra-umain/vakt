import SwiftUI
import AppKit

struct MenuContent: View {
    @ObservedObject var sentry: SentryController
    @Environment(\.openWindow) private var openWindow
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status

            if sentry.isArmed {
                separator
                readings
            }

            separator

            if !sentry.isEnrolled {
                MenuRow("Enrol my face…", systemImage: "person.crop.circle.badge.plus") {
                    openEnrollment()
                }
            } else if sentry.isArmed {
                MenuRow("Disarm…", systemImage: "eye.slash") {
                    run { await sentry.requestDisarm() }
                }
                MenuRow("Lock now", systemImage: "lock.fill", shortcut: "⌘L") {
                    sentry.lockManually()
                }
            } else {
                MenuRow("Arm…", systemImage: "eye.fill") {
                    run { await sentry.requestArm() }
                }
                MenuRow("Re-enrol my face…", systemImage: "person.crop.circle.badge.plus") {
                    openEnrollment()
                }
                MenuRow("Forget my face…", systemImage: "trash") {
                    run { await sentry.forgetEnrollment() }
                }
            }

            separator

            SettingsLink {
                MenuRowLabel(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,")
            }
            .buttonStyle(MenuRowButtonStyle())

            MenuRow("About VAKT", systemImage: "info.circle") {
                openWindow(id: AboutWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }

            separator

            MenuRow("Quit VAKT…", systemImage: "power", shortcut: "⌘Q") {
                run { if await AuthGate.authenticate(for: .quit) { NSApp.terminate(nil) } }
            }
        }
        .padding(6)
        .frame(width: 268)
        .disabled(busy)
    }

    // MARK: - Sections

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The numbers that make a lock decision auditable while it is happening.
    private var readings: some View {
        VStack(spacing: 3) {
            reading("Liveness", String(format: "%.2f", sentry.lastLiveness.score))
            reading("Match", String(format: "%.2f", sentry.lastSimilarity))
            reading("Blink seen", sentry.lastLiveness.blinkObserved ? "yes" : "no")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func reading(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var separator: some View {
        Divider().padding(.vertical, 4)
    }

    // MARK: - Actions

    /// A menu-bar-only app opens windows behind everything else unless it is
    /// activated first.
    private func openEnrollment() {
        openWindow(id: EnrollmentWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    // MARK: - Status text

    private var statusColor: Color {
        switch sentry.state {
        case .disarmed, .notEnrolled: return .secondary
        case .ownerPresent:           return .green
        case .searching, .verifying:  return .yellow
        case .awaitingReturn:         return .orange
        case .locked:                 return .red
        }
    }

    private var statusTitle: String {
        switch sentry.state {
        case .notEnrolled:    return "Not set up"
        case .disarmed:       return "Disarmed"
        case .searching:      return "Watching"
        case .verifying:      return "Verifying"
        case .ownerPresent:   return "You're here"
        case .awaitingReturn: return "Waiting for you"
        case .locked:         return "Locked"
        }
    }

    private var statusDetail: String {
        switch sentry.state {
        case .notEnrolled:
            return "Enrol your face to get started. Nothing leaves this Mac."
        case .disarmed:
            return "The camera is off."
        case .searching:
            return "Sampling the camera in short bursts."
        case .verifying:
            return "A face is in frame. Confirming it is you, and that it is moving."
        case .ownerPresent:
            return "Face matched and confirmed live. Sleep is held off."
        case .awaitingReturn(let since):
            let left = max(0, sentry.policy.absenceGrace - Date().timeIntervalSince(since))
            return "You left frame. Locking in \(Int(left))s."
        case .locked(let reason):
            return reason.rawValue
        }
    }
}

// MARK: - Rows

/// A flat menu row: icon, title, shortcut hint, highlight on hover. `.window`
/// style gives us bordered push buttons by default, which reads as a form rather
/// than a menu.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    init(_ title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, systemImage: systemImage, shortcut: shortcut)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowLabel: View {
    let title: String
    let systemImage: String
    var shortcut: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 16, alignment: .center)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlight(pressed: configuration.isPressed))
            )
            .onHover { hovering = $0 && isEnabled }
    }

    private func highlight(pressed: Bool) -> Color {
        if pressed { return .accentColor.opacity(0.75) }
        return hovering ? .primary.opacity(0.12) : .clear
    }
}
