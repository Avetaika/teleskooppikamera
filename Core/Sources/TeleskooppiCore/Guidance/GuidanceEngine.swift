import Foundation

/// 8-way stick arrow. Angles are counterclockwise in stick space (x right, y up).
public enum StickDir8: Int, Sendable, Codable, CaseIterable {
    case right = 0, upRight, up, upLeft, left, downLeft, down, downRight

    /// Direction angle in stick space (radians).
    public var angle: Double { Double(rawValue) * .pi / 4 }

    public var isDiagonal: Bool { rawValue % 2 == 1 }

    /// Unit vector in stick space (x right, y up).
    public var stickVector: Vec2 { Vec2.unit(angle: angle) }

    /// Unit vector for drawing on screen (x right, y down).
    public var screenVector: Vec2 {
        let v = stickVector
        return Vec2(v.x, -v.y)
    }

    public var symbol: String {
        ["→", "↗", "↑", "↖", "←", "↙", "↓", "↘"][rawValue]
    }

    /// Nearest of the 8 directions to a stick-space angle.
    public static func nearest(angle: Double) -> StickDir8 {
        let k = Int((AngleMath.wrapTwoPi(angle) / (.pi / 4)).rounded()) % 8
        return StickDir8(rawValue: k) ?? .right
    }

    /// Axis direction (right/up/left/down) nearest to a stick vector.
    public static func majorAxis(of v: Vec2) -> StickDir8 {
        if abs(v.x) >= abs(v.y) { return v.x >= 0 ? .right : .left }
        return v.y >= 0 ? .up : .down
    }
}

/// Arrow convention (D-09).
public enum GuidanceConvention: String, Sendable, Codable {
    /// "Window": the arrow points from the crosshair toward the star and equals the stick push.
    case window
    /// Arrow flipped (points where the star should go).
    case inverted
}

public struct GuidanceConfig: Sendable, Codable, Equatable {
    /// Inner tolerance radius r_ok in image pixels (plan 4.5: ~3 % of the field diameter).
    public var toleranceRadius: Double
    /// Guidance resumes only when |e| exceeds `exitHysteresisFactor * toleranceRadius`.
    public var exitHysteresisFactor: Double = 1.5
    /// Extra angle beyond the 22.5 degree sector half-width before the arrow changes (plan 4.5: 5 deg).
    public var sectorHysteresis: Double = AngleMath.radians(5)
    /// A diagonal arrow requires the minor stick component to be at least this many seconds...
    public var diagonalMinimumSeconds: Double = 0.4
    /// ...and at least this fraction of the major component (see `GuidanceEngine`).
    public var diagonalMinimumRatio: Double = 0.25
    public var convention: GuidanceConvention = .window

    public init(toleranceRadius: Double, convention: GuidanceConvention = .window) {
        self.toleranceRadius = toleranceRadius
        self.convention = convention
    }

    /// Plan 4.5 default: 3 % of the field diameter.
    public static func defaults(fieldRadius: Double) -> GuidanceConfig {
        GuidanceConfig(toleranceRadius: 0.03 * 2 * fieldRadius)
    }
}

public struct GuidanceOutput: Sendable, Equatable {
    /// Quantized arrow to show (after convention), `nil` inside the tolerance.
    public var arrow: StickDir8?
    /// Stick push that brings the star to the crosshair, `s = -M^-1 e`, in seconds at the
    /// calibration speed per axis (x = RIGHT, y = UP). Physical; independent of the convention.
    public var stickSeconds: Vec2
    /// Continuous arrow direction in stick space (unit, after convention).
    public var arrowDirection: Vec2
    /// Continuous arrow direction for drawing on screen (unit, x right, y down).
    public var arrowScreenDirection: Vec2
    /// |s_R| and |s_U|: time estimates at calibration speed (plan 4.5).
    public var secondsAtCalibrationRate: Vec2 { Vec2(abs(stickSeconds.x), abs(stickSeconds.y)) }
    public var withinTolerance: Bool
    /// |e| in image pixels.
    public var errorPixels: Double
}

