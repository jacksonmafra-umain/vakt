import Foundation
import AVFoundation
import CoreVideo

/// Owns the camera. Duty-cycles it so the machine is not streaming video 24/7:
/// while nothing is happening we sample in short bursts; once a face shows up we
/// stay on continuously until it settles again.
///
/// Note: the camera privacy LED is wired to the sensor in hardware. It *will*
/// light up whenever we sample, and no software can suppress that. Treat the
/// blinking LED as an honest indicator that VAKT is armed.
final class CaptureEngine: NSObject {

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        /// Mean luma 0...1, sampled sparsely. Used to notice a covered lens.
        let luma: Double
    }

    enum Cadence {
        case burst(onSeconds: Double, everySeconds: Double)
        case continuous
    }

    var onFrame: ((Frame) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Pin a specific camera by `uniqueID` so an iPhone joining as Continuity
    /// Camera cannot silently become the sensor of record.
    var preferredDeviceUniqueID: String?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "vakt.capture", qos: .userInitiated)
    private var configured = false
    private var dutyTimer: DispatchSourceTimer?
    private(set) var cadence: Cadence = .burst(onSeconds: 2.5, everySeconds: 9)

    // MARK: Lifecycle

    func start(cadence: Cadence) {
        self.cadence = cadence
        queue.async { [weak self] in
            guard let self else { return }
            guard self.configure() else { return }
            self.applyCadence()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.dutyTimer?.cancel(); self.dutyTimer = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func setCadence(_ new: Cadence) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cadence = new
            self.applyCadence()
        }
    }

    // MARK: Internals

    private func applyCadence() {
        dutyTimer?.cancel(); dutyTimer = nil
        switch cadence {
        case .continuous:
            if !session.isRunning { session.startRunning() }
        case .burst(let on, let every):
            if !session.isRunning { session.startRunning() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + on, repeating: every)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                    self.queue.asyncAfter(deadline: .now() + max(0.5, every - on)) {
                        if case .burst = self.cadence, !self.session.isRunning {
                            self.session.startRunning()
                        }
                    }
                }
            }
            timer.resume()
            dutyTimer = timer
        }
    }

    private func configure() -> Bool {
        guard !configured else { return true }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified)

        let device: AVCaptureDevice? = {
            if let id = preferredDeviceUniqueID {
                return discovery.devices.first { $0.uniqueID == id }
            }
            return discovery.devices.first
        }()

        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            onFailure?("No usable camera found.")
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = .medium          // 640x480-ish is plenty for landmarks
        if session.canAddInput(input) { session.addInput(input) }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        configured = true
        return true
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(Frame(pixelBuffer: pb, luma: CaptureEngine.meanLuma(pb)))
    }

    /// Sparse mean of the Y plane. Cheap enough to run on every frame.
    static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)

        var total = 0, count = 0
        for y in Swift.stride(from: 0, to: h, by: 8) {
            for x in Swift.stride(from: 0, to: w, by: 8) {
                total += Int(p[y * stride + x]); count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) / 255.0 : 0
    }
}
