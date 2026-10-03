import Foundation
import TeleskooppiCore

/// Text for the guidance arrow. The arrow is a stick instruction (stick space), already after the
/// D-09 convention, so `TATTI ↖` always means "push the stick up-left".
enum GuidanceText {
    static func label(for arrow: StickDir8) -> String {
        "TATTI \(arrow.symbol)"
    }

    /// Seconds estimate at calibration speed, Finnish decimal comma. Axis arrows show the major
    /// component, diagonals both ("2,3 / 0,8 s").
    static func seconds(for output: GuidanceOutput, arrow: StickDir8) -> String {
        let s = output.secondsAtCalibrationRate
        if arrow.isDiagonal {
            return "\(format(max(s.x, s.y))) / \(format(min(s.x, s.y))) s"
        }
        let major = arrow == .left || arrow == .right ? s.x : s.y
        return "\(format(major)) s"
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Rotation in degrees (clockwise, 0 = pointing up) for drawing a screen-up arrow symbol.
    static func screenRotationDegrees(for arrow: StickDir8) -> Double {
        let v = arrow.screenVector
        return atan2(v.x, -v.y) * 180 / .pi
    }
}

/// Which guidance state is on screen and how strongly (fade and hysteresis, plan 4.5).
struct GuidanceDisplayState: Equatable {
    enum Mode: Equatable {
        case hidden
        case arrow(StickDir8)
        case ok
        /// Calibrated, but no star is tracked: show axis markers.
        case noStar
    }

    private(set) var mode: Mode = .hidden
    private(set) var since: Double = 0
    private var lastStarSeen: Double = -.infinity

    /// A tracked star may drop out for this long before the view falls back to the axis markers.
    static let lostGrace = 0.6
    /// "OK" stays at full strength this long, then fades to `okRestingOpacity` over `okFade`.
    static let okHold = 1.5
    static let okFade = 1.0
    static let okRestingOpacity = 0.3
    static let arrowOpacity = 0.6

    /// `output` is `nil` when no star position is available in this frame.
    mutating func update(output: GuidanceOutput?, calibrated: Bool, now: Double) {
        guard calibrated else {
            set(.hidden, at: now)
            return
        }
        if let output {
            lastStarSeen = now
            if output.withinTolerance {
                set(.ok, at: now)
            } else if let arrow = output.arrow {
                set(.arrow(arrow), at: now)
            } else {
                set(.ok, at: now)
            }
        } else if now - lastStarSeen > Self.lostGrace {
            set(.noStar, at: now)
        } else if mode == .hidden {
            set(.noStar, at: now)
        }
    }

    func opacity(now: Double) -> Double {
        switch mode {
        case .hidden: return 0
        case .arrow: return Self.arrowOpacity
        case .noStar: return 0.5
        case .ok:
            let age = now - since
            if age <= Self.okHold { return 1 }
            let f = min(1, (age - Self.okHold) / Self.okFade)
            return 1 - f * (1 - Self.okRestingOpacity)
        }
    }

    private mutating func set(_ new: Mode, at now: Double) {
        guard new != mode else { return }
        mode = new
        since = now
    }
}
