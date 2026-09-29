import Foundation

/// One detected star (plan 4.9). Positions use image pixel coordinates (pixel centers at integers,
/// u right, v down, D-05).
public struct StarDetection: Sendable, Codable, Equatable {
    /// Intensity-weighted centroid (pixels).
    public var position: Vec2
    /// Background-subtracted sum inside the measurement aperture (ADU). Use this, not `peak`, as the
    /// brightness: saturated stars are flattened.
    public var flux: Double
    /// Brightest background-subtracted pixel (ADU).
    public var peak: Double
    /// `flux / (sigma * sqrt(aperture area))`, i.e. background-limited signal-to-noise of the aperture.
    public var snr: Double
    /// Half-flux radius (pixels).
    public var hfr: Double
    /// True when at least one pixel in the aperture reached the saturation level.
    public var saturated: Bool
    /// Pixels above the detection threshold in the connected component that seeded the detection.
    public var pixelCount: Int
    /// Local background level at the star (ADU).
    public var background: Double
    /// Local noise sigma at the star (ADU).
    public var noise: Double

    public init(position: Vec2, flux: Double, peak: Double, snr: Double, hfr: Double, saturated: Bool,
                pixelCount: Int, background: Double, noise: Double) {
        self.position = position
        self.flux = flux
        self.peak = peak
        self.snr = snr
        self.hfr = hfr
        self.saturated = saturated
        self.pixelCount = pixelCount
        self.background = background
        self.noise = noise
    }
}

public struct StarDetectorConfig: Sendable, Codable, Equatable {
    /// Background block size (pixels); plan 4.9: 32.
    public var blockSize = 32
    /// Detection threshold in sigmas above the local background (k = 5).
    public var thresholdSigmas = 5.0
    /// Connected components smaller than this are rejected (hot pixels).
    public var minPixels = 2
    /// Components larger than this are rejected (field stop edges, clouds).
    public var maxPixels = 2500
    /// Components wider or taller than this (pixels) are rejected (arcs, streaks).
    public var maxExtent = 60
    /// Minimum aperture SNR of a detection.
    public var minSNR = 4.0
    /// Half-flux radius limits (pixels). Very small values are hot pixels, large ones blobs.
    public var minHFR = 0.5
    public var maxHFR = 12.0
    /// Floor for the estimated noise sigma (ADU); guards against quantized, noise-free frames.
    public var minSigma = 0.5
    /// Pixel value at or above which a pixel counts as saturated.
    public var saturationLevel: UInt8 = 250
    /// Maximum centroid refinement iterations.
    public var centroidIterations = 6
    /// Aperture radius limits (pixels); the aperture is `2 * HFR` inside these.
    public var minApertureRadius = 3.0
    public var maxApertureRadius = 15.0
    /// Keep at most this many stars (brightest first).
    public var maxStars = 300
    /// Detections closer than this (pixels) are merged into the brighter one.
    public var minSeparation = 2.0

    public init() {}
}

/// Block-median background with bilinear interpolation between block centers and a MAD-like noise map.
struct BackgroundModel {
    let rect: PixelRect
    private let nbx: Int
    private let nby: Int
    private var level: [Double]
    private var sigma: [Double]
    private var colIndex: [Int]
    private var colWeight: [Double]
    private var rowIndex: [Int]
    private var rowWeight: [Double]

    /// Interpolated quantile of a 256-bin histogram, treating each bin as uniform over [v - 0.5, v + 0.5].
    private static func quantile(_ hist: [Int], total: Int, q: Double) -> Double {
        let target = q * Double(total)
        var cum = 0
        for v in 0..<256 {
            let h = hist[v]
            if h > 0 && Double(cum + h) >= target {
                return Double(v) - 0.5 + (target - Double(cum)) / Double(h)
            }
            cum += h
        }
        return 255
    }

    private static func edges(count n: Int, start: Int, length: Int) -> [Int] {
        (0...n).map { start + ($0 * length) / n }
    }

    /// Interpolation index/weight per pixel along one axis.
    private static func axis(edges: [Int], start: Int, length: Int) -> (index: [Int], weight: [Double]) {
        let n = edges.count - 1
        let centers = (0..<n).map { Double(edges[$0] + edges[$0 + 1] - 1) / 2 }
        var index = [Int](repeating: 0, count: length)
        var weight = [Double](repeating: 0, count: length)
        if n == 1 { return (index, weight) }
        var i = 0
        for k in 0..<length {
            let x = Double(start + k)
            while i < n - 2 && x >= centers[i + 1] { i += 1 }
            if x <= centers[0] {
                index[k] = 0
                weight[k] = 0
            } else if x >= centers[n - 1] {
                index[k] = n - 2
                weight[k] = 1
            } else {
                index[k] = i
                weight[k] = (x - centers[i]) / (centers[i + 1] - centers[i])
            }
        }
        return (index, weight)
    }

