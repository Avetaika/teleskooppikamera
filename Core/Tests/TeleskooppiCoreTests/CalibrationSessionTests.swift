import Foundation
import Testing
@testable import TeleskooppiCore

/// Drives a session with a scripted star track (10 Hz, small deterministic jitter).
private func runScript(_ session: inout CalibrationSession, duration: Double, jitter: Double = 0.3,
                       position: (Double) -> Vec2?) -> [CalibrationPrompt] {
    var rng = SplitMix64(seed: 2024)
    var prompts: [CalibrationPrompt] = []
    var t = 0.0
    while t < duration {
        t += 0.1
        let s = position(t).map { TrackSample(t: t, p: $0 + Vec2(rng.gaussian(), rng.gaussian()) * jitter) }
        let p = session.feed(s, at: t)
        if prompts.last != p { prompts.append(p) }
        if p.isTerminal { break }
    }
    return prompts
}

private let center = Vec2(480, 360)
private func makeSession(mode: CalibrationSession.Mode = .full) -> CalibrationSession {
    CalibrationSession(config: CalibrationConfig(opticalCenter: center, fieldRadius: 380), mode: mode)
}

@Suite struct CalibrationSessionTests {
    @Test func promptsFollowTheFlow() {
        let sc = CalibrationScenario(seed: 3, optics: SimulatedOptics(displayRotation: 0.4), jitterSigma: 0.5)
        let out = CalibrationSimulation(scenario: sc).run()
        let kinds = out.promptLog.map(\.prompt)
        #expect(kinds.first == .centerStar)
        #expect(kinds.contains(.holdStill))
        let upIndex = kinds.firstIndex(of: .pressAndHold(.up))!
        let rightIndex = kinds.firstIndex(of: .pressAndHold(.right))!
        let stopIndices = kinds.indices.filter { kinds[$0] == .stop }
        #expect(stopIndices.count == 2)
        #expect(upIndex < stopIndices[0] && stopIndices[0] < rightIndex && rightIndex < stopIndices[1])
        #expect(kinds.contains(.releaseAndWait))
        guard case .done(let r) = kinds.last else {
            Issue.record("did not finish: \(String(describing: kinds.last))")
            return
        }
        #expect(r.quality == .good)
        #expect(out.duration < 45)  // plan phase 5: calibration <= 45 s
    }

    @Test func noiseFreeCalibrationIsExact() {
        var sc = CalibrationScenario(seed: 1, optics: SimulatedOptics(displayRotation: AngleMath.radians(37)),
                                     jitterSigma: 0)
        sc.mount.backlash = .zero
        sc.mount.driftArcsecPerSecond = .zero
        let out = CalibrationSimulation(scenario: sc).run()
        let r = try! #require(out.result)
        #expect(AngleMath.degrees(out.rotationError!) < 0.05)
        #expect(!r.mirrored)
        let expected = out.expectedStickToImage
        #expect((r.mRight - expected.column0).length < 0.01 * expected.column0.length)
        #expect((r.mUp - expected.column1).length < 0.01 * expected.column1.length)
        #expect(abs(r.axisRateRatio - cos(AngleMath.radians(sc.mount.altitudeDegrees))) < 0.01)
    }

    @Test func driftBacklashAndJitterAreHandled() {
        var sc = CalibrationScenario(seed: 8, optics: SimulatedOptics(displayRotation: AngleMath.radians(211), mirrored: true),
                                     jitterSigma: 2)
        sc.mount.backlash = Vec2(900, 900)
        sc.mount.backlashEngagement = Vec2(-1, -1)
        sc.mount.driftArcsecPerSecond = Vec2(9, -12)  // 15 arcsec/s
        sc.mount.altitudeDegrees = 55
        let out = CalibrationSimulation(scenario: sc).run()
        let r = try! #require(out.result, "failure: \(String(describing: out.failure))")
        #expect(r.mirrored)
        #expect(AngleMath.degrees(out.rotationError!) < 1)
        // Drift estimate in px/s matches the simulated drift.
        let driftImage = sc.optics.naturalToImage * Vec2(9, 12) / sc.optics.plateScale
        #expect((r.driftVelocity - driftImage).length < 0.75)
    }

    @Test func quickRecalibration() {
        let full = CalibrationSimulation(scenario: CalibrationScenario(
            seed: 4, optics: SimulatedOptics(displayRotation: AngleMath.radians(100), mirrored: true))).run()
        let previous = try! #require(full.result)
        let sc = CalibrationScenario(seed: 5, optics: SimulatedOptics(displayRotation: AngleMath.radians(135), mirrored: true))
        let out = CalibrationSimulation(scenario: sc, mode: .quick(previous: previous)).run()
        let r = try! #require(out.result, "failure: \(String(describing: out.failure))")
        #expect(r.isQuick && r.mirrored)
        #expect(AngleMath.degrees(out.rotationError!) < 1)
        #expect(!out.promptLog.contains { $0.prompt == .pressAndHold(.right) })
    }

