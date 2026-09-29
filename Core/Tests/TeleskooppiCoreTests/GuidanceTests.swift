import Foundation
import Testing
@testable import TeleskooppiCore

@Suite struct GuidanceTests {
    private func exactCalibration(theta: Double, mirrored: Bool, rateR: Double = 30, rateU: Double = 30)
        -> (CalibrationResult, SimulatedOptics) {
        let optics = SimulatedOptics(displayRotation: theta, mirrored: mirrored)
        let m = optics.expectedStickToImage(rightSkyRate: rateR * optics.plateScale, upSkyRate: rateU * optics.plateScale)
        let sol = CalibrationSolver.solve(mRight: m.column0, mUp: m.column1)!
        let r = CalibrationResult(stickToImage: m, displayRotation: sol.displayRotation, mirrored: sol.mirrored,
                                  orthogonalityError: sol.orthogonalityError, lineResidual: 0,
                                  opticalCenter: optics.opticalCenter, fieldRadius: optics.fieldRadius)
        return (r, optics)
    }

    /// Window convention (D-09): the arrow points on screen from the crosshair toward the star.
    @Test func windowConventionAllAngles() {
        var rng = SplitMix64(seed: 31)
        for deg in stride(from: 0.0, to: 360.0, by: 1.0) {
            for mirrored in [false, true] {
                let (cal, optics) = exactCalibration(theta: AngleMath.radians(deg), mirrored: mirrored)
                let display = DisplayTransform(calibration: cal, scale: 1.7, screenCenter: Vec2(200, 430))
                for _ in 0..<5 {
                    var engine = GuidanceEngine(config: .defaults(fieldRadius: optics.fieldRadius))
                    let star = optics.opticalCenter + Vec2.unit(angle: rng.uniform(0...(2 * .pi))) * rng.uniform(60...350)
                    let out = engine.guide(target: star, center: optics.opticalCenter, calibration: cal)
                    let onScreen = display.imageToScreen(star) - display.imageToScreen(optics.opticalCenter)
                    let err = abs(out.arrowScreenDirection.signedAngle(to: onScreen))
                    #expect(err < AngleMath.radians(2), "theta \(deg) mirrored \(mirrored): \(AngleMath.degrees(err)) deg")
                    // The quantized arrow is within 45 deg (+ hysteresis) of the continuous direction.
                    let arrow = try! #require(out.arrow)
                    #expect(abs(arrow.screenVector.signedAngle(to: onScreen)) <= AngleMath.radians(50))

                    var inverted = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 45, convention: .inverted))
                    let inv = inverted.guide(target: star, center: optics.opticalCenter, calibration: cal)
                    #expect(abs(inv.arrowScreenDirection.signedAngle(to: -onScreen)) < AngleMath.radians(2))
                    #expect(inv.stickSeconds == out.stickSeconds)
                }
            }
        }
    }

    /// End to end: following the stick instruction from a *measured* (simulated, noisy) calibration
    /// moves the star toward the crosshair under the *true* mount behaviour, for any rotation /
    /// mirror / altitude (unequal axis rates). This compounds the calibration error of both columns,
    /// so the bound is p95 < 2 deg and max < 3.5 deg; the pure guidance invariant (+-2 deg) is
    /// checked on screen for near-horizon (equal-rate) cases and in `windowConventionAllAngles`.
    @Test func measuredCalibrationBringsStarToCrosshair() {
        var rng = SplitMix64(seed: 404)
        var worst = 0.0
        var screenWorst = 0.0
        var motionErrors = [Double]()
        for seed in 1...60 {
            var sc = CalibrationScenario.random(seed: 50_000 + UInt64(seed))
            let nearHorizon = seed % 3 == 0
            if nearHorizon { sc.mount.altitudeDegrees = 2 }  // cos(alt) ~ 1: equal axis rates
            let out = CalibrationSimulation(scenario: sc).run()
            let cal = try! #require(out.result, "seed \(seed): \(String(describing: out.failure))")
            let trueM = out.expectedStickToImage
            let display = DisplayTransform(calibration: cal, screenCenter: Vec2(0, 0))
            for _ in 0..<20 {
                let e = Vec2.unit(angle: rng.uniform(0...(2 * .pi))) * rng.uniform(40...300)
                var engine = GuidanceEngine(config: .defaults(fieldRadius: 380))
                let g = engine.guide(target: cal.opticalCenter + e, center: cal.opticalCenter, calibration: cal)
                let motion = trueM * g.stickSeconds
                let err = abs(motion.signedAngle(to: -e))
                worst = max(worst, err)
                motionErrors.append(AngleMath.degrees(err))
                #expect(err < AngleMath.radians(3.5), "seed \(seed): \(AngleMath.degrees(err)) deg")
                if nearHorizon {
                    let screenErr = abs(g.arrowScreenDirection.signedAngle(to: display.imageVectorToScreen(e)))
                    screenWorst = max(screenWorst, screenErr)
                    #expect(screenErr < AngleMath.radians(2))
                }
            }
        }
        let p95 = Statistics.percentile(motionErrors, 95) ?? .infinity
        #expect(p95 < 2)
        print("[guidance] motion direction error p95 \(p95) deg, worst \(AngleMath.degrees(worst)) deg, "
            + "worst screen arrow error (equal rates) \(AngleMath.degrees(screenWorst)) deg")
    }

    @Test func stickSecondsAndTimeEstimate() {
        let (cal, _) = exactCalibration(theta: 0.3, mirrored: false, rateR: 20, rateU: 40)
        // Star displaced along -m_U by 120 px: needs 3 s of stick UP (120 / 40).
        let e = -cal.mUp.normalized * 120
        var engine = GuidanceEngine(config: .defaults(fieldRadius: 380))
        let g = engine.guide(target: cal.opticalCenter + e, center: cal.opticalCenter, calibration: cal)
        #expect(g.stickSeconds.distance(to: Vec2(0, 3)) < 1e-9)
        #expect(g.secondsAtCalibrationRate.distance(to: Vec2(0, 3)) < 1e-9)
        #expect(g.arrow == .up)
        #expect(abs(g.errorPixels - 120) < 1e-9)
    }

    @Test func quantizationHysteresisAndDiagonalRule() {
        let m = Mat2(columns: Vec2(-1, 0), Vec2(0, 1))  // identity-like calibration, 1 px/s
        var engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 0.01))
        func guide(_ stick: Vec2) -> StickDir8? {
            // e = -M s
            engine.guide(target: -(m * stick), center: .zero, stickToImage: m).arrow
        }
        #expect(guide(Vec2(10, 0)) == .right)
        // 25 deg: past the 22.5 deg border but inside the 5 deg hysteresis -> stays right.
        #expect(guide(Vec2.unit(angle: AngleMath.radians(25)) * 10) == .right)
        // 30 deg: beyond hysteresis -> diagonal.
        #expect(guide(Vec2.unit(angle: AngleMath.radians(30)) * 10) == .upRight)
        // Back to 20 deg: stays diagonal (within 22.5 + 5 of 45).
        #expect(guide(Vec2.unit(angle: AngleMath.radians(20)) * 10) == .upRight)
        #expect(guide(Vec2.unit(angle: AngleMath.radians(10)) * 10) == .right)
        // Fresh engine: plain nearest sector (border at 22.5 deg).
        engine.reset()
        #expect(guide(Vec2.unit(angle: AngleMath.radians(25)) * 10) == .upRight)
        engine.reset()
        #expect(guide(Vec2.unit(angle: AngleMath.radians(20)) * 10) == .right)
        engine.reset()
        // Small diagonal: minor component 0.3 s < 0.4 s -> only the major axis.
        #expect(guide(Vec2(-0.35, -0.3)) == .left)
        engine.reset()
        #expect(guide(Vec2(-3, -3)) == .downLeft)
        engine.reset()
        #expect(guide(Vec2(0, -5)) == .down)
    }

    @Test func toleranceHysteresis() {
        let (cal, _) = exactCalibration(theta: 1.2, mirrored: true)
        var engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 40))
        let c = cal.opticalCenter
        func at(_ r: Double) -> GuidanceOutput {
            engine.guide(target: c + Vec2(r, 0), center: c, calibration: cal)
        }
        #expect(!at(100).withinTolerance)
        #expect(at(100).arrow != nil)
        #expect(at(39).withinTolerance)
        #expect(at(39).arrow == nil)
        #expect(at(55).withinTolerance)  // < 1.5 r_ok: still OK
        #expect(!at(61).withinTolerance)  // > 1.5 r_ok: guidance resumes
        #expect(!at(45).withinTolerance)  // must get back inside r_ok first
    }

    @Test func axisMarkers() {
        for deg in stride(from: 0.0, to: 360.0, by: 30) {
            for mirrored in [false, true] {
                let (cal, _) = exactCalibration(theta: AngleMath.radians(deg), mirrored: mirrored, rateR: 15, rateU: 30)
                let display = DisplayTransform(calibration: cal, screenCenter: .zero)
                let markers = GuidanceEngine.axisMarkerDirections(stickToImage: cal.stickToImage, display: display)
                #expect(markers[.up]!.distance(to: Vec2(0, -1)) < 1e-9)
                #expect(markers[.down]!.distance(to: Vec2(0, 1)) < 1e-9)
                #expect(markers[.right]!.distance(to: Vec2(1, 0)) < 1e-9)
                #expect(markers[.left]!.distance(to: Vec2(-1, 0)) < 1e-9)
            }
        }
    }

    @Test func stickDir8Geometry() {
        #expect(StickDir8.up.screenVector.distance(to: Vec2(0, -1)) < 1e-12)
        #expect(StickDir8.nearest(angle: AngleMath.radians(-44)) == .downRight)
        #expect(StickDir8.nearest(angle: AngleMath.radians(350)) == .right)
        #expect(StickDir8.majorAxis(of: Vec2(-3, 2)) == .left)
        #expect(StickDir8.upLeft.isDiagonal && !StickDir8.left.isDiagonal)
        #expect(StickDir8.allCases.map(\.symbol).joined() == "→↗↑↖←↙↓↘")
    }
}

