import Foundation

/// Telescope optics (default: Heritage 150P, 150 mm f/5).
public struct TelescopeSpec: Sendable, Codable, Equatable, Hashable {
    public var apertureMM: Double
    public var focalLengthMM: Double

    public init(apertureMM: Double, focalLengthMM: Double) {
        self.apertureMM = apertureMM
        self.focalLengthMM = focalLengthMM
    }

    public static let heritage150P = TelescopeSpec(apertureMM: 150, focalLengthMM: 750)
}

/// Eyepiece (+ optional Barlow) with derived visual optics. The apparent field of view is an
/// editable estimate (default 52 deg); the true field is only as accurate as that number.
public struct EyepieceProfile: Sendable, Codable, Equatable, Hashable {
    public var focalLengthMM: Double
    /// Barlow multiplier; 1 = none.
    public var barlowFactor: Double
    /// Apparent field of view in degrees.
    public var apparentFOVDegrees: Double
    public var telescope: TelescopeSpec

    public static let defaultApparentFOV = 52.0

    public init(focalLengthMM: Double, barlowFactor: Double = 1,
                apparentFOVDegrees: Double = EyepieceProfile.defaultApparentFOV,
                telescope: TelescopeSpec = .heritage150P) {
        self.focalLengthMM = focalLengthMM
        self.barlowFactor = barlowFactor
        self.apparentFOVDegrees = apparentFOVDegrees
        self.telescope = telescope
    }

    /// Effective telescope focal length including the Barlow (mm).
    public var effectiveFocalLengthMM: Double { telescope.focalLengthMM * barlowFactor }

    public var magnification: Double { effectiveFocalLengthMM / focalLengthMM }

    /// True field of view in degrees (apparent FOV / magnification).
    public var trueFOVDegrees: Double { apparentFOVDegrees / magnification }

    /// Exit pupil diameter in mm.
    public var exitPupilMM: Double { telescope.apertureMM / magnification }

    /// Angular size of one pixel (arcsec) when the eyepiece field stop spans `fieldDiameterPixels`
    /// in the camera image.
    public func plateScaleArcsecPerPixel(fieldDiameterPixels: Double) -> Double {
        guard fieldDiameterPixels > 0 else { return 0 }
        return trueFOVDegrees * 3600 / fieldDiameterPixels
    }

    /// Short label such as `25 mm` or `25 mm + 2x`.
    public var label: String {
        func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        if barlowFactor == 1 { return "\(fmt(focalLengthMM)) mm" }
        return "\(fmt(focalLengthMM)) mm + \(fmt(barlowFactor))x"
    }
}