    init?(image: GrayImage8, rect: PixelRect, mask: CircleMask?, config: StarDetectorConfig) {
        self.rect = rect
        let bs = max(config.blockSize, 4)
        let nx = max(1, Int((Double(rect.width) / Double(bs)).rounded()))
        let ny = max(1, Int((Double(rect.height) / Double(bs)).rounded()))
        let ex = Self.edges(count: nx, start: rect.x0, length: rect.width)
        let ey = Self.edges(count: ny, start: rect.y0, length: rect.height)
        var lv = [Double](repeating: .nan, count: nx * ny)
        var sg = [Double](repeating: .nan, count: nx * ny)
        var hist = [Int](repeating: 0, count: 256)
        for by in 0..<ny {
            for bx in 0..<nx {
                for i in 0..<256 { hist[i] = 0 }
                var total = 0
                for y in ey[by]..<ey[by + 1] {
                    let row = y * image.stride
                    for x in ex[bx]..<ex[bx + 1] {
                        if let m = mask, !m.contains(x: x, y: y) { continue }
                        hist[Int(image.pixels[row + x])] += 1
                        total += 1
                    }
                }
                if total >= 16 {
                    let q25 = Self.quantile(hist, total: total, q: 0.25)
                    let q50 = Self.quantile(hist, total: total, q: 0.5)
                    let q75 = Self.quantile(hist, total: total, q: 0.75)
                    lv[by * nx + bx] = q50
                    // (q75 - q25) / 2 is the MAD of a symmetric distribution; x 1.4826 gives sigma.
                    sg[by * nx + bx] = max(0.5 * (q75 - q25) * 1.4826, config.minSigma)
                }
            }
        }
        let valid = lv.indices.filter { !lv[$0].isNaN }
        guard !valid.isEmpty else { return nil }
        let fillLevel = Statistics.median(valid.map { lv[$0] }) ?? 0
        let fillSigma = Statistics.median(valid.map { sg[$0] }) ?? config.minSigma
        for i in lv.indices where lv[i].isNaN {
            lv[i] = fillLevel
            sg[i] = fillSigma
        }
        nbx = nx
        nby = ny
        level = lv
        sigma = sg
        let cx = Self.axis(edges: ex, start: rect.x0, length: rect.width)
        let cy = Self.axis(edges: ey, start: rect.y0, length: rect.height)
        colIndex = cx.index
        colWeight = cx.weight
        rowIndex = cy.index
        rowWeight = cy.weight
    }

    /// Background level and noise sigma at pixel (x, y); coordinates outside the rect are clamped.
    @inline(__always)
    func sample(x: Int, y: Int) -> (level: Double, sigma: Double) {
        let cx = min(max(x - rect.x0, 0), rect.width - 1)
        let cy = min(max(y - rect.y0, 0), rect.height - 1)
        let ix = colIndex[cx], wx = colWeight[cx]
        let iy = rowIndex[cy], wy = rowWeight[cy]
        let i00 = iy * nbx + ix
        if nbx == 1 && nby == 1 { return (level[0], sigma[0]) }
        let ixr = nbx > 1 ? ix + 1 : ix
        let iyb = nby > 1 ? iy + 1 : iy
        let i01 = iy * nbx + ixr
        let i10 = iyb * nbx + ix
        let i11 = iyb * nbx + ixr
        let l0 = level[i00] * (1 - wx) + level[i01] * wx
        let l1 = level[i10] * (1 - wx) + level[i11] * wx
        let s0 = sigma[i00] * (1 - wx) + sigma[i01] * wx
        let s1 = sigma[i10] * (1 - wx) + sigma[i11] * wx
        return (l0 * (1 - wy) + l1 * wy, s0 * (1 - wy) + s1 * wy)
    }
}

/// Star detector for 8-bit luma frames (plan 4.9, D-03: pure Swift, CPU only).
///
/// 1. Background: median of 32x32 blocks, bilinearly interpolated; noise sigma from the block's
///    inter-quartile range (MAD-equivalent, robust against stars).
/// 2. Threshold `background + k * sigma` (k = 5), 8-connected components, single-pixel components
///    (hot pixels) rejected.
/// 3. Centroid: background-subtracted intensity-weighted centroid inside a circular aperture of
///    `2 * HFR`, iterated a few times; HFR and flux come from the same aperture.
/// 4. Brightness is the flux, not the peak; saturation is reported as a flag.
public struct StarDetector: Sendable {
    public var config: StarDetectorConfig

