import Foundation

public struct StarTrackerConfig: Sendable, Codable, Equatable {
    /// Prediction gate = `gateFactor * motion per frame + gateMinimum` pixels (plan 4.3).
    public var gateFactor = 3.0
    public var gateMinimum = 10.0
    /// Upper limit of the gate radius (pixels).
    public var gateMaximum = 250.0
    /// Extra margin around the gate in the detection ROI so that centroid apertures are not cut.
    public var searchPadding = 14.0
    /// The lock is dropped after this long without an accepted detection (seconds).
    public var lostTimeout = 2.0
    /// When locking on a requested point, the star must be within this distance (pixels).
    public var lockRadius = 30.0
    /// A candidate whose flux differs from the tracked star's by more than this factor is not accepted.
    public var fluxRatioLimit = 3.0
    /// Exponential smoothing of the velocity estimate (0...1, higher = faster).
    public var velocitySmoothing = 0.3
    /// Where to look for the initial star (nil = whole image).
    public var acquisitionRegion: PixelRect?
    /// Field stop; pixels outside are ignored.
    public var fieldMask: CircleMask?

    public init() {}
}

/// Locks on one star (the requested one or the brightest) and follows it with a prediction gate.
/// It never jumps to another star: candidates must lie inside the gate and have a similar flux.
/// After `lostTimeout` seconds without a detection the tracker reports `.lost` and stays lost until
/// `lock(near:)` or `reset()` is called (plan 4.3, 4.9).
///
/// Only a small region of interest around the predicted position is analysed while locked, which keeps
/// the per-frame cost tiny. Use `searchRegion(at:)` to see (or render) exactly the region the next
/// `update` will use.
public struct StarTracker: Sendable {
    public enum State: String, Sendable, Codable {
        case searching, locked, lost
    }

    public var config: StarTrackerConfig
    public var detector: StarDetector
    public private(set) var state: State = .searching
    /// Last accepted position.
    public private(set) var position: Vec2?
    /// Smoothed image velocity (px/s).
    public private(set) var velocity: Vec2 = .zero
    public private(set) var lastDetection: StarDetection?
    /// All detections of the last analysed frame (for overlays).
    public private(set) var lastDetections: [StarDetection] = []
    public private(set) var lastSeenTime = 0.0
    public private(set) var missCount = 0
    /// Distance moved between the last two accepted detections (px).
    public private(set) var lastStep = 0.0
    private var referenceFlux = 0.0
    private var lockPoint: Vec2?

    public init(config: StarTrackerConfig = StarTrackerConfig(), detector: StarDetector = StarDetector()) {
        self.config = config
        self.detector = detector
    }

    /// Starts (re)acquisition. With `point`, the star nearest to it (within `lockRadius`) is chosen,
    /// otherwise the brightest star in the acquisition region.
    public mutating func lock(near point: Vec2? = nil) {
        state = .searching
        lockPoint = point
        position = nil
        velocity = .zero
        lastDetection = nil
        lastStep = 0
        missCount = 0
    }

    public mutating func reset() {
        lock(near: nil)
        lastDetections = []
    }

    /// Predicted star position at `time`.
    public func predictedPosition(at time: Double) -> Vec2? {
        guard let p = position else { return nil }
        return p + velocity * max(0, time - lastSeenTime)
    }

    /// Current prediction gate radius (pixels) at `time`.
    public func gate(at time: Double) -> Double {
        let dt = max(0, time - lastSeenTime)
        let motion = max(velocity.length * dt, lastStep)
        return min(config.gateFactor * motion + config.gateMinimum, config.gateMaximum)
    }

    /// The pixel region the next `update(_:time:)` analyses (not clipped to the image). Empty when lost.
    public func searchRegion(at time: Double) -> PixelRect {
        switch state {
        case .lost:
            return PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)
        case .searching:
            return config.acquisitionRegion ?? PixelRect(x0: 0, y0: 0, x1: Int.max / 4, y1: Int.max / 4)
        case .locked:
            guard let p = predictedPosition(at: time) else { return PixelRect(x0: 0, y0: 0, x1: 0, y1: 0) }
            return PixelRect.around(p, halfSize: gate(at: time) + config.searchPadding)
        }
    }

    /// Analyses one frame. Returns the star position as a `TrackSample`, or nil when the star was not found.
    public mutating func update(_ image: GrayImage8, time: Double) -> TrackSample? {
        switch state {
        case .lost:
            lastDetections = []
            return nil

        case .searching:
            let region = searchRegion(at: time).clipped(width: image.width, height: image.height)
            let detections = detector.detect(image, roi: region, mask: config.fieldMask)
            lastDetections = detections
            let chosen: StarDetection?
            if let target = lockPoint {
                chosen = detections
                    .filter { ($0.position - target).length <= config.lockRadius }
                    .min { ($0.position - target).length < ($1.position - target).length }
            } else {
                chosen = detections.first  // sorted by flux, brightest first
            }
            guard let star = chosen else { return nil }
            state = .locked
            position = star.position
            velocity = .zero
            lastStep = 0
            lastSeenTime = time
            missCount = 0
            referenceFlux = star.flux
            lastDetection = star
            return sample(for: star, time: time)

        case .locked:
            guard let predicted = predictedPosition(at: time) else {
                state = .searching
                return nil
            }
            let gate = self.gate(at: time)
            let region = PixelRect.around(predicted, halfSize: gate + config.searchPadding)
                .clipped(width: image.width, height: image.height)
            let detections = detector.detect(image, roi: region, mask: config.fieldMask)
            lastDetections = detections
            let limit = max(config.fluxRatioLimit, 1)
            let candidates = detections.filter { d in
                let ratio = referenceFlux > 0 ? d.flux / referenceFlux : 1
                return (d.position - predicted).length <= gate && ratio <= limit && ratio >= 1 / limit
            }
            guard let star = candidates.min(by: {
                ($0.position - predicted).length < ($1.position - predicted).length
            }) else {
                missCount += 1
                if time - lastSeenTime > config.lostTimeout { state = .lost }
                return nil
            }
            let dt = time - lastSeenTime
            if let old = position, dt > 1e-6 {
                let measured = (star.position - old) / dt
                let a = min(max(config.velocitySmoothing, 0), 1)
                velocity = velocity * (1 - a) + measured * a
                lastStep = (star.position - old).length
            }
            position = star.position
            lastSeenTime = time
            missCount = 0
            referenceFlux = 0.9 * referenceFlux + 0.1 * star.flux
            lastDetection = star
            return sample(for: star, time: time)
        }
    }

    private func sample(for star: StarDetection, time: Double) -> TrackSample {
        TrackSample(t: time, p: star.position, quality: min(1, max(0.05, star.snr / 10)))
    }
}
