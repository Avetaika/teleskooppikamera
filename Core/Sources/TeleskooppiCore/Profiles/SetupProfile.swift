import Foundation

/// Camera settings stored with a profile. Plain values so the core stays platform independent.
public struct CameraSettingsSnapshot: Sendable, Codable, Equatable {
    /// "auto", "locked" or "manual".
    public var exposureMode: String
    /// Exposure time in seconds (used when manual).
    public var exposureSeconds: Double
    public var iso: Double
    /// Lens position 0...1 (infinity focus).
    public var lensPosition: Double
    /// Exposure preset raw value, if one is active.
    public var preset: String?

    public init(exposureMode: String = "manual", exposureSeconds: Double = 0.125, iso: Double = 1600,
                lensPosition: Double = 0.8, preset: String? = nil) {
        self.exposureMode = exposureMode
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.lensPosition = lensPosition
        self.preset = preset
    }
}

/// One setup: eyepiece + phone position on the adapter + calibration + camera settings.
public struct SetupProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var eyepiece: EyepieceProfile
    /// Optical centre in image pixels; nil = image centre.
    public var opticalCenter: Vec2?
    public var fieldRadius: Double?
    public var calibration: CalibrationResult?
    public var camera: CameraSettingsSnapshot?
    /// Free-text note about where the phone sits in the adapter.
    public var adapterNote: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, eyepiece: EyepieceProfile, opticalCenter: Vec2? = nil,
                fieldRadius: Double? = nil, calibration: CalibrationResult? = nil,
                camera: CameraSettingsSnapshot? = nil, adapterNote: String = "",
                createdAt: Date = Date(), updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.eyepiece = eyepiece
        self.opticalCenter = opticalCenter
        self.fieldRadius = fieldRadius
        self.calibration = calibration
        self.camera = camera
        self.adapterNote = adapterNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Built-in starting points for the owner's eyepieces (25, 10, 9, 6 mm; plus 2x Barlow).
    /// IDs are fixed so defaults are stable across launches.
    public static func defaults(now: Date = Date()) -> [SetupProfile] {
        let specs: [(String, Double, Double)] = [
            ("00000000-0000-0000-0000-000000000025", 25, 1),
            ("00000000-0000-0000-0000-000000000010", 10, 1),
            ("00000000-0000-0000-0000-000000000009", 9, 1),
            ("00000000-0000-0000-0000-000000000006", 6, 1),
            ("00000000-0000-0000-0001-000000000025", 25, 2),
            ("00000000-0000-0000-0001-000000000010", 10, 2),
        ]
        return specs.map { idString, f, barlow in
            let eyepiece = EyepieceProfile(focalLengthMM: f, barlowFactor: barlow)
            return SetupProfile(id: UUID(uuidString: idString) ?? UUID(), name: eyepiece.label,
                                eyepiece: eyepiece, createdAt: now)
        }
    }
}
