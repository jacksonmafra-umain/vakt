import SwiftUI

struct MenuContent: View {
    @ObservedObject var sentry: SentryController
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusTitle).font(.headline)
            }
            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sentry.isArmed {
                Divider()
                LabeledContent("Liveness") {
                    Text(String(format: "%.2f", sentry.lastLiveness.score)).monospacedDigit()
                }
                LabeledContent("Match") {
                    Text(String(format: "%.2f", sentry.lastSimilarity)).monospacedDigit()
                }
                .font(.caption)
                LabeledContent("Blink seen") {
                    Text(sentry.lastLiveness.blinkObserved ? "yes" : "no")
                }
                .font(.caption)
            }

            Divider()

            if !sentry.isEnrolled {
                Button("Enrol my face…") { run { await sentry.beginEnrollment() } }
            } else if sentry.isArmed {
                Button("Disarm…") { run { await sentry.requestDisarm() } }
                Button("Lock now") { sentry.lockManually() }
            } else {
                Button("Arm…") { run { await sentry.requestArm() } }
                Button("Re-enrol my face…") { run { await sentry.beginEnrollment() } }
                Button("Forget my face…") { run { await sentry.forgetEnrollment() } }
            }

            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit VAKT…") {
                run {
                    if await AuthGate.authenticate(for: .quit) { NSApp.terminate(nil) }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .disabled(busy)
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

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
