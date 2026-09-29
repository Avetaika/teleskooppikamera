import Foundation

/// All parameters of one closed-loop simulated calibration (plan 4.8).
public struct CalibrationScenario: Sendable, Codable, Equatable {
    public var seed: UInt64
    /// Camera geometry and ground truth (`displayRotation`, `mirrored`).
    public var optics: SimulatedOptics
    public var mount: SimulatedMount.Configuration
    /// Stick misalignment of the user's UP and RIGHT pushes (radians).
    public var misalignmentUp: Double
    public var misalignmentRight: Double
    /// Seeing jitter: Gaussian position noise per frame and axis (px).
    public var jitterSigma: Double
    /// Probability that a frame loses the star (e.g. clouds).
    public var dropoutProbability: Double
    /// Analysis frame rate (Hz).
    public var frameRate: Double
    /// User reaction time to a prompt change (s).
    public var reactionTime: Double
    /// Initial star position relative to the optical center (px).
    public var starOffset: Vec2

    public init(seed: UInt64 = 1, optics: SimulatedOptics = SimulatedOptics(),
                mount: SimulatedMount.Configuration = .init(), misalignmentUp: Double = 0,
                misalignmentRight: Double = 0, jitterSigma: Double = 1, dropoutProbability: Double = 0,
                frameRate: Double = 10, reactionTime: Double = 0.35, starOffset: Vec2 = Vec2(10, -6)) {
        self.seed = seed
        self.optics = optics
        self.mount = mount
        self.misalignmentUp = misalignmentUp
        self.misalignmentRight = misalignmentRight
        self.jitterSigma = jitterSigma
        self.dropoutProbability = dropoutProbability
        self.frameRate = frameRate
        self.reactionTime = reactionTime
        self.starOffset = starOffset
    }

    /// Random scenario within the plan 4.8 acceptance ranges: rotation 0-360 deg, mirror yes/no,
    /// backlash 0-15 arcmin, drift 0-15 arcsec/s, jitter 0.5-3 px, stick misalignment +-10 deg,
    /// SynScan level 3-4, altitude 10-60 deg.
    public static func random(seed: UInt64) -> CalibrationScenario {
        var rng = SplitMix64(seed: seed ^ 0xC0FF_EE00_DEAD_BEEF)
        let optics = SimulatedOptics(displayRotation: rng.uniform(0...(2 * .pi)), mirrored: rng.bool())
        let driftMag = rng.uniform(0...15)
        let driftDir = rng.uniform(0...(2 * .pi))
        let level = rng.bool() ? 3 : 4
        let mount = SimulatedMount.Configuration(
            speedMultiplier: SynScanSpeed.multiplier(level: level) ?? 16,
            backlash: Vec2(rng.uniform(0...900), rng.uniform(0...900)),
            backlashEngagement: Vec2(rng.uniform(-1...1), rng.uniform(-1...1)),
            rampTime: rng.uniform(0.1...0.5),
            stickResponse: .digital(axisThreshold: 0.35),
            altitudeDegrees: rng.uniform(10...60),
            driftArcsecPerSecond: Vec2.unit(angle: driftDir) * driftMag,
            trackingEnabled: false)
        let offsetR = rng.uniform(0...25), offsetA = rng.uniform(0...(2 * .pi))
        return CalibrationScenario(
            seed: seed, optics: optics, mount: mount,
            misalignmentUp: AngleMath.radians(rng.uniform(-10...10)),
            misalignmentRight: AngleMath.radians(rng.uniform(-10...10)),
            jitterSigma: rng.uniform(0.5...3), dropoutProbability: 0, frameRate: 10,
            reactionTime: rng.uniform(0.2...0.6), starOffset: Vec2.unit(angle: offsetA) * offsetR)
    }

    /// Ground-truth M at the starting altitude (px/s), taking the stick response into account.
    public var expectedStickToImage: Mat2 {
        let rate = mount.axisRate
        let cosAlt = cos(AngleMath.radians(mount.altitudeDegrees))
        func command(_ s: Vec2, _ mis: Double) -> Vec2 {
            var m = SimulatedMount(configuration: mount)
            m.configuration.stickMisalignment = mis
            m.setStick(s)
            return m.axisCommand
        }
        let cr = command(Vec2(1, 0), misalignmentRight), cu = command(Vec2(0, 1), misalignmentUp)
        let g = optics.naturalToImage
        func image(_ axis: Vec2) -> Vec2 {
            let sky = Vec2(axis.x * rate * cosAlt, axis.y * rate)
            return g * Vec2(-sky.x, sky.y) / optics.plateScale
        }
        return Mat2(columns: image(cr), image(cu))
    }
}

/// One simulated analysis frame, for rendering or logging.
public struct SimulationFrame: Sendable {
    public var time: Double
    public var boresight: Vec2
    /// Seeing offset applied to the whole image this frame (px).
    public var jitter: Vec2
    /// True star position (without jitter).
    public var truePosition: Vec2
    public var sample: TrackSample?
    public var prompt: CalibrationPrompt
    public var stick: Vec2
}

