import CoreVideo
import Foundation
import QuartzCore
import TeleskooppiCore

/// Converts core gray images into the renderer's pixel format.
enum SyntheticFrames {
    /// Creates a Metal-compatible bi-planar `420f` buffer with `image` in the luma plane and
    /// neutral chroma. Returns `nil` if the buffer cannot be allocated.
    static func makePixelBuffer(from image: GrayImage8) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let rows = min(image.height, CVPixelBufferGetHeightOfPlane(buffer, 0))
            let columns = min(image.width, CVPixelBufferGetWidthOfPlane(buffer, 0))
            image.pixels.withUnsafeBufferPointer { source in
                for y in 0..<rows {
                    let destination = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    let row = source.baseAddress!.advanced(by: y * image.stride)
                    destination.update(from: row, count: columns)
                }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
            for y in 0..<rows {
                memset(base.advanced(by: y * stride), 128, stride)
            }
        }
        return buffer
    }
}

/// Renders `SyntheticSky` frames from the core at about 15 fps, driven by a `SimulatedMount`
/// that the dev menu's virtual stick moves (plan phase 2).
final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    let kind = FrameSourceKind.synthetic

    /// Ground truth of the simulated optics: the rotation the display needs so that stick up
    /// moves stars down on screen. Nonzero on purpose, so the manual rotation slider is needed.
    static let groundTruthRotationDegrees = 35.0

    private let targetFps: Double
    private let lock = NSLock()
    private var handler: (@Sendable (Frame) -> Void)?
    private var stick = Vec2.zero
    private var task: Task<Void, Never>?
    private var lastRenderMilliseconds = 0.0

    init(targetFps: Double = 15) {
        self.targetFps = targetFps
    }

    func setFrameHandler(_ handler: (@Sendable (Frame) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Stick deflection, x right and y up, each in [-1, 1].
    func setStick(_ value: Vec2) {
        lock.withLock { stick = value }
    }

    /// Time the last frame took to render on the CPU (milliseconds), for the dev overlay.
    var renderMilliseconds: Double {
        lock.withLock { lastRenderMilliseconds }
    }

    func start() async throws {
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let old = task
            task = nil
            return old
        }
        previous?.cancel()
        let newTask = Task.detached(priority: .userInitiated) { [self] in
            await run()
        }
        lock.withLock { task = newTask }
    }

    func stop() async {
        let old = lock.withLock { () -> Task<Void, Never>? in
            let old = task
            task = nil
            return old
        }
        old?.cancel()
        await old?.value
    }

    private func currentInputs() -> (stick: Vec2, handler: (@Sendable (Frame) -> Void)?) {
        lock.withLock { (stick, handler) }
    }

    private func run() async {
        var rng = SplitMix64(seed: 2026)
        // A reduced-size field keeps the CPU renderer fast enough for 15 fps.
        let optics = SimulatedOptics(
            imageWidth: 480, imageHeight: 360, fieldRadius: 190, plateScale: 17.64,
            displayRotation: AngleMath.radians(Self.groundTruthRotationDegrees), mirrored: false
        )
        let field = StarField.random(
            count: 3500, radiusArcsec: 20000, brightest: 4.5, faintest: 11, rng: &rng
        )
        let configuration = SyntheticSky.Configuration(
            psf: .moffat(fwhm: 2.4, beta: 3), background: 30, readNoise: 3, gain: 0.5, poissonNoise: false
        )
        let sky = SyntheticSky(optics: optics, field: field, configuration: configuration)
        var mount = SimulatedMount(configuration: SimulatedMount.Configuration(
            speedMultiplier: 64, stickResponse: .analog
        ))

        let interval = 1 / targetFps
        let start = CACurrentMediaTime()
        var next = start
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            let inputs = currentInputs()
            mount.setStick(inputs.stick)
            mount.advance(to: now - start)

            let image = sky.render(boresight: mount.boresight, rng: &rng)
            let rendered = CACurrentMediaTime()
            lock.withLock { lastRenderMilliseconds = (rendered - now) * 1000 }

            if let handler = inputs.handler, let buffer = SyntheticFrames.makePixelBuffer(from: image) {
                handler(Frame(pixelBuffer: buffer, timestamp: now, exposureSeconds: interval, iso: 100))
            }

            next += interval
            let wait = next - CACurrentMediaTime()
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            } else {
                // Behind schedule: do not try to catch up.
                next = CACurrentMediaTime()
            }
        }
    }
}
