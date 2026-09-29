import Foundation

/// One position measurement of the tracked star (or of the whole-frame shift estimator, D-12).
public struct TrackSample: Sendable, Codable, Equatable {
    /// Timestamp in seconds (monotonic; mid-exposure).
    public var t: Double
    /// Position in image pixels (native buffer orientation, D-05).
    public var p: Vec2
    /// Detection quality in [0, 1]. Samples with quality <= 0 are treated as "star lost".
    public var quality: Double

    public init(t: Double, p: Vec2, quality: Double = 1) {
        self.t = t
        self.p = p
        self.quality = quality
    }
}

/// Stick directions used for calibration moves and axis markers. Stick space: x right, y up.
public enum StickDirection: String, Sendable, Codable, CaseIterable {
    case up, right, down, left

    public var unitVector: Vec2 {
        switch self {
        case .up: return Vec2(0, 1)
        case .right: return Vec2(1, 0)
        case .down: return Vec2(0, -1)
        case .left: return Vec2(-1, 0)
        }
    }
}

/// Why a calibration failed. The UI maps these to Finnish messages.
public enum CalibrationFailure: Error, Sendable, Codable, Equatable {
    /// The star was lost for longer than the allowed gap.
    case starLost
    /// No motion was detected after asking for a stick push.
    case noMotionDetected
    /// The star never became still (e.g. mount still moving, extreme seeing).
    case notSettled
    /// The star stopped before the target displacement was reached (stick released early).
    case moveTooShort(displacement: Double, target: Double)
    /// The star came too close to the field stop.
    case nearEdge
    /// The two moves are not perpendicular enough (e.g. a diagonal push). Degrees from 90.
    case orthogonalityBad(degrees: Double)
    /// Moves are (anti)parallel or zero: no rotation can be solved.
    case degenerate
    /// A move took too long.
    case timeout
}

/// Overall quality flag shown as green / yellow in the UI (failures are red).
public enum CalibrationQuality: String, Sendable, Codable {
    case good
    case warning
}

/// Result of one calibration move (drift-corrected).
public struct MoveMeasurement: Sendable, Codable, Equatable {
    public var direction: StickDirection
    /// Image velocity in px/s at the calibration speed: a column of M.
    public var velocity: Vec2
    /// RMS perpendicular residual of the TLS line fit (px).
    public var lineResidual: Double
    /// Length of the move along the fitted line (px).
    public var displacement: Double
    /// Time from detected start to settle (s).
    public var duration: Double
    public var sampleCount: Int

    public init(direction: StickDirection, velocity: Vec2, lineResidual: Double, displacement: Double,
                duration: Double, sampleCount: Int) {
        self.direction = direction
        self.velocity = velocity
        self.lineResidual = lineResidual
        self.displacement = displacement
        self.duration = duration
        self.sampleCount = sampleCount
    }
}

/// Stored calibration (plan 3.3, 4.4). Codable for setup profiles.
public struct CalibrationResult: Sendable, Codable, Equatable {
    /// M: columns are image velocities (px/s at calibration speed) for stick RIGHT and stick UP.
    public var stickToImage: Mat2
    /// Display rotation theta (radians) such that `R(theta) F^k` maps M's column directions onto
    /// the target view (RIGHT -> screen left, UP -> screen down).
    public var displayRotation: Double
    /// Whether a horizontal flip precedes the rotation (det M has the "wrong" sign).
    public var mirrored: Bool
    /// |angle(m_R, m_U) - 90 deg| in radians.
    public var orthogonalityError: Double
    /// Largest TLS residual of the moves (px).
    public var lineResidual: Double
    /// Angle spread between repeated calibrations (radians), if measured.
    public var repeatability: Double?
    public var opticalCenter: Vec2
    public var fieldRadius: Double?
    /// Drift velocity estimated during calibration (px/s).
    public var driftVelocity: Vec2
    public var quality: CalibrationQuality
    /// True for a one-move quick recalibration (D-06).
    public var isQuick: Bool
    public var createdAt: Date

    public init(stickToImage: Mat2, displayRotation: Double, mirrored: Bool, orthogonalityError: Double,
                lineResidual: Double, repeatability: Double? = nil, opticalCenter: Vec2,
                fieldRadius: Double? = nil, driftVelocity: Vec2 = .zero, quality: CalibrationQuality = .good,
                isQuick: Bool = false, createdAt: Date = Date()) {
        self.stickToImage = stickToImage
        self.displayRotation = displayRotation
        self.mirrored = mirrored
        self.orthogonalityError = orthogonalityError
        self.lineResidual = lineResidual
        self.repeatability = repeatability
        self.opticalCenter = opticalCenter
        self.fieldRadius = fieldRadius
        self.driftVelocity = driftVelocity
        self.quality = quality
        self.isQuick = isQuick
        self.createdAt = createdAt
    }

    /// Image velocity for stick RIGHT (px/s).
    public var mRight: Vec2 { stickToImage.column0 }
    /// Image velocity for stick UP (px/s).
    public var mUp: Vec2 { stickToImage.column1 }

    /// `|m_R| / |m_U|`, approximately cos(alt) when both axes ran at the same speed (plan 4.4 bonus).
    public var axisRateRatio: Double {
        let u = mUp.length
        return u > 0 ? mRight.length / u : 0
    }

    public var displayRotationDegrees: Double { AngleMath.degrees(displayRotation) }
}

/// What the UI should show (plan 3.3).
public enum CalibrationPrompt: Sendable, Equatable {
    /// Waiting for a tracked star near the crosshair.
    case centerStar
    /// Star found; keep the mount still while the baseline and drift are measured.
    case holdStill
    /// Push and hold the stick in this direction.
    case pressAndHold(StickDirection)
    /// Target displacement reached: release the stick now (flash + beep + haptic).
    case stop
    /// Stick released; waiting for the star to settle.
    case releaseAndWait
    case done(CalibrationResult)
    case failed(CalibrationFailure)

    public var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}
