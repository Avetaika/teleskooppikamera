import Foundation

/// Angle helpers. All angles are radians unless the name says otherwise.
public enum AngleMath {
    public static let twoPi = 2 * Double.pi

    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Wraps to the range (-pi, pi].
    public static func wrapPi(_ a: Double) -> Double {
        guard a.isFinite else { return a }
        var r = a.truncatingRemainder(dividingBy: twoPi)
        if r <= -.pi { r += twoPi }
        if r > .pi { r -= twoPi }
        return r
    }

    /// Wraps to the range [0, 2pi).
    public static func wrapTwoPi(_ a: Double) -> Double {
        guard a.isFinite else { return a }
        var r = a.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        if r >= twoPi { r -= twoPi }
        return r
    }

    /// Wraps degrees to [0, 360).
    public static func wrapDegrees360(_ a: Double) -> Double {
        guard a.isFinite else { return a }
        var r = a.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        if r >= 360 { r -= 360 }
        return r
    }

    /// Smallest signed difference `a - b`, wrapped to (-pi, pi].
    @inlinable public static func difference(_ a: Double, _ b: Double) -> Double {
        wrapPi(a - b)
    }

    /// Circular (vector) mean of angles: `atan2(sum w sin, sum w cos)`. Returns `nil` when the
    /// resultant is (numerically) zero, e.g. for two opposite angles.
    public static func circularMean(_ angles: [Double], weights: [Double]? = nil) -> Double? {
        guard !angles.isEmpty else { return nil }
        var s = 0.0, c = 0.0, wsum = 0.0
        for (i, a) in angles.enumerated() {
            let w = weights?[i] ?? 1
            s += w * sin(a)
            c += w * cos(a)
            wsum += abs(w)
        }
        guard wsum > 0, (s * s + c * c).squareRoot() > 1e-12 * wsum else { return nil }
        return atan2(s, c)
    }
}
