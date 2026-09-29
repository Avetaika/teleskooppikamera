import Foundation
import Testing
@testable import TeleskooppiCore

/// Phase 4 acceptance: the phase 1 closed-loop calibration, but the samples come from the real
/// detector + tracker running on rendered synthetic frames instead of ground-truth positions.
/// Only the tracker's search window is rendered each frame (cost proportional to the window), which
/// is exactly the region the tracker analyses.
@Suite struct PipelineAcceptanceTests {
    struct CaseResult: Sendable {
        var seed: UInt64
        var rotationErrorDeg: Double?
        var mirrorCorrect: Bool?
        var failure: String?
        var duration: Double
        var frames = 0
        var samples = 0
        var visibleFrames = 0
        var visibleWithSample = 0
        var maxPositionError = 0.0
        var lost = false
    }

    static func runPipeline(_ sc: CalibrationScenario) -> CaseResult {
        let sim = CalibrationSimulation(scenario: sc)
        let options = SimulatedSessionOptions()
        let sky = SimulatedSession.makeSky(scenario: sc, guideStar: sim.guideStar, options: options)
        let optics = sc.optics
        var config = StarTrackerConfig()
        config.acquisitionRegion = PixelRect.around(optics.opticalCenter, halfSize: 100)
        config.fieldMask = CircleMask(center: optics.opticalCenter, radius: optics.fieldRadius * 0.98)
        var tracker = StarTracker(config: config)
        var frame = GrayImage8(width: optics.imageWidth, height: optics.imageHeight,
                               fill: UInt8(clampingDouble: sky.configuration.bias))
        var rng = SplitMix64(seed: sc.seed &+ 99)
        var result = CaseResult(seed: sc.seed, duration: 0)

        let outcome = sim.run(observe: { f in
            let region = tracker.searchRegion(at: f.time).clipped(width: optics.imageWidth, height: optics.imageHeight)
            sky.render(into: &frame, window: region, boresight: f.boresight, imageOffset: f.jitter, rng: &rng)
            let sample = tracker.update(frame, time: f.time)
            result.frames += 1
            if sample != nil { result.samples += 1 }
            if f.visible {
                result.visibleFrames += 1
                if let s = sample {
                    result.visibleWithSample += 1
                    result.maxPositionError = max(result.maxPositionError, (s.p - (f.truePosition + f.jitter)).length)
                }
            }
            return sample
        })
        result.lost = tracker.state == .lost
        result.duration = outcome.duration
        result.rotationErrorDeg = outcome.rotationError.map(AngleMath.degrees)
        result.mirrorCorrect = outcome.mirrorCorrect
        if outcome.result == nil { result.failure = String(describing: outcome.failure) }
        return result
    }

    @Test func trackerKeepsLockThroughFullCalibration() {
        var sc = CalibrationScenario.random(seed: 7)
        sc.dropoutProbability = 0
        let r = Self.runPipeline(sc)
        print("[pipeline] single case: rotation error \(r.rotationErrorDeg ?? -1) deg, frames \(r.frames), "
            + "samples \(r.samples), max position error vs truth \(r.maxPositionError) px, failure \(r.failure ?? "-")")
        #expect(r.failure == nil)
        #expect(!r.lost)
        #expect(Double(r.visibleWithSample) >= 0.97 * Double(r.visibleFrames))
        #expect(r.maxPositionError < 1.0, "the tracker reported a position that does not match the true star")
        #expect((r.rotationErrorDeg ?? 99) < 2.0)
    }

    @Test func calibrationAcceptanceThroughDetectorAndTracker() async {
        let count = 60
        let scenarios = (1...count).map { CalibrationScenario.random(seed: UInt64(1000 + $0)) }
        let clock = ContinuousClock()
        var results = [CaseResult]()
        let started = clock.now
        results = await withTaskGroup(of: [CaseResult].self) { group in
            let chunks = 8
            for c in 0..<chunks {
                group.addTask {
                    var out = [CaseResult]()
                    var i = c
                    while i < scenarios.count {
                        out.append(Self.runPipeline(scenarios[i]))
                        i += chunks
                    }
                    return out
                }
            }
            var all = [CaseResult]()
            for await part in group { all += part }
            return all
        }
        let elapsed = clock.now - started
        let errors = results.compactMap { $0.rotationErrorDeg }
        let failures = results.filter { $0.failure != nil }
        let mirrorWrong = results.filter { $0.mirrorCorrect == false }
        let lost = results.filter { $0.lost }
        let sampleFraction = Double(results.reduce(0) { $0 + $1.visibleWithSample })
            / Double(max(results.reduce(0) { $0 + $1.visibleFrames }, 1))
        print("[pipeline] acceptance through detector+tracker: n=\(results.count), succeeded \(errors.count), "
            + "rotation error median \(Statistics.median(errors) ?? -1) deg, p95 \(p95(errors)) deg, "
            + "max \(errors.max() ?? -1) deg, mirror wrong \(mirrorWrong.count), lost \(lost.count), "
            + "visible frames with sample \(sampleFraction), max position error \(results.map { $0.maxPositionError }.max() ?? 0) px, "
            + "duration p95 \(Statistics.percentile(results.map { $0.duration }, 95) ?? 0) s, "
            + "wall time \(SessionReplay.milliseconds(elapsed)) ms, failures \(failures.prefix(5).map { "\($0.seed): \($0.failure ?? "")" })")
        #expect(failures.count <= 2, "failures: \(failures.map { "\($0.seed): \($0.failure ?? "")" })")
        #expect(mirrorWrong.isEmpty)
        #expect(p95(errors) < 1.5)
        #expect(sampleFraction > 0.97)
    }
}
