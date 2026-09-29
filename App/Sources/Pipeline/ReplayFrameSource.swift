import CoreVideo
import Foundation
import QuartzCore
import TeleskooppiCore

/// Plays a recorded `.tcs` session as the live source, looping, at the recorded frame timing.
final class ReplayFrameSource: FrameSource, @unchecked Sendable {
    let kind = FrameSourceKind.replay
    let url: URL

    private let lock = NSLock()
    private var handler: (@Sendable (Frame) -> Void)?
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func setFrameHandler(_ handler: (@Sendable (Frame) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func start() async throws {
        let reader = try SessionReader(directory: url)
        guard reader.frameCount > 0 else { throw SessionError.invalidImage }
        let old = lock.withLock { () -> Task<Void, Never>? in
            let previous = task
            task = nil
            return previous
        }
        old?.cancel()
        let newTask = Task.detached(priority: .userInitiated) { [self] in
            await run(reader)
        }
        lock.withLock { task = newTask }
    }

    func stop() async {
        let old = lock.withLock { () -> Task<Void, Never>? in
            let previous = task
            task = nil
            return previous
        }
        old?.cancel()
        await old?.value
    }

    private func currentHandler() -> (@Sendable (Frame) -> Void)? {
        lock.withLock { handler }
    }

    private func run(_ reader: SessionReader) async {
        let first = reader.index[0].meta.timestamp
        let span = max(reader.duration, 0) + 0.1
        let wallStart = CACurrentMediaTime()
        var loopOffset = 0.0
        while !Task.isCancelled {
            for i in 0..<reader.frameCount {
                if Task.isCancelled { return }
                let meta = reader.index[i].meta
                let due = wallStart + loopOffset + max(0, meta.timestamp - first)
                let wait = due - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let frame = try? reader.frame(at: i), let handler = currentHandler(),
                      let buffer = SyntheticFrames.makePixelBuffer(from: frame.image) else { continue }
                handler(Frame(
                    pixelBuffer: buffer, timestamp: due, exposureSeconds: meta.exposure > 0 ? meta.exposure : nil,
                    iso: meta.iso > 0 ? meta.iso : nil
                ))
            }
            loopOffset += span
        }
    }
}
