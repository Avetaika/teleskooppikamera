import Foundation
import QuartzCore
import TeleskooppiCore

enum RecordingRate: Double, CaseIterable, Identifiable, Sendable {
    case fps1 = 1
    case fps2 = 2
    case fps5 = 5
    case fps10 = 10
    case fps15 = 15

    var id: Double { rawValue }
    var title: String { "\(Int(rawValue)) fps" }
}

struct RecordingStatus: Equatable, Sendable {
    var isRecording = false
    var elapsed = 0.0
    var bytes: Int64 = 0
    var frames = 0
    var dropped = 0
    var name: String?
    var error: String?
}

enum RecordingFormat {
    static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func size(_ bytes: Int64) -> String {
        String(format: "%.1f Mt", Double(bytes) / 1_048_576)
    }
}

/// Writes 2x-binned luma frames to a session (D-11) with the core `SessionWriter`.
///
/// `offer` never blocks: file writes run on a private serial queue and a frame is dropped when
/// more than `maxPending` writes are already queued.
final class SessionRecorder: @unchecked Sendable {
    static let maxPending = 4

    private final class Active: @unchecked Sendable {
        let parent: URL
        let rate: Double
        let notes: String
        let device: DeviceInfo
        let startedAt: Double
        var writer: SessionWriter?  // touched on the write queue only
        var pending = 0
        var frames = 0
        var dropped = 0
        var bytes: Int64 = 0
        var name: String?
        var error: String?

        init(parent: URL, rate: Double, notes: String, device: DeviceInfo, startedAt: Double) {
            self.parent = parent
            self.rate = rate
            self.notes = notes
            self.device = device
            self.startedAt = startedAt
        }
    }

    private let queue = DispatchQueue(label: "fi.teleskooppi.recorder", qos: .utility)
    private let lock = NSLock()
    private var active: Active?

    var isRecording: Bool { lock.withLock { active != nil } }

    func start(parent: URL, rate: Double, notes: String, device: DeviceInfo, now: Double = CACurrentMediaTime()) {
        lock.withLock {
            guard active == nil else { return }
            active = Active(parent: parent, rate: rate, notes: notes, device: device, startedAt: now)
        }
    }

    func offer(_ image: GrayImage8, meta: FrameMeta) {
        let session: Active? = lock.withLock {
            guard let a = active else { return nil }
            if a.pending >= Self.maxPending {
                a.dropped += 1
                return nil
            }
            a.pending += 1
            return a
        }
        guard let session else { return }
        queue.async { [self] in
            do {
                if session.writer == nil {
                    let format = FrameFormat(width: image.width, height: image.height, binning: 2, frameRate: session.rate)
                    let sessionMeta = SessionMeta(device: session.device, format: format, notes: session.notes)
                    let writer = try SessionWriter.create(in: session.parent, meta: sessionMeta)
                    session.writer = writer
                    lock.withLock { session.name = writer.directory.lastPathComponent }
                }
                try session.writer?.append(image, meta: meta)
                let size = Int64(SessionFormat.headerSize + image.stride * image.height)
                lock.withLock {
                    session.pending -= 1
                    session.frames += 1
                    session.bytes += size
                }
            } catch {
                lock.withLock {
                    session.pending -= 1
                    session.error = "\(error)"
                }
            }
        }
    }

    /// Counts a frame the pipeline could not offer because it was busy.
    func noteDropped() {
        lock.withLock { active?.dropped += 1 }
    }

    func addEvent(_ event: SessionEvent) {
        guard let session = lock.withLock({ active }) else { return }
        queue.async { try? session.writer?.appendEvent(event) }
    }

    /// Finishes the session (waits for queued writes) and returns its directory.
    @discardableResult
    func stop(notes: String) -> URL? {
        let finished: Active? = lock.withLock {
            let a = active
            active = nil
            return a
        }
        guard let session = finished else { return nil }
        var url: URL?
        queue.sync {
            guard let writer = session.writer else { return }
            try? writer.updateMeta { $0.notes = notes }
            try? writer.finish()
            url = writer.directory
        }
        return url
    }

    func status(now: Double) -> RecordingStatus {
        lock.withLock {
            guard let a = active else { return RecordingStatus() }
            return RecordingStatus(
                isRecording: true, elapsed: now - a.startedAt, bytes: a.bytes, frames: a.frames,
                dropped: a.dropped, name: a.name, error: a.error
            )
        }
    }
}
