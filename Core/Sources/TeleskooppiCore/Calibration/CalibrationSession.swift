import Foundation

/// Tunables of the calibration state machine. All distances in image pixels, times in seconds.
public struct CalibrationConfig: Sendable, Codable, Equatable {
    /// Optical center (crosshair) in image pixels.
    public var opticalCenter: Vec2
    /// Field stop radius in image pixels.
    public var fieldRadius: Double
    /// STOP when the displacement reaches this fraction of the field *diameter* (plan 4.3: 25 %).
    public var targetDisplacementFraction: Double = 0.25
    /// The star must be within this fraction of the field radius from the center to start.
    public var maxStartOffsetFraction: Double = 0.4
    /// Fail with `.nearEdge` when the star gets closer than this fraction of R to the field stop.
    public var edgeMarginFraction: Double = 0.05
    /// Minimum stillness window before a move (plan 4.3: >= 1 s).
    public var minSettleDuration: Double = 1.0
    /// Longest stillness window used (older samples are dropped); also ends a settle when the
    /// drift precision target cannot be reached.
    public var maxSettleDuration: Double = 8.0
    /// Give up if the star does not become still within this time.
    public var settleTimeout: Double = 25.0
    /// Target standard error (px/s per axis) of the pooled drift estimate.
    public var driftPrecision: Double = 0.25
    /// Largest image speed (px/s) still considered "still" (drift of an untracked mount).
    public var maxDriftSpeed: Double = 6.0
    /// Motion start threshold `max(minimum, sigmas * noise sigma)` (plan 4.3: max(3 px, 5 sigma)).
    public var motionThresholdMinimum: Double = 3.0
    public var motionThresholdSigmas: Double = 5.0
    /// Consecutive samples beyond the threshold needed to declare motion.
    public var motionConfirmSamples: Int = 2
    /// Give up if no motion starts within this time after asking for a push (plan 4.3: 20 s).
    public var motionStartTimeout: Double = 20.0
    /// Longest tolerated gap without a star (plan 4.3: 1 s).
    public var lostTimeout: Double = 1.0
    /// While moving: no progress for this long means the stick was released early.
    public var stallDuration: Double = 1.5
    /// After STOP: no progress for this long means the star has stopped.
    public var stopDetectDuration: Double = 1.0
    /// Samples right after the stop detection that are ignored for settling (deceleration tail).
    public var settleGuard: Double = 0.3
    public var moveTimeout: Double = 60.0
    /// Orthogonality limits (plan 4.4): < 8 deg OK, 8-15 deg warning, > 15 deg failure.
    public var orthogonalityWarning: Double = AngleMath.radians(8)
    public var orthogonalityFailure: Double = AngleMath.radians(15)
    /// TLS residual warning level (plan 4.4: 1.5 px), raised to 2.5 sigma of the measured noise.
    public var lineResidualWarning: Double = 1.5
    public var minMoveSamples: Int = 5

    public init(opticalCenter: Vec2, fieldRadius: Double) {
        self.opticalCenter = opticalCenter
        self.fieldRadius = fieldRadius
    }

    public var targetDisplacement: Double { targetDisplacementFraction * 2 * fieldRadius }
}

