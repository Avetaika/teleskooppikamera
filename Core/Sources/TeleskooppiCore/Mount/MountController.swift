import Foundation

/// Mount pointing as reported by the mount (degrees).
public struct MountPosition: Sendable, Codable, Equatable {
    public var azimuth: Double
    public var altitude: Double
    /// Seconds (monotonic clock of the reporter).
    public var timestamp: Double

    public init(azimuth: Double, altitude: Double, timestamp: Double) {
        self.azimuth = azimuth
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

/// Interface for driving a mount directly (plan 3.3, 7.3). No implementation in the MVP.
///
/// Safety contract (D-19, D-20), mandatory for every implementation that can move a mount:
/// 1. Every motion command is checked against a sun exclusion zone (30 deg, `SolarPosition`),
///    including stick motion and the path of the move, day and night.
/// 2. Dead man's switch: motion only while heartbeats arrive; a missed heartbeat sends stop.
/// 3. Only one controller may command motion at a time.
public protocol MountController: AnyObject, Sendable {
    /// Starts continuous motion with signed axis rates in degrees per second.
    func move(alt: Double, az: Double) async throws
    /// Stops both axes.
    func stop() async throws
    /// Position updates.
    var position: AsyncStream<MountPosition> { get }
}
