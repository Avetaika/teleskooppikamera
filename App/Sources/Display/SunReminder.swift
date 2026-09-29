import Foundation
import TeleskooppiCore

/// Sun position for the safety reminder (D-19, plan 8): fixed Helsinki coordinates, no location
/// permission. Warns when the sun is above the horizon and in the western/northern half
/// (azimuth 200–360°), i.e. near the balcony's north-west view.
struct SunReminder: Equatable, Sendable {
    var azimuth: Double
    var altitude: Double
    var isUp: Bool
    var isWarning: Bool

    init(date: Date = .now, location: GeoLocation = .helsinki) {
        let position = SolarPosition(date: date, location: location)
        azimuth = position.azimuth
        altitude = position.apparentAltitude
        isUp = position.isAboveHorizon
        isWarning = position.isInWarningSector
    }

    /// Cardinal direction of the azimuth in Finnish, e.g. `länsi`.
    var directionName: String { Self.directionName(forAzimuth: azimuth) }

    static func directionName(forAzimuth azimuth: Double) -> String {
        let names = ["pohjoinen", "koillinen", "itä", "kaakko", "etelä", "lounas", "länsi", "luode"]
        let wrapped = (azimuth + 22.5).truncatingRemainder(dividingBy: 360)
        let index = Int((wrapped < 0 ? wrapped + 360 : wrapped) / 45)
        return names[min(max(index, 0), names.count - 1)]
    }

    /// One-line status, e.g. `Aurinko: az 243° (lounas), korkeus 12°`.
    var summary: String {
        let az = Int(azimuth.rounded()) % 360
        let alt = Int(altitude.rounded())
        if isUp {
            return String(localized: "Aurinko: az \(az)° (\(directionName)), korkeus \(alt)°")
        }
        return String(localized: "Aurinko horisontin alla (\(alt)°)")
    }

    var warningText: String {
        String(localized: "AURINKO YLHÄÄLLÄ: älä osoita putkea länteen tai pohjoiseen ilman peitettä.")
    }
}
