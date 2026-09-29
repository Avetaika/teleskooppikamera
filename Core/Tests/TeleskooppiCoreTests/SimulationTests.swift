import Foundation
import Testing
@testable import TeleskooppiCore

@Suite struct SimulationTests {
    @Test func opticsProjectionRoundTripAndTruth() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<100 {
            let optics = SimulatedOptics(displayRotation: rng.uniform(0...(2 * .pi)), mirrored: rng.bool())
            let star = Vec2(rng.uniform(-3000...3000), rng.uniform(-3000...3000))
            let bore = Vec2(rng.uniform(-500...500), rng.uniform(-500...500))
            let p = optics.project(star: star, boresight: bore)
            #expect((optics.unproject(p, boresight: bore) - star).length < 1e-6)
            // The true display transform maps image offsets to the natural frame: moving the boresight
            // up (+eta) moves stars screen-down, right (+xi) moves them screen-left.
            let d = optics.imageToNatural
            let up = d * (optics.project(star: star, boresight: bore + Vec2(0, 100)) - p)
            let right = d * (optics.project(star: star, boresight: bore + Vec2(100, 0)) - p)
            #expect(up.normalized.distance(to: Vec2(0, 1)) < 1e-9)
            #expect(right.normalized.distance(to: Vec2(-1, 0)) < 1e-9)
        }
    }

    @Test func mountRatesAndCosAlt() {
        var cfg = SimulatedMount.Configuration(speedMultiplier: 16, altitudeDegrees: 60)
        cfg.rampTime = 0.2
        var m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0, 1))
        m.step(0.5)
        let a = m.boresight
        m.step(1.0)
        let rate = SynScanSpeed.arcsecPerSecond(multiplier: 16)
        #expect(abs((m.boresight - a).y - rate) < 1e-6)
        #expect(abs((m.boresight - a).x) < 1e-9)

        var m2 = SimulatedMount(configuration: cfg)
        m2.setStick(Vec2(1, 0))
        m2.step(0.5)
        let b = m2.boresight
        m2.step(1.0)
        #expect(abs((m2.boresight - b).x - rate * cos(AngleMath.radians(60))) < 1e-6)
        #expect(SynScanSpeed.multiplier(level: 3) == 16 && SynScanSpeed.multiplier(level: 6) == 128)
        #expect(SynScanSpeed.multiplier(level: 9) == nil)
    }

    @Test func accelerationRamp() {
        let cfg = SimulatedMount.Configuration(speedMultiplier: 32, rampTime: 0.4)
        var m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0, 1))
        m.step(0.2)
        #expect(abs(m.axisRate.y - cfg.axisRate / 2) < 1e-6)
        // Distance during the ramp is half of the full-speed distance.
        #expect(abs(m.axisPosition.y - 0.5 * cfg.axisRate / 2 * 0.2) < 0.5)
    }

    @Test func backlashDeadTimeOnReversal() {
        let backlash = 600.0  // 10 arcmin
        let cfg = SimulatedMount.Configuration(speedMultiplier: 16, backlash: Vec2(backlash, backlash),
                                               backlashEngagement: Vec2(1, 1), rampTime: 0.01)
        var m = SimulatedMount(configuration: cfg)
        // Engaged for positive motion: moving up starts immediately.
        m.setStick(Vec2(0, 1))
        m.step(1)
        #expect(m.boresight.y > 0.9 * cfg.axisRate)
        // Reverse: the tube does not move until the dead band is crossed.
        let y0 = m.boresight.y
        m.setStick(Vec2(0, -1))
        let dead = backlash / cfg.axisRate
        m.step(dead * 0.9)
        // Only the braking of the forward motion (rate * rampTime / 2) moves the tube.
        #expect(abs(m.boresight.y - y0) < cfg.axisRate * cfg.rampTime)
        m.step(dead * 0.1 + 1)
        #expect(abs((y0 - m.boresight.y) - cfg.axisRate * 1) < 0.02 * cfg.axisRate)
    }

    @Test func stickResponseModels() {
        var cfg = SimulatedMount.Configuration(stickMisalignment: AngleMath.radians(10))
        var m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0, 1))
        #expect(m.axisCommand == Vec2(0, 1))  // digital: off-axis leak suppressed
        cfg.stickResponse = .analog
        m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0, 1))
        #expect(abs(m.axisCommand.x + sin(AngleMath.radians(10))) < 1e-12)
        m.setStick(Vec2(0.1, 0))
        cfg.stickResponse = .digital(axisThreshold: 0.35)
        m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0.1, 0))
        #expect(m.axisCommand == .zero)  // below the 0.2 center dead zone
        m.setStick(Vec2(0.7, 0.7))
        #expect(m.axisCommand == Vec2(1, 1))  // diagonal
    }

    @Test func driftWhenNotTracking() {
        let drift = Vec2(10, -5)
        var m = SimulatedMount(configuration: .init(driftArcsecPerSecond: drift, trackingEnabled: false))
        m.step(2)
        #expect((m.boresight + drift * 2).length < 1e-9)
        var tracked = SimulatedMount(configuration: .init(driftArcsecPerSecond: drift, trackingEnabled: true))
        tracked.step(2)
        #expect(tracked.boresight == .zero)
    }

    @Test func syntheticSkyRendersStarAtProjectedPosition() {
        let optics = SimulatedOptics(displayRotation: 0.8, mirrored: true)
        let starPos = optics.unproject(Vec2(520.3, 300.7), boresight: .zero)
        let field = StarField(stars: [SimulatedStar(position: starPos, magnitude: 5)])
        var cfg = SyntheticSky.Configuration()
        cfg.backgroundGradient = .zero
        cfg.vignetting = 0
        let sky = SyntheticSky(optics: optics, field: field, configuration: cfg)
        let img = sky.renderExpected(boresight: .zero)
        // Background-subtracted centroid in a box covering the whole rendered PSF.
        var sw = 0.0, sx = 0.0, sy = 0.0
        for y in 278...323 {
            for x in 498...543 {
                let v = Double(img[x, y]) - cfg.background
                sw += v
                sx += v * Double(x)
                sy += v * Double(y)
            }
        }
        #expect(abs(sx / sw - 520.3) < 0.05)
        #expect(abs(sy / sw - 300.7) < 0.05)
        // Total flux is conserved (within the PSF tail cut-off).
        #expect(abs(sw / cfg.flux(magnitude: 5) - 1) < 0.05)
        // Outside the field stop only the scattered light level remains.
        #expect(abs(Double(img[2, 2]) - cfg.outsideFieldLevel) < 1e-3)
    }

    @Test func syntheticSkyNoiseIsDeterministicAndRealistic() {
        let optics = SimulatedOptics()
        var starRng = SplitMix64(seed: 11)
        let field = StarField.random(count: 50, radiusArcsec: 3000, rng: &starRng)
        #expect(field.stars.allSatisfy { $0.magnitude >= 6 && $0.magnitude <= 12 })
        let sky = SyntheticSky(optics: optics, field: field)
        var r1 = SplitMix64(seed: 1), r2 = SplitMix64(seed: 1)
        let a = sky.render(boresight: .zero, rng: &r1)
        let b = sky.render(boresight: .zero, rng: &r2)
        #expect(a == b)
        // Noise near the center: background ~25 e- + bias 4 -> ~29 ADU, sigma ~ sqrt(25 + 2.5^2) ~ 5.6.
        var patch = [Double]()
        for y in 340..<380 { for x in 460..<500 { patch.append(Double(a[x, y])) } }
        let st = Statistics.robust(patch)
        #expect(abs(st.median - 29) < 2)
        #expect(st.sigma > 4 && st.sigma < 7.5)
        // Vignetting: the edge of the field is darker than the center.
        let expected = sky.renderExpected(boresight: .zero)
        let edge = Double(expected[480 + 370, 360])
        let center = Double(expected[480, 360])
        #expect(edge < center)
    }

    @Test func expectedStickToImageMatchesSimulatedMotion() {
        let sc = CalibrationScenario.random(seed: 99)
        var cfg = sc.mount
        cfg.backlash = .zero
        cfg.driftArcsecPerSecond = .zero
        var m = SimulatedMount(configuration: cfg)
        m.setStick(Vec2(0, 1))
        m.step(1)
        let p0 = sc.optics.project(star: .zero, boresight: m.boresight)
        m.step(1)
        let p1 = sc.optics.project(star: .zero, boresight: m.boresight)
        let expected = sc.expectedStickToImage.column1
        // Altitude changes slightly during the move, so allow a small tolerance.
        #expect((p1 - p0 - expected).length < 0.01 * expected.length)
    }
}
