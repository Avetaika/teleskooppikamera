import Foundation

/// Median / MAD summary. `sigma` is the MAD scaled to a Gaussian standard deviation (x 1.4826).
public struct RobustStats: Sendable, Equatable {
    public var median: Double
    public var mad: Double
    public var sigma: Double { mad * 1.4826 }
    public var count: Int
}

public enum Statistics {
    public static func mean(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Sample standard deviation (n - 1).
    public static func standardDeviation(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        let ss = v.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(v.count - 1)).squareRoot()
    }

    public static func rms(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : (v.reduce(0) { $0 + $1 * $1 } / Double(v.count)).squareRoot()
    }

    /// Median (average of the two middle values for even counts).
    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    /// Percentile with linear interpolation, `p` in [0, 100].
    public static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let pos = min(max(p, 0), 100) / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let f = pos - Double(lo)
        return s[lo] * (1 - f) + s[hi] * f
    }

    /// Median absolute deviation from the median.
    public static func mad(_ v: [Double]) -> Double? {
        guard let m = median(v) else { return nil }
        return median(v.map { abs($0 - m) })
    }

    public static func robust(_ v: [Double]) -> RobustStats {
        let m = median(v) ?? 0
        let d = median(v.map { abs($0 - m) }) ?? 0
        return RobustStats(median: m, mad: d, count: v.count)
    }
}