    @Test func survivesShortDropouts() {
        var sc = CalibrationScenario(seed: 12, optics: SimulatedOptics(displayRotation: 2.0), jitterSigma: 1)
        sc.dropoutProbability = 0.1
        let out = CalibrationSimulation(scenario: sc).run()
        #expect(out.result != nil, "failure: \(String(describing: out.failure))")
        #expect(AngleMath.degrees(out.rotationError ?? .pi) < 1)
    }

    @Test func earlyStopKeepsStarInsideField() {
        // theta = 0, not mirrored: stick UP moves the star +v, stick RIGHT moves it -u in the image.
        // Starting 100 px left of the center, the RIGHT move heads outward: the early STOP at 0.75 R ends
        // it after ~130 px instead of 190 px.
        let sc = CalibrationScenario(seed: 30, optics: SimulatedOptics(displayRotation: 0), jitterSigma: 0.5,
                                     reactionTime: 0.6, starOffset: Vec2(-100, 0))
        let out = CalibrationSimulation(scenario: sc).run()
        let r = try! #require(out.result, "failure: \(String(describing: out.failure))")
        #expect(AngleMath.degrees(out.rotationError!) < 1)
        #expect(!r.mirrored)
        let right = try! #require(out.measurements.first(where: { $0.direction == .right }))
        #expect(right.displacement < 170)
        #expect(out.measurements.allSatisfy { $0.displacement >= 0.6 * 190 })
    }

    // MARK: Failure modes

    @Test func diagonalPushFailsOrthogonality() {
        var sc = CalibrationScenario(seed: 21, optics: SimulatedOptics(displayRotation: 1.0), jitterSigma: 0.5)
        sc.mount.stickResponse = .analog
        sc.misalignmentUp = AngleMath.radians(10)
        sc.misalignmentRight = AngleMath.radians(-10)
        let out = CalibrationSimulation(scenario: sc).run()
        guard case .orthogonalityBad(let deg)? = out.failure else {
            Issue.record("expected orthogonalityBad, got \(String(describing: out.failure))")
            return
        }
        #expect(abs(deg - 20) < 2)
    }

    @Test func slightlyDiagonalPushWarns() {
        var sc = CalibrationScenario(seed: 22, optics: SimulatedOptics(displayRotation: 1.0), jitterSigma: 0.5)
        sc.mount.stickResponse = .analog
        sc.misalignmentUp = AngleMath.radians(5)
        sc.misalignmentRight = AngleMath.radians(-5)
        let out = CalibrationSimulation(scenario: sc).run()
        let r = try! #require(out.result)
        #expect(r.quality == .warning)
        #expect(abs(AngleMath.degrees(r.orthogonalityError) - 10) < 1.5)
    }

    @Test func noMotionTimesOut() {
        var s = makeSession()
        let prompts = runScript(&s, duration: 40) { _ in center }
        #expect(prompts.contains(.pressAndHold(.up)))
        #expect(s.failure == .noMotionDetected)
    }

    @Test func earlyReleaseIsTooShort() {
        var s = makeSession()
        _ = runScript(&s, duration: 30) { t in
            let moving = min(max(t - 3, 0), 2)  // 2 s at 30 px/s = 60 px, then stops
            return center + Vec2(0, -30) * moving
        }
        guard case .moveTooShort(let d, let target)? = s.failure else {
            Issue.record("expected moveTooShort, got \(String(describing: s.failure))")
            return
        }
        #expect(d > 50 && d < 70 && target == 190)
    }

    @Test func starLostDuringMove() {
        var s = makeSession()
        _ = runScript(&s, duration: 30) { t in
            if t > 4 && t < 6.5 { return nil }
            return center + Vec2(0, -30) * max(t - 3, 0)
        }
        #expect(s.failure == .starLost)
    }

    @Test func starNearEdge() {
        var s = makeSession()
        let start = center + Vec2(150, 0)
        let prompts = runScript(&s, duration: 30) { t in start + Vec2(40, 0) * max(t - 3, 0) }
        #expect(prompts.contains(.stop))
        #expect(s.failure == .nearEdge)
    }

    @Test func waitsForCenteredStarAndRestartsWhenLostEarly() {
        var s = makeSession()
        let far = runScript(&s, duration: 3) { _ in center + Vec2(250, 0) }
        #expect(far == [.centerStar])
        var s2 = makeSession()
        let prompts = runScript(&s2, duration: 5) { t in (t > 0.5 && t < 3) ? nil : center }
        #expect(s2.failure == nil)
        #expect(prompts.prefix(3) == [.holdStill, .centerStar, .holdStill])
    }

    @Test func moveMeasurementUsesMiddleForRate() {
        // Acceleration at the start and braking at the end do not bias the rate.
        var samples = [TrackSample]()
        var pos = 0.0, v = 0.0
        let dir = Vec2.unit(angle: 0.3)
        for i in 0..<100 {
            let t = Double(i) * 0.1
            v = t < 1 ? 25 * t : (t < 8 ? 25 : max(0, 25 - 25 * (t - 8)))
            pos += v * 0.1
            samples.append(TrackSample(t: t, p: Vec2(100, 100) + dir * pos))
        }
        let m = CalibrationSession.measure(samples, direction: .up, drift: .zero)!
        #expect(abs(m.velocity.length - 25) < 0.3)
        #expect(m.velocity.normalized.distance(to: dir) < 1e-6)
    }
}