    public init(config: StarDetectorConfig = StarDetectorConfig()) {
        self.config = config
    }

    /// Detects stars, brightest (by flux) first. `roi` restricts all processing (background, threshold,
    /// centroid windows) to a sub-rectangle; `mask` ignores pixels outside a circle (field stop).
    public func detect(_ image: GrayImage8, roi: PixelRect? = nil, mask: CircleMask? = nil) -> [StarDetection] {
        let full = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = (roi ?? full).clipped(width: image.width, height: image.height)
        guard rect.width >= 4, rect.height >= 4,
              let bg = BackgroundModel(image: image, rect: rect, mask: mask, config: config) else { return [] }
        let rw = rect.width, rh = rect.height
        let k = config.thresholdSigmas

        // Threshold.
        var flags = [UInt8](repeating: 0, count: rw * rh)
        for y in rect.y0..<rect.y1 {
            let row = y * image.stride
            let frow = (y - rect.y0) * rw
            for x in rect.x0..<rect.x1 {
                if let m = mask, !m.contains(x: x, y: y) { continue }
                let s = bg.sample(x: x, y: y)
                if Double(image.pixels[row + x]) - s.level > k * s.sigma {
                    flags[frow + (x - rect.x0)] = 1
                }
            }
        }

        // 8-connected components.
        var detections = [StarDetection]()
        var stack = [Int]()
        for start in 0..<(rw * rh) where flags[start] == 1 {
            flags[start] = 2
            stack.append(start)
            var count = 0
            var sumE = 0.0, sx = 0.0, sy = 0.0
            var peakValue = -1, peakX = 0, peakY = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            while let j = stack.popLast() {
                let jx = j % rw, jy = j / rw
                let x = rect.x0 + jx, y = rect.y0 + jy
                let v = Int(image.pixels[y * image.stride + x])
                let e = Double(v) - bg.sample(x: x, y: y).level
                count += 1
                sumE += e
                sx += e * Double(x)
                sy += e * Double(y)
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if v > peakValue {
                    peakValue = v
                    peakX = x
                    peakY = y
                }
                for dy in -1...1 {
                    let ny = jy + dy
                    if ny < 0 || ny >= rh { continue }
                    for dx in -1...1 {
                        let nx = jx + dx
                        if nx < 0 || nx >= rw || (dx == 0 && dy == 0) { continue }
                        let n = ny * rw + nx
                        if flags[n] == 1 {
                            flags[n] = 2
                            stack.append(n)
                        }
                    }
                }
            }
            if count < config.minPixels || count > config.maxPixels { continue }
            if maxX - minX + 1 > config.maxExtent || maxY - minY + 1 > config.maxExtent { continue }
            let seed = sumE > 0 ? Vec2(sx / sumE, sy / sumE) : Vec2(Double(peakX), Double(peakY))
            let equivalentRadius = (Double(count) / Double.pi).squareRoot()
            let radius = min(max(1.5 * equivalentRadius + 1, config.minApertureRadius), config.maxApertureRadius)
            if let d = refine(image: image, rect: rect, bg: bg, mask: mask, seed: seed, radius: radius, pixelCount: count) {
                detections.append(d)
            }
        }

        // Brightest first, merge near-duplicates, limit.
        detections.sort { $0.flux > $1.flux }
        var kept = [StarDetection]()
        for d in detections {
            if kept.contains(where: { ($0.position - d.position).length < config.minSeparation }) { continue }
            kept.append(d)
            if kept.count >= config.maxStars { break }
        }
        return kept
    }

