import Foundation
import Vision
import CoreImage
import CoreVideo
import QuartzCore

/// Decides whether the face and the scene behind it are one rigid object.
///
/// A phone or a printed photo held in the hand carries its own background along
/// with the face: move the hand, and the "wall" behind the face moves by exactly
/// the same amount. In a real scene your head moves while the room stays put.
///
/// So: estimate the translation of patches *outside* the face box between two
/// frames, and compare it with the translation of the face itself. Sustained
/// agreement, while the face is clearly moving, means the face is painted onto
/// whatever is behind it.
///
/// This is deliberately independent of the homography check in `LivenessEngine`:
/// that one needs head rotation, this one needs translation, and a hand holding a
/// device supplies plenty of the latter.
final class SceneMotionEngine {

    struct Report {
        /// Fraction of recent moving samples where background and face agreed.
        var coupling: Double = 0
        var samples: Int = 0
        var heldObjectSuspected = false
    }

    struct Tuning {
        /// Do not sample every frame: each sample runs several registrations.
        var minInterval: CFTimeInterval = 0.25
        /// The face must move at least this fraction of frame width for the pair
        /// to say anything. Below it, everything looks equally still.
        var minFaceShift: Double = 0.010
        /// Background shift counts as agreeing with the face when it is at least
        /// this fraction of the face's, and points the same way.
        var agreementRatio: Double = 0.55
        var windowSeconds: CFTimeInterval = 20
        var minSamples: Int = 10
        /// Fraction of agreeing samples that means "held object".
        var couplingLimit: Double = 0.75
    }

    var tuning = Tuning()

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var previous: (image: CIImage, faceCentre: CGPoint, time: CFTimeInterval)?
    private var samples: [(t: CFTimeInterval, agreed: Bool)] = []

    func reset() {
        previous = nil
        samples.removeAll()
    }

    @discardableResult
    func ingest(pixelBuffer: CVPixelBuffer, sample: FaceSample) -> Report {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let centre = Geometry.centroid(sample.stable)
        let now = sample.time

        guard let last = previous else {
            previous = (image, centre, now)
            return report()
        }
        guard now - last.time >= tuning.minInterval else { return report() }
        previous = (image, centre, now)

        let width = Double(image.extent.width)
        let faceShift = CGVector(dx: centre.x - last.faceCentre.x, dy: centre.y - last.faceCentre.y)
        let faceMagnitude = faceShift.magnitude

        // Nothing moved. Silence is not evidence either way.
        guard faceMagnitude >= tuning.minFaceShift * width else { return report() }

        guard let background = backgroundShift(from: last.image, to: image,
                                               faceBox: faceBox(sample, in: image.extent)) else {
            return report()
        }

        let projected = background.dot(faceShift) / max(faceMagnitude, 1e-6)
        let agreed = projected >= tuning.agreementRatio * faceMagnitude
        samples.append((now, agreed))
        samples.removeAll { $0.t < now - tuning.windowSeconds }
        return report()
    }

    // MARK: - Internals

    private func report() -> Report {
        var r = Report()
        r.samples = samples.count
        guard r.samples > 0 else { return r }
        r.coupling = Double(samples.filter(\.agreed).count) / Double(r.samples)
        r.heldObjectSuspected = r.samples >= tuning.minSamples && r.coupling >= tuning.couplingLimit
        return r
    }

    private func faceBox(_ sample: FaceSample, in extent: CGRect) -> CGRect {
        let box = VNImageRectForNormalizedRect(sample.observation.boundingBox,
                                              Int(extent.width), Int(extent.height))
        // Pad generously: hair, shoulders and the device's own bezel are part of
        // the moving object, not background.
        return box.insetBy(dx: -box.width * 0.6, dy: -box.height * 0.6)
    }

    /// Median translation of the patches that do not overlap the face.
    private func backgroundShift(from previous: CIImage, to current: CIImage,
                                 faceBox: CGRect) -> CGVector? {
        let extent = current.extent
        let side = min(extent.width, extent.height) * 0.28
        let candidates = [
            CGRect(x: extent.minX, y: extent.minY, width: side, height: side),
            CGRect(x: extent.maxX - side, y: extent.minY, width: side, height: side),
            CGRect(x: extent.minX, y: extent.maxY - side, width: side, height: side),
            CGRect(x: extent.maxX - side, y: extent.maxY - side, width: side, height: side)
        ].filter { !$0.intersects(faceBox) }

        guard !candidates.isEmpty else { return nil }

        var shifts: [CGVector] = []
        for patch in candidates {
            guard let a = cgImage(previous.cropped(to: patch)),
                  let b = cgImage(current.cropped(to: patch)) else { continue }
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: b)
            guard (try? VNImageRequestHandler(cgImage: a, options: [:]).perform([request])) != nil,
                  let observation = request.results?.first as? VNImageTranslationAlignmentObservation
            else { continue }
            let t = observation.alignmentTransform
            shifts.append(CGVector(dx: t.tx, dy: t.ty))
        }
        guard shifts.count >= 2 else { return nil }

        return CGVector(dx: CGFloat(Geometry.median(shifts.map { Double($0.dx) })),
                        dy: CGFloat(Geometry.median(shifts.map { Double($0.dy) })))
    }

    private func cgImage(_ image: CIImage) -> CGImage? {
        guard image.extent.width > 8, image.extent.height > 8 else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}

struct CGVector {
    var dx: CGFloat
    var dy: CGFloat

    var magnitude: Double { Double(hypot(dx, dy)) }

    func dot(_ other: CGVector) -> Double {
        Double(dx * other.dx + dy * other.dy)
    }
}
