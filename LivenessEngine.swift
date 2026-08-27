import Foundation
import CoreGraphics

/// Result of the rolling liveness evaluation.
struct LivenessReport {
    enum Verdict { case live, spoofSuspected, undecided }

    var verdict: Verdict = .undecided
    var score: Double = 0

    /// Non-rigid facial deformation, normalised by interocular distance and by
    /// the detector's own noise floor. This is the signal a flat photo cannot fake.
    var nonRigidEnergy: Double = 0
    var blinkObserved: Bool = false
    /// Out-of-plane reprojection error per radian of head rotation, normalised by
    /// interocular distance. A head has depth, so rotating it breaks any single
    /// homography; a panel does not, whatever the content on it is doing.
    var parallaxPerRadian: Double = 0
    var parallaxSamples: Int = 0
    /// The face deforms and blinks, but its geometry is provably flat.
    var planarReplaySuspected: Bool = false
    /// Rotation produced real parallax: this is a volume, not a plane. Used to
    /// veto the scene-coupling check, which cannot tell a held device from a
    /// camera that moved — a nudged desk shifts face and room together too.
    var depthConfirmed: Bool = false
    /// Head micro-motion. Near zero means a *mounted* photo (or a statue).
    var poseJitter: Double = 0
    var samples: Int = 0
}

/// Decides whether the face in front of the camera is a living head or a picture
/// of one, using RGB only. Macs have no TrueDepth / IR sensor, so there is no
/// depth channel to lean on — everything here is geometric and temporal.
///
/// The central idea:
///
///   A photograph — printed, or a face on a phone screen — is a **rigid plane**.
///   When someone holds it up, every landmark on it moves under one single
///   rotation + scale + translation. A real head does not: while the skull moves
///   rigidly, the eyelids, brows and lips move *independently* of it.
///
///   So we fit a similarity transform using only the rigid landmarks (nose ridge,
///   nose crest, median line, face contour), then apply that transform to the
///   expressive landmarks (eyes, brows, lips) and measure how far off they land.
///   For a photo the leftover residual is pure detector jitter. For a live face
///   it is consistently larger.
///
///   We subtract the residual of the rigid points themselves, which *is* the
///   detector's noise floor, so the metric survives poor lighting and low frame
///   rates without recalibration.
final class LivenessEngine {

    struct Tuning {
        /// Rolling window length in seconds.
        var windowSeconds: Double = 6.0
        /// Minimum frame pairs before we are willing to call spoof.
        var minSamples: Int = 24
        /// And they must span this long. 24 pairs arrive in under a second at
        /// 30fps — long enough to catch someone mid-blink and call them a photo.
        /// A spoof verdict is a screen lock, so it has to earn real time. Raised
        /// to 10s after two observed false locks on a reading, still owner, where
        /// the score sat at 0.247 and 0.222 against a 0.25 floor while identity
        /// was 0.88 and 0.90 confident.
        var minSpanSeconds: Double = 10.0
        /// Non-rigid displacement, as a fraction of interocular distance, that
        /// counts as a fully "alive" face. ~2% ≈ a visible blink or lip move.
        var fullMotion: Double = 0.020
        /// Relative eye-opening collapse that counts as a blink.
        var blinkDropRatio: Double = 0.35
        /// Head rotation std-dev (radians) above which the head is "not mounted".
        var jitterFloor: Double = 0.006     // ≈ 0.35°
        /// score >= liveAt  -> live
        var liveAt: Double = 0.50
        /// score <= spoofAt -> spoof (only once the window is full)
        var spoofAt: Double = 0.25

        /// A frame pair must rotate at least this much (radians) before its
        /// homography residual says anything: with no rotation there is no
        /// parallax to miss, and a head looks exactly as flat as a screen.
        var parallaxMinRotation: Double = 0.04      // ≈ 2.3°
        var parallaxMinSamples: Int = 12
        /// Below this, rotation produced no depth. Real faces measured well above.
        var planarityFloor: Double = 0.04
        /// Rotation pairs are rare compared to frames, so they get their own,
        /// much longer window.
        var parallaxWindowSeconds: Double = 60

        var weightMotion: Double = 0.55
        var weightBlink: Double = 0.35
        var weightJitter: Double = 0.10
    }

    var tuning = Tuning()

    private var previous: FaceSample?
    private var energies: [(t: CFTimeInterval, v: Double)] = []
    private var openness: [(t: CFTimeInterval, v: Double)] = []
    private var yaws: [(t: CFTimeInterval, v: Double)] = []
    private var pitches: [(t: CFTimeInterval, v: Double)] = []
    private var parallax: [(t: CFTimeInterval, v: Double)] = []

    func reset() {
        previous = nil
        energies.removeAll(); openness.removeAll()
        yaws.removeAll(); pitches.removeAll(); parallax.removeAll()
    }

    @discardableResult
    func ingest(_ sample: FaceSample) -> LivenessReport {
        defer { previous = sample }

        if let prev = previous, sample.time - prev.time < 0.5 {
            if let e = nonRigidEnergy(prev: prev, curr: sample) {
                energies.append((sample.time, e))
            }
            if let p = parallaxRatio(prev: prev, curr: sample) {
                parallax.append((sample.time, p))
            }
        } else if previous != nil {
            // Gap in the stream (duty-cycled camera). Drop the pairing, keep history.
            previous = nil
        }

        openness.append((sample.time, eyeOpenness(sample)))
        yaws.append((sample.time, sample.yaw))
        pitches.append((sample.time, sample.pitch))
        trim(before: sample.time - tuning.windowSeconds)

        return evaluate()
    }

    /// Call when the face disappears for a while.
    func decay() { reset() }

