import Foundation
import TeleskooppiCore

extension CameraSettings {
    /// Platform-independent copy for storing in a profile.
    var snapshot: CameraSettingsSnapshot {
        let mode: String
        switch exposure {
        case .auto: mode = "auto"
        case .locked: mode = "locked"
        case .manual: mode = "manual"
        }
        return CameraSettingsSnapshot(exposureMode: mode, exposureSeconds: manualDuration, iso: Double(manualISO),
                                      lensPosition: Double(manualLensPosition), preset: activePreset?.rawValue)
    }
}

extension CameraControlModel {
    /// Applies stored settings (preset if any, otherwise the exposure mode) and the focus position.
    func apply(_ snapshot: CameraSettingsSnapshot) {
        if let raw = snapshot.preset, let preset = CameraPreset(rawValue: raw) {
            applyPreset(preset)
        } else {
            setManualDuration(snapshot.exposureSeconds)
            setManualISO(Float(snapshot.iso))
            switch snapshot.exposureMode {
            case "auto": setExposureMode(.auto)
            case "locked": setExposureMode(.locked)
            default: setExposureMode(.manual)
            }
        }
        setLensPosition(Float(snapshot.lensPosition))
    }
}

extension AppModel {
    /// Eyepiece switch: restore the profile's crosshair centre and camera settings.
    func applyProfile(_ profile: SetupProfile) {
        let center = profile.opticalCenter ?? profile.calibration?.opticalCenter
        updateDisplay { $0.opticalCenter = center }
        if let camera = profile.camera { controls.apply(camera) }
    }

    /// Current camera + centre, for saving back into the active profile.
    func currentCameraSnapshot() -> CameraSettingsSnapshot { controls.settings.snapshot }
}
