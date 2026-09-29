import Foundation

/// A star at a fixed tangent-plane position (arcsec, see `SimulatedOptics`).
public struct SimulatedStar: Sendable, Codable, Equatable {
    public var position: Vec2
    public var magnitude: Double

    public init(position: Vec2, magnitude: Double) {
        self.position = position
        self.magnitude = magnitude
    }
}

/// Point spread function.
public enum PSF: Sendable, Codable, Equatable {
    case gaussian(fwhm: Double)
    case moffat(fwhm: Double, beta: Double)

    /// Normalized profile value at squared radius `r2` (pixels^2); integrates to 1.
    public func value(r2: Double) -> Double {
        switch self {
        case .gaussian(let fwhm):
            let sigma = fwhm / 2.354_820_045
            return exp(-r2 / (2 * sigma * sigma)) / (2 * .pi * sigma * sigma)
        case .moffat(let fwhm, let beta):
            let alpha = fwhm / (2 * (pow(2, 1 / beta) - 1).squareRoot())
            return (beta - 1) / (.pi * alpha * alpha) * pow(1 + r2 / (alpha * alpha), -beta)
        }
    }

    /// Radius (pixels) beyond which the profile is negligible for rendering.
    public var renderRadius: Double {
        switch self {
        case .gaussian(let fwhm): return max(2, 2.5 * fwhm)
        case .moffat(let fwhm, _): return max(3, min(6 * fwhm, 40))
        }
    }
}

/// Deterministic star field generator.
public struct StarField: Sendable, Codable, Equatable {
    public var stars: [SimulatedStar]

    public init(stars: [SimulatedStar]) {
        self.stars = stars
    }

    /// Random stars uniformly inside a circle of `radiusArcsec` around `center`, with magnitudes
    /// following a power law `N(<m) ~ 10^(slope * m)` between `brightest` and `faintest`
    /// (slope 0.35 is typical for field stars at these magnitudes).
    public static func random(count: Int, center: Vec2 = .zero, radiusArcsec: Double,
                              brightest: Double = 6, faintest: Double = 12, slope: Double = 0.35,
                              rng: inout SplitMix64) -> StarField {
        var stars = [SimulatedStar]()
        stars.reserveCapacity(count)
        let a = pow(10, slope * brightest), b = pow(10, slope * faintest)
        for _ in 0..<count {
            let r = radiusArcsec * rng.nextUnit().squareRoot()
            let phi = rng.uniform(0...(2 * .pi))
            let u = rng.nextUnit()
            let m = log10(a + u * (b - a)) / slope
            stars.append(SimulatedStar(position: center + Vec2.unit(angle: phi) * r, magnitude: m))
        }
        return StarField(stars: stars)
    }
}

/// Renders synthetic eyepiece frames: stars with a PSF, sky background with a gradient,
/// circular field stop with vignetting, Poisson + read noise, 8-bit output.
public struct SyntheticSky: Sendable {
    public struct Configuration: Sendable, Codable, Equatable {
        public var psf: PSF
        /// Photo-electrons per frame for a star of `referenceMagnitude`.
        public var referenceFlux: Double
        public var referenceMagnitude: Double
        /// Sky background at the optical center, electrons per pixel.
        public var background: Double
        /// Background gradient, electrons per pixel per pixel (image axes).
        public var backgroundGradient: Vec2
        /// Fractional illumination drop at the field edge (0 = none): `1 - v (r/R)^2`.
        public var vignetting: Double
        /// Level outside the field stop (electrons per pixel), e.g. scattered light.
        public var outsideFieldLevel: Double
        /// Width of the soft field-stop edge in pixels.
        public var fieldEdgeWidth: Double
        public var readNoise: Double
        /// Electrons per ADU.
        public var gain: Double
        /// ADU offset added to every pixel.
        public var bias: Double
        public var poissonNoise: Bool