    // MARK: - Signals

    private func nonRigidEnergy(prev: FaceSample, curr: FaceSample) -> Double? {
        guard prev.stable.count == curr.stable.count,
              prev.expressive.count == curr.expressive.count,
              let t = SimilarityTransform.fit(from: prev.stable, to: curr.stable)
        else { return nil }

        // Residual on the rigid set == detector noise for this frame pair.
        var noise: [Double] = []
        for i in 0..<prev.stable.count {
            let p = t.apply(prev.stable[i])
            noise.append(Double(hypot(p.x - curr.stable[i].x, p.y - curr.stable[i].y)))
        }

        // Residual on the expressive set == noise + real deformation.
        var signal: [Double] = []
        for i in 0..<prev.expressive.count {
            let p = t.apply(prev.expressive[i])
            signal.append(Double(hypot(p.x - curr.expressive[i].x, p.y - curr.expressive[i].y)))
        }

        let iod = Double(curr.interocular)
        guard iod > 0 else { return nil }

        // 75th percentile on the signal: a blink only deforms part of the set,
        // so the median would wash it out.
        let deformation = Geometry.percentile(signal, 0.75) - Geometry.median(noise)
        return max(0, deformation / iod)
    }

    /// Reprojection error the best-fit homography cannot absorb, per radian of
    /// rotation, normalised by interocular distance. Returns nil when the pair
    /// did not rotate enough to carry information.
    private func parallaxRatio(prev: FaceSample, curr: FaceSample) -> Double? {
        let rotation = abs(curr.yaw - prev.yaw) + abs(curr.pitch - prev.pitch)
        guard rotation >= tuning.parallaxMinRotation else { return nil }

        let a = prev.stable + prev.expressive
        let b = curr.stable + curr.expressive
        guard a.count == b.count, a.count >= 8,
              let h = Homography.fit(from: a, to: b) else { return nil }

        let iod = Double(curr.interocular)
        guard iod > 0 else { return nil }
        return (Homography.residual(h, from: a, to: b) / iod) / rotation
    }

    /// Eye aperture as height/width in the eye's own frame, averaged over both
    /// eyes. Index-order independent: we derive the long axis from the two
    /// farthest-apart points rather than assuming a contour ordering.
    private func eyeOpenness(_ s: FaceSample) -> Double {
        let l = aperture(s.leftEye), r = aperture(s.rightEye)
        let vals = [l, r].compactMap { $0 }
        guard !vals.isEmpty else { return 0 }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private func aperture(_ pts: [CGPoint]) -> Double? {
        guard pts.count >= 4 else { return nil }
        var a = pts[0], b = pts[1], best: CGFloat = -1
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y)
                if d > best { best = d; a = pts[i]; b = pts[j] }
            }
        }
        guard best > 1e-3 else { return nil }
        let ux = (b.x - a.x) / best, uy = (b.y - a.y) / best   // unit long axis
        var minPerp: CGFloat = .greatestFiniteMagnitude, maxPerp: CGFloat = -.greatestFiniteMagnitude
        for p in pts {
            let perp = (p.x - a.x) * (-uy) + (p.y - a.y) * ux
            minPerp = min(minPerp, perp); maxPerp = max(maxPerp, perp)
        }
        return Double((maxPerp - minPerp) / best)
    }

    // MARK: - Fusion

    private func evaluate() -> LivenessReport {
        var r = LivenessReport()
        r.samples = energies.count

        let e = energies.map(\.v)
        // 85th percentile: we care that motion happened *at some point* in the
        // window, not that it happens on every single frame. A person can hold
        // still for a second; a photo holds still for all of them.
        r.nonRigidEnergy = Geometry.percentile(e, 0.85)
        let motion = min(1.0, r.nonRigidEnergy / tuning.fullMotion)

        let o = openness.map(\.v).filter { $0 > 0 }
        if o.count >= 8 {
            let open = Geometry.percentile(o, 0.85)
            let shut = Geometry.percentile(o, 0.05)
            if open > 0 { r.blinkObserved = (open - shut) / open >= tuning.blinkDropRatio }
        }

        r.parallaxSamples = parallax.count
        if r.parallaxSamples >= tuning.parallaxMinSamples {
            r.parallaxPerRadian = Geometry.median(parallax.map(\.v))
            r.planarReplaySuspected = r.parallaxPerRadian <= tuning.planarityFloor
            r.depthConfirmed = r.parallaxPerRadian > tuning.planarityFloor
        }

        r.poseJitter = max(Geometry.stdDev(yaws.map(\.v)), Geometry.stdDev(pitches.map(\.v)))
        let jitter = min(1.0, r.poseJitter / tuning.jitterFloor)

        r.score = tuning.weightMotion * motion
                + tuning.weightBlink * (r.blinkObserved ? 1 : 0)
                + tuning.weightJitter * jitter

        let span = (energies.last?.t ?? 0) - (energies.first?.t ?? 0)

        if r.score >= tuning.liveAt {
            r.verdict = .live
        } else if r.samples >= tuning.minSamples,
                  span >= tuning.minSpanSeconds,
                  r.score <= tuning.spoofAt {
            r.verdict = .spoofSuspected
        } else {
            r.verdict = .undecided
        }
        return r
    }

    private func trim(before cutoff: CFTimeInterval) {
        parallax.removeAll { $0.t < cutoff - (tuning.parallaxWindowSeconds - tuning.windowSeconds) }
        energies.removeAll { $0.t < cutoff }
        openness.removeAll { $0.t < cutoff }
        yaws.removeAll { $0.t < cutoff }
        pitches.removeAll { $0.t < cutoff }
    }
}
