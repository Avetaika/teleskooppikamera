import Foundation

extension CalibrationScenario {
    /// The same physical scenario on a smaller (or larger) sensor: image size, field radius and star
    /// offset scale with `factor`, the plate scale (arcsec per pixel) with `1 / factor`. Useful to keep
    /// rendered test sessions small.
    public func scaled(by factor: Double) -> CalibrationScenario {
        var sc = self
        let o = optics
        sc.optics = SimulatedOptics(
            imageWidth: max(16, Int((Double(o.imageWidth) * factor).rounded())),
            imageHeight: max(16, Int((Double(o.imageHeight) * factor).rounded())),
            opticalCenter: o.opticalCenter * factor, fieldRadius: o.fieldRadius * factor,
            plateScale: o.plateScale / factor, displayRotation: o.displayRotation, mirrored: o.mirrored)
        sc.starOffset = starOffset * factor
        return sc
    }
}

public struct SimulatedSessionOptions: Sendable {
    /// Sensor scale relative to 960x720 (see `CalibrationScenario.scaled(by:)`).
    public var scale = 1.0
    /// Number of random field stars (magnitude 6...12).
    public var starCount = 700
    /// Magnitude of the tracked star.
    public var guideMagnitude = 4.5
    /// Electrons per ADU of the rendered frames; 8 keeps the guide star below saturation.
    public var gain = 8.0
    /// Exposure time stored in the frame headers (s).
    public var exposure = 0.05
    public var eyepiece = "simulated 25 mm"
    /// Parent directory names/time stamp are chosen by the caller; this date names the session.
    public var date = Date()

    public init() {}
}

/// Writes a synthetic two-move calibration as a recording (D-11), so that replay and the detector
/// pipeline can be developed and tested without a phone.
public enum SimulatedSession {
    /// Sky renderer configuration used for recorded sessions.
    public static func skyConfiguration(_ options: SimulatedSessionOptions) -> SyntheticSky.Configuration {
        SyntheticSky.Configuration(gain: options.gain)
    }

    /// Star field of a scenario: random field plus the guide star at its true position.
    public static func makeSky(scenario sc: CalibrationScenario, guideStar: Vec2,
                               options: SimulatedSessionOptions) -> SyntheticSky {
        var starRng = SplitMix64(seed: sc.seed &+ 0x5EED)
        let fieldArcsec = sc.optics.fieldRadius * sc.optics.plateScale
        var field = StarField.random(count: options.starCount, radiusArcsec: fieldArcsec * 2.2, brightest: 6,
                                     faintest: 12, rng: &starRng)
        field.stars.append(SimulatedStar(position: guideStar, magnitude: options.guideMagnitude))
        return SyntheticSky(optics: sc.optics, field: field, configuration: skyConfiguration(options))
    }

    /// Simulates `scenario` (scaled by `options.scale`), rendering and recording every analysis frame to
    /// `<parent>/session-YYYYMMDD-HHMMSS.tcs`. Events: `calibration.start`, `star.select`, every prompt
    /// change and `calibration.end`. `meta.calibration` holds the result of the ground-truth run and the
    /// notes the true rotation, so a replay can be compared with it.
    @discardableResult
    public static func record(scenario: CalibrationScenario, in parent: URL,
                              options: SimulatedSessionOptions = SimulatedSessionOptions())
        throws -> (directory: URL, outcome: CalibrationRunOutcome) {
        let sc = options.scale == 1 ? scenario : scenario.scaled(by: options.scale)
        let sim = CalibrationSimulation(scenario: sc)
        let sky = makeSky(scenario: sc, guideStar: sim.guideStar, options: options)
        let background = sky.expectedBackground()
        let optics = sc.optics
        let meta = SessionMeta(
            createdAt: options.date,
            device: DeviceInfo(model: "TeleskooppiCore simulator", systemVersion: "-",
                               appVersion: TeleskooppiCore.version, camera: "synthetic"),
            format: FrameFormat(width: optics.imageWidth, height: optics.imageHeight,
                                binning: 2, frameRate: sc.frameRate),
            profile: SessionProfile(eyepiece: options.eyepiece,
                                    speedLevel: SynScanSpeed.level(multiplier: sc.mount.speedMultiplier),
                                    opticalCenter: optics.opticalCenter, fieldRadius: optics.fieldRadius),
            calibration: nil,
            notes: "simulated seed \(sc.seed), true rotation "
                + String(format: "%.2f", AngleMath.degrees(optics.displayRotation))
                + " deg, mirrored \(optics.mirrored)")
        let writer = try SessionWriter.create(in: parent, date: options.date, meta: meta)

        var image = GrayImage8(width: optics.imageWidth, height: optics.imageHeight,
                               fill: UInt8(clampingDouble: sky.configuration.bias))
        let full = PixelRect(x: 0, y: 0, width: optics.imageWidth, height: optics.imageHeight)
        var noise = SplitMix64(seed: sc.seed &+ 0xF00D)
        var writeError: Error?
        var lastPrompt: CalibrationPrompt?
        let start = optics.opticalCenter + sc.starOffset
        var first = true

        let outcome = sim.run(onFrame: { frame in
            guard writeError == nil else { return }
            do {
                if first {
                    first = false
                    try writer.appendEvent(SessionEvent(t: frame.time, type: SessionEvent.calibrationStart))
                    try writer.appendEvent(SessionEvent(t: frame.time, type: SessionEvent.starSelect,
                                                        values: ["x": start.x, "y": start.y]))
                }
                sky.render(into: &image, window: full, boresight: frame.boresight, imageOffset: frame.jitter,
                           background: background, rng: &noise)
                try writer.append(image, meta: FrameMeta(timestamp: frame.time, exposure: options.exposure,
                                                         iso: 800, lensPosition: 1))
                if frame.prompt != lastPrompt {
                    lastPrompt = frame.prompt
                    try writer.appendEvent(SessionEvent(t: frame.time, type: SessionEvent.prompt,
                                                        text: ["prompt": frame.prompt.summary]))
                    if frame.prompt.isTerminal {
                        try writer.appendEvent(SessionEvent(t: frame.time, type: SessionEvent.calibrationEnd,
                                                            text: ["result": frame.prompt.summary]))
                    }
                }
            } catch {
                writeError = error
            }
        })
        if let e = writeError { throw e }
        try writer.updateMeta { $0.calibration = outcome.result }
        try writer.finish()
        return (writer.directory, outcome)
    }
}

extension SynScanSpeed {
    /// Inverse of `multiplier(level:)`, nil for non-standard multipliers.
    public static func level(multiplier: Double) -> Int? {
        (2...6).first { self.multiplier(level: $0) == multiplier }
    }
}
