import Foundation

/// 2x2 matrix, row-major storage:
///
///     | a  b |
///     | c  d |
///
/// Columns are `(a, c)` and `(b, d)`. Codable as `{a, b, c, d}`.
public struct Mat2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double

    @inlinable public init(a: Double, b: Double, c: Double, d: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    /// Matrix whose columns are `c0` and `c1`.
    @inlinable public init(columns c0: Vec2, _ c1: Vec2) {
        self.init(a: c0.x, b: c1.x, c: c0.y, d: c1.y)
    }

    /// Matrix whose rows are `r0` and `r1`.
    @inlinable public init(rows r0: Vec2, _ r1: Vec2) {
        self.init(a: r0.x, b: r0.y, c: r1.x, d: r1.y)
    }

    public static let identity = Mat2(a: 1, b: 0, c: 0, d: 1)
    public static let zero = Mat2(a: 0, b: 0, c: 0, d: 0)

    /// Horizontal flip `F = diag(-1, 1)` (mirrors the x coordinate).
    public static let flipX = Mat2(a: -1, b: 0, c: 0, d: 1)
    /// Vertical flip `diag(1, -1)`.
    public static let flipY = Mat2(a: 1, b: 0, c: 0, d: -1)

    /// Counterclockwise rotation by `angle` radians (in a y-up frame; in a y-down image frame
    /// the same matrix appears clockwise on screen).
    @inlinable public static func rotation(_ angle: Double) -> Mat2 {
        let co = cos(angle), s = sin(angle)
        return Mat2(a: co, b: -s, c: s, d: co)
    }

    @inlinable public static func scale(_ sx: Double, _ sy: Double) -> Mat2 {
        Mat2(a: sx, b: 0, c: 0, d: sy)
    }

    @inlinable public var column0: Vec2 { Vec2(a, c) }
    @inlinable public var column1: Vec2 { Vec2(b, d) }
    @inlinable public var row0: Vec2 { Vec2(a, b) }
    @inlinable public var row1: Vec2 { Vec2(c, d) }

    @inlinable public var determinant: Double { a * d - b * c }
    @inlinable public var trace: Double { a + d }
    @inlinable public var transposed: Mat2 { Mat2(a: a, b: c, c: b, d: d) }

    /// Inverse, or `nil` when the matrix is (numerically) singular.
    public var inverse: Mat2? {
        let det = determinant
        let scale = max(abs(a), abs(b), abs(c), abs(d))
        guard det.isFinite, scale > 0, abs(det) > 1e-12 * scale * scale else { return nil }
        let inv = 1 / det
        return Mat2(a: d * inv, b: -b * inv, c: -c * inv, d: a * inv)
    }

    public var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite && d.isFinite }

    @inlinable public static func * (m: Mat2, v: Vec2) -> Vec2 {
        Vec2(m.a * v.x + m.b * v.y, m.c * v.x + m.d * v.y)
    }

    @inlinable public static func * (m: Mat2, n: Mat2) -> Mat2 {
        Mat2(a: m.a * n.a + m.b * n.c, b: m.a * n.b + m.b * n.d,
             c: m.c * n.a + m.d * n.c, d: m.c * n.b + m.d * n.d)
    }

    @inlinable public static func * (m: Mat2, s: Double) -> Mat2 {
        Mat2(a: m.a * s, b: m.b * s, c: m.c * s, d: m.d * s)
    }

    @inlinable public static func + (m: Mat2, n: Mat2) -> Mat2 {
        Mat2(a: m.a + n.a, b: m.b + n.b, c: m.c + n.c, d: m.d + n.d)
    }

    @inlinable public static func - (m: Mat2, n: Mat2) -> Mat2 {
        Mat2(a: m.a - n.a, b: m.b - n.b, c: m.c - n.c, d: m.d - n.d)
    }

    /// Largest absolute element difference to `o`.
    public func maxAbsDifference(_ o: Mat2) -> Double {
        max(abs(a - o.a), abs(b - o.b), abs(c - o.c), abs(d - o.d))
    }

    public var description: String {
        "[[\(Vec2.format(a)), \(Vec2.format(b))], [\(Vec2.format(c)), \(Vec2.format(d))]]"
    }
}
