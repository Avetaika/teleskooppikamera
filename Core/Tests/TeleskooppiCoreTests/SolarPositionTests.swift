import Foundation
import Testing
@testable import TeleskooppiCore

/// Reference values: JPL Horizons (https://ssd.jpl.nasa.gov/api/horizons.api), Sun (10),
/// observer 60.17 N 24.94 E 0 m, apparent airless azimuth / elevation (QUANTITIES=4), UT.
@Suite struct SolarPositionTests {
    struct Reference: Sendable, CustomTestStringConvertible {
        var iso: String
        var azimuth: Double
        var altitude: Double
        var testDescription: String { iso }
    }

    static let references: [Reference] = [
        Reference(iso: "2026-09-29T09:00:00Z", azimuth: 160.331736, altitude: 25.850196),
        Reference(iso: "2026-09-29T15:30:00Z", azimuth: 259.921819, altitude: 2.763377),
        Reference(iso: "2026-06-21T10:00:00Z", azimuth: 171.570270, altitude: 53.064975),
        Reference(iso: "2026-12-21T10:20:00Z", azimuth: 180.399153, altitude: 6.390120),
        Reference(iso: "2026-03-20T06:00:00Z", azimuth: 110.340800, altitude: 11.106667),
        Reference(iso: "2026-10-15T14:00:00Z", azimuth: 238.182095, altitude: 7.258070),
        Reference(iso: "2025-01-15T12:00:00Z", azimuth: 201.146827, altitude: 6.747715),
        Reference(iso: "2030-07-01T18:00:00Z", azimuth: 301.673488, altitude: 8.859312),
        Reference(iso: "2026-06-21T22:30:00Z", azimuth: 1.811417, altitude: -6.380229),
    ]

    @Test(arguments: references)
    func matchesHorizons(_ ref: Reference) throws {
        let date = try #require(ISO8601DateFormatter().date(from: ref.iso))
        let p = SolarPosition(date: date)
        #expect(abs(AngleMath.difference(AngleMath.radians(p.azimuth), AngleMath.radians(ref.azimuth))) < AngleMath.radians(0.2),
                "azimuth \(p.azimuth) vs \(ref.azimuth)")
        #expect(abs(p.altitude - ref.altitude) < 0.2, "altitude \(p.altitude) vs \(ref.altitude)")
    }

    @Test func warningSectorAndRefraction() throws {
        let afternoon = SolarPosition(date: try #require(ISO8601DateFormatter().date(from: "2026-09-29T15:30:00Z")))
        #expect(afternoon.isInWarningSector)
        let morning = SolarPosition(date: try #require(ISO8601DateFormatter().date(from: "2026-09-29T07:00:00Z")))
        #expect(!morning.isInWarningSector)
        let night = SolarPosition(date: try #require(ISO8601DateFormatter().date(from: "2026-12-21T22:00:00Z")))
        #expect(!night.isAboveHorizon)
        #expect(abs(SolarPosition.refraction(altitude: 0) - 0.482) < 0.01)
        #expect(SolarPosition.refraction(altitude: 45) < 0.02)
        #expect(abs(afternoon.angularDistance(azimuth: afternoon.azimuth, altitude: afternoon.altitude)) < 1e-6)
        #expect(abs(afternoon.angularDistance(azimuth: afternoon.azimuth + 180, altitude: -afternoon.altitude) - 180) < 1e-6)
    }
}
