import Foundation

/// Sky-Watcher SynScan speed levels (plan 4.6). 1x = sidereal rate.
public enum SynScanSpeed {
    /// Sidereal rate in arcsec per second.
    public static let siderealArcsecPerSecond = 15.041

    /// Multiplier of the sidereal rate for a SynScan speed level (levels 2...6 are documented).
    public static func multiplier(level: Int) -> Double? {
        switch level {
        case 2: return 8
        case 3: return 16
        case 4: return 32
        case 5: return 64
        case 6: return 128
        default: return nil
        }
    }

    /// Axis rate in arcsec/s for a multiplier.
    public static func arcsecPerSecond(multiplier: Double) -> Double {
        multiplier * siderealArcsecPerSecond
    }
}

/// How the mount turns a stick vector into per-axis commands.
public enum StickResponse: Sendable, Codable, Equatable {
    /// On/off per axis: an axis runs at full speed when its component is at least
    /// `axisThreshold` times the stick magnitude (so small off-axis pushes are ignored),
    /// otherwise it stops. Stick magnitudes below 0.2 are ignored entirely.
    case digital(axisThreshold: Double)
    /// Proportional: each axis runs at `speed * component`. Off-axis pushes leak into the
    /// other axis (cross-talk).
    case analog
}

/// Simulated alt-az mount driven by a stick vector (x = right = +azimuth, y = up = +altitude).
///
/// Models: SynScan speed levels, acceleration ramp, per-axis backlash (dead band on direction
/// reversal), sidereal drift when tracking is off, stick misalignment (user pushes a few degrees
/// off-axis), and the cos(alt) shrinking of azimuth motion on the sky.
///
/// `boresight` is the telescope pointing relative to the star field in tangent-plane arcsec
/// (see `SimulatedOptics`). Drift is applied to the boresight (stars fixed), which is equivalent.
public struct SimulatedMount: Sendable {
    public struct Configuration: Sendable, Codable, Equatable {
        /// Speed as a multiple of sidereal (SynScan level 3 = 16x).
        public var speedMultiplier: Double
        /// Backlash dead band per axis in arcsec of axis angle (x = azimuth, y = altitude).
        public var backlash: Vec2
        /// Where each axis starts inside its dead band: +1 = engaged for positive motion (no dead
        /// time when moving positive, full dead band on the first negative move), -1 the opposite.
        public var backlashEngagement: Vec2
        /// Time to ramp from standstill to full speed (seconds).
        public var rampTime: Double
        /// Rotation (radians, counterclockwise in stick space) between the intended and the actual
        /// stick push.
        public var stickMisalignment: Double
        public var stickResponse: StickResponse
        /// Initial altitude of the boresight in degrees (drives the cos(alt) factor).
        public var altitudeDegrees: Double
        /// Apparent drift of the stars across the sky frame when tracking is off, arcsec/s
        /// (x = xi / azimuth direction, y = eta / altitude direction). Ignored when tracking.
        public var driftArcsecPerSecond: Vec2
        public var trackingEnabled: Bool

        public init(speedMultiplier: Double = 16, backlash: Vec2 = .zero, backlashEngagement: Vec2 = Vec2(1, 1),
                    rampTime: Double = 0.3, stickMisalignment: Double = 0,
                    stickResponse: StickResponse = .digital(axisThreshold: 0.35),
                    altitudeDegrees: Double = 35, driftArcsecPerSecond: Vec2 = .zero,
                    trackingEnabled: Bool = false) {
            self.speedMultiplier = speedMultiplier
            self.backlash = backlash
            self.backlashEngagement = backlashEngagement
            self.rampTime = rampTime
            self.stickMisalignment = stickMisalignment
            self.stickResponse = stickResponse
            self.altitudeDegrees = altitudeDegrees
            self.driftArcsecPerSecond = driftArcsecPerSecond
            self.trackingEnabled = trackingEnabled
        }

        /// Full-deflection axis rate in arcsec/s.
        public var axisRate: Double { SynScanSpeed.arcsecPerSecond(multiplier: speedMultiplier) }
    }

