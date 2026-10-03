import Foundation
import TeleskooppiCore

/// Where the active calibration is kept between launches. The default is `UserDefaults`; the
/// setup profile store (phase 6) replaces it: see `ActiveProfileCalibrationStore`.
protocol CalibrationPersisting {
    func load() -> CalibrationResult?
    /// `nil` clears the stored calibration.
    func save(_ calibration: CalibrationResult?)
}

struct UserDefaultsCalibrationStore: CalibrationPersisting {
    static let storageKey = "calibration.active.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = Self.storageKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> CalibrationResult? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CalibrationResult.self, from: data)
    }

    func save(_ calibration: CalibrationResult?) {
        guard let calibration, let data = try? JSONEncoder().encode(calibration) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
