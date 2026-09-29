import Foundation
import Testing
@testable import TeleskooppiCore

/// Phase 4 (plan 4.9): star detector, tracker.
@Suite struct StarDetectorTests {
    /// Flux (electrons) that gives an aperture SNR of about 20 on the default test background
    /// (sigma 5.6 e, Moffat FWHM 3 px, aperture about 3.8 px radius, 86 % of the flux inside).
    static let fluxSNR20 = 875.0

    static func grid(seed: UInt64, flux: Double) -> [(pos: Vec2, flux: Double)] {
        var rng = SplitMix64(seed: seed)
        var stars = [(pos: Vec2, flux: Double)]()
        for gy in 0..<4 {
            for gx in 0..<6 {
                stars.append((Vec2(70 + 100 * Double(gx) + rng.uniform(0...1),
                                   70 + 100 * Double(gy) + rng.uniform(0...1)), flux))
            }
        }
        return stars
    }

    @Test func centroidErrorAtSNR20() {
        let detector = StarDetector()
        var errors = [Double](), snrs = [Double]()
        var missed = 0, extra = 0
        for seed in 0..<3 {
            let stars = Self.grid(seed: UInt64(seed + 1), flux: Self.fluxSNR20)
            let img = TestImages.starFrame(width: 640, height: 480, stars: stars, seed: UInt64(100 + seed))
            let dets = detector.detect(img)
            var used = Set<Int>()
            for s in stars {
                if let (i, d) = dets.enumerated().min(by: {
                    ($0.element.position - s.pos).length < ($1.element.position - s.pos).length
                }), (d.position - s.pos).length < 2 {
                    errors.append((d.position - s.pos).length)
                    snrs.append(d.snr)
                    used.insert(i)
                } else {
                    missed += 1
                }
            }
            extra += dets.count - used.count
        }
        let mean = Statistics.mean(errors) ?? .infinity
        let rms = Statistics.rms(errors) ?? .infinity
        print("[detector] SNR-20 centroid error: mean \(mean) px, rms \(rms) px, p95 \(p95(errors)) px, "
            + "max \(errors.max() ?? 0) px; detection SNR mean \(Statistics.mean(snrs) ?? 0); "
            + "missed \(missed), extra \(extra) of \(errors.count + missed)")
        #expect(missed == 0)
        #expect(extra == 0)
        #expect(rms < 0.2)
        #expect(mean < 0.2)
        #expect((Statistics.mean(snrs) ?? 0) > 12 && (Statistics.mean(snrs) ?? 0) < 35)
    }

    @Test func centroidErrorOnGradient() {
        // Strong city-sky gradient: still sub-0.2 px at higher SNR.
        let detector = StarDetector()
        let stars = Self.grid(seed: 9, flux: 3 * Self.fluxSNR20)
        let img = TestImages.starFrame(width: 640, height: 480, stars: stars, background: 40,
                                       gradient: Vec2(0.06, -0.04), seed: 7)
        let dets = detector.detect(img)
        var errors = [Double]()
        for s in stars {
            if let d = dets.min(by: { ($0.position - s.pos).length < ($1.position - s.pos).length }),
               (d.position - s.pos).length < 2 {
                errors.append((d.position - s.pos).length)
            }
        }
        #expect(errors.count == stars.count)
        #expect((Statistics.mean(errors) ?? .infinity) < 0.15)
        #expect(dets.count == stars.count)
    }

    @Test func noFalsePositivesOnNoiseWithGradient() {
        let detector = StarDetector()
        var total = 0
        for seed in 0..<3 {
            let img = TestImages.starFrame(width: 640, height: 480, stars: [], background: 30,
                                           gradient: Vec2(0.05, -0.03), seed: UInt64(50 + seed))
            total += detector.detect(img).count
        }
        #expect(total == 0)
    }

    @Test func hotPixelsAreRejected() {
        let detector = StarDetector()
        let stars = Self.grid(seed: 3, flux: 2 * Self.fluxSNR20)
        var img = TestImages.starFrame(width: 640, height: 480, stars: stars, seed: 21)
        var rng = SplitMix64(seed: 5)
        var hot = [Vec2]()
        while hot.count < 40 {
            let p = Vec2(Double(rng.int(in: 5...634)), Double(rng.int(in: 5...474)))
            if stars.contains(where: { ($0.pos - p).length < 12 }) { continue }
            hot.append(p)
            img[Int(p.x), Int(p.y)] = rng.bool() ? 255 : 120
        }
        let dets = detector.detect(img)
        for h in hot {
            #expect(!dets.contains { ($0.position - h).length < 3 }, "hot pixel at \(h) detected")
        }
        #expect(dets.count == stars.count)
    }

    @Test func saturatedStarsAreFlagged() {
        let detector = StarDetector()
        let stars: [(pos: Vec2, flux: Double)] = [
            (Vec2(120.3, 100.6), 60_000),  // peak about 4400 e: saturated at gain 1
            (Vec2(300.7, 200.2), 60_000),
            (Vec2(200.5, 300.5), 2000),    // unsaturated
        ]
        let img = TestImages.starFrame(width: 480, height: 400, stars: stars, seed: 33)
        let dets = detector.detect(img)
        #expect(dets.count == 3)
        for s in stars {
            let d = dets.min { ($0.position - s.pos).length < ($1.position - s.pos).length }
            #expect(d != nil)
            #expect(d.map { ($0.position - s.pos).length < 0.5 } ?? false)
            #expect(d?.saturated == (s.flux > 10_000))
        }
        // Brightness ordering by flux even though the peaks are clipped.
        #expect(dets[0].flux > dets[2].flux)
    }

