import Foundation
import TeleskooppiCore

/// What the calibration screen shows for a core prompt. Pure, so it can be unit tested; the
/// view turns each case into Finnish text.
enum CalibrationScreen: Equatable {
    /// Start screen: preparation text and the "Kalibroi" button.
    case intro
    /// Tap a bright star near the crosshair (no star tracked yet).
    case pickStar
    /// A star is tracked but not yet near the crosshair.
    case centerStar
    case holdStill
    case press(StickDirection)
    /// Full-screen STOP flash.
    case stop
    case release
    case result
    case failure
}

/// Traffic-light quality of a finished calibration.
enum CalibrationQualityLevel: Equatable {
    case green, yellow, red
}

enum CalibrationScreenMapper {
    static func screen(for prompt: CalibrationPrompt?, starSelected: Bool, stopAcknowledged: Bool) -> CalibrationScreen {
        guard let prompt else { return .intro }
        switch prompt {
        case .centerStar: return starSelected ? .centerStar : .pickStar
        case .holdStill: return .holdStill
        case .pressAndHold(let direction): return .press(direction)
        case .stop: return stopAcknowledged ? .release : .stop
        case .releaseAndWait: return .release
        case .done: return .result
        case .failed: return .failure
        }
    }

    /// Orthogonality of the two moves: green up to 4 degrees, yellow up to 10, red beyond. The
    /// core's own warning flag always forces at least yellow.
    static func qualityLevel(for result: CalibrationResult) -> CalibrationQualityLevel {
        let degrees = AngleMath.degrees(result.orthogonalityError)
        if degrees > 10 { return .red }
        if degrees > 4 || result.quality == .warning { return .yellow }
        return .green
    }
}

/// Reaction to a hardware button press (D-18): "calibrate / next / acknowledge".
enum CalibrationTriggerAction: Equatable {
    case startCalibration
    case acknowledgeStop
    case accept
    case retry
    case none

    static func action(prompt: CalibrationPrompt?, panelVisible: Bool, stopAcknowledged: Bool) -> CalibrationTriggerAction {
        guard panelVisible, let prompt else { return .startCalibration }
        switch prompt {
        case .stop: return stopAcknowledged ? .none : .acknowledgeStop
        case .done: return .accept
        case .failed: return .retry
        default: return .none
        }
    }
}