        public init(psf: PSF = .moffat(fwhm: 3.0, beta: 3.0), referenceFlux: Double = 40000,
                    referenceMagnitude: Double = 4, background: Double = 25,
                    backgroundGradient: Vec2 = Vec2(0.01, -0.006), vignetting: Double = 0.35,
                    outsideFieldLevel: Double = 1, fieldEdgeWidth: Double = 3, readNoise: Double = 2.5,
                    gain: Double = 1, bias: Double = 4, poissonNoise: Bool = true) {
            self.psf = psf
            self.referenceFlux = referenceFlux
            self.referenceMagnitude = referenceMagnitude
            self.background = background
            self.backgroundGradient = backgroundGradient
            self.vignetting = vignetting
            self.outsideFieldLevel = outsideFieldLevel
            self.fieldEdgeWidth = fieldEdgeWidth
            self.readNoise = readNoise
            self.gain = gain
            self.bias = bias
            self.poissonNoise = poissonNoise
        }

        public func flux(magnitude: Double) -> Double {
            referenceFlux * pow(10, -0.4 * (magnitude - referenceMagnitude))
        }
    }

    public var optics: SimulatedOptics
    public var field: StarField
    public var configuration: Configuration

    public init(optics: SimulatedOptics, field: StarField, configuration: Configuration = Configuration()) {
        self.optics = optics
        self.field = field
        self.configuration = configuration
    }

    /// Relative illumination (field stop x vignetting) at image position `p`, in [0, 1].
    public func illumination(at p: Vec2) -> Double {
        let r = (p - optics.opticalCenter).length
        let rr = r / optics.fieldRadius
        let vig = max(0, 1 - configuration.vignetting * rr * rr)
        let w = max(configuration.fieldEdgeWidth, 1e-6)
        let edge = min(max((optics.fieldRadius - r) / w + 0.5, 0), 1)
        return vig * edge
    }

    /// Sky background (no stars) in electrons per pixel for the whole image. Independent of the
    /// boresight, so callers rendering many frames can compute it once.
    public func expectedBackground() -> GrayImageF {
        let w = optics.imageWidth, h = optics.imageHeight
        var img = GrayImageF(width: w, height: h)
        fillBackground(&img.pixels, rect: PixelRect(x: 0, y: 0, width: w, height: h), bufferWidth: w)
        return img
    }

