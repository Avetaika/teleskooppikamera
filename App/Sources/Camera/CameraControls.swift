import Foundation

/// Exposure control requested from the camera (plan 5.2).
enum ExposureControl: Equatable, Codable, Sendable {
    case auto
    /// Locks the current auto exposure values.
    case locked
    case manual(duration: Double, iso: Float)
}

/// Focus control requested from the camera.
enum FocusControl: Equatable, Codable, Sendable {
    case auto
    case locked
    case manual(lensPosition: Float)
}

/// Exposure duration / ISO limits of the active format.
struct ExposureLimits: Equatable, Sendable {
    var minDuration: Double
    var maxDuration: Double
    var minISO: Float
    var maxISO: Float

    /// Used before the first camera read-out (plan 5.2 expectations for iPhone 17).
    static let assumed = ExposureLimits(minDuration: 0.0001, maxDuration: 1.0, minISO: 50, maxISO: 6000)

    func clamp(duration: Double) -> Double {
        min(max(duration, minDuration), maxDuration)
    }

    func clamp(iso: Float) -> Float {
        min(max(iso, minISO), maxISO)
    }
}

/// The two exposure presets of plan 5.2.
enum CameraPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Short exposure, high ISO: fast loop for centering and calibration.
    case centering
    /// Longer exposure for looking at faint objects (0.5–1 s).
    case viewing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centering: String(localized: "Keskitys")
        case .viewing: String(localized: "Katselu")
        }
    }

    var exposureSeconds: Double {
        switch self {
        case .centering: 0.125
        case .viewing: 0.75
        }
    }

    var iso: Float {
        switch self {
        case .centering: 3200
        case .viewing: 1600
        }
    }

    /// The manual exposure for this preset, clamped to what the device supports.
    func exposure(limits: ExposureLimits) -> ExposureControl {
        .manual(duration: limits.clamp(duration: exposureSeconds), iso: limits.clamp(iso: iso))
    }
}

/// Frame duration planning for long exposures (plan 5.2): a frame cannot be shorter than its
/// exposure, so `activeVideoMaxFrameDuration` must be raised to at least the exposure time.
enum ExposurePlanner {
    /// Default frame duration of the preview format (30 fps).
    static let baseFrameDuration = 1.0 / 30

    /// Longest frame duration (seconds) to request for `exposure`, or `nil` when the format's
    /// default frame rate already covers it. Never exceeds `longestSupported`; values outside the
    /// supported frame-rate ranges would raise an Objective-C exception in AVFoundation.
    static func maxFrameDuration(forExposure exposure: Double, longestSupported: Double) -> Double? {
        guard exposure > baseFrameDuration * 1.05 else { return nil }
        return min(exposure, longestSupported)
    }
}

/// Logarithmic mapping between a slider position in 0...1 and a positive value.
enum LogScale {
    static func value(unit: Double, min lo: Double, max hi: Double) -> Double {
        guard lo > 0, hi > lo else { return lo }
        let u = Swift.min(Swift.max(unit, 0), 1)
        return lo * pow(hi / lo, u)
    }

    static func unit(value: Double, min lo: Double, max hi: Double) -> Double {
        guard lo > 0, hi > lo else { return 0 }
        let v = Swift.min(Swift.max(value, lo), hi)
        return log(v / lo) / log(hi / lo)
    }
}

/// Snapshot of the camera state for the UI (read on the session queue, twice a second).
struct CameraReadout: Sendable, Equatable {
    var exposureSeconds: Double
    var iso: Float
    var lensPosition: Float
    var limits: ExposureLimits
    var longestFrameDuration: Double
    var activeMaxFrameDuration: Double
    var isAdjustingExposure: Bool
    var isAdjustingFocus: Bool
    var pressureLevel: String
    var formatSummary: String
    var supportsCustomLensPosition: Bool
}

/// Formats an exposure time for display: `1/8 s` for short, `0.75 s` for long exposures.
func formatExposure(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "–" }
    if seconds >= 0.95 { return String(format: "%.1f s", seconds) }
    if seconds >= 0.3 { return String(format: "%.2f s", seconds) }
    return "1/\(Int((1 / seconds).rounded())) s"
}