    public var configuration: Configuration
    public private(set) var time: Double = 0
    /// Stick vector as intended by the user (before misalignment), components in [-1, 1].
    public private(set) var stick: Vec2 = .zero
    /// Motor (input) side axis positions in arcsec of axis angle (x = az, y = alt).
    public private(set) var motorPosition: Vec2 = .zero
    /// Output (tube) side axis positions in arcsec of axis angle.
    public private(set) var axisPosition: Vec2 = .zero
    /// Current motor axis rates in arcsec/s.
    public private(set) var axisRate: Vec2 = .zero
    /// Boresight relative to the star field, tangent-plane arcsec.
    public private(set) var boresight: Vec2 = .zero

    /// Integration step (seconds).
    public var maxSubstep: Double = 0.005

    public init(configuration: Configuration) {
        self.configuration = configuration
        let half = configuration.backlash * 0.5
        // Output lags the motor by `engagement * half` on each axis.
        motorPosition = .zero
        axisPosition = Vec2(-configuration.backlashEngagement.x * half.x, -configuration.backlashEngagement.y * half.y)
    }

    /// Current altitude of the tube in degrees.
    public var altitudeDegrees: Double {
        configuration.altitudeDegrees + (axisPosition.y - initialAxisPosition.y) / 3600
    }

    private var initialAxisPosition: Vec2 {
        let half = configuration.backlash * 0.5
        return Vec2(-configuration.backlashEngagement.x * half.x, -configuration.backlashEngagement.y * half.y)
    }

    public mutating func setStick(_ s: Vec2) {
        stick = s
    }

    /// Axis command in [-1, 1] per axis resulting from the current stick (after misalignment
    /// and the stick response model).
    public var axisCommand: Vec2 {
        let actual = stick.rotated(by: configuration.stickMisalignment)
        switch configuration.stickResponse {
        case .analog:
            return Vec2(min(max(actual.x, -1), 1), min(max(actual.y, -1), 1))
        case .digital(let threshold):
            let mag = actual.length
            guard mag >= 0.2 else { return .zero }
            func axis(_ c: Double) -> Double { abs(c) >= threshold * mag ? (c > 0 ? 1 : -1) : 0 }
            return Vec2(axis(actual.x), axis(actual.y))
        }
    }

    /// Advances the simulation by `dt` seconds.
    public mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        var remaining = dt
        while remaining > 1e-12 {
            let h = min(remaining, maxSubstep)
            substep(h)
            remaining -= h
        }
    }

    /// Advances to absolute time `t` (no-op if `t` is not in the future).
    public mutating func advance(to t: Double) {
        step(t - time)
    }

    private mutating func substep(_ h: Double) {
        let cfg = configuration
        let target = axisCommand * cfg.axisRate
        let maxDelta = cfg.rampTime > 0 ? cfg.axisRate / cfg.rampTime * h : Double.infinity
        func approach(_ v: Double, _ t: Double) -> Double {
            if abs(t - v) <= maxDelta { return t }
            return v + (t > v ? maxDelta : -maxDelta)
        }
        let newRate = Vec2(approach(axisRate.x, target.x), approach(axisRate.y, target.y))
        // Trapezoidal motor position update.
        motorPosition += (axisRate + newRate) * (0.5 * h)
        axisRate = newRate

        // Backlash: the output only moves when the motor pushes against one side of the gap.
        let old = axisPosition
        var out = axisPosition
        let half = cfg.backlash * 0.5
        if motorPosition.x - out.x > half.x { out.x = motorPosition.x - half.x }
        if motorPosition.x - out.x < -half.x { out.x = motorPosition.x + half.x }
        if motorPosition.y - out.y > half.y { out.y = motorPosition.y - half.y }
        if motorPosition.y - out.y < -half.y { out.y = motorPosition.y + half.y }
        axisPosition = out

        let delta = out - old
        let cosAlt = cos(AngleMath.radians(altitudeDegrees))
        boresight += Vec2(delta.x * cosAlt, delta.y)
        if !cfg.trackingEnabled {
            // Stars drift by +drift; equivalently the boresight moves by -drift relative to them.
            boresight -= cfg.driftArcsecPerSecond * h
        }
        time += h
    }
}