    /// Writes the background of `rect` into `buffer` (row-major, `bufferWidth` wide, origin at the rect corner).
    private func fillBackground(_ buffer: inout [Float], rect: PixelRect, bufferWidth: Int) {
        let cfg = configuration
        let c = optics.opticalCenter
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let p = Vec2(Double(x), Double(y))
                let ill = illumination(at: p)
                let sky = max(0, cfg.background + cfg.backgroundGradient.dot(p - c))
                let v = sky * ill + cfg.outsideFieldLevel * (1 - ill)
                buffer[(y - rect.y0) * bufferWidth + (x - rect.x0)] = Float(v)
            }
        }
    }

    /// Adds all stars that touch `rect` to `buffer` (same layout as `fillBackground`).
    private func addStars(to buffer: inout [Float], rect: PixelRect, bufferWidth: Int, boresight: Vec2,
                          imageOffset: Vec2) {
        let cfg = configuration
        let radius = cfg.psf.renderRadius
        let r2max = radius * radius
        // 3x3 sub-pixel sampling of the PSF.
        let sub: [Double] = [-1.0 / 3, 0, 1.0 / 3]
        for star in field.stars {
            let p = optics.project(star: star.position, boresight: boresight) + imageOffset
            guard p.x > Double(rect.x0) - radius, p.y > Double(rect.y0) - radius,
                  p.x < Double(rect.x1) + radius, p.y < Double(rect.y1) + radius else { continue }
            let ill = illumination(at: p)
            guard ill > 0 else { continue }
            let flux = cfg.flux(magnitude: star.magnitude) * ill
            let x0 = max(rect.x0, Int((p.x - radius).rounded(.down))), x1 = min(rect.x1 - 1, Int((p.x + radius).rounded(.up)))
            let y0 = max(rect.y0, Int((p.y - radius).rounded(.down))), y1 = min(rect.y1 - 1, Int((p.y + radius).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - p.x, dy = Double(y) - p.y
                    if dx * dx + dy * dy > r2max { continue }
                    var s = 0.0
                    for sy in sub {
                        for sx in sub {
                            let ddx = dx + sx, ddy = dy + sy
                            s += cfg.psf.value(r2: ddx * ddx + ddy * ddy)
                        }
                    }
                    buffer[(y - rect.y0) * bufferWidth + (x - rect.x0)] += Float(flux * s / 9)
                }
            }
        }
    }

    /// Noise-free expected electrons per pixel. `imageOffset` shifts all stars (seeing jitter).
    public func renderExpected(boresight: Vec2, imageOffset: Vec2 = .zero) -> GrayImageF {
        let w = optics.imageWidth, h = optics.imageHeight
        var img = expectedBackground()
        addStars(to: &img.pixels, rect: PixelRect(x: 0, y: 0, width: w, height: h), bufferWidth: w,
                 boresight: boresight, imageOffset: imageOffset)
        return img
    }

    /// Renders only `window` of a noisy 8-bit frame into `image` (which must have the optics' size);
    /// pixels outside the window are left untouched. Cost is proportional to the window area, which
    /// makes closed-loop tests with a tracking ROI cheap. Noise is Gaussian with variance
    /// `signal + readNoise^2` (the Poisson noise is approximated), one deviate per pixel.
    /// Pass a cached `background` (from `expectedBackground()`) to skip recomputing the sky.
    public func render(into image: inout GrayImage8, window: PixelRect, boresight: Vec2,
                       imageOffset: Vec2 = .zero, background: GrayImageF? = nil, rng: inout SplitMix64) {
        let rect = window.clipped(width: image.width, height: image.height)
        guard !rect.isEmpty else { return }
        let w = rect.width, h = rect.height
        let cfg = configuration
        var buf = [Float](repeating: 0, count: w * h)
        if let bg = background {
            for y in 0..<h {
                let src = (rect.y0 + y) * bg.stride + rect.x0
                for x in 0..<w { buf[y * w + x] = bg.pixels[src + x] }
            }
        } else {
            fillBackground(&buf, rect: rect, bufferWidth: w)
        }
        addStars(to: &buf, rect: rect, bufferWidth: w, boresight: boresight, imageOffset: imageOffset)
        let read2 = cfg.readNoise * cfg.readNoise
        for y in 0..<h {
            let dst = (rect.y0 + y) * image.stride + rect.x0
            for x in 0..<w {
                let e = Double(buf[y * w + x])
                let variance = read2 + (cfg.poissonNoise ? max(e, 0) : 0)
                let electrons = e + variance.squareRoot() * rng.gaussian()
                image.pixels[dst + x] = UInt8(clampingDouble: electrons / cfg.gain + cfg.bias)
            }
        }
    }

    /// Full frame with noise, 8-bit.
    public func render(boresight: Vec2, imageOffset: Vec2 = .zero, rng: inout SplitMix64) -> GrayImage8 {
        let expected = renderExpected(boresight: boresight, imageOffset: imageOffset)
        let cfg = configuration
        var out = GrayImage8(width: expected.width, height: expected.height)
        for i in 0..<expected.pixels.count {
            let e = Double(expected.pixels[i])
            var electrons = cfg.poissonNoise ? rng.poisson(e) : e
            if cfg.readNoise > 0 { electrons += cfg.readNoise * rng.gaussian() }
            out.pixels[i] = UInt8(clampingDouble: electrons / cfg.gain + cfg.bias)
        }
        return out
    }
}
