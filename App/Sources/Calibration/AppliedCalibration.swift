import Foundation

/// Display rotation and mirroring that came from a calibration (stick up = screen up).
struct AppliedCalibration: Codable, Equatable, Sendable {
    var rotationDegrees: Double
    var mirrored: Bool

    /// Angle comparison modulo 360 degrees with a 0.05 degree tolerance.
    func matches(rotationDegrees other: Double, flipHorizontal: Bool, flipVertical: Bool) -> Bool {
        guard flipHorizontal == mirrored, !flipVertical else { return false }
        var d = (other - rotationDegrees).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return abs(d) < 0.05
    }
}
