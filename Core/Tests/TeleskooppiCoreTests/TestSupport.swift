import Foundation
@testable import TeleskooppiCore

enum TestImages {
    /// Frame with Moffat stars at given image positions (`flux` in electrons) on a flat or gradient
    /// background, rendered with `SyntheticSky` (Gaussian approximation of Poisson noise).
    static func starFrame(width: Int, height: Int, stars: [(pos: Vec2, flux: Double)],
                          background: Double = 25, gradient: Vec2 = .zero, readNoise: Double = 2.5,
                          gain: Double = 1, fwhm: Double = 3.0, seed: UInt64) -> GrayImage8 {
        let optics = SimulatedOptics(imageWidth: width, imageHeight: height, fieldRadius: 1e6, plateScale: 1)
        let cfg = SyntheticSky.Configuration(
            psf: .moffat(fwhm: fwhm, beta: 3), referenceFlux: 1, referenceMagnitude: 0, background: background,
            backgroundGradient: gradient, vignetting: 0, outsideFieldLevel: 0, fieldEdgeWidth: 3,
            readNoise: readNoise, gain: gain, bias: 4, poissonNoise: true)
        let field = StarField(stars: stars.map {
            SimulatedStar(position: optics.unproject($0.pos, boresight: .zero), magnitude: -2.5 * log10($0.flux))
        })
        let sky = SyntheticSky(optics: optics, field: field, configuration: cfg)
        var img = GrayImage8(width: width, height: height, fill: 4)
        var rng = SplitMix64(seed: seed)
        sky.render(into: &img, window: PixelRect(x: 0, y: 0, width: width, height: height), boresight: .zero, rng: &rng)
        return img
    }

    /// Bright disk (the eyepiece field) on a dark surround, with soft edge, vignetting and noise.
    static func fieldDisk(width: Int, height: Int, center: Vec2, radius: Double, seed: UInt64) -> GrayImage8 {
        var img = GrayImage8(width: width, height: height)
        var rng = SplitMix64(seed: seed)
        for y in 0..<height {
            for x in 0..<width {
                let r = (Vec2(Double(x), Double(y)) - center).length
                let edge = min(max((radius - r) / 3 + 0.5, 0), 1)
                let vignette = 1 - 0.25 * min(r / radius, 1.2) * min(r / radius, 1.2)
                let v = 10 + (200 * vignette - 10) * edge + 3 * rng.gaussian()
                img.pixels[y * width + x] = UInt8(clampingDouble: v)
            }
        }
        return img
    }
}

/// Procedural "daytime" scene: many Gaussian blobs of different sizes. Because it is an analytic
/// function of position, it can be rendered at any sub-pixel displacement exactly.
struct TexturedScene: Sendable {
    struct Blob: Sendable {
        var cx: Double, cy: Double, sigma: Double, amplitude: Double
    }

    var blobs: [Blob]
    var width: Int
    var height: Int
    var noiseSigma: Double

    init(width: Int, height: Int, blobCount: Int, margin: Double, noiseSigma: Double = 2, seed: UInt64) {
        self.width = width
        self.height = height
        self.noiseSigma = noiseSigma
        var rng = SplitMix64(seed: seed)
        let scale = (Double(min(width, height)) / 720).squareRoot()
        blobs = (0..<blobCount).map { i in
            let kind = i % 5
            let sigma: Double
            switch kind {
            case 0, 1: sigma = rng.uniform(2...4)
            case 2, 3: sigma = rng.uniform(4...10)
            default: sigma = rng.uniform(10...20)
            }
            let amp = rng.uniform(25...80) * (rng.bool() ? 1 : -1)
            return Blob(cx: rng.uniform(-margin...(Double(width) + margin)),
                        cy: rng.uniform(-margin...(Double(height) + margin)),
                        sigma: max(1.5, sigma * scale), amplitude: amp)
        }
    }

    /// Frame whose content is displaced by `shift` pixels: `image(x) = scene(x - shift)`.
    func render(shift: Vec2, rng: inout SplitMix64) -> GrayImage8 {
        var acc = [Double](repeating: 0, count: width * height)
        for b in blobs {
            let cx = b.cx + shift.x, cy = b.cy + shift.y
            let ext = 3.5 * b.sigma
            let x0 = max(0, Int((cx - ext).rounded(.down))), x1 = min(width - 1, Int((cx + ext).rounded(.up)))
            let y0 = max(0, Int((cy - ext).rounded(.down))), y1 = min(height - 1, Int((cy + ext).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let inv = 1 / (2 * b.sigma * b.sigma)
            for y in y0...y1 {
                let dy = Double(y) - cy
                for x in x0...x1 {
                    let dx = Double(x) - cx
                    acc[y * width + x] += b.amplitude * exp(-(dx * dx + dy * dy) * inv)
                }
            }
        }
        var img = GrayImage8(width: width, height: height)
        for i in 0..<(width * height) {
            img.pixels[i] = UInt8(clampingDouble: 120 + acc[i] + noiseSigma * rng.gaussian())
        }
        return img
    }
}

func p95(_ v: [Double]) -> Double { Statistics.percentile(v, 95) ?? .infinity }

func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("teleskooppi-tests-\(name)-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
