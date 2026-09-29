import Foundation

extension CalibrationPrompt {
    /// Short machine-friendly description (logs, `events.jsonl`, CLI output).
    public var summary: String {
        switch self {
        case .centerStar: return "centerStar"
        case .holdStill: return "holdStill"
        case .pressAndHold(let d): return "pressAndHold(\(d.rawValue))"
        case .stop: return "STOP"
        case .releaseAndWait: return "releaseAndWait"
        case .done: return "done"
        case .failed(let f): return "failed(\(f))"
        }
    }
}

public struct ReplayOptions: Sendable {
    /// Frame indices to process (default: all).
    public var frameRange: ClosedRange<Int>?
    /// Use the whole-frame `ShiftEstimator` instead of star detection + tracking (daytime recordings).
    public var useShiftEstimator = false
    /// Overrides for the optical center / field radius; otherwise `meta.profile`, otherwise the frame
    /// center and a field of 0.53 x the frame height (380 px for 720).
    public var opticalCenter: Vec2?
    public var fieldRadius: Double?
    /// Star to lock on (image pixels). Overrides `star.select` events.
    public var lockPoint: Vec2?
    /// Ignore `calibration.start` / `calibration.end` markers in `events.jsonl`.
    public var ignoreMarkers = false
    public var detector = StarDetectorConfig()
    public var tracker = StarTrackerConfig()
    public var shift = ShiftEstimatorConfig()
    /// Half size of the initial star search square around the optical center, as a fraction of the field radius.
    public var acquisitionFraction = 0.6

    public init() {}
}

public struct ReplayFrameRecord: Sendable {
    public var index: Int
    public var time: Double
    public var detectionCount: Int
    public var sample: TrackSample?
    /// Prompt after feeding the frame to the `CalibrationSession` (nil outside the calibration window).
    public var prompt: CalibrationPrompt?
    /// Wall time spent in detection / tracking / shift estimation for this frame.
    public var analysisMilliseconds: Double
}

public struct ReplayReport: Sendable {
    public var framesProcessed = 0
    /// Frames that produced a `TrackSample`.
    public var framesWithSample = 0
    public var totalDetections = 0
    public var calibrationStart: Double?
    public var calibrationEnd: Double?
    public var promptLog: [(time: Double, prompt: CalibrationPrompt)] = []
    public var result: CalibrationResult?
    public var failure: CalibrationFailure?
    public var samples: [TrackSample] = []
    public var totalAnalysisMilliseconds = 0.0
    public var maxAnalysisMilliseconds = 0.0
    public var opticalCenter = Vec2.zero
    public var fieldRadius = 0.0

    public var averageAnalysisMilliseconds: Double {
        framesProcessed > 0 ? totalAnalysisMilliseconds / Double(framesProcessed) : 0
    }

    /// Fraction of processed frames with a sample.
    public var sampleRate: Double {
        framesProcessed > 0 ? Double(framesWithSample) / Double(framesProcessed) : 0
    }
}

/// Runs the analysis pipeline (detector + tracker or shift estimator, then `CalibrationSession`) over a
/// recorded session, exactly as the live app would (plan 3, phase 3 and 4).
public enum SessionReplay {
    static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
    }

    public static func run(_ reader: SessionReader, options: ReplayOptions = ReplayOptions(),
                           onFrame: ((ReplayFrameRecord) -> Void)? = nil) throws -> ReplayReport {
        var report = ReplayReport()
        guard reader.frameCount > 0 else { return report }
        let first = reader.index[0]
        let profile = reader.meta.profile
        let center = options.opticalCenter ?? profile?.opticalCenter
            ?? Vec2(Double(first.width) / 2, Double(first.height) / 2)
        let radius = options.fieldRadius ?? profile?.fieldRadius ?? 0.5277 * Double(first.height)
        report.opticalCenter = center
        report.fieldRadius = radius

        let events = try reader.events().sorted { $0.t < $1.t }
        if !options.ignoreMarkers {
            report.calibrationStart = events.first { $0.type == SessionEvent.calibrationStart }?.t
            if let s = report.calibrationStart {
                report.calibrationEnd = events.first { $0.type == SessionEvent.calibrationEnd && $0.t >= s }?.t
            }
        }
        let selects = events.filter { $0.type == SessionEvent.starSelect && $0.values?["x"] != nil && $0.values?["y"] != nil }
        var nextSelect = 0

        var trackerConfig = options.tracker
        if trackerConfig.acquisitionRegion == nil {
            trackerConfig.acquisitionRegion = PixelRect.around(center, halfSize: options.acquisitionFraction * radius)
        }
        if trackerConfig.fieldMask == nil {
            trackerConfig.fieldMask = CircleMask(center: center, radius: radius * 0.98)
        }
        var tracker = StarTracker(config: trackerConfig, detector: StarDetector(config: options.detector))
        var shifter = ShiftEstimator(config: options.shift, origin: center)
        var session = CalibrationSession(config: CalibrationConfig(opticalCenter: center, fieldRadius: radius))
        var lockPointApplied = false

        let range = options.frameRange ?? 0...(reader.frameCount - 1)
        let clock = ContinuousClock()
        for i in max(range.lowerBound, 0)...min(range.upperBound, reader.frameCount - 1) {
            let frame = try reader.frame(at: i)
            let t = frame.meta.timestamp

            // Star selection markers / explicit lock point (re-lock at the moment of the event).
            if !options.useShiftEstimator {
                if let p = options.lockPoint, !lockPointApplied {
                    tracker.lock(near: p)
                    lockPointApplied = true
                }
                while nextSelect < selects.count, selects[nextSelect].t <= t {
                    if options.lockPoint == nil, let v = selects[nextSelect].values,
                       let x = v["x"], let y = v["y"] {
                        tracker.lock(near: Vec2(x, y))
                    }
                    nextSelect += 1
                }
            }

            var sample: TrackSample?
            var detections = 0
            let elapsed = clock.measure {
                if options.useShiftEstimator {
                    sample = shifter.update(frame.image, time: t)
                } else {
                    sample = tracker.update(frame.image, time: t)
                    detections = tracker.lastDetections.count
                }
            }
            let ms = milliseconds(elapsed)
            report.framesProcessed += 1
            report.totalDetections += detections
            report.totalAnalysisMilliseconds += ms
            report.maxAnalysisMilliseconds = max(report.maxAnalysisMilliseconds, ms)
            if let s = sample {
                report.framesWithSample += 1
                report.samples.append(s)
            }

            var prompt: CalibrationPrompt?
            let inWindow = (report.calibrationStart.map { t >= $0 } ?? true)
                && (report.calibrationEnd.map { t <= $0 } ?? true)
            if inWindow && !session.prompt.isTerminal {
                let p = session.feed(sample, at: t)
                prompt = p
                if report.promptLog.last?.prompt != p { report.promptLog.append((t, p)) }
            }
            onFrame?(ReplayFrameRecord(index: i, time: t, detectionCount: detections, sample: sample,
                                       prompt: prompt, analysisMilliseconds: ms))
        }
        report.result = session.result
        report.failure = session.failure
        return report
    }
}