public struct CalibrationRunOutcome: Sendable {
    public var scenario: CalibrationScenario
    public var result: CalibrationResult?
    public var failure: CalibrationFailure?
    /// |theta_measured - theta_true| wrapped, radians.
    public var rotationError: Double?
    public var mirrorCorrect: Bool?
    /// Simulated seconds until done / failed.
    public var duration: Double
    public var expectedStickToImage: Mat2
    /// Prompt changes with their times.
    public var promptLog: [(time: Double, prompt: CalibrationPrompt)]
    public var succeeded: Bool { result != nil }
}

/// Closed loop: `SimulatedMount` + `SimulatedOptics` produce ground-truth star positions (+ jitter),
/// a `CalibrationSession` consumes them, and a virtual user reacts to the prompts.
public struct CalibrationSimulation: Sendable {
    public var scenario: CalibrationScenario
    public var mode: CalibrationSession.Mode
    public var calibrationConfig: CalibrationConfig
    /// Guide star position on the sky (tangent-plane arcsec).
    public let guideStar: Vec2

    public init(scenario: CalibrationScenario, mode: CalibrationSession.Mode = .full,
                calibrationConfig: CalibrationConfig? = nil) {
        self.scenario = scenario
        self.mode = mode
        self.calibrationConfig = calibrationConfig
            ?? CalibrationConfig(opticalCenter: scenario.optics.opticalCenter, fieldRadius: scenario.optics.fieldRadius)
        guideStar = scenario.optics.unproject(scenario.optics.opticalCenter + scenario.starOffset, boresight: .zero)
    }

    /// Runs until the session finishes or `maxDuration` simulated seconds pass.
    /// `onFrame` is called for every analysis frame.
    public func run(maxDuration: Double = 180, onFrame: ((SimulationFrame) -> Void)? = nil) -> CalibrationRunOutcome {
        var rng = SplitMix64(seed: scenario.seed)
        var mount = SimulatedMount(configuration: scenario.mount)
        var session = CalibrationSession(config: calibrationConfig, mode: mode)
        let dt = 1 / scenario.frameRate
        var t = 0.0
        var lastPrompt = session.prompt
        var pendingStick: (stick: Vec2, misalignment: Double, at: Double)?
        var log: [(time: Double, prompt: CalibrationPrompt)] = [(0, lastPrompt)]
        let optics = scenario.optics

        while t < maxDuration {
            t += dt
            if let p = pendingStick, p.at <= t {
                // Apply the stick change at its exact time inside this frame interval.
                mount.advance(to: p.at)
                mount.configuration.stickMisalignment = p.misalignment
                mount.setStick(p.stick)
                pendingStick = nil
            }
            mount.advance(to: t)

            let truth = optics.project(star: guideStar, boresight: mount.boresight)
            let jitter = Vec2(rng.gaussian(), rng.gaussian()) * scenario.jitterSigma
            let observed = truth + jitter
            let dropped = scenario.dropoutProbability > 0 && rng.bool(probability: scenario.dropoutProbability)
            let visible = optics.isInsideField(observed) && optics.isInsideImage(observed) && !dropped
            let sample: TrackSample? = visible ? TrackSample(t: t, p: observed) : nil
            let prompt = session.feed(sample, at: t)
            onFrame?(SimulationFrame(time: t, boresight: mount.boresight, jitter: jitter, truePosition: truth,
                                     sample: sample, prompt: prompt, stick: mount.stick))

            if prompt != lastPrompt {
                log.append((t, prompt))
                lastPrompt = prompt
                switch prompt {
                case .pressAndHold(let dir):
                    let mis = dir == .up || dir == .down ? scenario.misalignmentUp : scenario.misalignmentRight
                    pendingStick = (dir.unitVector, mis, t + scenario.reactionTime)
                case .stop, .releaseAndWait, .holdStill, .centerStar:
                    let releasePending = pendingStick.map { $0.stick == .zero } ?? false
                    if !releasePending && (mount.stick != .zero || pendingStick != nil) {
                        pendingStick = (.zero, mount.configuration.stickMisalignment, t + scenario.reactionTime)
                    }
                case .done, .failed:
                    break
                }
            }
            if prompt.isTerminal { break }
        }

        var rotationError: Double?
        var mirrorCorrect: Bool?
        if let r = session.result {
            rotationError = abs(AngleMath.difference(r.displayRotation, optics.displayRotation))
            mirrorCorrect = r.mirrored == optics.mirrored
        }
        return CalibrationRunOutcome(scenario: scenario, result: session.result,
                                     failure: session.failure ?? (session.result == nil ? .timeout : nil),
                                     rotationError: rotationError, mirrorCorrect: mirrorCorrect, duration: t,
                                     expectedStickToImage: scenario.expectedStickToImage, promptLog: log)
    }
}
