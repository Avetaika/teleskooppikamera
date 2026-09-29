import Foundation

/// Float image plane used by the shift estimator and the field circle detector.
struct FloatPlane: Sendable {
    var width: Int
    var height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]) {
        self.width = width
        self.height = height
        self.data = data
    }

    init(_ image: GrayImage8) {
        width = image.width
        height = image.height
        var d = [Float](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let src = y * image.stride, dst = y * image.width
            for x in 0..<image.width { d[dst + x] = Float(image.pixels[src + x]) }
        }
        data = d
    }

    /// Box-average binning by `factor` (trailing rows/columns that do not fill a bin are dropped).
    func binned(_ factor: Int) -> FloatPlane {
        if factor <= 1 { return self }
        let w = width / factor, h = height / factor
        var out = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(factor * factor)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dy in 0..<factor {
                    let row = (y * factor + dy) * width + x * factor
                    for dx in 0..<factor { s += data[row + dx] }
                }
                out[y * w + x] = s * inv
            }
        }
        return FloatPlane(width: w, height: h, data: out)
    }
}

public struct ShiftEstimatorConfig: Sendable, Codable, Equatable {
    /// Binning factors of the pyramid, coarse to fine. Levels whose smaller side would be under 24
    /// pixels are dropped. The default is 16x -> 4x -> 2x (plan 4.9 uses 4x as the working level; the
    /// 2x level and the fractional refinement give the sub-pixel accuracy).
    public var binning: [Int] = [16, 4, 2]
    /// Largest shift searched without a hint, as a fraction of the smaller image side.
    public var maxShiftFraction = 0.4
    /// Search radius around the hint (px) when one is available.
    public var hintRadius = 24.0
    /// Minimum overlap of the compared areas, as a fraction of the plane area.
    public var minOverlapFraction = 0.4
    /// Estimates with a lower normalized correlation are rejected.
    public var minCorrelation = 0.4
    /// Starts a new keyframe when the shift against the current one exceeds this fraction of the smaller side.
    public var rekeyFraction = 0.25
    /// Fractional refinement step sizes in fine-level pixels.
    public var refinementSteps: [Double] = [0.5, 0.25]

    public init() {}
}

/// Result of registering one image against a reference.
public struct ShiftEstimate: Sendable, Equatable {
    /// Content displacement in full-resolution pixels: `image(x) == reference(x - shift)`.
    public var shift: Vec2
    /// Normalized cross-correlation at the optimum, in [-1, 1].
    public var correlation: Double
}

/// Whole-frame translation estimator (D-12, plan 4.9): binned normalized cross-correlation from coarse
/// to fine with sub-pixel refinement. Used for daytime calibration (no star needed) and later for EAA
/// alignment. `update` accumulates the shift against keyframes and emits a `TrackSample` that behaves
/// like a star position: `origin + cumulative displacement of the scene`.
public struct ShiftEstimator: Sendable {
    struct Pyramid: Sendable {
        var levels: [(factor: Int, plane: FloatPlane)]
        var width: Int
        var height: Int
    }

    public var config: ShiftEstimatorConfig
    /// Virtual position at the start (e.g. the optical center or a marked feature).
    public var origin: Vec2

    private var keyframe: Pyramid?
    private var keyOffset = Vec2.zero
    private var lastShiftFromKey = Vec2.zero
    private var lastStep = 0.0
    /// Latest cumulative position.
    public private(set) var position: Vec2
    public private(set) var lastCorrelation = 0.0
    public private(set) var consecutiveFailures = 0

    public init(config: ShiftEstimatorConfig = ShiftEstimatorConfig(), origin: Vec2 = .zero) {
        self.config = config
        self.origin = origin
        position = origin
    }

    public mutating func reset() {
        keyframe = nil
        keyOffset = .zero
        lastShiftFromKey = .zero
        lastStep = 0
        position = origin
        consecutiveFailures = 0
    }

    /// Registers `image`; returns the cumulative position sample, or nil when the correlation is too low.
    public mutating func update(_ image: GrayImage8, time: Double) -> TrackSample? {
        let pyramid = Self.buildPyramid(image, config: config)
        guard let key = keyframe else {
            keyframe = pyramid
            position = origin
            lastCorrelation = 1
            return TrackSample(t: time, p: origin, quality: 1)
        }
        let hint = lastShiftFromKey
        var estimate = Self.estimate(reference: key, image: pyramid, config: config, hint: hint,
                                     hintRadius: max(config.hintRadius, 4 * lastStep))
        if estimate == nil || estimate!.correlation < config.minCorrelation {
            // Lost track around the hint: search the full range once.
            estimate = Self.estimate(reference: key, image: pyramid, config: config, hint: nil, hintRadius: 0)
        }
        guard let e = estimate, e.correlation >= config.minCorrelation else {
            consecutiveFailures += 1
            return nil
        }
        consecutiveFailures = 0
        lastCorrelation = e.correlation
        lastStep = (e.shift - lastShiftFromKey).length
        lastShiftFromKey = e.shift
        position = origin + keyOffset + e.shift
        let minSide = Double(min(image.width, image.height))
        if e.shift.length > config.rekeyFraction * minSide {
            keyframe = pyramid
            keyOffset = keyOffset + e.shift
            lastShiftFromKey = .zero
        }
        return TrackSample(t: time, p: position, quality: min(1, max(0.05, e.correlation)))
    }

