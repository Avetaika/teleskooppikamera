import Foundation

/// The eyepiece field stop as a circle in image pixels.
public struct FieldCircle: Sendable, Codable, Equatable {
    public var center: Vec2
    public var radius: Double
    /// 0...1: arc coverage of the visible circumference times the inlier ratio of the edge points.
    public var confidence: Double
    public var inlierCount: Int
    public var edgePointCount: Int

    public init(center: Vec2, radius: Double, confidence: Double, inlierCount: Int, edgePointCount: Int) {
        self.center = center
        self.radius = radius
        self.confidence = confidence
        self.inlierCount = inlierCount
        self.edgePointCount = edgePointCount
    }
}

public struct FieldCircleConfig: Sendable, Codable, Equatable {
    /// Binning used for edge extraction.
    public var binning = 4
    /// Radius limits as fractions of the smaller image side.
    public var minRadiusFraction = 0.2
    public var maxRadiusFraction = 1.2
    /// Inlier distance in binned pixels.
    public var inlierTolerance = 1.5
    public var iterations = 600
    public var minEdgePoints = 40
    /// Minimum contrast (gray levels) between the bright field and the dark surround.
    public var minContrast = 20.0
    public var seed: UInt64 = 0xF1E1D

    public init() {}
}

/// Finds the bright eyepiece field circle (daytime / bright sky, D-17). The edge of the bright disk
/// is extracted from an Otsu-thresholded, binned image and a circle is fitted with RANSAC followed by a
/// least-squares refinement, so a field that is cut off at the top and bottom of the 4:3 frame still
/// gives the right center and radius. Points on the image border are never edge points.
public struct FieldCircleDetector: Sendable {
    public var config: FieldCircleConfig

    public init(config: FieldCircleConfig = FieldCircleConfig()) {
        self.config = config
    }

