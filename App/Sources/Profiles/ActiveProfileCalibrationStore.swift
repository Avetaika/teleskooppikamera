import Foundation
import TeleskooppiCore

/// `CalibrationPersisting` backed by the active setup profile: one calibration per profile, so an
/// eyepiece switch loads that eyepiece's calibration (phase 6, replaces the single UserDefaults slot).
@MainActor
final class ActiveProfileCalibrationStore: CalibrationPersisting {
    private let manager: ProfileManager

    init(manager: ProfileManager) {
        self.manager = manager
    }

    func load() -> CalibrationResult? {
        guard let id = manager.activeID else { return nil }
        return manager.load(profileID: id)
    }

    func save(_ calibration: CalibrationResult?) {
        if manager.activeID == nil { manager.adoptDefaultActive() }
        guard let id = manager.activeID else { return }
        if let calibration {
            manager.save(calibration, profileID: id)
        } else {
            manager.clearCalibration(profileID: id)
        }
    }

    /// Moves a calibration saved by the phase 5 build (single UserDefaults slot) into the active
    /// profile, once. Does nothing when the profile already has a calibration.
    func migrateLegacy(from legacy: CalibrationPersisting) {
        guard let old = legacy.load() else { return }
        if load() == nil { save(old) }
        legacy.save(nil)
    }
}
