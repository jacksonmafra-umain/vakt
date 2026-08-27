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
    /// Camera — or a virtual camera feeding synthetic frames — cannot silently
    /// become the sensor of record. Set from the enrolled template.
    var pinnedDeviceUniqueID: String?

    /// Allow a non-built-in camera. Off by default: a virtual camera is the
    /// cheapest way to defeat every optical liveness signal at once, because
    /// there is no physical scene left to measure.
    var allowsExternalCameras = false

    /// The camera actually in use, once configured.
    private(set) var activeDeviceUniqueID: String?

    enum CameraProblem: Error, Equatable {
        case noneFound
        case pinnedCameraMissing(String)
        case notBuiltIn(String)

        var message: String {
            switch self {
            case .noneFound:
                return "No usable camera found."
            case .pinnedCameraMissing:
                return "The camera you enrolled with is not present. VAKT will not "
                     + "watch through a different sensor — reconnect it, or re-enrol."
            case .notBuiltIn(let name):
                return "\"\(name)\" is not the built-in camera. A virtual or external "
                     + "camera can feed VAKT any video at all, so it is refused."
            }
        }
    }

    private let session = AVCaptureSession()

    /// Exposed so the enrolment window can attach an `AVCaptureVideoPreviewLayer`.
    /// A preview layer is a second *sink* on the same session, not a second
    /// session — two sessions on one camera contend and one of them fails.
    var previewSession: AVCaptureSession { session }
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

    /// Nil on success, otherwise why no camera was acceptable.
    func selectDevice() -> Result<AVCaptureDevice, CameraProblem> {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)

        if let id = pinnedDeviceUniqueID {
            guard let device = discovery.devices.first(where: { $0.uniqueID == id }) else {
                return .failure(.pinnedCameraMissing(id))
            }
            return .success(device)
        }

        let builtIn = discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
        if let builtIn { return .success(builtIn) }

        guard let fallback = discovery.devices.first else { return .failure(.noneFound) }
        guard allowsExternalCameras else { return .failure(.notBuiltIn(fallback.localizedName)) }
        return .success(fallback)
    }

    private func configure() -> Bool {
        guard !configured else { return true }

        let device: AVCaptureDevice
        switch selectDevice() {
        case .success(let d):
            device = d
        case .failure(let problem):
            onFailure?(problem.message)
            return false
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            onFailure?(CameraProblem.noneFound.message)
            return false
        }
        activeDeviceUniqueID = device.uniqueID

        session.beginConfiguration()
        // 720p, falling back to medium. 640x480 finds landmarks fine but Vision
        // rates the crop's capture quality low, which starves enrolment and
        // makes the identity match skip frames.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium
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