@Suite struct DisplayTransformTests {
    @Test func calibrationMakesStickUpScreenUp() {
        var rng = SplitMix64(seed: 8)
        for _ in 0..<100 {
            let optics = SimulatedOptics(displayRotation: rng.uniform(0...(2 * .pi)), mirrored: rng.bool())
            let m = optics.expectedStickToImage(rightSkyRate: 100, upSkyRate: 200)
            let sol = CalibrationSolver.solve(mRight: m.column0, mUp: m.column1)!
            let cal = CalibrationResult(stickToImage: m, displayRotation: sol.displayRotation, mirrored: sol.mirrored,
                                        orthogonalityError: 0, lineResidual: 0, opticalCenter: optics.opticalCenter)
            let d = DisplayTransform(calibration: cal, scale: 0.8, screenCenter: Vec2(196, 426))
            #expect(d.imageToScreen(optics.opticalCenter).distance(to: Vec2(196, 426)) < 1e-9)
            // Star motion for stick UP is screen-down, for RIGHT screen-left ("window" view).
            #expect(d.imageVectorToScreen(m.column1).normalized.distance(to: Vec2(0, 1)) < 1e-9)
            #expect(d.imageVectorToScreen(m.column0).normalized.distance(to: Vec2(-1, 0)) < 1e-9)
            let p = Vec2(rng.uniform(0...960), rng.uniform(0...720))
            #expect(d.screenToImage(d.imageToScreen(p)).distance(to: p) < 1e-9)
            // Scale is preserved (orthogonal transform, D-08).
            #expect(abs(d.imageVectorToScreen(Vec2(3, 4)).length - 4) < 1e-9)
        }
    }

