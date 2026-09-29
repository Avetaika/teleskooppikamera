import Foundation

/// Observer location on Earth (degrees; longitude positive east).
public struct GeoLocation: Sendable, Codable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Fixed default: Helsinki (D-19, no location permission needed).
    public static let helsinki = GeoLocation(latitude: 60.17, longitude: 24.94)
}

/// Sun position from the NOAA low-precision algorithm (the NOAA Solar Calculator spreadsheet,
/// after Meeus). Accuracy about 0.01-0.02 deg for dates between 1900 and 2100, far better than the
/// 0.1 deg needed for the sun reminder (plan 8, D-19).
public struct SolarPosition: Sendable, Equatable {
    /// Azimuth in degrees, clockwise from north, [0, 360).
    public var azimuth: Double
    /// Geometric (airless) altitude of the sun's center in degrees.
    public var altitude: Double
    /// Altitude including the NOAA approximation of atmospheric refraction.
    public var apparentAltitude: Double
    /// Declination in degrees.
    public var declination: Double
    /// Equation of time in minutes.
    public var equationOfTime: Double
    /// Local hour angle in degrees (negative before solar noon).
    public var hourAngle: Double

    /// Computes the sun position at `date` for `location` (default Helsinki).
    public init(date: Date, location: GeoLocation = .helsinki) {
        let jd = date.timeIntervalSince1970 / 86400 + 2_440_587.5
        self.init(julianDay: jd, location: location)
    }

    public init(julianDay jd: Double, location: GeoLocation) {
        let rad = Double.pi / 180
        let t = (jd - 2_451_545.0) / 36525.0

        let l0 = AngleMath.wrapDegrees360(280.46646 + t * (36000.76983 + t * 0.0003032))
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * m * rad) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(omega * rad)
        let decl = asin(sin(obliq * rad) * sin(appLong * rad)) / rad

        let y = pow(tan(obliq * rad / 2), 2)
        let eqTime = 4 / rad * (y * sin(2 * l0 * rad)
            - 2 * e * sin(m * rad)
            + 4 * e * y * sin(m * rad) * cos(2 * l0 * rad)
            - 0.5 * y * y * sin(4 * l0 * rad)
            - 1.25 * e * e * sin(2 * m * rad))

        // Minutes past UTC midnight.
        let dayFraction = (jd + 0.5) - (jd + 0.5).rounded(.down)
        let minutes = dayFraction * 1440
        var trueSolarTime = (minutes + eqTime + 4 * location.longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }
        let hourAngle = trueSolarTime / 4 < 0 ? trueSolarTime / 4 + 180 : trueSolarTime / 4 - 180

        let lat = location.latitude * rad
        let cosZenith = min(max(sin(lat) * sin(decl * rad) + cos(lat) * cos(decl * rad) * cos(hourAngle * rad), -1), 1)
        let zenith = acos(cosZenith) / rad
        let sinZ = sin(zenith * rad)
        var azimuth: Double
        let denom = cos(lat) * sinZ
        if abs(denom) < 1e-12 {
            azimuth = location.latitude >= 0 ? 180 : 0
        } else {
            let cosAz = min(max((sin(lat) * cos(zenith * rad) - sin(decl * rad)) / denom, -1), 1)
            let a = acos(cosAz) / rad
            azimuth = hourAngle > 0 ? a + 180 : 540 - a
        }
        azimuth = AngleMath.wrapDegrees360(azimuth)
        let altitude = 90 - zenith

        self.azimuth = azimuth
        self.altitude = altitude
        self.apparentAltitude = altitude + Self.refraction(altitude: altitude)
        self.declination = decl
        self.equationOfTime = eqTime
        self.hourAngle = hourAngle
    }

    /// NOAA approximation of atmospheric refraction (degrees) for a geometric altitude (degrees).
    public static func refraction(altitude h: Double) -> Double {
        if h > 85 { return 0 }
        let rad = Double.pi / 180
        let te = tan(h * rad)
        let arcsec: Double
        if h > 5 {
            arcsec = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)
        } else if h > -0.575 {
            arcsec = 1735 + h * (-518.2 + h * (103.4 + h * (-12.79 + h * 0.711)))
        } else {
            arcsec = -20.772 / te
        }
        return arcsec / 3600
    }

    public var isAboveHorizon: Bool { apparentAltitude > -0.833 }

    /// Plan 8: warn when the sun is up and in the western/northern half (azimuth 200-360 deg),
    /// i.e. near the balcony's north-west view.
    public var isInWarningSector: Bool {
        isAboveHorizon && azimuth >= 200 && azimuth < 360
    }

    /// Great-circle angle (degrees) between the sun and a direction given in azimuth / altitude
    /// (degrees). Basis for the future 30 deg exclusion zone (D-19).
    public func angularDistance(azimuth az: Double, altitude alt: Double) -> Double {
        let rad = Double.pi / 180
        let c = sin(altitude * rad) * sin(alt * rad)
            + cos(altitude * rad) * cos(alt * rad) * cos((azimuth - az) * rad)
        return acos(min(max(c, -1), 1)) / rad
    }
}
