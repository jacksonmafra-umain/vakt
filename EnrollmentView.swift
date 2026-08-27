import SwiftUI
import AppKit
import AVFoundation

/// The one window VAKT ever shows. Enrolling blind — no preview, no reason for a
/// rejected frame — is indistinguishable from a broken camera, so this screen
/// exists to make the capture legible while it happens.
struct EnrollmentView: View {
    @ObservedObject var sentry: SentryController
    @Environment(\.dismiss) private var dismiss

    @State private var starting = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            header

            CameraPreview(session: sentry.previewSession)
                .frame(width: 420, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .overlay { if !sentry.isEnrolling { idleOverlay } }

            if let status = sentry.enrollmentStatus {
                progress(status)
            } else if failed {
                Text("Authentication failed. Nothing was captured.")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("VAKT will ask for Touch ID, then capture 18 views of your face. "
                     + "Nothing leaves this Mac and no image is stored — only vectors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 420)
            }

            buttons
        }
        .padding(20)
        .frame(width: 460)
        .centredOnScreen()
        .onDisappear { sentry.cancelEnrollment() }
        // The capture completes on its own; close as soon as it stops running.
        .onChange(of: sentry.isEnrolling) { was, now in
            if was && !now { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(sentry.isEnrolled ? "Re-enrol your face" : "Enrol your face")
                .font(.title2.weight(.semibold))
            Text("Look at the camera and turn your head slowly: left, right, up, down.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var idleOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.55))
            VStack(spacing: 6) {
                Image(systemName: "video.slash").font(.largeTitle)
                Text("The camera is off until you start.").font(.callout)
            }
            .foregroundStyle(.white)
        }
    }

    private func progress(_ status: SentryController.EnrollmentStatus) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: status.progress) {
                Text("\(status.captured) of \(status.target) captured")
                    .font(.callout.monospacedDigit())
            }
            .frame(width: 420)

            Label(status.feedback.message, systemImage: icon(for: status.feedback))
                .font(.callout)
                .foregroundStyle(status.feedback == .accepted ? Color.green : .secondary)
                .frame(width: 420, alignment: .leading)

            HStack(spacing: 18) {
                gauge("Liveness", String(format: "%.2f", status.livenessScore))
                gauge("Quality", String(format: "%.2f", status.quality))
                gauge("Blink", status.blinkObserved ? "yes" : "no")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func gauge(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
    }

    private func icon(for feedback: EnrollmentFeedback) -> String {
        switch feedback {
        case .accepted:   return "checkmark.circle.fill"
        case .noFace:     return "person.slash"
        case .tooFar:     return "arrow.up.left.and.arrow.down.right"
        case .lowQuality: return "camera.metering.unknown"
        case .notLive:    return "eye"
        case .tooSimilar: return "arrow.triangle.2.circlepath"
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") {
                sentry.cancelEnrollment()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(sentry.isEnrolling ? "Capturing…" : "Start") {
                starting = true
                Task {
                    let ok = await sentry.beginEnrollment()
                    failed = !ok
                    starting = false
                    // The Touch ID sheet hands focus back to whatever was
                    // frontmost before it. Take it back, or the user ends up
                    // enrolling into a window they cannot see.
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.keyWindow?.orderFrontRegardless()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(starting || sentry.isEnrolling)
        }
        .frame(width: 420)
    }
}

/// `AVCaptureVideoPreviewLayer` on the sentry's own session. Mirrored, because a
/// preview of yourself that is not mirrored makes people turn the wrong way.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session: session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    /// The layer has to be resized from `layout()`. `updateNSView` only runs when
    /// SwiftUI state changes, which is not when AppKit hands the view its bounds —
    /// leaving the preview layer at zero size and the panel black.
    final class PreviewView: NSView {
        private let preview = AVCaptureVideoPreviewLayer()

        func attach(session: AVCaptureSession) {
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor

            preview.session = session
            preview.videoGravity = .resizeAspectFill
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            layer?.addSublayer(preview)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}

/// An accessory app (`LSUIElement`) has no Dock icon, so nothing brings its
/// windows forward for it: SwiftUI restores the last frame — which can be
/// off-screen or on another Space — and whatever the user was using stays in
/// front. Claim the front explicitly, on the Space that is actually visible.
///
/// `openWindow` returns before the window exists, so activating from the call
/// site is too early. This runs once the view is in a window, which is not.
struct WindowFronting: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("")
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func centredOnScreen() -> some View {
        background(WindowFronting().frame(width: 0, height: 0))
    }
}
