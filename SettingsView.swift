import SwiftUI

struct SettingsView: View {
    @ObservedObject var sentry: SentryController
    @State private var draft: Policy = PolicyStore.load()
    @State private var message: String?

    var body: some View {
        Form {
            Section("Timing") {
                Stepper("Lock \(Int(draft.absenceGrace))s after I leave frame",
                        value: $draft.absenceGrace, in: 5...180, step: 5)
                Stepper("Tolerate a still, matching face for \(Int(draft.spoofGrace))s",
                        value: $draft.spoofGrace, in: 3...30, step: 1)
                Stepper("Lock \(Int(draft.strangerGrace))s after a stranger appears",
                        value: $draft.strangerGrace, in: 0...15, step: 1)
            }
            Section("Rules") {
                Toggle("Lock if the camera is covered", isOn: $draft.lockOnObstruction)
                Toggle("Lock if a second face appears", isOn: $draft.lockOnSecondFace)
                Toggle("Keep the Mac awake while armed", isOn: $draft.holdSystemAwake)
                Toggle("Re-arm after I unlock the Mac", isOn: $draft.rearmAfterUnlock)
                Toggle("Start watching as soon as VAKT launches", isOn: $draft.armAtLaunch)
            }
            Section("Camera duty cycle") {
                Stepper("Sample \(draft.idleBurstOn, specifier: "%.1f")s",
                        value: $draft.idleBurstOn, in: 1...10, step: 0.5)
                Stepper("every \(Int(draft.idleBurstEvery))s while idle",
                        value: $draft.idleBurstEvery, in: 3...60, step: 1)
            }
            Section("Authorisation") {
                LabeledContent("Changes are confirmed with") {
                    Text(AuthGate.availability.summary)
                        .foregroundStyle(AuthGate.availability.reason == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Button("Save…") {
                    Task {
                        switch await AuthGate.authenticate(for: .changeRules) {
                        case .authorised:
                            break
                        case .refused:
                            message = "Not saved — authentication failed."
                            return
                        case .unavailable(let reason):
                            // Loosening the rules is a weakening, so it stays shut.
                            message = "Not saved. \(reason)"
                            return
                        }
                        PolicyStore.save(draft)
                        sentry.policy = draft
                        message = "Saved."
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
