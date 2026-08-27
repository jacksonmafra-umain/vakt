import SwiftUI

/// Credits, version and the privacy claims in one place. The privacy lines are
/// not marketing: they are assertions the code has to keep true.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 2) {
                Text("VAKT").font(.title.weight(.semibold))
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Swedish for guard. Watches the camera, confirms the person at the keyboard "
                 + "is you, and locks the screen when it stops being true — without sleeping "
                 + "the machine, so background work keeps running.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                credit("Created by", "Jackson Mafra")
                credit("Liveness", "Non-rigid landmark deformation, blink and head micro-jitter")
                credit("Built with", "SwiftUI, AVFoundation, Vision, Core ML, LocalAuthentication")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                promise("No image or video is ever written to disk.")
                promise("No network code exists in this app.")
                promise("The face template is a set of vectors in the Keychain, this device only.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("© 2026 Jackson Mafra")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 420)
        .centredOnScreen()
    }

    private func credit(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func promise(_ text: String) -> some View {
        Label(text, systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
