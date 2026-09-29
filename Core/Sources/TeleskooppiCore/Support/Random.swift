import Foundation

/// Small, fast, seedable PRNG (SplitMix64). Deterministic on every platform, so simulations and
/// tests are reproducible. Not cryptographically secure.
public struct SplitMix64: RandomNumberGenerator, Sendable, Hashable, Codable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1) with 53 random bits.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Uniform double in `range`.
    public mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }

    /// Uniform integer in `range` (slightly biased for huge ranges; fine for simulation).
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    public mutating func bool(probability p: Double = 0.5) -> Bool {
        nextUnit() < p
    }

    /// Standard normal deviate (Box-Muller, one value per call).
    public mutating func gaussian() -> Double {
        var u1 = nextUnit()
        if u1 < 1e-300 { u1 = 1e-300 }
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    public mutating func gaussian(mean: Double, sigma: Double) -> Double {
        mean + sigma * gaussian()
    }

    /// Poisson deviate. Exact (Knuth) for small means, normal approximation above 30.
    public mutating func poisson(_ mean: Double) -> Double {
        guard mean > 0 else { return 0 }
        if mean > 30 {
            return max(0, (mean + mean.squareRoot() * gaussian()).rounded())
        }
        let l = exp(-mean)
        var k = 0.0
        var p = 1.0
        repeat {
            k += 1
            p *= nextUnit()
        } while p > l
        return k - 1
    }

    /// Derives an independent generator (for sub-streams that must not disturb this one).
    public mutating func split() -> SplitMix64 {
        SplitMix64(seed: next())
    }
}
