import Foundation
import QuartzCore
import TeleskooppiCore

/// Fans frames out to recording and star detection (plan 3.4) without ever blocking the
/// camera queue: `submit` only takes a lock and, when work is due, hands the frame to a serial
/// analysis queue. A frame arriving while that queue is busy is skipped.
final class FramePipeline: @unchecked Sendable {
    static let searchInterval = 1.0 / 5
    static let trackInterval = 1.0 / 15

    private enum Command {
        case select(Vec2)
        case clear
    }

    let recorder = SessionRecorder()

    private let queue = DispatchQueue(label: "fi.teleskooppi.analysis", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var detectLimiter = MinIntervalLimiter(minInterval: FramePipeline.searchInterval)
    private var recordLimiter = MinIntervalLimiter(minInterval: 0.1)
    private var detectionEnabled = false
    private var lensPosition: Float = 0
    private var pending: Command?
    private var resultHandler: (@Sendable (StarAnalysisResult) -> Void)?
    private var analyzer = StarAnalyzer()  // touched on the analysis queue only

    func setResultHandler(_ handler: (@Sendable (StarAnalysisResult) -> Void)?) {
        lock.withLock { resultHandler = handler }
    }

    func setLensPosition(_ value: Float) {
        lock.withLock { lensPosition = value }
    }

    func setDetectionEnabled(_ enabled: Bool) {
        lock.withLock {
            detectionEnabled = enabled
            if !enabled { pending = .clear }
        }
    }

    /// `point` in binned coordinates; `nil` clears the selection.
    func selectStar(near point: Vec2?) {
        lock.withLock { pending = point.map { Command.select($0) } ?? Command.clear }
        if let point {
            recorder.addEvent(SessionEvent(
                t: CACurrentMediaTime(), type: SessionEvent.starSelect, values: ["x": point.x, "y": point.y]
            ))
        }
    }

    func startRecording(parent: URL, rate: Double, notes: String, device: DeviceInfo) {
        lock.withLock { recordLimiter = MinIntervalLimiter(minInterval: 1 / max(rate, 0.1)) }
        recorder.start(parent: parent, rate: rate, notes: notes, device: device)
    }

    @discardableResult
    func stopRecording(notes: String) -> URL? {
        recorder.stop(notes: notes)
    }

    func submit(_ frame: Frame) {
        let now = CACurrentMediaTime()
        let isRecording = recorder.isRecording
        let plan: (record: Bool, detect: Bool)? = lock.withLock {
            let wantsRecord = isRecording && recordLimiter.allow(now)
            if busy {
                if wantsRecord { recorder.noteDropped() }
                return nil
            }
            let wantsDetect = detectionEnabled && detectLimiter.allow(now)
            guard wantsRecord || wantsDetect else { return nil }
            busy = true
            return (wantsRecord, wantsDetect)
        }
        guard let plan else { return }
        queue.async { [self] in
            process(frame, record: plan.record, detect: plan.detect)
        }
    }

    private func process(_ frame: Frame, record: Bool, detect: Bool) {
        let started = ProcessInfo.processInfo.systemUptime
        var locked = false
        var result: StarAnalysisResult?
        if let binned = LumaBinning.binned(frame.pixelBuffer) {
            let binMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            if record {
                let lens = lock.withLock { lensPosition }
                recorder.offer(binned, meta: FrameMeta(
                    timestamp: frame.timestamp, exposure: frame.exposureSeconds ?? 0,
                    iso: frame.iso ?? 0, lensPosition: lens
                ))
            }
            if detect {
                let command = lock.withLock { () -> Command? in
                    let c = pending
                    pending = nil
                    return c
                }
                switch command {
                case .select(let point)?: analyzer.select(near: point)
                case .clear?: analyzer.select(near: nil)
                case nil: break
                }
                let geometry = BinningGeometry(factor: max(1, frame.width / binned.width))
                result = analyzer.process(
                    binned, time: frame.timestamp, geometry: geometry, binMilliseconds: binMilliseconds
                )
                locked = analyzer.isLocked
            }
        }
        let handler: (@Sendable (StarAnalysisResult) -> Void)? = lock.withLock {
            busy = false
            detectLimiter.minInterval = locked ? Self.trackInterval : Self.searchInterval
            return resultHandler
        }
        if let result { handler?(result) }
    }
}
