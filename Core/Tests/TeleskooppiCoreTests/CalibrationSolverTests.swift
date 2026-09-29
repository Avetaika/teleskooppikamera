import Foundation
import Testing
@testable import TeleskooppiCore

@Suite struct CalibrationSolverTests {
    @Test func exactRecoveryAllAnglesAndMirror() {
        for deg in stride(from: 0.0, to: 360.0, by: 1.0) {
            for mirrored in [false, true] {
                for (rateR, rateU) in [(20.0, 20.0), (8.0, 25.0), (60.0, 30.0)] {
                    let optics = SimulatedOptics(displayRotation: AngleMath.radians(deg), mirrored: mirrored)
                    let m = optics.expectedStickToImage(rightSkyRate: rateR * optics.plateScale,
                                                        upSkyRate: rateU * optics.plateScale)
                    let sol = CalibrationSolver.solve(mRight: m.column0, mUp: m.column1)!
                    #expect(sol.mirrored == mirrored)
                    #expect(abs(AngleMath.difference(sol.displayRotation, optics.displayRotation)) < 1e-9)
                    #expect(sol.orthogonalityError < 1e-9)
                    // R(theta) F^k maps the columns onto E (up to the rates).
                    let d = CalibrationSolver.displayMatrix(rotation: sol.displayRotation, mirrored: sol.mirrored)
                    #expect((d * m.column0).normalized.distance(to: Vec2(-1, 0)) < 1e-9)
                    #expect((d * m.column1).normalized.distance(to: Vec2(0, 1)) < 1e-9)
                }
            }
        }
    }

    @Test func rotationIsCircularMeanOfBothMoves() {
        // m_U rotated +4 deg and m_R rotated -2 deg from ideal: theta error is the mean (+1 deg).
        let mU = Vec2(0, 1).rotated(by: AngleMath.radians(4)) * 30
        let mR = Vec2(-1, 0).rotated(by: AngleMath.radians(-2)) * 30
        let sol = CalibrationSolver.solve(mRight: mR, mUp: mU)!
        #expect(!sol.mirrored)
        #expect(abs(AngleMath.degrees(sol.displayRotation) - (-1)) < 1e-9)
        #expect(abs(AngleMath.degrees(sol.orthogonalityError) - 6) < 1e-9)
    }

    @Test func degenerateInputs() {
        #expect(CalibrationSolver.solve(mRight: .zero, mUp: Vec2(0, 1)) == nil)
        #expect(CalibrationSolver.solve(mRight: Vec2(1, 1), mUp: Vec2(2, 2)) == nil)
        #expect(CalibrationSolver.solve(mRight: Vec2(1, 1), mUp: Vec2(-2, -2)) == nil)
    }

    @Test func quickRecalibrationFollowsPhoneRotation() {
        var rng = SplitMix64(seed: 77)
        for _ in 0..<200 {
            let mirrored = rng.bool()
            let before = SimulatedOptics(displayRotation: rng.uniform(0...(2 * .pi)), mirrored: mirrored)
            let mOld = before.expectedStickToImage(rightSkyRate: 120, upSkyRate: 240)
            // Phone rotated in the adapter and a different speed level.
            var after = before
            after.displayRotation += rng.uniform(-.pi ... .pi)
            let mNew = after.expectedStickToImage(rightSkyRate: 240, upSkyRate: 480)
            let sol = CalibrationSolver.quickRecalibration(mUp: mNew.column1, previous: mOld)!
            #expect(sol.mirrored == mirrored)
            #expect(abs(AngleMath.difference(sol.displayRotation, after.displayRotation)) < 1e-9)
            #expect(sol.stickToImage.maxAbsDifference(mNew) < 1e-6)
        }
    }

    @Test func resultIsCodable() throws {
        let r = CalibrationResult(stickToImage: Mat2(a: 1, b: 2, c: 3, d: 4), displayRotation: 0.5, mirrored: true,
                                  orthogonalityError: 0.01, lineResidual: 0.7, repeatability: nil,
                                  opticalCenter: Vec2(480, 360), fieldRadius: 380, driftVelocity: Vec2(0.1, -0.2),
                                  quality: .warning, isQuick: false,
                                  createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(CalibrationResult.self, from: data)
        #expect(back == r)
        let f = CalibrationFailure.orthogonalityBad(degrees: 17)
        #expect(try JSONDecoder().decode(CalibrationFailure.self, from: JSONEncoder().encode(f)) == f)
    }
}
