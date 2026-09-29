import Foundation

/// 2D vector in double precision. Used for image coordinates (u right, v down, pixels),
/// screen coordinates and stick vectors (x right, y up). See plan.md 4.1.
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    @inlinable public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    @inlinable public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    /// Unit vector at `angle` radians (counterclockwise from +x in a y-up frame).
    @inlinable public static func unit(angle: Double) -> Vec2 {
        Vec2(cos(angle), sin(angle))
    }

    @inlinable public var length: Double { (x * x + y * y).squareRoot() }
    @inlinable public var lengthSquared: Double { x * x + y * y }

    /// `atan2(y, x)` in radians, range (-pi, pi].
    @inlinable public var angle: Double { atan2(y, x) }

    /// Unit vector in the same direction, or `.zero` for a zero vector.
    @inlinable public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x / l, y / l) : .zero
    }

    /// Rotated counterclockwise (in a y-up frame) by `angle` radians.
    @inlinable public func rotated(by angle: Double) -> Vec2 {
        let c = cos(angle), s = sin(angle)
        return Vec2(c * x - s * y, s * x + c * y)
    }

    /// Perpendicular vector (rotated +90 degrees).
    @inlinable public var perpendicular: Vec2 { Vec2(-y, x) }

    @inlinable public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }

    /// 2D cross product (z component of the 3D cross product).
    @inlinable public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }

    @inlinable public func distance(to o: Vec2) -> Double { (self - o).length }

    /// Signed angle from `self` to `o` in radians, range (-pi, pi].
    @inlinable public func signedAngle(to o: Vec2) -> Double {
        atan2(cross(o), dot(o))
    }

    /// Unsigned angle between the vectors in radians, range [0, pi].
    @inlinable public func angle(to o: Vec2) -> Double {
        abs(signedAngle(to: o))
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public var description: String {
        "(\(Self.format(x)), \(Self.format(y)))"
    }

    static func format(_ v: Double) -> String {
        String(format: "%.3f", v)
    }

    // MARK: Operators

    @inlinable public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inlinable public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    @inlinable public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    @inlinable public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    @inlinable public static func -= (a: inout Vec2, b: Vec2) { a = a - b }
    @inlinable public static func *= (a: inout Vec2, s: Double) { a = a * s }
}
