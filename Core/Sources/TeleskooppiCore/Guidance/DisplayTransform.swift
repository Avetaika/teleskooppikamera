import Foundation

/// Image-to-screen transform (plan 4.4, D-08, D-10):
///
///     q = S * R(theta) * F^k * (p - c) + q_center
///
/// `p` in image pixels (native buffer, D-05), `q` in screen points (x right, y down). The same
/// 3x3 matrix drives the Metal vertex shader and the SwiftUI overlay.
public struct DisplayTransform: Sendable, Codable, Equatable {
    /// Rotation theta in radians.
    public var rotation: Double
    /// Horizontal flip before the rotation.
    public var mirrored: Bool
    /// Screen points per image pixel.
    public var scale: Double
    /// Optical center `c` in image pixels (rotation pivot).
    public var opticalCenter: Vec2
    /// Where the optical center lands on screen (crosshair position), screen points.
    public var screenCenter: Vec2
    /// True when set by hand (UI shows "KÄSI"); calibration then does not override it.
    public var isManualOverride: Bool

    public init(rotation: Double, mirrored: Bool, scale: Double = 1, opticalCenter: Vec2,
                screenCenter: Vec2, isManualOverride: Bool = false) {
        self.rotation = rotation
        self.mirrored = mirrored
        self.scale = scale
        self.opticalCenter = opticalCenter
        self.screenCenter = screenCenter
        self.isManualOverride = isManualOverride
    }

    /// Transform from a calibration: stick UP = screen up (plan 4.4).
    public init(calibration: CalibrationResult, scale: Double = 1, opticalCenter: Vec2? = nil,
                screenCenter: Vec2) {
        self.init(rotation: calibration.displayRotation, mirrored: calibration.mirrored, scale: scale,
                  opticalCenter: opticalCenter ?? calibration.opticalCenter, screenCenter: screenCenter)
    }

    /// Manual override from a rotation slider and two flip toggles. A vertical flip equals a
    /// horizontal flip plus 180 degrees, so the result is still expressed as `R(theta) F^k`.
    public static func manual(rotation: Double, flipHorizontal: Bool, flipVertical: Bool, scale: Double = 1,
                              opticalCenter: Vec2, screenCenter: Vec2) -> DisplayTransform {
        DisplayTransform(rotation: AngleMath.wrapPi(rotation + (flipVertical ? .pi : 0)),
                         mirrored: flipHorizontal != flipVertical, scale: scale,
                         opticalCenter: opticalCenter, screenCenter: screenCenter, isManualOverride: true)
    }

    /// Identity-like transform (no rotation) centering `opticalCenter` on `screenCenter`.
    public static func unrotated(scale: Double = 1, opticalCenter: Vec2, screenCenter: Vec2) -> DisplayTransform {
        DisplayTransform(rotation: 0, mirrored: false, scale: scale, opticalCenter: opticalCenter,
                         screenCenter: screenCenter)
    }

    public enum ScaleMode: String, Sendable, Codable {
        /// The whole field circle is visible.
        case fit
        /// The circle covers the whole screen (no black corners).
        case cover
    }

    /// Scale that makes a field circle of `fieldRadius` image pixels fit or cover `screenSize`.
    public static func scale(fieldRadius: Double, screenSize: Vec2, mode: ScaleMode) -> Double {
        guard fieldRadius > 0 else { return 1 }
        switch mode {
        case .fit: return min(screenSize.x, screenSize.y) / 2 / fieldRadius
        case .cover: return screenSize.length / 2 / fieldRadius
        }
    }

    /// Linear part `S R(theta) F^k`.
    public var linear: Mat2 {
        CalibrationSolver.displayMatrix(rotation: rotation, mirrored: mirrored) * scale
    }

    /// The full affine image -> screen transform.
    public var affine: Affine2 {
        let l = linear
        return Affine2(linear: l, translation: screenCenter - l * opticalCenter)
    }

    public func imageToScreen(_ p: Vec2) -> Vec2 { affine.apply(p) }

    public func screenToImage(_ q: Vec2) -> Vec2 {
        guard let inv = affine.inverse else { return opticalCenter }
        return inv.apply(q)
    }

    /// Maps an image-space direction to a screen direction (not normalized).
    public func imageVectorToScreen(_ v: Vec2) -> Vec2 { linear * v }

    /// Row-major 3x3 homogeneous matrix (image -> screen).
    public var matrixRowMajor: [Double] { affine.rowMajor3x3 }

    /// Column-major 3x3 homogeneous matrix (image -> screen).
    public var matrixColumnMajor: [Double] { affine.columnMajor3x3 }

    /// Metal / simd `float3x3` memory layout (3 columns padded to 4 floats).
    public var metalFloat3x3: [Float] { affine.metalFloat3x3Padded }

    public var rotationDegrees: Double { AngleMath.degrees(rotation) }
}
