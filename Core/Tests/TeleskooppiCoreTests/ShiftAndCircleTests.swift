import Foundation
import Testing
@testable import TeleskooppiCore

/// Phase 4: whole-frame shift estimator (D-12) and field circle detector (D-17).
@Suite struct ShiftEstimatorTests {
    @Test func recoversKnownShiftsOnTexturedScene() {
        let scene = TexturedScene(width: 960, height: 720, blobCount: 150, margin: 120, seed: 11)
        var rng = SplitMix64(seed: 1)
        let reference = scene.render(shift: .zero, rng: &rng)
        let shifts: [Vec2] = [Vec2(5.3, -3.7), Vec2(-12.25, 8.6), Vec2(0.4, 0.3), Vec2(30.5, 20.1), Vec2(-45.7, -33.2)]
        var worst = 0.0
        var errors = [Double]()
        let clock = ContinuousClock()
        for s in shifts {
            let img = scene.render(shift: s, rng: &rng)
            var estimate: ShiftEstimate?
            let t = clock.measure { estimate = ShiftEstimator.estimateShift(reference: reference, image: img) }
            guard let e = estimate else {
                Issue.record("no estimate for shift \(s)")
                continue
            }
            let err = max(abs(e.shift.x - s.x), abs(e.shift.y - s.y))
            errors.append(err)
            worst = max(worst, err)
            print("[shift] true (\(s.x), \(s.y)) estimated (\(e.shift.x), \(e.shift.y)) corr \(e.correlation) "
                + "error \(err) px, \(SessionReplay.milliseconds(t)) ms (debug build)")
        }
        #expect(errors.count == shifts.count)
        #expect(worst < 0.3, "worst axis error \(worst) px")
    }

    @Test func cumulativeTrackFollowsSceneMotion() {
        // A scene panning across the frame with keyframe re-registration.
        let scene = TexturedScene(width: 320, height: 240, blobCount: 260, margin: 150, seed: 5)
        var rng = SplitMix64(seed: 2)
        var estimator = ShiftEstimator(origin: Vec2(160, 120))
        var maxError = 0.0
        var samples = 0
        for i in 0..<40 {
            let truth = Vec2(3.1 * Double(i), -1.7 * Double(i))
            let img = scene.render(shift: truth, rng: &rng)
            if let s = estimator.update(img, time: Double(i) * 0.1) {
                samples += 1
                maxError = max(maxError, (s.p - (Vec2(160, 120) + truth)).length)
            }
        }
        print("[shift] cumulative track over 40 frames (final shift 121 px): max error \(maxError) px")
        #expect(samples == 40)
        #expect(maxError < 1.0)
    }

    @Test func calibrationThroughShiftEstimator() {
        // Daytime mode: the whole scene moves like the guide star did; the estimator provides the samples.
        let scale = 0.25
        var chosen: CalibrationScenario?
        for seed in UInt64(1)...60 {
            var sc = CalibrationScenario.random(seed: seed).scaled(by: scale)
            sc.jitterSigma = 0.3
            sc.frameRate = 5
            sc.mount.backlash = .zero
            if let r = CalibrationSimulation(scenario: sc).run().result, r.quality == .good {
                chosen = sc
                break
            }
        }
        guard let sc = chosen else {
            Issue.record("no working scenario found")
            return
        }
        let sim = CalibrationSimulation(scenario: sc)
        let optics = sc.optics
        let start = optics.project(star: sim.guideStar, boresight: .zero)
        let scene = TexturedScene(width: optics.imageWidth, height: optics.imageHeight, blobCount: 300,
                                  margin: 150, seed: sc.seed)
        var config = ShiftEstimatorConfig()
        config.hintRadius = 8
        var estimator = ShiftEstimator(config: config, origin: start)
        var rng = SplitMix64(seed: 3)
        var maxError = 0.0
        var frames = 0, samples = 0
        let outcome = sim.run(observe: { f in
            let img = scene.render(shift: f.truePosition + f.jitter - start, rng: &rng)
            let s = estimator.update(img, time: f.time)
            frames += 1
            if let s {
                samples += 1
                maxError = max(maxError, (s.p - (f.truePosition + f.jitter)).length)
            }
            return s
        })
        let r = outcome.result
        let err = r.map { AngleMath.degrees(abs(AngleMath.difference($0.displayRotation, optics.displayRotation))) }
        print("[shift] calibration via ShiftEstimator: frames \(frames), samples \(samples), max position error "
            + "\(maxError) px, rotation error \(err ?? -1) deg, failure \(String(describing: outcome.failure))")
        #expect(r != nil)
        #expect(r?.mirrored == optics.mirrored)
        #expect((err ?? 99) < 3.0)
        #expect(samples == frames)
    }
}

@Suite struct FieldCircleDetectorTests {
    static func check(width: Int, height: Int, center: Vec2, radius: Double, seed: UInt64) {
        let img = TestImages.fieldDisk(width: width, height: height, center: center, radius: radius, seed: seed)
        let detector = FieldCircleDetector()
        guard let c = detector.detect(img) else {
            Issue.record("no circle found (\(width)x\(height), r \(radius))")
            return
        }
        let d = 2 * radius
        let centerError = (c.center - center).length
        print("[circle] \(width)x\(height) r \(radius) c (\(center.x), \(center.y)): found c (\(c.center.x), \(c.center.y)) "
            + "r \(c.radius), center error \(centerError) px = \(100 * centerError / d) % of diameter, "
            + "radius error \(c.radius - radius) px, confidence \(c.confidence)")
        #expect(centerError < 0.02 * d)
        #expect(abs(c.radius - radius) < 0.02 * d)
        #expect(c.confidence > 0.5)
    }

    @Test func clippedTopAndBottom20Percent() {
        // Diameter 900 in a 720-high frame: 90 px (10 %) cut off at the top and at the bottom.
        Self.check(width: 960, height: 720, center: Vec2(480, 360), radius: 450, seed: 1)
        Self.check(width: 960, height: 720, center: Vec2(500, 340), radius: 450, seed: 2)
    }

    @Test func clippedTopAndBottom20PercentEach() {
        // Diameter 1200 in a 720-high frame: 20 % of the diameter cut off on each side.
        Self.check(width: 1280, height: 720, center: Vec2(640, 360), radius: 600, seed: 3)
        Self.check(width: 1280, height: 720, center: Vec2(660, 350), radius: 600, seed: 4)
    }

    @Test func fullyVisibleCircle() {
        Self.check(width: 960, height: 720, center: Vec2(470, 365), radius: 330, seed: 5)
    }

    @Test func noCircleInUniformImage() {
        var img = GrayImage8(width: 480, height: 360, fill: 120)
        var rng = SplitMix64(seed: 9)
        for i in 0..<img.pixels.count { img.pixels[i] = UInt8(clampingDouble: 120 + 3 * rng.gaussian()) }
        let c = FieldCircleDetector().detect(img)
        #expect(c == nil || c!.confidence < 0.3)
    }
}
