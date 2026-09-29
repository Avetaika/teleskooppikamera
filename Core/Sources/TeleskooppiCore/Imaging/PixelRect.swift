import Foundation

/// Half-open integer pixel rectangle: columns `x0..<x1`, rows `y0..<y1`. Used as region of interest.
public struct PixelRect: Sendable, Codable, Equatable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x0: x, y0: y, x1: x + width, y1: y + height)
    }

    /// Square rectangle containing every pixel within `halfSize` of `center` (pixel centers at integers).
    public static func around(_ center: Vec2, halfSize: Double) -> PixelRect {
        PixelRect(x0: Int((center.x - halfSize).rounded(.down)), y0: Int((center.y - halfSize).rounded(.down)),
                  x1: Int((center.x + halfSize).rounded(.down)) + 1, y1: Int((center.y + halfSize).rounded(.down)) + 1)
    }

    public var width: Int { max(0, x1 - x0) }
    public var height: Int { max(0, y1 - y0) }
    public var isEmpty: Bool { width == 0 || height == 0 }
    public var area: Int { width * height }

    public func contains(_ x: Int, _ y: Int) -> Bool {
        x >= x0 && x < x1 && y >= y0 && y < y1
    }

    /// Intersection with the image bounds `0..<width` x `0..<height` (may be empty).
    public func clipped(width: Int, height: Int) -> PixelRect {
        let r = PixelRect(x0: max(x0, 0), y0: max(y0, 0), x1: min(x1, width), y1: min(y1, height))
        return r.isEmpty ? PixelRect(x0: 0, y0: 0, x1: 0, y1: 0) : r
    }
}

/// Circular mask (e.g. the eyepiece field stop). Pixels outside are ignored by the detectors.
public struct CircleMask: Sendable, Codable, Equatable {
    public var center: Vec2
    public var radius: Double

    public init(center: Vec2, radius: Double) {
        self.center = center
        self.radius = radius
    }

    @inlinable public func contains(x: Int, y: Int) -> Bool {
        let dx = Double(x) - center.x, dy = Double(y) - center.y
        return dx * dx + dy * dy <= radius * radius
    }

    @inlinable public func contains(_ p: Vec2) -> Bool {
        (p - center).lengthSquared <= radius * radius
    }
}