    @Test func roiAndMaskRestrictDetection() {
        let detector = StarDetector()
        let stars: [(pos: Vec2, flux: Double)] = [(Vec2(100, 100), 3000), (Vec2(400, 300), 3000)]
        let img = TestImages.starFrame(width: 480, height: 400, stars: stars, seed: 4)
        #expect(detector.detect(img).count == 2)
        let roi = detector.detect(img, roi: PixelRect(x: 60, y: 60, width: 90, height: 90))
        #expect(roi.count == 1)
        #expect((roi.first.map { ($0.position - Vec2(100, 100)).length } ?? 99) < 0.5)
        let mask = detector.detect(img, mask: CircleMask(center: Vec2(400, 300), radius: 80))
        #expect(mask.count == 1)
        #expect((mask.first.map { ($0.position - Vec2(400, 300)).length } ?? 99) < 0.5)
    }

    @Test func detectorPerformanceOnFullFrame() {
        // Performance hint (Linux CI, debug build): detection time per 960x720 frame with a field of stars.
        let sc = CalibrationScenario(seed: 1)
        let sim = CalibrationSimulation(scenario: sc)
        var starRng = SplitMix64(seed: 77)
        var field = StarField.random(count: 250, radiusArcsec: sc.optics.fieldRadius * sc.optics.plateScale * 1.05,
                                     brightest: 6, faintest: 10, rng: &starRng)
        field.stars.append(SimulatedStar(position: sim.guideStar, magnitude: 4.5))
        let sky = SyntheticSky(optics: sc.optics, field: field, configuration: SimulatedSession.skyConfiguration(SimulatedSessionOptions()))
        var img = GrayImage8(width: 960, height: 720, fill: 4)
        var rng = SplitMix64(seed: 2)
        sky.render(into: &img, window: PixelRect(x: 0, y: 0, width: 960, height: 720), boresight: .zero, rng: &rng)
        let mask = CircleMask(center: sc.optics.opticalCenter, radius: sc.optics.fieldRadius * 0.98)
        let detector = StarDetector()
        let clock = ContinuousClock()
        var times = [Double]()
        var count = 0
        for _ in 0..<5 {
            let t = clock.measure { count = detector.detect(img, mask: mask).count }
            times.append(SessionReplay.milliseconds(t))
        }
        let median = Statistics.median(times) ?? 0
        print("[detector] 960x720 frame: \(count) stars, median \(median) ms (min \(times.min() ?? 0), "
            + "max \(times.max() ?? 0)) per detect() call, debug build unless noted")
        #expect(count > 20)
        #expect(median < 5000)
    }
}

@Suite struct StarTrackerTests {
    /// Static frame builder for tracker tests.
    static func frame(_ stars: [(pos: Vec2, flux: Double)], seed: UInt64) -> GrayImage8 {
        TestImages.starFrame(width: 480, height: 360, stars: stars, seed: seed)
    }

    @Test func followsMovingStarWithoutJumpingToDistractors() {
        var tracker = StarTracker()
        tracker.lock(near: Vec2(100, 150))
        var maxError = 0.0
        var lockedFrames = 0
        for i in 0..<50 {
            let t = Double(i) * 0.1
            let truth = Vec2(100 + 4 * Double(i), 150 + 1.5 * Double(i))
            // Fainter distractor stars close to the path, plus a brighter one nearby but outside the gate.
            let stars: [(pos: Vec2, flux: Double)] = [
                (truth, 2500),
                (truth + Vec2(9, 6), 900),
                (truth + Vec2(-7, 11), 1400),
                (truth + Vec2(0, -45), 7000),
            ]
            let img = Self.frame(stars, seed: UInt64(i))
            if let s = tracker.update(img, time: t) {
                lockedFrames += 1
                maxError = max(maxError, (s.p - truth).length)
            }
        }
        #expect(lockedFrames >= 49)
        #expect(maxError < 0.5, "max error \(maxError)")
        #expect(tracker.state == .locked)
    }

    @Test func picksRequestedStarAndLosesItAfterTimeout() {
        var tracker = StarTracker()
        let a = Vec2(150, 120), b = Vec2(320, 250)
        tracker.lock(near: Vec2(155, 125))
        var img = Self.frame([(a, 1500), (b, 6000)], seed: 1)
        let first = tracker.update(img, time: 0)
        #expect(first != nil)
        #expect((first.map { ($0.p - a).length } ?? 99) < 0.5)
        // The tracked star vanishes; the brighter one stays 200 px away. No jump, then lost.
        var lostAt: Double?
        for i in 1..<40 {
            let t = Double(i) * 0.1
            img = Self.frame([(b, 6000)], seed: UInt64(i + 1))
            let s = tracker.update(img, time: t)
            #expect(s == nil)
            if tracker.state == .lost, lostAt == nil { lostAt = t }
        }
        #expect(lostAt != nil)
        #expect((lostAt ?? 0) > 1.9 && (lostAt ?? 99) < 2.5)
        #expect(tracker.update(img, time: 5) == nil)
        // A new lock request re-acquires.
        tracker.lock(near: b)
        #expect(tracker.update(img, time: 6) != nil)
    }

    @Test func gateGrowsWithMotion() {
        var tracker = StarTracker()
        let img0 = Self.frame([(Vec2(100, 100), 3000)], seed: 1)
        _ = tracker.update(img0, time: 0)
        #expect(tracker.gate(at: 0.1) == 10)  // standing still: 10 px
        let img1 = Self.frame([(Vec2(108, 100), 3000)], seed: 2)
        _ = tracker.update(img1, time: 0.1)
        // 8 px/frame: gate = 3 * 8 + 10
        #expect(abs(tracker.gate(at: 0.2) - 34) < 1.5)
    }
}
