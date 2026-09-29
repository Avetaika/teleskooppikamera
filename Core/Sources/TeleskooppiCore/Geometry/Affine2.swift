import Foundation

/// 2D affine transform `p' = linear * p + translation`, equivalent to the 3x3 homogeneous matrix
///
///     | l.a  l.b  t.x |
///     | l.c  l.d  t.y |
///     |  0    0    1  |
public struct Affine2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var linear: Mat2
    public var translation: Vec2

    @inlinable public init(linear: Mat2 = .identity, translation: Vec2 = .zero) {
        self.linear = linear
        self.translation = translation
    }

    public static let identity = Affine2()

    @inlinable public static func translation(_ t: Vec2) -> Affine2 {
        Affine2(linear: .identity, translation: t)
    }

    @inlinable public func apply(_ p: Vec2) -> Vec2 { linear * p + translation }

    /// Applies only the linear part (for direction vectors).
    @inlinable public func applyToVector(_ v: Vec2) -> Vec2 { linear * v }

    /// `self ∘ other`: first `other`, then `self`.
    @inlinable public static func * (lhs: Affine2, rhs: Affine2) -> Affine2 {
        Affine2(linear: lhs.linear * rhs.linear, translation: lhs.linear * rhs.translation + lhs.translation)
    }

    public var inverse: Affine2? {
        guard let li = linear.inverse else { return nil }
        return Affine2(linear: li, translation: -(li * translation))
    }

    /// Row-major 3x3 homogeneous matrix (9 values).
    public var rowMajor3x3: [Double] {
        [linear.a, linear.b, translation.x,
         linear.c, linear.d, translation.y,
         0, 0, 1]
    }

    /// Column-major 3x3 matrix (9 values), the element order of `float3x3(columns:)`.
    public var columnMajor3x3: [Double] {
        [linear.a, linear.c, 0,
         linear.b, linear.d, 0,
         translation.x, translation.y, 1]
    }

    /// Column-major 3x3 as `Float`, each column padded to 4 floats (12 values, 48 bytes).
    /// This is the in-memory layout of Metal's / simd's `float3x3`, so the array can be copied
    /// straight into a uniform buffer.
    public var metalFloat3x3Padded: [Float] {
        [Float(linear.a), Float(linear.c), 0, 0,
         Float(linear.b), Float(linear.d), 0, 0,
         Float(translation.x), Float(translation.y), 1, 0]
    }

    public var description: String {
        "Affine2(linear: \(linear), translation: \(translation))"
    }
}
