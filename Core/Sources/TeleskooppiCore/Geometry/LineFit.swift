import Foundation

/// Total-least-squares (orthogonal regression) line fit through 2D points, i.e. the principal
/// component of the point cloud. Used for the calibration move direction (D-07).
public struct LineFit: Sendable, Equatable {
    /// Mean of the points (a point on the line).
    public var centroid: Vec2
    /// Unit direction of the line. The sign is arbitrary unless oriented with `oriented(along:)`.
    public var direction: Vec2
    /// RMS of the perpendicular distances of the points from the line (pixels).
    public var rmsResidual: Double
    /// Min and max projection of the points onto `direction`, relative to `centroid`.
    public var extent: ClosedRange<Double>
    public var count: Int

    /// Length of the point cloud along the line.
    public var length: Double { extent.upperBound - extent.lowerBound }

    /// Fits a line; returns `nil` for fewer than two points or when all points coincide.
    public static func fit(_ points: [Vec2]) -> LineFit? {
        let n = points.count
        guard n >= 2 else { return nil }
        var mean = Vec2.zero
        for p in points { mean += p }
        mean = mean / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
        }
        sxx /= Double(n)
        syy /= Double(n)
        sxy /= Double(n)
        guard sxx + syy > 0 else { return nil }
        let phi = 0.5 * atan2(2 * sxy, sxx - syy)
        let dir = Vec2(cos(phi), sin(phi))
        let normal = dir.perpendicular
        var ss = 0.0
        var lo = Double.infinity, hi = -Double.infinity
        for p in points {
            let d = p - mean
            let r = d.dot(normal)
            ss += r * r
            let t = d.dot(dir)
            lo = min(lo, t)
            hi = max(hi, t)
        }
        return LineFit(centroid: mean, direction: dir, rmsResidual: (ss / Double(n)).squareRoot(),
                       extent: lo...hi, count: n)
    }

    /// Same line with `direction` flipped if needed so that `direction · v >= 0`.
    public func oriented(along v: Vec2) -> LineFit {
        guard direction.dot(v) < 0 else { return self }
        var f = self
        f.direction = -direction
        f.extent = (-extent.upperBound)...(-extent.lowerBound)
        return f
    }
}

/// Ordinary least-squares fit `y = intercept + slope * (x - xRef)`.
public struct LinearFit1D: Sendable, Equatable {
    public var slope: Double
    public var intercept: Double
    public var xRef: Double
    /// Standard error of the slope estimate (from residual scatter), `nil` when n < 3.
    public var slopeStandardError: Double?
    public var rmsResidual: Double
    public var count: Int

    public func value(at x: Double) -> Double { intercept + slope * (x - xRef) }

    /// `xRef` defaults to the mean of `xs`. Returns `nil` for fewer than two points or zero x spread.
    public static func fit(xs: [Double], ys: [Double], xRef: Double? = nil) -> LinearFit1D? {
        let n = min(xs.count, ys.count)
        guard n >= 2 else { return nil }
        var mx = 0.0, my = 0.0
        for i in 0..<n { mx += xs[i]; my += ys[i] }
        mx /= Double(n)
        my /= Double(n)
        var sxx = 0.0, sxy = 0.0
        for i in 0..<n {
            let dx = xs[i] - mx
            sxx += dx * dx
            sxy += dx * (ys[i] - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        var ss = 0.0
        for i in 0..<n {
            let r = ys[i] - (my + slope * (xs[i] - mx))
            ss += r * r
        }
        let se: Double? = n >= 3 ? (ss / Double(n - 2) / sxx).squareRoot() : nil
        let ref = xRef ?? mx
        return LinearFit1D(slope: slope, intercept: my + slope * (ref - mx), xRef: ref,
                           slopeStandardError: se, rmsResidual: (ss / Double(n)).squareRoot(), count: n)
    }
}

/// Least-squares fit of uniform 2D motion `p(t) = position + velocity * (t - tRef)`,
/// fitted independently per axis.
public struct LinearMotionFit: Sendable, Equatable {
    public var position: Vec2
    public var velocity: Vec2
    public var tRef: Double
    /// Standard error of the velocity (combined over both axes, px/s); `nil` when n < 3.
    public var velocityStandardError: Double?
    /// Per-axis RMS residual combined as `sqrt((rx^2 + ry^2) / 2)`: an estimate of the
    /// per-axis position noise sigma.
    public var noiseSigma: Double
    public var count: Int
    public var duration: Double

    public func position(at t: Double) -> Vec2 { position + velocity * (t - tRef) }

    public static func fit(times: [Double], points: [Vec2], tRef: Double? = nil) -> LinearMotionFit? {
        guard times.count == points.count,
              let fx = LinearFit1D.fit(xs: times, ys: points.map(\.x), xRef: tRef),
              let fy = LinearFit1D.fit(xs: times, ys: points.map(\.y), xRef: tRef ?? fitMean(times))
        else { return nil }
        let se: Double?
        if let sx = fx.slopeStandardError, let sy = fy.slopeStandardError {
            se = ((sx * sx + sy * sy) / 2).squareRoot()
        } else {
            se = nil
        }
        let n = Double(fx.count)
        // Unbiased-ish per-axis sigma from the residuals (two parameters per axis).
        let dof = max(n - 2, 1)
        let sigma = ((fx.rmsResidual * fx.rmsResidual + fy.rmsResidual * fy.rmsResidual) * n / (2 * dof)).squareRoot()
        let duration = (times.max() ?? 0) - (times.min() ?? 0)
        return LinearMotionFit(position: Vec2(fx.intercept, fy.intercept), velocity: Vec2(fx.slope, fy.slope),
                               tRef: fx.xRef, velocityStandardError: se, noiseSigma: sigma,
                               count: fx.count, duration: duration)
    }

    private static func fitMean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(max(xs.count, 1))
    }
}