    @Test func manualFlips() {
        let c = Vec2(10, 20), s = Vec2(100, 200)
        let h = DisplayTransform.manual(rotation: 0, flipHorizontal: true, flipVertical: false, opticalCenter: c, screenCenter: s)
        #expect(h.isManualOverride)
        #expect(h.imageToScreen(c + Vec2(5, 3)).distance(to: s + Vec2(-5, 3)) < 1e-9)
        let v = DisplayTransform.manual(rotation: 0, flipHorizontal: false, flipVertical: true, opticalCenter: c, screenCenter: s)
        #expect(v.imageToScreen(c + Vec2(5, 3)).distance(to: s + Vec2(5, -3)) < 1e-9)
        let both = DisplayTransform.manual(rotation: 0, flipHorizontal: true, flipVertical: true, opticalCenter: c, screenCenter: s)
        #expect(!both.mirrored)
        #expect(both.imageToScreen(c + Vec2(5, 3)).distance(to: s + Vec2(-5, -3)) < 1e-9)
        let r = DisplayTransform.manual(rotation: .pi / 2, flipHorizontal: false, flipVertical: false,
                                        opticalCenter: c, screenCenter: s)
        // R(+90 deg) in the y-down screen frame: +x goes to +y (screen-down, i.e. clockwise on screen).
        #expect(r.imageToScreen(c + Vec2(1, 0)).distance(to: s + Vec2(0, 1)) < 1e-9)
    }

    @Test func matrixOutputs() {
        let d = DisplayTransform(rotation: 0.4, mirrored: true, scale: 2, opticalCenter: Vec2(480, 360),
                                 screenCenter: Vec2(200, 400))
        let p = Vec2(123, 456)
        let q = d.imageToScreen(p)
        let rm = d.matrixRowMajor
        #expect(abs(rm[0] * p.x + rm[1] * p.y + rm[2] - q.x) < 1e-9)
        #expect(abs(rm[3] * p.x + rm[4] * p.y + rm[5] - q.y) < 1e-9)
        let cm = d.matrixColumnMajor
        #expect(abs(cm[0] * p.x + cm[3] * p.y + cm[6] - q.x) < 1e-9)
        let mf = d.metalFloat3x3
        #expect(abs(Double(mf[0]) * p.x + Double(mf[4]) * p.y + Double(mf[8]) - q.x) < 1e-3)
        #expect(abs(Double(mf[1]) * p.x + Double(mf[5]) * p.y + Double(mf[9]) - q.y) < 1e-3)
    }

    @Test func scaleModes() {
        let fit = DisplayTransform.scale(fieldRadius: 380, screenSize: Vec2(393, 852), mode: .fit)
        #expect(abs(fit * 380 * 2 - 393) < 1e-9)
        let cover = DisplayTransform.scale(fieldRadius: 380, screenSize: Vec2(393, 852), mode: .cover)
        #expect(abs(cover * 380 - Vec2(393, 852).length / 2) < 1e-9)
    }

    @Test func codable() throws {
        let d = DisplayTransform(rotation: 1, mirrored: true, scale: 2, opticalCenter: Vec2(1, 2), screenCenter: Vec2(3, 4))
        #expect(try JSONDecoder().decode(DisplayTransform.self, from: JSONEncoder().encode(d)) == d)
    }
}
