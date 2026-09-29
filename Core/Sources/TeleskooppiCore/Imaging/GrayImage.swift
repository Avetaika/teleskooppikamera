import Foundation

/// Pixel type usable in `GrayImage`.
public protocol GrayPixel: Sendable, Equatable, Codable {
    static var zero: Self { get }
    /// Nominal white level (255 for UInt8, 65535 for UInt16, 1 for Float).
    static var nominalMax: Double { get }
    /// Converts with rounding and clamping to the representable range (Float: no clamping).
    init(clampingDouble value: Double)
    var doubleValue: Double { get }
}

extension UInt8: GrayPixel {
    public static var nominalMax: Double { 255 }
    @inlinable public init(clampingDouble value: Double) {
        if !(value > 0) { self = 0 } else if value >= 255 { self = 255 } else { self = UInt8(value.rounded()) }
    }
    @inlinable public var doubleValue: Double { Double(self) }
}

extension UInt16: GrayPixel {
    public static var nominalMax: Double { 65535 }
    @inlinable public init(clampingDouble value: Double) {
        if !(value > 0) { self = 0 } else if value >= 65535 { self = 65535 } else { self = UInt16(value.rounded()) }
    }
    @inlinable public var doubleValue: Double { Double(self) }
}

extension Float: GrayPixel {
    public static var nominalMax: Double { 1 }
    @inlinable public init(clampingDouble value: Double) { self = Float(value) }
    @inlinable public var doubleValue: Double { Double(self) }
}

/// Owning single-channel image. Row `y` starts at `pixels[y * stride]`; `stride >= width`
/// (padding pixels at the end of a row are ignored). Coordinates: u (x) right, v (y) down,
/// pixel centers at integer coordinates (D-05).
public struct GrayImage<Pixel: GrayPixel>: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row stride in pixels (not bytes).
    public let stride: Int
    public var pixels: [Pixel]

    /// Blank image filled with `fill`.
    public init(width: Int, height: Int, stride: Int? = nil, fill: Pixel = .zero) {
        precondition(width >= 0 && height >= 0, "negative image size")
        let s = stride ?? width
        precondition(s >= width, "stride must be >= width")
        self.width = width
        self.height = height
        self.stride = s
        self.pixels = [Pixel](repeating: fill, count: s * height)
    }

    /// Wraps existing pixel data (copied into the image).
    public init(width: Int, height: Int, stride: Int? = nil, pixels: [Pixel]) {
        let s = stride ?? width
        precondition(width >= 0 && height >= 0 && s >= width, "invalid image geometry")
        precondition(pixels.count >= s * max(height - 1, 0) + (height > 0 ? width : 0), "pixel buffer too small")
        self.width = width
        self.height = height
        self.stride = s
        self.pixels = pixels
    }

    public var pixelCount: Int { width * height }

    @inlinable public func index(_ x: Int, _ y: Int) -> Int { y * stride + x }

    @inlinable public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get { pixels[y * stride + x] }
        set { pixels[y * stride + x] = newValue }
    }

    /// Pixel as Double, `nil` outside the image.
    public func value(atX x: Int, y: Int) -> Double? {
        contains(x, y) ? pixels[y * stride + x].doubleValue : nil
    }

    /// Calls `body(x, y, value)` for every visible pixel (row-major order).
    public func forEachPixel(_ body: (Int, Int, Pixel) -> Void) {
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width { body(x, y, pixels[row + x]) }
        }
    }

    /// Visible pixels as Double, row-major, without stride padding.
    public func doubleValues() -> [Double] {
        var out = [Double]()
        out.reserveCapacity(pixelCount)
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width { out.append(pixels[row + x].doubleValue) }
        }
        return out
    }

    /// Converts the pixel type, applying `value * scale + offset` before clamping.
    public func converted<P: GrayPixel>(to: P.Type, scale: Double = 1, offset: Double = 0) -> GrayImage<P> {
        var out = GrayImage<P>(width: width, height: height)
        for y in 0..<height {
            let src = y * stride, dst = y * width
            for x in 0..<width {
                out.pixels[dst + x] = P(clampingDouble: pixels[src + x].doubleValue * scale + offset)
            }
        }
        return out
    }

    /// Copy with `stride == width`.
    public func compacted() -> GrayImage<Pixel> {
        if stride == width { return self }
        var out = GrayImage<Pixel>(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { out.pixels[y * width + x] = pixels[y * stride + x] }
        }
        return out
    }
}

public typealias GrayImage8 = GrayImage<UInt8>
public typealias GrayImage16 = GrayImage<UInt16>
public typealias GrayImageF = GrayImage<Float>

extension GrayImage {
    /// 2x2 binning by averaging (odd trailing row/column is dropped). Output has the same pixel type.
    public func binned2x() -> GrayImage<Pixel> {
        let w = width / 2, h = height / 2
        var out = GrayImage<Pixel>(width: w, height: h)
        for y in 0..<h {
            let r0 = (2 * y) * stride, r1 = (2 * y + 1) * stride
            for x in 0..<w {
                let x0 = 2 * x
                let s = pixels[r0 + x0].doubleValue + pixels[r0 + x0 + 1].doubleValue
                    + pixels[r1 + x0].doubleValue + pixels[r1 + x0 + 1].doubleValue
                out.pixels[y * w + x] = Pixel(clampingDouble: s * 0.25)
            }
        }
        return out
    }

    /// Median and MAD-based sigma of the visible pixels (optionally subsampled every `step` pixels).
    public func robustStatistics(step: Int = 1) -> RobustStats {
        let s = max(step, 1)
        var values = [Double]()
        values.reserveCapacity(pixelCount / (s * s) + 1)
        var y = 0
        while y < height {
            var x = 0
            let row = y * stride
            while x < width {
                values.append(pixels[row + x].doubleValue)
                x += s
            }
            y += s
        }
        return Statistics.robust(values)
    }
}