    public func detect(_ image: GrayImage8) -> FieldCircle? {
        let bin = max(config.binning, 1)
        let plane = FloatPlane(image).binned(bin)
        let w = plane.width, h = plane.height
        guard w >= 16, h >= 16 else { return nil }

        // Otsu threshold.
        var hist = [Double](repeating: 0, count: 256)
        for v in plane.data { hist[min(max(Int(v.rounded()), 0), 255)] += 1 }
        let total = Double(plane.data.count)
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i) * hist[i] }
        var wB = 0.0, sumB = 0.0, bestVar = -1.0, threshold = 127.0
        var meanLow = 0.0, meanHigh = 0.0
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t) * hist[t]
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > bestVar {
                bestVar = between
                threshold = Double(t) + 0.5
                meanLow = mB
                meanHigh = mF
            }
        }
        guard meanHigh - meanLow >= config.minContrast else { return nil }

        // Edge points: midpoints between a bright pixel and a dark 4-neighbour inside the image.
        var bright = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { bright[i] = Double(plane.data[i]) > threshold }
        var points = [Vec2]()
        func full(_ bx: Double, _ by: Double) -> Vec2 {
            Vec2(bx * Double(bin) + Double(bin - 1) / 2, by * Double(bin) + Double(bin - 1) / 2)
        }
        for y in 0..<h {
            for x in 0..<w where bright[y * w + x] {
                if x + 1 < w, !bright[y * w + x + 1] { points.append(full(Double(x) + 0.5, Double(y))) }
                if x > 0, !bright[y * w + x - 1] { points.append(full(Double(x) - 0.5, Double(y))) }
                if y + 1 < h, !bright[(y + 1) * w + x] { points.append(full(Double(x), Double(y) + 0.5)) }
                if y > 0, !bright[(y - 1) * w + x] { points.append(full(Double(x), Double(y) - 0.5)) }
            }
        }
        guard points.count >= config.minEdgePoints else { return nil }
        let edgeCount = points.count
        if points.count > 4000 {
            let stride = points.count / 4000 + 1
            points = points.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        }

        let minSide = Double(min(image.width, image.height))
        let rMin = config.minRadiusFraction * minSide, rMax = config.maxRadiusFraction * minSide
        let tolerance = config.inlierTolerance * Double(bin)

        // RANSAC on 3-point circles.
        var rng = SplitMix64(seed: config.seed)
        var bestCount = 0
        var bestCircle: (c: Vec2, r: Double)?
        for _ in 0..<config.iterations {
            let a = points[rng.int(in: 0...(points.count - 1))]
            let b = points[rng.int(in: 0...(points.count - 1))]
            let c = points[rng.int(in: 0...(points.count - 1))]
            guard let circle = Self.circle(a, b, c), circle.r >= rMin, circle.r <= rMax else { continue }
            var count = 0
            for p in points where abs((p - circle.c).length - circle.r) <= tolerance { count += 1 }
            if count > bestCount {
                bestCount = count
                bestCircle = circle
            }
        }
        guard var current = bestCircle, bestCount >= config.minEdgePoints / 2 else { return nil }

        // Refit on inliers (algebraic start, then Gauss-Newton), twice with re-selected inliers.
        var inliers = [Vec2]()
        for _ in 0..<3 {
            inliers = points.filter { abs(($0 - current.c).length - current.r) <= tolerance }
            guard inliers.count >= 8 else { break }
            if let fit = Self.fitCircle(inliers, start: current) { current = fit }
        }
        guard current.r >= rMin, current.r <= rMax, inliers.count >= 8 else { return nil }
        inliers = points.filter { abs(($0 - current.c).length - current.r) <= tolerance }

        // Confidence: coverage of the part of the circle that is inside the frame, times inlier ratio.
        let sectors = 72
        var expected = [Bool](repeating: false, count: sectors)
        var covered = [Bool](repeating: false, count: sectors)
        for s in 0..<sectors {
            let angle = 2 * Double.pi * (Double(s) + 0.5) / Double(sectors)
            let p = current.c + Vec2.unit(angle: angle) * current.r
            expected[s] = p.x >= 2 && p.y >= 2 && p.x <= Double(image.width) - 3 && p.y <= Double(image.height) - 3
        }
        for p in inliers {
            let d = p - current.c
            var a = atan2(d.y, d.x)
            if a < 0 { a += 2 * Double.pi }
            covered[min(Int(a / (2 * Double.pi) * Double(sectors)), sectors - 1)] = true
        }
        let expectedCount = expected.filter { $0 }.count
        var coverage = 0.0
        if expectedCount >= 6 {
            var hit = 0
            for s in 0..<sectors where expected[s] && covered[s] { hit += 1 }
            coverage = Double(hit) / Double(expectedCount)
        }
        let ratio = Double(inliers.count) / Double(points.count)
        let confidence = coverage * min(1, ratio / 0.6)
        return FieldCircle(center: current.c, radius: current.r, confidence: confidence,
                           inlierCount: inliers.count, edgePointCount: edgeCount)
    }

    /// Circle through three points, nil when (nearly) collinear.
    static func circle(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> (c: Vec2, r: Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-6 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = Vec2(ux, uy)
        return (center, (a - center).length)
    }

    /// Least-squares circle fit: algebraic (Kasa) start, then Gauss-Newton on the geometric distance.
    static func fitCircle(_ pts: [Vec2], start: (c: Vec2, r: Double)) -> (c: Vec2, r: Double)? {
        let n = Double(pts.count)
        guard n >= 3 else { return nil }
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        // Kasa on centered coordinates: minimize sum (u^2 + v^2 + A u + B v + C)^2.
        var suu = 0.0, suv = 0.0, svv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for p in pts {
            let u = p.x - mx, v = p.y - my
            suu += u * u
            suv += u * v
            svv += v * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
        }
        var center = start.c
        var radius = start.r
        let det = suu * svv - suv * suv
        if abs(det) > 1e-9 {
            let rhs1 = 0.5 * (suuu + suvv), rhs2 = 0.5 * (svvv + svuu)
            let uc = (rhs1 * svv - rhs2 * suv) / det
            let vc = (rhs2 * suu - rhs1 * suv) / det
            let c = Vec2(uc + mx, vc + my)
            let r = (uc * uc + vc * vc + (suu + svv) / n).squareRoot()
            if r.isFinite, c.isFinite { center = c; radius = r }
        }
        // Gauss-Newton refinement of (cx, cy, r).
        for _ in 0..<8 {
            var jtj = [Double](repeating: 0, count: 9)
            var jtr = [Double](repeating: 0, count: 3)
            for p in pts {
                let d = p - center
                let dist = max(d.length, 1e-9)
                let res = dist - radius
                let j = [-d.x / dist, -d.y / dist, -1.0]
                for i in 0..<3 {
                    jtr[i] += j[i] * res
                    for k in 0..<3 { jtj[i * 3 + k] += j[i] * j[k] }
                }
            }
            guard let delta = solve3(jtj, jtr) else { break }
            center = Vec2(center.x - delta[0], center.y - delta[1])
            radius -= delta[2]
            if abs(delta[0]) + abs(delta[1]) + abs(delta[2]) < 1e-6 { break }
        }
        guard center.isFinite, radius.isFinite, radius > 0 else { return nil }
        return (center, radius)
    }

    /// Solves a 3x3 linear system (row-major) by Gaussian elimination with partial pivoting.
    static func solve3(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b
        for col in 0..<3 {
            var pivot = col
            for r in (col + 1)..<3 where abs(m[r * 3 + col]) > abs(m[pivot * 3 + col]) { pivot = r }
            guard abs(m[pivot * 3 + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<3 { m.swapAt(col * 3 + k, pivot * 3 + k) }
                v.swapAt(col, pivot)
            }
            for r in (col + 1)..<3 {
                let f = m[r * 3 + col] / m[col * 3 + col]
                for k in col..<3 { m[r * 3 + k] -= f * m[col * 3 + k] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for r in stride(from: 2, through: 0, by: -1) {
            var s = v[r]
            for k in (r + 1)..<3 where k < 3 { s -= m[r * 3 + k] * x[k] }
            x[r] = s / m[r * 3 + r]
        }
        return x
    }
}
