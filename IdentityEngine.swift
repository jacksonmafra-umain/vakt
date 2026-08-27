import Foundation
import Vision
import CoreImage
import CoreML
import CoreVideo

/// Turns a detected face into a comparable vector.
protocol FaceEmbedder {
    var identifier: String { get }
    /// Length of a returned vector; used to reject templates from another embedder.
    func embed(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float]
}

enum EmbedError: Error { case cropFailed, inferenceFailed, modelMissing }

// MARK: - Aligned crop

enum FaceCrop {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Crop around the face, de-rotated by the observed roll, padded by `pad`.
    static func aligned(pixelBuffer: CVPixelBuffer,
                        face: VNFaceObservation,
                        side: Int = 160,
                        pad: CGFloat = 0.30) throws -> CGImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent

        let roll = CGFloat(face.roll?.doubleValue ?? 0)
        var box = VNImageRectForNormalizedRect(face.boundingBox,
                                               Int(extent.width), Int(extent.height))

        if abs(roll) > 0.02 {
            let c = CGPoint(x: box.midX, y: box.midY)
            image = image
                .transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y))
                .transformed(by: CGAffineTransform(rotationAngle: -roll))
                .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
        }

        box = box.insetBy(dx: -box.width * pad, dy: -box.height * pad)
            .intersection(extent)
        guard !box.isNull, box.width > 24, box.height > 24 else { throw EmbedError.cropFailed }

        let cropped = image.cropped(to: box)
        let scale = CGFloat(side) / max(box.width, box.height)
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            throw EmbedError.cropFailed
        }
        return cg
    }
}

// MARK: - Zero-dependency baseline

/// Uses Vision's general-purpose image descriptor on the aligned face crop.
/// Ships with the OS, needs no model file — but it is an *image similarity*
/// descriptor, not an identity descriptor. It separates you from a stranger
/// reasonably well under stable lighting and is a poor choice for lookalikes.
/// Good enough to get running today; swap in `CoreMLFaceEmbedder` for real use.
final class FeaturePrintEmbedder: FaceEmbedder {
    let identifier = "vision.featureprint.v1"

    func embed(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        let cg = try FaceCrop.aligned(pixelBuffer: pixelBuffer, face: face)
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        guard let obs = request.results?.first as? VNFeaturePrintObservation else {
            throw EmbedError.inferenceFailed
        }
        var out = [Float](repeating: 0, count: obs.elementCount)
        obs.data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            for i in 0..<min(obs.elementCount, src.count) { out[i] = src[i] }
        }
        return VectorMath.l2Normalized(out)
    }
}

// MARK: - Recommended path

/// Drop a face-embedding model (FaceNet / ArcFace / MobileFaceNet converted to
/// Core ML) into the bundle. Expects a single image input and a 1-D float output.
final class CoreMLFaceEmbedder: FaceEmbedder {
    let identifier: String
    private let model: VNCoreMLModel
    private let side: Int

    init(modelName: String, inputSide: Int = 160) throws {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodel") else {
            throw EmbedError.modelMissing
        }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        self.model = try VNCoreMLModel(for: try MLModel(contentsOf: compiled, configuration: config))
        self.identifier = "coreml.\(modelName).v1"
        self.side = inputSide
    }

    func embed(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        let cg = try FaceCrop.aligned(pixelBuffer: pixelBuffer, face: face, side: side)
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

        if let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
           let arr = obs.featureValue.multiArrayValue {
            var out = [Float](repeating: 0, count: arr.count)
            for i in 0..<arr.count { out[i] = arr[i].floatValue }
            return VectorMath.l2Normalized(out)
        }
        throw EmbedError.inferenceFailed
    }
}

enum VectorMath {
    static func l2Normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard n > 1e-8 else { return v }
        return v.map { $0 / n }
    }

    /// Both vectors are expected L2-normalised, so this is a plain dot product.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}

// MARK: - Matching

struct IdentityDecision {
    enum Outcome { case owner, stranger, inconclusive }
    let outcome: Outcome
    let similarity: Float
}

final class IdentityEngine {
    private let embedder: FaceEmbedder
    private var template: OwnerTemplate?

    /// Calibrate this. For FaceNet-style embeddings ~0.62 is a sane start.
    /// For `FeaturePrintEmbedder` you will typically need something higher.
    var acceptThreshold: Float
    /// Below this we actively call "stranger" rather than "inconclusive".
    var rejectThreshold: Float
    /// Skip frames Vision rates as low quality — a blurry crop produces a
    /// low similarity score for the owner too, and that is a false lock.
    var minCaptureQuality: Float = FaceQuality.minimum

    init(embedder: FaceEmbedder,
         template: OwnerTemplate?,
         acceptThreshold: Float = 0.62,
         rejectThreshold: Float = 0.45) {
        self.embedder = embedder
        self.template = template
        self.acceptThreshold = acceptThreshold
        self.rejectThreshold = rejectThreshold
    }

    var isEnrolled: Bool { (template?.vectors.isEmpty == false) }

    func updateTemplate(_ t: OwnerTemplate?) { template = t }

    func embedderIdentifier() -> String { embedder.identifier }

    func embed(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        try embedder.embed(pixelBuffer: pixelBuffer, face: face)
    }

    func match(pixelBuffer: CVPixelBuffer, sample: FaceSample) -> IdentityDecision {
        guard let template, !template.vectors.isEmpty else {
            return IdentityDecision(outcome: .inconclusive, similarity: 0)
        }
        guard template.embedderIdentifier == embedder.identifier else {
            // Template came from a different model; refuse to compare.
            return IdentityDecision(outcome: .inconclusive, similarity: 0)
        }
        guard sample.captureQuality >= minCaptureQuality else {
            return IdentityDecision(outcome: .inconclusive, similarity: 0)
        }
        guard let v = try? embedder.embed(pixelBuffer: pixelBuffer, face: sample.observation) else {
            return IdentityDecision(outcome: .inconclusive, similarity: 0)
        }

        let best = template.vectors.map { VectorMath.cosine(v, $0) }.max() ?? -1
        if best >= acceptThreshold { return IdentityDecision(outcome: .owner, similarity: best) }
        if best <= rejectThreshold { return IdentityDecision(outcome: .stranger, similarity: best) }
        return IdentityDecision(outcome: .inconclusive, similarity: best)
    }
}
