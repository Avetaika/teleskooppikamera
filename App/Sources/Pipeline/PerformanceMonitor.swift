import Foundation

/// Sliding-window event rate (frames per second) over the last `window` seconds.
struct RateCounter: Sendable {
    let window: Double
    private var times: [Double] = []

    init(window: Double = 2) {
        self.window = window
    }

    mutating func record(_ time: Double) {
        times.append(time)
        trim(now: time)
    }

    private mutating func trim(now: Double) {
        let cutoff = now - window
        if let firstKept = times.firstIndex(where: { $0 >= cutoff }) {
            if firstKept > 0 { times.removeFirst(firstKept) }
        } else {
            times.removeAll()
        }
    }

    /// Events per second over the window ending at `now`.
    mutating func rate(now: Double) -> Double {
        trim(now: now)
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else {
            return 0
        }
        return Double(times.count - 1) / (last - first)
    }
}

/// Exponential moving average with running maximum, for latency estimates.
struct LatencyTracker: Sendable {
    private(set) var last: Double = 0
    private(set) var average: Double = 0
    private(set) var maximum: Double = 0
    private var count = 0
    let smoothing: Double

    init(smoothing: Double = 0.1) {
        self.smoothing = smoothing
    }

    mutating func record(_ value: Double) {
        last = value
        average = count == 0 ? value : average + smoothing * (value - average)
        maximum = max(maximum, value)
        count += 1
    }

    mutating func resetMaximum() {
        maximum = 0
    }
}

struct PerformanceSnapshot: Sendable, Equatable {
    var captureFps: Double = 0
    var renderFps: Double = 0
    /// Estimated frame-to-GPU-completion latency in milliseconds (frame PTS → render completed).
    /// The panel scan-out adds roughly one display refresh on top of this.
    var latencyMs: Double = 0
    var maxLatencyMs: Double = 0
    var totalFrames: Int = 0
    var droppedFrames: Int = 0
}

/// Thread-safe counters filled by the frame pipeline and read once a second by the UI.
final class PerformanceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var capture = RateCounter()
    private var render = RateCounter()
    private var latency = LatencyTracker()
    private var totalFrames = 0
    private var dropped = 0

    func frameArrived(at now: Double) {
        lock.withLock {
            capture.record(now)
            totalFrames += 1
        }
    }

    func frameDropped() {
        lock.withLock { dropped += 1 }
    }

    /// Called when the GPU finished rendering a *new* frame.
    func framePresented(framePTS: Double, now: Double) {
        lock.withLock {
            render.record(now)
            let ms = (now - framePTS) * 1000
            if ms.isFinite, ms >= 0 { latency.record(ms) }
        }
    }

    func resetMaximum() {
        lock.withLock { latency.resetMaximum() }
    }

    func snapshot(now: Double) -> PerformanceSnapshot {
        lock.withLock {
            PerformanceSnapshot(
                captureFps: capture.rate(now: now),
                renderFps: render.rate(now: now),
                latencyMs: latency.average,
                maxLatencyMs: latency.maximum,
                totalFrames: totalFrames,
                droppedFrames: dropped
            )
        }
    }
}