    /// Iterative centroid / HFR / flux measurement around `seed`.
    private func refine(image: GrayImage8, rect: PixelRect, bg: BackgroundModel, mask: CircleMask?,
                        seed: Vec2, radius: Double, pixelCount: Int) -> StarDetection? {
        var c = seed
        var radiusNow = radius
        var hfr = 0.0
        var profile = [(r: Double, e: Double)]()
        profile.reserveCapacity(700)

        for iteration in 0..<max(config.centroidIterations, 1) {
            // Centroid inside the current aperture.
            let bounds = windowBounds(center: c, radius: radiusNow, rect: rect)
            guard bounds.x0 <= bounds.x1, bounds.y0 <= bounds.y1 else { return nil }
            var s = 0.0, sx = 0.0, sy = 0.0
            let r2 = radiusNow * radiusNow
            // Gaussian-windowed centroid (near-optimal for noisy stars); sigma follows the measured HFR.
            let sigmaW = iteration == 0 ? radiusNow / 2.4 : max(0.85 * hfr, 1.0)
            let invTwoSigma2 = 1 / (2 * sigmaW * sigmaW)
            for y in bounds.y0...bounds.y1 {
                let row = y * image.stride
                for x in bounds.x0...bounds.x1 {
                    let dx = Double(x) - c.x, dy = Double(y) - c.y
                    let d2 = dx * dx + dy * dy
                    if d2 > r2 { continue }
                    if let m = mask, !m.contains(x: x, y: y) { continue }
                    let e = (Double(image.pixels[row + x]) - bg.sample(x: x, y: y).level) * exp(-d2 * invTwoSigma2)
                    s += e
                    sx += e * Double(x)
                    sy += e * Double(y)
                }
            }
            guard s > 0 else { return nil }
            let next = Vec2(sx / s, sy / s)
            guard (next - seed).length <= 2 * config.maxApertureRadius else { return nil }
            let moved = (next - c).length
            c = next

            // Half-flux radius around the new centroid.
            profile.removeAll(keepingCapacity: true)
            let b2 = windowBounds(center: c, radius: radiusNow, rect: rect)
            guard b2.x0 <= b2.x1, b2.y0 <= b2.y1 else { return nil }
            var total = 0.0
            for y in b2.y0...b2.y1 {
                let row = y * image.stride
                for x in b2.x0...b2.x1 {
                    let dx = Double(x) - c.x, dy = Double(y) - c.y
                    let d2 = dx * dx + dy * dy
                    if d2 > r2 { continue }
                    if let m = mask, !m.contains(x: x, y: y) { continue }
                    let e = Double(image.pixels[row + x]) - bg.sample(x: x, y: y).level
                    profile.append((d2.squareRoot(), e))
                    total += e
                }
            }
            guard total > 0 else { return nil }
            profile.sort { $0.r < $1.r }
            var cum = 0.0
            var previousR = 0.0, previousCum = 0.0
            hfr = radiusNow
            for p in profile {
                cum += p.e
                if cum >= total / 2 {
                    let span = cum - previousCum
                    hfr = span > 0 ? previousR + (p.r - previousR) * (total / 2 - previousCum) / span : p.r
                    break
                }
                previousR = p.r
                previousCum = cum
            }
            let nextRadius = min(max(2 * hfr, config.minApertureRadius), config.maxApertureRadius)
            let converged = abs(nextRadius - radiusNow) < 0.05 && moved < 0.01
            radiusNow = nextRadius
            if converged && iteration > 0 { break }
        }

        guard hfr >= config.minHFR, hfr <= config.maxHFR else { return nil }
        if let m = mask, !m.contains(c) { return nil }

        // Final measurements with the final aperture.
        let bounds = windowBounds(center: c, radius: radiusNow, rect: rect)
        guard bounds.x0 <= bounds.x1, bounds.y0 <= bounds.y1 else { return nil }
        var flux = 0.0, peak = -Double.infinity
        var saturated = false
        let r2 = radiusNow * radiusNow
        var area = 0
        for y in bounds.y0...bounds.y1 {
            let row = y * image.stride
            for x in bounds.x0...bounds.x1 {
                let dx = Double(x) - c.x, dy = Double(y) - c.y
                if dx * dx + dy * dy > r2 { continue }
                if let m = mask, !m.contains(x: x, y: y) { continue }
                let raw = image.pixels[row + x]
                let e = Double(raw) - bg.sample(x: x, y: y).level
                flux += e
                area += 1
                if e > peak { peak = e }
                if raw >= config.saturationLevel { saturated = true }
            }
        }
        guard flux > 0, area > 0 else { return nil }
        let local = bg.sample(x: Int(c.x.rounded()), y: Int(c.y.rounded()))
        let snr = flux / (local.sigma * Double(area).squareRoot())
        guard snr >= config.minSNR else { return nil }
        return StarDetection(position: c, flux: flux, peak: peak, snr: snr, hfr: hfr, saturated: saturated,
                             pixelCount: pixelCount, background: local.level, noise: local.sigma)
    }

    private func windowBounds(center c: Vec2, radius r: Double, rect: PixelRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (max(rect.x0, Int((c.x - r).rounded(.down))), max(rect.y0, Int((c.y - r).rounded(.down))),
         min(rect.x1 - 1, Int((c.x + r).rounded(.up))), min(rect.y1 - 1, Int((c.y + r).rounded(.up))))
    }
}