    /// Estimates the displacement of `image` relative to `reference` (full-resolution pixels).
    public static func estimateShift(reference: GrayImage8, image: GrayImage8,
                                     config: ShiftEstimatorConfig = ShiftEstimatorConfig()) -> ShiftEstimate? {
        estimate(reference: buildPyramid(reference, config: config), image: buildPyramid(image, config: config),
                 config: config, hint: nil, hintRadius: 0)
    }

    // MARK: Internals

    static func buildPyramid(_ image: GrayImage8, config: ShiftEstimatorConfig) -> Pyramid {
        let base = FloatPlane(image)
        let minSide = min(image.width, image.height)
        var factors = config.binning.filter { $0 >= 1 && minSide / $0 >= 24 }.sorted(by: >)
        if factors.isEmpty { factors = [1] }
        var levels = [(factor: Int, plane: FloatPlane)]()
        // Chain the binning: each level is built from the previous finer one where the factors divide.
        var previous: (factor: Int, plane: FloatPlane) = (1, base)
        for f in factors.sorted() {
            let step = f / previous.factor
            let plane = (step > 1 && f % previous.factor == 0) ? previous.plane.binned(step) : base.binned(f)
            previous = (f, plane)
            levels.append(previous)
        }
        levels.reverse()  // coarse to fine
        return Pyramid(levels: levels, width: image.width, height: image.height)
    }

    /// Normalized cross-correlation of `cur(x)` with `ref(x - s)` (bilinear for fractional shifts).
    /// Returns nil when the overlap is too small.
    static func ncc(ref: FloatPlane, cur: FloatPlane, shift s: Vec2, minOverlap: Double) -> Double? {
        let w = cur.width, h = cur.height
        let xa = max(0, Int(s.x.rounded(.up))), xb = min(w - 1, Int((s.x + Double(ref.width - 1)).rounded(.down)))
        let ya = max(0, Int(s.y.rounded(.up))), yb = min(h - 1, Int((s.y + Double(ref.height - 1)).rounded(.down)))
        guard xa <= xb, ya <= yb else { return nil }
        let n = Double((xb - xa + 1) * (yb - ya + 1))
        guard n >= minOverlap * Double(w * h) else { return nil }
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        let integer = s.x == s.x.rounded() && s.y == s.y.rounded()
        if integer {
            let ix = Int(s.x), iy = Int(s.y)
            for y in ya...yb {
                let crow = y * w
                let rrow = (y - iy) * ref.width - ix
                for x in xa...xb {
                    let a = Double(cur.data[crow + x]), b = Double(ref.data[rrow + x])
                    sa += a
                    sb += b
                    saa += a * a
                    sbb += b * b
                    sab += a * b
                }
            }
        } else {
            for y in ya...yb {
                let ry = Double(y) - s.y
                let y0 = min(Int(ry.rounded(.down)), ref.height - 1)
                let y1 = min(y0 + 1, ref.height - 1)
                let wy = ry - Double(y0)
                for x in xa...xb {
                    let rx = Double(x) - s.x
                    let x0 = min(Int(rx.rounded(.down)), ref.width - 1)
                    let x1 = min(x0 + 1, ref.width - 1)
                    let wx = rx - Double(x0)
                    let p00 = Double(ref.data[y0 * ref.width + x0]), p01 = Double(ref.data[y0 * ref.width + x1])
                    let p10 = Double(ref.data[y1 * ref.width + x0]), p11 = Double(ref.data[y1 * ref.width + x1])
                    let b = (p00 * (1 - wx) + p01 * wx) * (1 - wy) + (p10 * (1 - wx) + p11 * wx) * wy
                    let a = Double(cur.data[y * w + x])
                    sa += a
                    sb += b
                    saa += a * a
                    sbb += b * b
                    sab += a * b
                }
            }
        }
        let va = n * saa - sa * sa, vb = n * sbb - sb * sb
        guard va > 1e-9, vb > 1e-9 else { return nil }
        return (n * sab - sa * sb) / (va * vb).squareRoot()
    }

    /// Vertex offset (in steps, clamped to +-1) of the parabola through three equally spaced samples.
    static func parabolaOffset(_ fm: Double, _ f0: Double, _ fp: Double) -> Double {
        let curvature = fm - 2 * f0 + fp
        guard curvature < -1e-12 else { return 0 }
        return min(max(0.5 * (fm - fp) / curvature, -1), 1)
    }

