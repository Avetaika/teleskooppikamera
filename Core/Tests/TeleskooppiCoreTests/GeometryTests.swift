import Foundation
import Testing
@testable import TeleskooppiCore

@Suite struct GeometryTests {
    @Test func vectorBasics() {
        let a = Vec2(3, 4)
        #expect(a.length == 5)
        #expect(a.normalized.length.isApproximately(1))
        #expect((a + Vec2(1, 1)) == Vec2(4, 5))
        #expect(a.dot(Vec2(1, 0)) == 3)
        #expect(Vec2(1, 0).cross(Vec2(0, 1)) == 1)
        let r = Vec2(1, 0).rotated(by: .pi / 2)
        #expect(r.x.isApproximately(0) && r.y.isApproximately(1))
        #expect(Vec2(1, 0).signedAngle(to: Vec2(0, -1)).isApproximately(-.pi / 2))
        #expect(Vec2.zero.normalized == .zero)
    }

    @Test func matrixInverseAndDeterminant() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let m = Mat2(a: rng.uniform(-5...5), b: rng.uniform(-5...5), c: rng.uniform(-5...5), d: rng.uniform(-5...5))
            guard abs(m.determinant) > 1e-3, let inv = m.inverse else { continue }
            #expect((m * inv).maxAbsDifference(.identity) < 1e-9)
            #expect((inv * m).maxAbsDifference(.identity) < 1e-9)
            let v = Vec2(rng.uniform(-3...3), rng.uniform(-3...3))
            let w = m * v
            #expect((inv * w - v).length < 1e-9)
        }
        #expect(Mat2(a: 1, b: 2, c: 2, d: 4).inverse == nil)
        #expect(Mat2.rotation(0.7).determinant.isApproximately(1))
        #expect(Mat2.flipX.determinant == -1)
        let cols = Mat2(columns: Vec2(1, 2), Vec2(3, 4))
        #expect(cols.column0 == Vec2(1, 2) && cols.column1 == Vec2(3, 4))
        #expect(cols.row0 == Vec2(1, 3))
    }

    @Test func rotationMatrixMatchesVectorRotation() {
        for deg in stride(from: -360.0, through: 360.0, by: 15) {
            let a = AngleMath.radians(deg)
            let v = Vec2(0.3, -1.7)
            #expect((Mat2.rotation(a) * v - v.rotated(by: a)).length < 1e-12)
        }
    }

    @Test func affineComposeInverseAndLayouts() {
        let a = Affine2(linear: Mat2.rotation(0.3) * 2, translation: Vec2(5, -2))
        let b = Affine2(linear: .flipX, translation: Vec2(1, 1))
        let p = Vec2(3, 7)
        #expect(((a * b).apply(p) - a.apply(b.apply(p))).length < 1e-12)
        let inv = a.inverse!
        #expect((inv.apply(a.apply(p)) - p).length < 1e-12)
        let rm = a.rowMajor3x3
        #expect(rm[2] == 5 && rm[5] == -2 && rm[8] == 1 && rm[6] == 0)
        let cm = a.columnMajor3x3
        #expect(cm[6] == 5 && cm[7] == -2 && cm[1] == a.linear.c)
        let metal = a.metalFloat3x3Padded
        #expect(metal.count == 12)
        #expect(metal[8] == 5 && metal[9] == -2 && metal[10] == 1)
        #expect(metal[3] == 0 && metal[7] == 0 && metal[11] == 0)
        #expect(metal[1] == Float(a.linear.c))
    }

    @Test func angleWrapping() {
        #expect(AngleMath.wrapPi(3 * .pi).isApproximately(.pi))
        #expect(AngleMath.wrapPi(-3 * .pi).isApproximately(.pi))
        #expect(AngleMath.wrapPi(-.pi / 2).isApproximately(-.pi / 2))
        #expect(AngleMath.wrapTwoPi(-.pi / 2).isApproximately(1.5 * .pi))
        #expect(AngleMath.wrapDegrees360(-10) == 350)
        #expect(AngleMath.wrapDegrees360(720) == 0)
        #expect(AngleMath.difference(AngleMath.radians(350), AngleMath.radians(10)).isApproximately(AngleMath.radians(-20)))
    }

    @Test func circularMean() {
        let m = AngleMath.circularMean([AngleMath.radians(350), AngleMath.radians(10)])!
        #expect(abs(m) < 1e-12)
        let m2 = AngleMath.circularMean([AngleMath.radians(170), AngleMath.radians(-170)])!
        #expect(abs(AngleMath.difference(m2, .pi)) < 1e-12)
        #expect(AngleMath.circularMean([0, .pi]) == nil)
        #expect(AngleMath.circularMean([]) == nil)
        let w = AngleMath.circularMean([0, .pi / 2], weights: [1, 3])!
        #expect(w.isApproximately(atan2(3, 1)))
    }

    @Test func tlsLineFitRecoversDirection() {
        var rng = SplitMix64(seed: 42)
        for trial in 0..<100 {
            let angle = rng.uniform(-.pi ... .pi)
            let dir = Vec2.unit(angle: angle)
            let origin = Vec2(rng.uniform(0...500), rng.uniform(0...500))
            let sigma = 0.5
            var pts = [Vec2]()
            for i in 0..<60 {
                let along = Double(i) * 5
                pts.append(origin + dir * along + Vec2(rng.gaussian(), rng.gaussian()) * sigma)
            }
            let fit = LineFit.fit(pts)!.oriented(along: pts.last! - pts.first!)
            let err = abs(fit.direction.signedAngle(to: dir))
            #expect(err < AngleMath.radians(0.2), "trial \(trial): \(AngleMath.degrees(err)) deg")
            #expect(fit.rmsResidual < 1.0 && fit.rmsResidual > 0.2)
            #expect(fit.length > 280 && fit.length < 310)
        }
        // Vertical line (TLS handles it, OLS y(x) would not).
        let vertical = (0..<10).map { Vec2(3, Double($0)) }
        let vf = LineFit.fit(vertical)!
        #expect(abs(vf.direction.x) < 1e-12 && vf.rmsResidual < 1e-12)
        #expect(LineFit.fit([Vec2(1, 1)]) == nil)
        #expect(LineFit.fit([Vec2(1, 1), Vec2(1, 1)]) == nil)
    }

    @Test func linearFits() {
        let xs = (0..<20).map(Double.init)
        let ys = xs.map { 2.5 * $0 - 1 }
        let f = LinearFit1D.fit(xs: xs, ys: ys)!
        #expect(f.slope.isApproximately(2.5) && f.value(at: 0).isApproximately(-1))
        #expect(f.slopeStandardError! < 1e-9)
        let times = (0..<30).map { Double($0) * 0.1 }
        let pts = times.map { Vec2(10 + 3 * $0, 20 - 1.5 * $0) }
        let mf = LinearMotionFit.fit(times: times, points: pts)!
        #expect((mf.velocity - Vec2(3, -1.5)).length < 1e-9)
        #expect((mf.position(at: 0) - Vec2(10, 20)).length < 1e-9)
        #expect(mf.noiseSigma < 1e-9)
    }

    @Test func splitMixIsDeterministic() {
        var a = SplitMix64(seed: 123), b = SplitMix64(seed: 123)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
        var r = SplitMix64(seed: 1)
        var sum = 0.0, sum2 = 0.0
        let n = 20000
        for _ in 0..<n {
            let g = r.gaussian()
            sum += g
            sum2 += g * g
        }
        #expect(abs(sum / Double(n)) < 0.03)
        #expect(abs(sum2 / Double(n) - 1) < 0.05)
        var pm = 0.0
        for _ in 0..<5000 { pm += r.poisson(4) }
        #expect(abs(pm / 5000 - 4) < 0.15)
    }
}

extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) <= tolerance
    }
}
