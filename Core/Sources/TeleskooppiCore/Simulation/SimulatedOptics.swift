import Foundation

/// Geometry of the simulated eyepiece + phone camera: maps sky offsets from the boresight to
/// image pixels.
///
/// Sky offsets are tangent-plane coordinates in arcseconds relative to the telescope boresight:
/// `xi` toward increasing azimuth (on the sky, i.e. already multiplied by cos(alt)), `eta` toward
/// increasing altitude. The "natural" screen frame (x right, y down) is `n = (xi, -eta) / plateScale`,
/// which is exactly the target view of plan 4.1: stick UP moves stars straight down, stick RIGHT moves
/// them straight left.
///
/// The camera image is that natural frame seen through an unknown rotation / mirror:
/// `p = c + G n` with `G = (R(theta) F^k)^-1`, where `theta = displayRotation` and `k = mirrored`.
/// A perfect calibration therefore recovers exactly `displayRotation` and `mirrored`.
public struct SimulatedOptics: Sendable, Codable, Equatable {
    public var imageWidth: Int
    public var imageHeight: Int
    /// Optical center `c` (center of the eyepiece field stop) in image pixels.
    public var opticalCenter: Vec2
    /// Field stop radius in image pixels.
    public var fieldRadius: Double
    /// Arcseconds per image pixel.
    public var plateScale: Double
    /// Ground truth: the display rotation (radians) that makes "stick up = screen up".
    public var displayRotation: Double
    /// Ground truth: whether a horizontal flip is needed before the rotation.
    public var mirrored: Bool

    /// Defaults model a 2x-binned 960x720 buffer (from 1920x1440) with a 25 mm eyepiece on a
    /// 750 mm Newtonian: field circle about 760 px across, about 8.8 arcsec/px.
    public init(imageWidth: Int = 960, imageHeight: Int = 720, opticalCenter: Vec2? = nil,
                fieldRadius: Double = 380, plateScale: Double = 8.82,
                displayRotation: Double = 0, mirrored: Bool = false) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.opticalCenter = opticalCenter ?? Vec2(Double(imageWidth) / 2, Double(imageHeight) / 2)
        self.fieldRadius = fieldRadius
        self.plateScale = plateScale
        self.displayRotation = displayRotation
        self.mirrored = mirrored
    }

    /// `R(theta) F^k`: maps image offsets to the natural (target) screen frame.
    public var imageToNatural: Mat2 {
        CalibrationSolver.displayMatrix(rotation: displayRotation, mirrored: mirrored)
    }

    /// `G = (R(theta) F^k)^-1 = F^k R(-theta)`: maps natural-frame offsets to image offsets.
    public var naturalToImage: Mat2 {
        (mirrored ? Mat2.flipX : Mat2.identity) * Mat2.rotation(-displayRotation)
    }

    /// Image position of a star at tangent-plane position `star` when the boresight is at `boresight`
    /// (both in arcsec).
    public func project(star: Vec2, boresight: Vec2) -> Vec2 {
        let d = star - boresight
        let natural = Vec2(d.x, -d.y) / plateScale
        return opticalCenter + naturalToImage * natural
    }

    /// Inverse of `project`: tangent-plane position (arcsec) seen at image position `p`.
    public func unproject(_ p: Vec2, boresight: Vec2) -> Vec2 {
        let n = imageToNatural * (p - opticalCenter) * plateScale
        return boresight + Vec2(n.x, -n.y)
    }

    public func isInsideField(_ p: Vec2) -> Bool {
        (p - opticalCenter).length <= fieldRadius
    }

    public func isInsideImage(_ p: Vec2) -> Bool {
        p.x >= -0.5 && p.y >= -0.5 && p.x <= Double(imageWidth) - 0.5 && p.y <= Double(imageHeight) - 0.5
    }

    /// Ground-truth stick-to-image matrix M (columns: px/s for stick RIGHT and UP at full deflection)
    /// for axis rates given in arcsec/s of *sky* motion.
    public func expectedStickToImage(rightSkyRate: Double, upSkyRate: Double) -> Mat2 {
        let g = naturalToImage
        return Mat2(columns: g * Vec2(-rightSkyRate / plateScale, 0), g * Vec2(0, upSkyRate / plateScale))
    }
}