    /// Integer search of the best shift around `center` (in this level's pixels). Extends the window
    /// when the optimum sits on its border. Returns the sub-bin optimum and its correlation.
    private static func integerSearch(ref: FloatPlane, cur: FloatPlane, center: (Int, Int), radius: Int,
                                      minOverlap: Double) -> (shift: Vec2, correlation: Double)? {
        var cx = center.0, cy = center.1
        var best: (dx: Int, dy: Int, c: Double)?
        var cache = [Int: Double]()
        func value(_ dx: Int, _ dy: Int) -> Double? {
            let key = (dy + 4096) * 8192 + (dx + 4096)
            if let v = cache[key] { return v }
            guard let v = ncc(ref: ref, cur: cur, shift: Vec2(Double(dx), Double(dy)), minOverlap: minOverlap) else {
                return nil
            }
            cache[key] = v
            return v
        }
        for _ in 0..<4 {
            best = nil
            for dy in (cy - radius)...(cy + radius) {
                for dx in (cx - radius)...(cx + radius) {
                    if let v = value(dx, dy), v > (best?.c ?? -2) { best = (dx, dy, v) }
                }
            }
            guard let b = best else { return nil }
            let onBorder = abs(b.dx - cx) == radius || abs(b.dy - cy) == radius
            if !onBorder { break }
            cx = b.dx
            cy = b.dy
        }
        guard let b = best else { return nil }
        var sx = Double(b.dx), sy = Double(b.dy)
        if let l = value(b.dx - 1, b.dy), let r = value(b.dx + 1, b.dy) {
            sx += parabolaOffset(l, b.c, r)
        }
        if let u = value(b.dx, b.dy - 1), let d = value(b.dx, b.dy + 1) {
            sy += parabolaOffset(u, b.c, d)
        }
        return (Vec2(sx, sy), b.c)
    }

    static func estimate(reference: Pyramid, image: Pyramid, config: ShiftEstimatorConfig, hint: Vec2?,
                         hintRadius: Double) -> ShiftEstimate? {
        guard reference.levels.count == image.levels.count, !reference.levels.isEmpty,
              reference.width == image.width, reference.height == image.height else { return nil }
        let minSide = Double(min(image.width, image.height))
        var shift = Vec2.zero      // in the current level's pixels
        var previousFactor = 0
        var correlation = 0.0
        for (i, level) in reference.levels.enumerated() {
            let f = level.factor
            let ref = level.plane, cur = image.levels[i].plane
            let center: (Int, Int)
            let radius: Int
            if i == 0 {
                if let h = hint {
                    center = (Int((h.x / Double(f)).rounded()), Int((h.y / Double(f)).rounded()))
                    radius = Int((hintRadius / Double(f)).rounded(.up)) + 1
                } else {
                    center = (0, 0)
                    radius = Int((config.maxShiftFraction * minSide / Double(f)).rounded(.up))
                }
            } else {
                let scale = Double(previousFactor) / Double(f)
                shift = shift * scale
                center = (Int(shift.x.rounded()), Int(shift.y.rounded()))
                radius = scale >= 4 ? 2 : 1
            }
            guard let r = integerSearch(ref: ref, cur: cur, center: center, radius: radius,
                                        minOverlap: config.minOverlapFraction) else { return nil }
            shift = r.shift
            correlation = r.correlation
            previousFactor = f
        }
        // Fractional refinement on the finest level.
        let fine = reference.levels.count - 1
        let ref = reference.levels[fine].plane, cur = image.levels[fine].plane
        for h in config.refinementSteps {
            guard let f0 = ncc(ref: ref, cur: cur, shift: shift, minOverlap: config.minOverlapFraction) else { break }
            var next = shift
            if let l = ncc(ref: ref, cur: cur, shift: shift - Vec2(h, 0), minOverlap: config.minOverlapFraction),
               let r = ncc(ref: ref, cur: cur, shift: shift + Vec2(h, 0), minOverlap: config.minOverlapFraction) {
                next.x += h * parabolaOffset(l, f0, r)
            }
            if let u = ncc(ref: ref, cur: cur, shift: shift - Vec2(0, h), minOverlap: config.minOverlapFraction),
               let d = ncc(ref: ref, cur: cur, shift: shift + Vec2(0, h), minOverlap: config.minOverlapFraction) {
                next.y += h * parabolaOffset(u, f0, d)
            }
            shift = next
            correlation = ncc(ref: ref, cur: cur, shift: shift, minOverlap: config.minOverlapFraction) ?? f0
        }
        let finalFactor = Double(reference.levels[fine].factor)
        return ShiftEstimate(shift: shift * finalFactor, correlation: correlation)
    }
}