/// Calibration state machine (plan 4.3, 4.6). Feed it one `TrackSample` per analysed frame (or
/// `nil` when the star was not found) and show the returned prompt.
///
/// Flow (full mode): settle (baseline + drift) -> "push UP" -> motion detected -> STOP at 25 % of
/// the field diameter -> settle -> "push RIGHT" -> ... -> settle -> solve.
///
/// Directions come from a TLS line through the drift-corrected move samples (D-07), so backlash,
/// acceleration and braking do not bias them. Drift is estimated from all still periods pooled
/// together and subtracted at the end.
public struct CalibrationSession: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Two moves: UP, then RIGHT (D-06).
        case full
        /// One UP move; rotation update against a previous full calibration (D-06).
        case quick(previous: CalibrationResult)
    }

    public enum Phase: String, Sendable, Codable {
        case acquiring, settling, waitingForMotion, moving, stopping, finished, failed
    }

    public let config: CalibrationConfig
    public let mode: Mode
    public let moves: [StickDirection]

    public private(set) var phase: Phase = .acquiring
    public private(set) var prompt: CalibrationPrompt = .centerStar
    /// Index of the current move in `moves`.
    public private(set) var moveIndex = 0
    public private(set) var measurements: [MoveMeasurement] = []
    /// Fraction of the target displacement reached in the current move (0...1+).
    public private(set) var progress: Double = 0
    /// Current pooled drift estimate (px/s).
    public private(set) var driftVelocity: Vec2 = .zero
    /// Current per-axis position noise estimate (px).
    public private(set) var noiseSigma: Double = 0
    public private(set) var result: CalibrationResult?
    public private(set) var failure: CalibrationFailure?

    // MARK: Internal state

    private struct DriftWindow: Sendable {
        var sxx: Double
        var sxp: Vec2
        var noiseVariance: Double
        var count: Int
    }

    private var phaseStart = 0.0
    private var lostSince: Double?
    private var settleBuffer: [TrackSample] = []
    private var driftWindows: [DriftWindow] = []
    private var baseline = Vec2.zero
    private var baselineTime = 0.0
    private var exceedCount = 0
    private var moveBuffer: [TrackSample] = []
    private var rawMoves: [[TrackSample]] = []
    /// Running maximum of the displacement from the baseline, with timestamps (for stall/stop detection).
    private var progressTimes: [Double] = []
    private var progressMax: [Double] = []

    public init(config: CalibrationConfig, mode: Mode = .full) {
        self.config = config
        self.mode = mode
        switch mode {
        case .full: moves = [.up, .right]
        case .quick: moves = [.up]
        }
    }

    /// Current move direction, if a move is pending or in progress.
    public var currentMove: StickDirection? {
        moveIndex < moves.count ? moves[moveIndex] : nil
    }

    /// Feeds a sample (uses the sample's own timestamp).
    @discardableResult
    public mutating func feed(_ sample: TrackSample) -> CalibrationPrompt {
        feed(sample, at: sample.t)
    }

    /// Feeds one analysed frame. `sample == nil` (or quality <= 0) means the star was not found in
    /// the frame taken at `time`.
    @discardableResult
    public mutating func feed(_ sample: TrackSample?, at time: Double) -> CalibrationPrompt {
        if prompt.isTerminal { return prompt }
        guard let s = sample, s.quality > 0, s.p.isFinite else {
            handleLost(at: time)
            return prompt
        }
        lostSince = nil
        let t = s.t

        if phase != .acquiring {
            let r = (s.p - config.opticalCenter).length
            if r > config.fieldRadius * (1 - config.edgeMarginFraction) {
                return fail(.nearEdge)
            }
        }

        switch phase {
        case .acquiring:
            let r = (s.p - config.opticalCenter).length
            if r <= config.maxStartOffsetFraction * config.fieldRadius {
                enter(.settling, at: t)
                prompt = .holdStill
                settleBuffer = [s]
            } else {
                prompt = .centerStar
            }

        case .settling:
            if t - phaseStart > config.settleTimeout { return fail(.notSettled) }
            let afterMove = !rawMoves.isEmpty || !moveBuffer.isEmpty
            if afterMove && t - phaseStart < config.settleGuard { break }
            settleBuffer.append(s)
            if let fit = evaluateSettle() {
                completeSettle(fit)
            }

        case .waitingForMotion:
            if t - phaseStart > config.motionStartTimeout { return fail(.noMotionDetected) }
            let d = (s.p - predictedPosition(at: t)).length
            if d > motionThreshold {
                exceedCount += 1
                moveBuffer.append(s)
                if exceedCount >= config.motionConfirmSamples {
                    enter(.moving, at: moveBuffer.first?.t ?? t)
                    progressTimes = []
                    progressMax = []
                    for m in moveBuffer { recordProgress(m) }
                }
            } else {
                exceedCount = 0
                moveBuffer.removeAll()
            }

        case .moving:
            if t - phaseStart > config.moveTimeout { return fail(.timeout) }
            moveBuffer.append(s)
            let d = recordProgress(s)
            progress = d / config.targetDisplacement
            if d >= config.targetDisplacement {
                enter(.stopping, at: t)
                prompt = .stop
            } else if t - phaseStart >= config.stallDuration,
                      progressGrowth(over: config.stallDuration, now: t) <= progressThreshold {
                return fail(.moveTooShort(displacement: d, target: config.targetDisplacement))
            }

        case .stopping:
            if t - phaseStart > config.settleTimeout { return fail(.notSettled) }
            moveBuffer.append(s)
            let d = recordProgress(s)
            progress = d / config.targetDisplacement
            if t - phaseStart >= config.stopDetectDuration,
               progressGrowth(over: config.stopDetectDuration, now: t) <= progressThreshold {
                enter(.settling, at: t)
                prompt = .releaseAndWait
                settleBuffer = []
            }

        case .finished, .failed:
            break
        }
        return prompt
    }

    // MARK: Phases

    private mutating func enter(_ p: Phase, at t: Double) {
        phase = p
        phaseStart = t
    }

    @discardableResult
    private mutating func fail(_ f: CalibrationFailure) -> CalibrationPrompt {
        failure = f
        phase = .failed
        prompt = .failed(f)
        return prompt
    }

    private mutating func handleLost(at time: Double) {
        if lostSince == nil { lostSince = time }
        guard let since = lostSince, time - since > config.lostTimeout else { return }
        switch phase {
        case .acquiring:
            prompt = .centerStar
        case .settling where rawMoves.isEmpty && moveBuffer.isEmpty && driftWindows.isEmpty:
            // Lost before anything was measured: just start over.
            phase = .acquiring
            prompt = .centerStar
            settleBuffer = []
        case .finished, .failed:
            break
        default:
            fail(.starLost)
        }
    }

    private var motionThreshold: Double {
        max(config.motionThresholdMinimum, config.motionThresholdSigmas * noiseSigma)
    }

    private var progressThreshold: Double {
        max(config.motionThresholdMinimum, 3 * noiseSigma)
    }

    private func predictedPosition(at t: Double) -> Vec2 {
        baseline + driftVelocity * (t - baselineTime)
    }

    /// Records the drift-corrected displacement from the baseline; returns it.
    @discardableResult
    private mutating func recordProgress(_ s: TrackSample) -> Double {
        let d = (s.p - predictedPosition(at: s.t)).length
        let running = max(progressMax.last ?? 0, d)
        progressTimes.append(s.t)
        progressMax.append(running)
        return d
    }

    /// Increase of the running maximum displacement during the last `window` seconds.
    private func progressGrowth(over window: Double, now: Double) -> Double {
        guard let current = progressMax.last else { return 0 }
        let cutoff = now - window
        var before = 0.0
        for i in stride(from: progressTimes.count - 1, through: 0, by: -1) where progressTimes[i] <= cutoff {
            before = progressMax[i]
            break
        }
        return current - before
    }

    // MARK: Settling

    /// Returns a motion fit when the settle window is still and precise enough.
    private mutating func evaluateSettle() -> LinearMotionFit? {
        guard let last = settleBuffer.last else { return nil }
        while let first = settleBuffer.first, last.t - first.t > config.maxSettleDuration + 1e-9 {
            settleBuffer.removeFirst()
        }
        guard let first = settleBuffer.first, settleBuffer.count >= 5 else { return nil }
        let duration = last.t - first.t
        guard duration >= config.minSettleDuration - 1e-9 else { return nil }
        guard let fit = LinearMotionFit.fit(times: settleBuffer.map(\.t), points: settleBuffer.map(\.p)) else {
            return nil
        }
        let se = fit.velocityStandardError ?? .infinity
        let limit = config.maxDriftSpeed + 2 * se * 2.0.squareRoot()
        if fit.velocity.length > limit || !halvesConsistent(duration: duration, first: first.t) {
            // Not still yet: keep only the newer half and try again with later samples.
            let cut = first.t + duration / 2
            settleBuffer.removeAll { $0.t < cut }
            return nil
        }
        let window = Self.driftWindow(settleBuffer, sigma: fit.noiseSigma)
        let pooled = driftWindows.reduce(0) { $0 + $1.sxx } + window.sxx
        let pooledSe = pooled > 0 ? fit.noiseSigma / pooled.squareRoot() : .infinity
        let full = duration >= config.maxSettleDuration - 0.25
        return (pooledSe <= config.driftPrecision || full) ? fit : nil
    }

    private func halvesConsistent(duration: Double, first: Double) -> Bool {
        let mid = first + duration / 2
        let a = settleBuffer.filter { $0.t < mid }, b = settleBuffer.filter { $0.t >= mid }
        guard a.count >= 3, b.count >= 3,
              let fa = LinearMotionFit.fit(times: a.map(\.t), points: a.map(\.p)),
              let fb = LinearMotionFit.fit(times: b.map(\.t), points: b.map(\.p)),
              let sa = fa.velocityStandardError, let sb = fb.velocityStandardError
        else { return true }
        let tol = 3 * (sa * sa + sb * sb).squareRoot() * 2.0.squareRoot() + 1.0
        return (fa.velocity - fb.velocity).length <= tol
    }

    private static func driftWindow(_ samples: [TrackSample], sigma: Double) -> DriftWindow {
        let n = Double(samples.count)
        let tm = samples.reduce(0) { $0 + $1.t } / n
        var pm = Vec2.zero
        for s in samples { pm += s.p }
        pm = pm / n
        var sxx = 0.0
        var sxp = Vec2.zero
        for s in samples {
            let dt = s.t - tm
            sxx += dt * dt
            sxp += (s.p - pm) * dt
        }
        return DriftWindow(sxx: sxx, sxp: sxp, noiseVariance: sigma * sigma, count: samples.count)
    }

    private mutating func completeSettle(_ fit: LinearMotionFit) {
        driftWindows.append(Self.driftWindow(settleBuffer, sigma: fit.noiseSigma))
        updatePooledDrift()
        let endTime = settleBuffer.last?.t ?? fit.tRef
        baseline = fit.position(at: endTime)
        baselineTime = endTime

        if !moveBuffer.isEmpty {
            // This settle ends the current move.
            let settleStart = settleBuffer.first?.t ?? endTime
            rawMoves.append(moveBuffer.filter { $0.t < settleStart })
            moveBuffer = []
            moveIndex += 1
        }
        settleBuffer = []
        exceedCount = 0
        progress = 0
        if moveIndex < moves.count {
            enter(.waitingForMotion, at: endTime)
            prompt = .pressAndHold(moves[moveIndex])
        } else {
            finish(at: endTime)
        }
    }

    private mutating func updatePooledDrift() {
        let sxx = driftWindows.reduce(0) { $0 + $1.sxx }
        var sxp = Vec2.zero
        for w in driftWindows { sxp += w.sxp }
        driftVelocity = sxx > 0 ? sxp / sxx : .zero
        let n = driftWindows.reduce(0) { $0 + $1.count }
        let v = driftWindows.reduce(0) { $0 + $1.noiseVariance * Double($1.count) }
        noiseSigma = n > 0 ? (v / Double(n)).squareRoot() : 0
    }

    // MARK: Solving

    /// Measures one move with the final pooled drift.
    static func measure(_ samples: [TrackSample], direction: StickDirection, drift: Vec2) -> MoveMeasurement? {
        guard let t0 = samples.first?.t, let tEnd = samples.last?.t else { return nil }
        let q = samples.map { $0.p - drift * ($0.t - t0) }
        guard let raw = LineFit.fit(q), let qFirst = q.first, let qLast = q.last else { return nil }
        let line = raw.oriented(along: qLast - qFirst)
        let u = line.direction
        let along = q.map { ($0 - line.centroid).dot(u) }
        let lo = line.extent.lowerBound, len = line.length
        // Rate from the constant-velocity middle part (excludes acceleration and braking).
        var ts = [Double](), ss = [Double]()
        for (i, a) in along.enumerated() where a >= lo + 0.15 * len && a <= lo + 0.85 * len {
            ts.append(samples[i].t)
            ss.append(a)
        }
        let rate: Double
        if ts.count >= 4, let f = LinearFit1D.fit(xs: ts, ys: ss), f.slope > 0 {
            rate = f.slope
        } else {
            rate = len / max(tEnd - t0, 1e-6)
        }
        return MoveMeasurement(direction: direction, velocity: u * rate, lineResidual: line.rmsResidual,
                               displacement: len, duration: tEnd - t0, sampleCount: samples.count)
    }

    private mutating func finish(at time: Double) {
        var ms = [MoveMeasurement]()
        for (i, raw) in rawMoves.enumerated() {
            guard raw.count >= config.minMoveSamples,
                  let m = Self.measure(raw, direction: moves[i], drift: driftVelocity) else {
                fail(.moveTooShort(displacement: 0, target: config.targetDisplacement))
                return
            }
            ms.append(m)
        }
        measurements = ms

        let solution: CalibrationSolution?
        let isQuick: Bool
        switch mode {
        case .full:
            let right = ms.first(where: { $0.direction == .right })
            let up = ms.first(where: { $0.direction == .up })
            guard let r = right, let u = up else { fail(.degenerate); return }
            solution = CalibrationSolver.solve(mRight: r.velocity, mUp: u.velocity)
            isQuick = false
        case .quick(let previous):
            guard let u = ms.first(where: { $0.direction == .up }) else { fail(.degenerate); return }
            solution = CalibrationSolver.quickRecalibration(mUp: u.velocity, previous: previous.stickToImage)
            isQuick = true
        }
        guard let sol = solution else { fail(.degenerate); return }
        if !isQuick && sol.orthogonalityError > config.orthogonalityFailure {
            fail(.orthogonalityBad(degrees: AngleMath.degrees(sol.orthogonalityError)))
            return
        }
        let residual = ms.map(\.lineResidual).max() ?? 0
        let residualLimit = max(config.lineResidualWarning, 2.5 * noiseSigma)
        let quality: CalibrationQuality =
            (sol.orthogonalityError > config.orthogonalityWarning || residual > residualLimit) ? .warning : .good
        var previousRepeatability: Double?
        if case .quick(let previous) = mode { previousRepeatability = previous.repeatability }
        let res = CalibrationResult(stickToImage: sol.stickToImage, displayRotation: sol.displayRotation,
                                    mirrored: sol.mirrored, orthogonalityError: sol.orthogonalityError,
                                    lineResidual: residual, repeatability: previousRepeatability,
                                    opticalCenter: config.opticalCenter, fieldRadius: config.fieldRadius,
                                    driftVelocity: driftVelocity, quality: quality, isQuick: isQuick)
        result = res
        phase = .finished
        prompt = .done(res)
    }
}
