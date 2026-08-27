import Foundation
import Vision
import CoreVideo
import CoreGraphics
import QuartzCore

/// One analysed frame. All landmark points are in image pixel coordinates
/// (Vision origin: lower-left).
struct FaceSample {
    let time: CFTimeInterval
    let observation: VNFaceObservation

    /// Points that move with expression: eyes, eyebrows, lips.
    let expressive: [CGPoint]
    /// Points that are (nearly) rigid w.r.t. the skull: nose ridge, crest, contour.
    let stable: [CGPoint]

    let leftEye: [CGPoint]
    let rightEye: [CGPoint]

    let yaw: Double
    let pitch: Double
    let roll: Double

    /// Distance between eye centroids. Every other measurement is normalised by
    /// this, so "how close you sit to the camera" does not move the thresholds.
    let interocular: CGFloat

    let captureQuality: Float
}

/// Thin wrapper over Vision. Produces zero or more `FaceSample` per frame.
final class FaceAnalyzer {

    private let sequenceHandler = VNSequenceRequestHandler()

    /// macOS delivers `AVCaptureVideoDataOutput` frames upright, so `.up` is
    /// correct for the built-in camera. Revisit if you pin an external camera.
    var orientation: CGImagePropertyOrientation = .up

    func analyze(pixelBuffer: CVPixelBuffer) -> [FaceSample] {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let now = CACurrentMediaTime()

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3

        do {
            try sequenceHandler.perform([landmarks], on: pixelBuffer, orientation: orientation)
        } catch {
            return []
        }
        guard let faces = landmarks.results, !faces.isEmpty else { return [] }

        // Second pass: capture quality, used to gate identity matching so we
        // never compare against a motion-blurred or badly lit crop.
        var qualityByUUID: [UUID: Float] = [:]
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        if (try? sequenceHandler.perform([quality], on: pixelBuffer, orientation: orientation)) != nil,
           let scored = quality.results {
            for obs in scored { qualityByUUID[obs.uuid] = obs.faceCaptureQuality ?? 0 }
        }

        return faces.compactMap { face in
            guard let lm = face.landmarks else { return nil }

            func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                region?.pointsInImage(imageSize: imageSize) ?? []
            }

            let leftEye = pts(lm.leftEye)
            let rightEye = pts(lm.rightEye)

            let expressive = leftEye + rightEye
                + pts(lm.leftEyebrow) + pts(lm.rightEyebrow)
                + pts(lm.outerLips) + pts(lm.innerLips)

            let stable = pts(lm.nose) + pts(lm.noseCrest)
                + pts(lm.medianLine) + pts(lm.faceContour)

            guard expressive.count >= 8, stable.count >= 6 else { return nil }

            let lc = Geometry.centroid(leftEye)
            let rc = Geometry.centroid(rightEye)
            let interocular = hypot(lc.x - rc.x, lc.y - rc.y)
            guard interocular > 8 else { return nil }   // too small / too far away

            return FaceSample(
                time: now,
                observation: face,
                expressive: expressive,
                stable: stable,
                leftEye: leftEye,
                rightEye: rightEye,
                yaw: face.yaw?.doubleValue ?? 0,
                pitch: face.pitch?.doubleValue ?? 0,
                roll: face.roll?.doubleValue ?? 0,
                interocular: interocular,
                captureQuality: qualityByUUID[face.uuid] ?? 0
            )
        }
    }
}

/// One bar for "is this frame worth trusting", shared by enrolment and matching.
/// Enrolling from frames worse than the ones matching will accept builds a
/// template the watcher can never match; enrolling from a stricter bar than
/// matching makes enrolment impossible in ordinary indoor light. Vision rates a
/// correctly exposed webcam face at roughly 0.35, a backlit or blurred one below
/// 0.25.
enum FaceQuality {
    static let minimum: Float = 0.30
}

enum Geometry {
    static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for q in p { x += q.x; y += q.y }
        return CGPoint(x: x / CGFloat(p.count), y: y / CGFloat(p.count))
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }

    static func stdDev(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
    }
}

/// 2D similarity transform: rotation + uniform scale + translation.
struct SimilarityTransform {
    let scale: Double
    let theta: Double
    let fromCentroid: CGPoint
    let toCentroid: CGPoint

    func apply(_ p: CGPoint) -> CGPoint {
        let dx = Double(p.x - fromCentroid.x)
        let dy = Double(p.y - fromCentroid.y)
        let c = cos(theta), s = sin(theta)
        return CGPoint(x: toCentroid.x + CGFloat(scale * (c * dx - s * dy)),
                       y: toCentroid.y + CGFloat(scale * (s * dx + c * dy)))
    }

    /// Closed-form Procrustes fit. Returns nil for degenerate input.
    static func fit(from a: [CGPoint], to b: [CGPoint]) -> SimilarityTransform? {
        guard a.count == b.count, a.count >= 3 else { return nil }
        let ac = Geometry.centroid(a), bc = Geometry.centroid(b)
        var n1 = 0.0, n2 = 0.0, den = 0.0
        for i in 0..<a.count {
            let px = Double(a[i].x - ac.x), py = Double(a[i].y - ac.y)
            let qx = Double(b[i].x - bc.x), qy = Double(b[i].y - bc.y)
            n1 += px * qx + py * qy
            n2 += px * qy - py * qx
            den += px * px + py * py
        }
        guard den > 1e-6 else { return nil }
        return SimilarityTransform(scale: sqrt(n1 * n1 + n2 * n2) / den,
                                   theta: atan2(n2, n1),
                                   fromCentroid: ac,
                                   toCentroid: bc)
    }
}