/// Turns the star position error into a stick instruction (plan 4.5).
///
/// Stateful only for hysteresis (arrow sector and tolerance); call `reset()` when the target changes.
///
/// Diagonal rule: plan 4.5 reads "diagonal only if the minor component is >= 0.4 s or >= 25 % of the
/// major". Inside a 45 degree diagonal sector the minor/major ratio is always >= tan(22.5) = 0.41, so
/// the OR form could never suppress a diagonal. It is implemented as AND: a diagonal additionally needs
/// at least 0.4 s on the minor axis, otherwise only the major axis arrow is shown ("do this first").
public struct GuidanceEngine: Sendable {
    public var config: GuidanceConfig
    public private(set) var lastArrow: StickDir8?
    public private(set) var isWithinTolerance = false

    public init(config: GuidanceConfig) {
        self.config = config
    }

    public mutating func reset() {
        lastArrow = nil
        isWithinTolerance = false
    }

    /// `s = -M^-1 e`: stick seconds (at calibration speed) that move the star by `-e`.
    public static func stickSeconds(error e: Vec2, stickToImage m: Mat2) -> Vec2? {
        guard let inv = m.inverse else { return nil }
        return -(inv * e)
    }

    /// Guidance for a star at `target` with the crosshair at `center` (both image pixels).
    public mutating func guide(target: Vec2, center: Vec2, calibration: CalibrationResult) -> GuidanceOutput {
        guide(target: target, center: center, stickToImage: calibration.stickToImage)
    }

    public mutating func guide(target: Vec2, center: Vec2, stickToImage m: Mat2) -> GuidanceOutput {
        let e = target - center
        let dist = e.length
        let s = Self.stickSeconds(error: e, stickToImage: m) ?? .zero
        let sign: Double = config.convention == .window ? 1 : -1
        let dir = (s * sign).normalized
        let screenDir = Vec2(dir.x, -dir.y)

        if isWithinTolerance {
            if dist > config.exitHysteresisFactor * config.toleranceRadius { isWithinTolerance = false }
        } else if dist <= config.toleranceRadius {
            isWithinTolerance = true
        }

        var arrow: StickDir8?
        if isWithinTolerance || s.length == 0 {
            lastArrow = nil
        } else {
            arrow = quantize(display: s * sign)
            lastArrow = arrow
        }
        return GuidanceOutput(arrow: arrow, stickSeconds: s, arrowDirection: dir, arrowScreenDirection: screenDir,
                              withinTolerance: isWithinTolerance, errorPixels: dist)
    }

    /// 8-way quantization with sector hysteresis and the diagonal rule.
    private func quantize(display v: Vec2) -> StickDir8 {
        let a = v.angle
        var candidate: StickDir8
        if let last = lastArrow, abs(AngleMath.difference(a, last.angle)) <= .pi / 8 + config.sectorHysteresis {
            candidate = last
        } else {
            candidate = StickDir8.nearest(angle: a)
        }
        if candidate.isDiagonal {
            let major = max(abs(v.x), abs(v.y)), minor = min(abs(v.x), abs(v.y))
            if minor < config.diagonalMinimumSeconds || minor < config.diagonalMinimumRatio * major {
                candidate = StickDir8.majorAxis(of: v)
            }
        }
        return candidate
    }

    /// Screen directions (unit, x right, y down) from the crosshair for the four dim axis markers
    /// shown when no star is tracked (plan 4.5): a star in that direction needs that stick push.
    /// With a correct calibration and the window convention UP is (0, -1) and RIGHT is (1, 0).
    public static func axisMarkerDirections(stickToImage m: Mat2, display: DisplayTransform,
                                            convention: GuidanceConvention = .window) -> [StickDirection: Vec2] {
        var out = [StickDirection: Vec2]()
        let sign: Double = convention == .window ? 1 : -1
        for d in StickDirection.allCases {
            // A star at e = -M s needs the push s; show it on the side where such a star would be.
            let e = -(m * d.unitVector) * sign
            out[d] = display.imageVectorToScreen(e).normalized
        }
        return out
    }
}
