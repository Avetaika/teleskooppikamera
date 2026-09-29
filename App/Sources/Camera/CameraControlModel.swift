import Foundation
import Observation

/// Choice shown in the exposure / focus segmented controls.
enum ControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case locked
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .locked: String(localized: "Lukitse")
        case .manual: String(localized: "Käsi")
        }
    }
}

/// Persisted camera control state.
struct CameraSettings: Codable, Equatable, Sendable {
    var exposure: ExposureControl = .auto
    var focus: FocusControl = .auto
    var manualDuration: Double = 0.125
    var manualISO: Float = 1600
    var manualLensPosition: Float = 0.8
    var activePreset: CameraPreset?

    static let storageKey = "cameraSettings.v1"
    static let infinityKey = "cameraInfinityLensPosition.v1"

    static func load(from defaults: UserDefaults = .standard) -> CameraSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else {
            return CameraSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    var exposureMode: ControlMode {
        switch exposure {
        case .auto: .auto
        case .locked: .locked
        case .manual: .manual
        }
    }

    var focusMode: ControlMode {
        switch focus {
        case .auto: .auto
        case .locked: .locked
        case .manual: .manual
        }
    }
}

/// Main-actor state for the camera controls (exposure, ISO, focus, presets). Every change is
/// stored in `UserDefaults` and forwarded to `CameraService`.
@MainActor
@Observable
final class CameraControlModel {
    private(set) var settings: CameraSettings
    private(set) var limits = ExposureLimits.assumed
    private(set) var readout: CameraReadout?
    private(set) var infinityLensPosition: Float?
    private(set) var isCalibratingInfinity = false

    private let camera: CameraService
    private let defaults: UserDefaults
    private let log = AppLog.camera

    init(camera: CameraService, defaults: UserDefaults = .standard) {
        self.camera = camera
        self.defaults = defaults
        self.settings = CameraSettings.load(from: defaults)
        let stored = defaults.object(forKey: CameraSettings.infinityKey) as? Float
        self.infinityLensPosition = stored
    }

    /// Sends the stored state to the camera (after the session started).
    func applyAll() async {
        await camera.applyExposure(settings.exposure)
        await camera.applyFocus(settings.focus)
    }

    /// Polled about twice a second while the app is active.
    func refresh() async {
        guard let readout = await camera.readout() else { return }
        self.readout = readout
        if readout.limits.maxDuration > readout.limits.minDuration, readout.limits.maxISO > readout.limits.minISO {
            limits = readout.limits
        }
    }

    // MARK: - Exposure

    func setExposureMode(_ mode: ControlMode) {
        switch mode {
        case .auto: settings.exposure = .auto
        case .locked: settings.exposure = .locked
        case .manual:
            settings.exposure = .manual(
                duration: limits.clamp(duration: settings.manualDuration),
                iso: limits.clamp(iso: settings.manualISO)
            )
        }
        settings.activePreset = nil
        commitExposure()
    }

    func setManualDuration(_ seconds: Double) {
        settings.manualDuration = limits.clamp(duration: seconds)
        settings.activePreset = nil
        settings.exposure = .manual(duration: settings.manualDuration, iso: limits.clamp(iso: settings.manualISO))
        commitExposure()
    }

    func setManualISO(_ iso: Float) {
        settings.manualISO = limits.clamp(iso: iso)
        settings.activePreset = nil
        settings.exposure = .manual(duration: limits.clamp(duration: settings.manualDuration), iso: settings.manualISO)
        commitExposure()
    }

    func applyPreset(_ preset: CameraPreset) {
        let control = preset.exposure(limits: limits)
        settings.exposure = control
        if case .manual(let duration, let iso) = control {
            settings.manualDuration = duration
            settings.manualISO = iso
        }
        settings.activePreset = preset
        log.notice("Preset \(preset.rawValue): \(control)")
        commitExposure()
    }

    private func commitExposure() {
        settings.save(to: defaults)
        let control = settings.exposure
        let camera = self.camera
        Task { await camera.applyExposure(control) }
    }

    // MARK: - Focus

    func setFocusMode(_ mode: ControlMode) {
        switch mode {
        case .auto: settings.focus = .auto
        case .locked: settings.focus = .locked
        case .manual: settings.focus = .manual(lensPosition: settings.manualLensPosition)
        }
        commitFocus()
    }

    func setLensPosition(_ position: Float) {
        let clamped = min(max(position, 0), 1)
        settings.manualLensPosition = clamped
        settings.focus = .manual(lensPosition: clamped)
        commitFocus()
    }

    /// Focus the stored "infinity" lens position (if calibrated).
    func goToInfinity() {
        guard let position = infinityLensPosition else { return }
        setLensPosition(position)
    }

    /// Autofocus once on a distant target, then lock and store the lens position.
    func calibrateInfinity() {
        guard !isCalibratingInfinity else { return }
        isCalibratingInfinity = true
        let camera = self.camera
        Task {
            let position = await camera.calibrateInfinity()
            isCalibratingInfinity = false
            guard let position else { return }
            infinityLensPosition = position
            defaults.set(position, forKey: CameraSettings.infinityKey)
            settings.manualLensPosition = position
            settings.focus = .manual(lensPosition: position)
            settings.save(to: defaults)
        }
    }

    private func commitFocus() {
        settings.save(to: defaults)
        let control = settings.focus
        let camera = self.camera
        Task { await camera.applyFocus(control) }
    }
}
