import Foundation
import Testing
@testable import TeleskooppiCore

/// Plan 4.8 / phase 1 acceptance: closed-loop simulated calibrations with ground-truth star
/// positions + jitter as `TrackSample`s (no star detector yet, that is phase 4).
@Suite struct CalibrationAcceptanceTests {
    struct Summary: Sendable {
        var errorsDeg: [Double] = []
        var mirrorWrong: [UInt64] = []
        var failures: [(seed: UInt64, failure: String)] = []
        var durations: [Double] = []

        mutating func add(_ o: CalibrationRunOutcome) {
            if let e = o.rotationError {
                errorsDeg.append(AngleMath.degrees(e))
                durations.append(o.duration)
                if o.mirrorCorrect != true { mirrorWrong.append(o.scenario.seed) }
            } else {
                failures.append((o.scenario.seed, String(describing: o.failure)))
            }
        }

        mutating func merge(_ o: Summary) {
            errorsDeg += o.errorsDeg
            mirrorWrong += o.mirrorWrong
            failures += o.failures
            durations += o.durations
        }
    }

    /// Runs scenarios in parallel chunks.
    static func runAll(_ scenarios: [CalibrationScenario]) async -> Summary {
        let chunks = 8
        return await withTaskGroup(of: Summary.self) { group in
            for c in 0..<chunks {
                group.addTask {
                    var s = Summary()
                    var i = c
                    while i < scenarios.count {
                        s.add(CalibrationSimulation(scenario: scenarios[i]).run())
                        i += chunks
                    }
                    return s
                }
            }
            var total = Summary()
            for await s in group { total.merge(s) }
            return total
        }
    }

    @Test func thousandRandomCases() async {
        let scenarios = (1...1000).map { CalibrationScenario.random(seed: UInt64($0)) }
        let s = await Self.runAll(scenarios)
        let p95 = Statistics.percentile(s.errorsDeg, 95) ?? .infinity
        let median = Statistics.median(s.errorsDeg) ?? .infinity
        print("[acceptance] random: n=\(s.errorsDeg.count)/1000, rotation error median \(median) deg, "
            + "p95 \(p95) deg, max \(s.errorsDeg.max() ?? 0) deg, mirror wrong \(s.mirrorWrong.count), "
            + "median duration \(Statistics.median(s.durations) ?? 0) s, failures \(s.failures.prefix(10))")
        #expect(s.failures.isEmpty, "failures: \(s.failures.prefix(20))")
        #expect(s.errorsDeg.count >= 1000 - s.failures.count)
        #expect(p95 < 1.0)
        #expect(s.mirrorWrong.isEmpty, "mirror wrong for seeds \(s.mirrorWrong)")
    }

    /// Plan phase 1: all rotation angles 0-360 in 5 deg steps x mirror x backlash x drift.
    @Test func angleGrid() async {
        var scenarios = [CalibrationScenario]()
        var seed: UInt64 = 10_000
        for deg in stride(from: 0.0, to: 360.0, by: 5.0) {
            for mirrored in [false, true] {
                for backlash in [0.0, 900.0] {
                    for drift in [0.0, 15.0] {
                        seed += 1
                        var sc = CalibrationScenario.random(seed: seed)
                        sc.optics.displayRotation = AngleMath.radians(deg)
                        sc.optics.mirrored = mirrored
                        sc.mount.backlash = Vec2(backlash, backlash)
                        sc.mount.driftArcsecPerSecond = sc.mount.driftArcsecPerSecond.normalized * drift
                        scenarios.append(sc)
                    }
                }
            }
        }
        let s = await Self.runAll(scenarios)
        let p95 = Statistics.percentile(s.errorsDeg, 95) ?? .infinity
        print("[acceptance] grid: n=\(s.errorsDeg.count)/\(scenarios.count), p95 \(p95) deg, "
            + "max \(s.errorsDeg.max() ?? 0) deg, mirror wrong \(s.mirrorWrong.count)")
        #expect(s.failures.isEmpty, "failures: \(s.failures.prefix(20))")
        #expect(p95 < 1.0)
        #expect(s.mirrorWrong.isEmpty)
    }
}
