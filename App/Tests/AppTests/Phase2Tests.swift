import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
import TeleskooppiCore
@testable import Teleskooppikamera

// Phase 2 tests: nothing here touches the camera. Metal tests skip themselves when the CI
// machine has no GPU device.

private let testImageSize = CGSize(width: 1920, height: 1440)
private let testViewSize = CGSize(width: 393, height: 852)

private func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-2) -> Bool { abs(a - b) <= tolerance }
private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

private func makeParams(_ settings: DisplaySettings) -> (RenderParams, DisplayTransform) {
    let transform = settings.transform(imageSize: testImageSize, viewSize: testViewSize)
    let params = RenderMath.params(
        transform: transform, viewSize: testViewSize, blackPoint: settings.blackPoint,
        whitePoint: settings.whitePoint, gamma: settings.gamma, redMode: settings.redMode
    )
    return (params, transform)
}

private func screenPoint(_ params: RenderParams, image: Vec2) -> SIMD2<Float> {
    RenderMath.screenPosition(imagePoint: SIMD2(Float(image.x), Float(image.y)), matrix: params.matrix)
}

// MARK: - Transform -> Metal

struct RenderMathTests {
    @Test func matrixHasMetalLayout() {
        let (params, _) = makeParams(DisplaySettings())
        #expect(params.matrix.count == 12)
        #expect(params.matrix[3] == 0 && params.matrix[7] == 0 && params.matrix[11] == 0)
        #expect(params.matrix[2] == 0 && params.matrix[6] == 0)
        #expect(params.matrix[10] == 1)
    }

    @Test func opticalCenterLandsOnViewCenter() {
        let (params, _) = makeParams(DisplaySettings())
        let c = DisplaySettings.imageCenter(imageSize: testImageSize)
        let clip = RenderMath.clipPosition(
            imagePoint: SIMD2(Float(c.x), Float(c.y)), matrix: params.matrix, viewSize: params.viewSize
        )
        #expect(near(clip.x, 0) && near(clip.y, 0))
    }

    @Test func defaultScaleFitsShortSideToWidth() {
        let settings = DisplaySettings()
        let scale = settings.scale(imageSize: testImageSize, viewSize: testViewSize)
        #expect(near(scale, 393.0 / 1440.0))
        let doubled = DisplaySettings(zoom: 2).scale(imageSize: testImageSize, viewSize: testViewSize)
        #expect(near(doubled, 2 * 393.0 / 1440.0))
    }

    @Test func rotation90TurnsImageRightIntoScreenDown() {
        let settings = DisplaySettings(rotationDegrees: 90)
        let (params, transform) = makeParams(settings)
        let c = settings.resolvedOpticalCenter(imageSize: testImageSize)
        let q = screenPoint(params, image: c + Vec2(100, 0))
        let s = Float(transform.scale)
        #expect(near(q.x, 196.5) && near(q.y, 426 + 100 * s))
    }

    @Test func horizontalFlipMirrorsX() {
        let settings = DisplaySettings(flipHorizontal: true)
        let (params, transform) = makeParams(settings)
        let c = settings.resolvedOpticalCenter(imageSize: testImageSize)
        let s = Float(transform.scale)
        let right = screenPoint(params, image: c + Vec2(100, 0))
        let down = screenPoint(params, image: c + Vec2(0, 100))
        #expect(near(right.x, 196.5 - 100 * s) && near(right.y, 426))
        #expect(near(down.x, 196.5) && near(down.y, 426 + 100 * s))
    }

    @Test func verticalFlipMirrorsY() {
        let settings = DisplaySettings(flipVertical: true)
        let (params, transform) = makeParams(settings)
        let c = settings.resolvedOpticalCenter(imageSize: testImageSize)
        let s = Float(transform.scale)
        let right = screenPoint(params, image: c + Vec2(100, 0))
        let down = screenPoint(params, image: c + Vec2(0, 100))
        #expect(near(right.x, 196.5 + 100 * s) && near(right.y, 426))
        #expect(near(down.x, 196.5) && near(down.y, 426 - 100 * s))
    }

    @Test func clipSpaceHasYUp() {
        let (params, _) = makeParams(DisplaySettings())
        let top = RenderMath.clipPosition(imagePoint: SIMD2(0, 0), matrix: params.matrix, viewSize: params.viewSize)
        // The image top-left corner is above and left of the screen center.
        #expect(top.x < 0 && top.y > 0)
    }

    @Test func stretchMatchesShader() {
        #expect(near(RenderMath.stretch(0.5, black: 0, white: 1, gamma: 1), 0.5))
        #expect(near(RenderMath.stretch(0.2, black: 0.2, white: 0.6, gamma: 1), 0))
        #expect(near(RenderMath.stretch(0.6, black: 0.2, white: 0.6, gamma: 1), 1))
        #expect(near(RenderMath.stretch(0.4, black: 0.2, white: 0.6, gamma: 1), 0.5))
        #expect(near(RenderMath.stretch(0.25, black: 0, white: 1, gamma: 2), 0.5))
        #expect(near(RenderMath.stretch(2, black: 0, white: 1, gamma: 1), 1))
    }
}

// MARK: - Display settings

struct DisplaySettingsTests {
    @Test func longPressMakesTouchedPointTheOpticalCenter() {
        var settings = DisplaySettings()
        let touch = CGPoint(x: 100, y: 300)
        let expected = settings.transform(imageSize: testImageSize, viewSize: testViewSize)
            .screenToImage(Vec2(100, 300))

        settings.setOpticalCenter(atScreen: touch, imageSize: testImageSize, viewSize: testViewSize)

        let center = try! #require(settings.opticalCenter)
        #expect(near(center.x, expected.x, 1e-6) && near(center.y, expected.y, 1e-6))
        // The crosshair (optical center) is recentered on the screen.
        let onScreen = settings.transform(imageSize: testImageSize, viewSize: testViewSize).imageToScreen(center)
        #expect(near(onScreen.x, 196.5, 1e-6) && near(onScreen.y, 426, 1e-6))
    }

    @Test func longPressWorksWithRotation() {
        var settings = DisplaySettings(rotationDegrees: 37, flipHorizontal: true)
        let before = settings.transform(imageSize: testImageSize, viewSize: testViewSize)
        let touch = CGPoint(x: 250, y: 450)
        let expected = before.screenToImage(Vec2(250, 450))
        settings.setOpticalCenter(atScreen: touch, imageSize: testImageSize, viewSize: testViewSize)
        let center = try! #require(settings.opticalCenter)
        #expect(near(center.x, expected.x, 1e-6) && near(center.y, expected.y, 1e-6))
    }

    @Test func opticalCenterStaysInsideImage() {
        var settings = DisplaySettings()
        settings.setOpticalCenter(atScreen: CGPoint(x: -5000, y: 9000), imageSize: testImageSize, viewSize: testViewSize)
        let center = try! #require(settings.opticalCenter)
        #expect(center.x >= 0 && center.x <= 1919 && center.y >= 0 && center.y <= 1439)
    }

    @Test func rotationWrapsIntoHalfTurn() {
        var settings = DisplaySettings()
        settings.setRotation(degrees: 190)
        #expect(near(settings.rotationDegrees, -170))
        settings.setRotation(degrees: -190)
        #expect(near(settings.rotationDegrees, 170))
        settings.setRotation(degrees: 360)
        #expect(near(settings.rotationDegrees, 0))
        settings.setRotation(degrees: 35.5)
        #expect(near(settings.rotationDegrees, 35.5))
    }

    @Test func manualFlagFollowsRotationAndFlips() {
        #expect(!DisplaySettings().isManual)
        #expect(DisplaySettings(rotationDegrees: 1).isManual)
        #expect(DisplaySettings(flipVertical: true).isManual)
    }

    @Test func stretchIsNormalized() {
        var settings = DisplaySettings(blackPoint: 0.9, whitePoint: 0.5, gamma: 10)
        settings.normalizeStretch()
        #expect(settings.whitePoint >= settings.blackPoint + 0.02 - 1e-9)
        #expect(settings.gamma <= 3)
    }

    @Test func persistenceRoundTrip() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DisplaySettings.load(from: defaults) == DisplaySettings())
        var settings = DisplaySettings(rotationDegrees: 12.5, flipHorizontal: true, zoom: 1.5)
        settings.opticalCenter = Vec2(900, 700)
        settings.brightness = 0.1
        settings.save(to: defaults)
        #expect(DisplaySettings.load(from: defaults) == settings)
    }
}

// MARK: - Camera controls

struct CameraControlTests {
    @Test func presetsFollowThePlan() {
        #expect(CameraPreset.centering.exposureSeconds <= 0.25)
        #expect(CameraPreset.viewing.exposureSeconds >= 0.5 && CameraPreset.viewing.exposureSeconds <= 1.0)
        #expect(CameraPreset.centering.iso > CameraPreset.viewing.iso)
    }

    @Test func presetsAreClampedToDeviceLimits() {
        let limits = ExposureLimits(minDuration: 0.001, maxDuration: 0.5, minISO: 100, maxISO: 2000)
        #expect(CameraPreset.viewing.exposure(limits: limits) == .manual(duration: 0.5, iso: 1600))
        #expect(CameraPreset.centering.exposure(limits: limits) == .manual(duration: 0.125, iso: 2000))
        let tight = ExposureLimits(minDuration: 0.5, maxDuration: 1.0, minISO: 3500, maxISO: 6000)
        #expect(CameraPreset.centering.exposure(limits: tight) == .manual(duration: 0.5, iso: 3500))
    }

    @Test func frameDurationPlanning() {
        #expect(ExposurePlanner.maxFrameDuration(forExposure: 0.02, longestSupported: 1) == nil)
        #expect(ExposurePlanner.maxFrameDuration(forExposure: 0.75, longestSupported: 1) == 0.75)
        #expect(ExposurePlanner.maxFrameDuration(forExposure: 1.0, longestSupported: 1) == 1.0)
        #expect(ExposurePlanner.maxFrameDuration(forExposure: 0.9, longestSupported: 0.4) == 0.4)
    }

    @Test func logScaleRoundTrip() {
        let lo = 0.0001, hi = 1.0
        #expect(near(LogScale.unit(value: lo, min: lo, max: hi), 0))
        #expect(near(LogScale.unit(value: hi, min: lo, max: hi), 1))
        #expect(near(LogScale.value(unit: 0, min: lo, max: hi), lo))
        #expect(near(LogScale.value(unit: 1, min: lo, max: hi), hi))
        for value in [0.001, 0.0125, 0.125, 0.75] {
            let unit = LogScale.unit(value: value, min: lo, max: hi)
            #expect(near(LogScale.value(unit: unit, min: lo, max: hi), value, 1e-9))
        }
    }

    @Test func exposureFormatting() {
        #expect(formatExposure(0.125) == "1/8 s")
        #expect(formatExposure(0.01) == "1/100 s")
        #expect(formatExposure(0.75) == "0.75 s")
        #expect(formatExposure(1.0) == "1.0 s")
        #expect(formatExposure(0) == "–")
    }

    @Test func settingsPersistenceRoundTrip() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(CameraSettings.load(from: defaults) == CameraSettings())
        var settings = CameraSettings()
        settings.exposure = .manual(duration: 0.75, iso: 1600)
        settings.focus = .manual(lensPosition: 0.81)
        settings.activePreset = .viewing
        settings.save(to: defaults)
        let loaded = CameraSettings.load(from: defaults)
        #expect(loaded == settings)
        #expect(loaded.exposureMode == .manual && loaded.focusMode == .manual)
    }
}

// MARK: - Sun reminder

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "UTC")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date!
}

struct SunReminderTests {
    @Test func afternoonSunInTheSouthWestWarns() {
        // 16:00 local time in Helsinki, late September: low sun in the south-west.
        let sun = SunReminder(date: utc(2026, 9, 29, 13))
        #expect(sun.isUp)
        #expect(sun.azimuth > 200 && sun.azimuth < 300)
        #expect(sun.isWarning)
    }

    @Test func middaySunDoesNotWarn() {
        let sun = SunReminder(date: utc(2026, 9, 29, 10, 10))
        #expect(sun.isUp)
        #expect(sun.azimuth > 165 && sun.azimuth < 195)
        #expect(!sun.isWarning)
    }

    @Test func morningSunInTheEastDoesNotWarn() {
        let sun = SunReminder(date: utc(2026, 9, 29, 6))
        #expect(sun.isUp)
        #expect(sun.azimuth < 180)
        #expect(!sun.isWarning)
    }

    @Test func nightDoesNotWarn() {
        let sun = SunReminder(date: utc(2026, 9, 29, 21))
        #expect(!sun.isUp)
        #expect(!sun.isWarning)
    }

    @Test func directionNames() {
        #expect(SunReminder.directionName(forAzimuth: 0) == "pohjoinen")
        #expect(SunReminder.directionName(forAzimuth: 359) == "pohjoinen")
        #expect(SunReminder.directionName(forAzimuth: 90) == "itä")
        #expect(SunReminder.directionName(forAzimuth: 180) == "etelä")
        #expect(SunReminder.directionName(forAzimuth: 243) == "lounas")
        #expect(SunReminder.directionName(forAzimuth: 270) == "länsi")
        #expect(SunReminder.directionName(forAzimuth: 315) == "luode")
    }
}

// MARK: - Virtual stick and performance counters

struct VirtualStickTests {
    @Test func mapsOffsetToStickVector() {
        let half = VirtualStick.vector(fromOffset: CGSize(width: 40, height: 0), radius: 80)
        #expect(near(half.x, 0.5) && near(half.y, 0))
        // Screen up (negative y) is stick up.
        let up = VirtualStick.vector(fromOffset: CGSize(width: 0, height: -80), radius: 80)
        #expect(near(up.x, 0) && near(up.y, 1))
    }

    @Test func clampsToUnitDisc() {
        let far = VirtualStick.vector(fromOffset: CGSize(width: 300, height: 0), radius: 80)
        #expect(near(far.x, 1) && near(far.y, 0))
        let diagonal = VirtualStick.vector(fromOffset: CGSize(width: 80, height: 80), radius: 80)
        #expect(near(diagonal.length, 1))
        #expect(diagonal.x > 0 && diagonal.y < 0)
        #expect(VirtualStick.vector(fromOffset: .zero, radius: 0) == .zero)
    }
}

struct PerformanceCounterTests {
    @Test func rateCounterMeasuresFps() {
        var counter = RateCounter(window: 2)
        for i in 0...30 { counter.record(Double(i) / 30) }
        #expect(near(counter.rate(now: 1.0), 30, 1e-6))
        #expect(counter.rate(now: 10) == 0)
    }

    @Test func rateCounterForgetsOldEvents() {
        var counter = RateCounter(window: 1)
        for i in 0..<10 { counter.record(Double(i)) }
        #expect(near(counter.rate(now: 9), 1, 1e-6))
    }

    @Test func latencyTrackerAveragesAndKeepsMaximum() {
        var tracker = LatencyTracker(smoothing: 0.1)
        tracker.record(100)
        tracker.record(200)
        #expect(near(tracker.average, 110, 1e-9))
        #expect(tracker.maximum == 200 && tracker.last == 200)
        tracker.resetMaximum()
        #expect(tracker.maximum == 0)
    }

    @Test func monitorComputesLatencyAndDrops() {
        let monitor = PerformanceMonitor()
        for i in 0..<10 { monitor.frameArrived(at: Double(i) * 0.1) }
        monitor.frameDropped()
        monitor.framePresented(framePTS: 5.0, now: 5.05)
        let snapshot = monitor.snapshot(now: 0.9)
        #expect(near(snapshot.captureFps, 10, 1e-6))
        #expect(snapshot.droppedFrames == 1 && snapshot.totalFrames == 10)
        #expect(near(snapshot.latencyMs, 50, 1e-6))
    }
}

// MARK: - Synthetic frames

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    func add(_ frame: Frame) { lock.withLock { frames.append(frame) } }
    var all: [Frame] { lock.withLock { frames } }
}

struct SyntheticFrameTests {
    @Test func pixelBufferHoldsLumaAndNeutralChroma() throws {
        var image = GrayImage8(width: 64, height: 48, fill: 7)
        image.pixels[5 * 64 + 10] = 200
        let buffer = try #require(SyntheticFrames.makePixelBuffer(from: image))

        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2)
        #expect(CVPixelBufferGetWidth(buffer) == 64 && CVPixelBufferGetHeight(buffer) == 48)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        #expect(luma[5 * lumaStride + 10] == 200)
        #expect(luma[0] == 7)
        #expect(luma[47 * lumaStride + 63] == 7)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        #expect(chroma[0] == 128)
    }

    @Test func sourceDeliversFrames() async throws {
        let source = SyntheticFrameSource(targetFps: 5)
        let collector = FrameCollector()
        source.setFrameHandler { collector.add($0) }
        source.setStick(Vec2(0, 1))
        try await source.start()
        // Debug builds render slowly; allow up to a minute for the first frame.
        for _ in 0..<600 where collector.all.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        await source.stop()

        let frame = try #require(collector.all.first)
        #expect(frame.width == 480 && frame.height == 360)
        #expect(frame.timestamp > 0)
        #expect(source.kind == .synthetic)
    }
}

// MARK: - Metal (skipped without a GPU device)

struct MetalRenderingTests {
    @Test func shaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        _ = try MetalPipeline.make(device: device)
    }

    @Test func rendersFrameThroughTheDisplayTransform() throws {
        guard let renderer = FrameRenderer(performance: nil) else { return }

        // 64x48 black image with a bright 9x9 block centered at pixel (40, 20).
        var image = GrayImage8(width: 64, height: 48, fill: 0)
        for y in 16...24 {
            for x in 36...44 { image.pixels[y * 64 + x] = 255 }
        }
        let buffer = try #require(SyntheticFrames.makePixelBuffer(from: image))
        let frame = Frame(pixelBuffer: buffer, timestamp: 1)

        // Scale 2, optical center (31.5, 23.5) on the screen center (64, 48): the block center
        // (40, 20) lands on screen (81, 41).
        let transform = DisplayTransform.unrotated(
            scale: 2, opticalCenter: Vec2(31.5, 23.5), screenCenter: Vec2(64, 48)
        )
        let params = RenderMath.params(
            transform: transform, viewSize: CGSize(width: 128, height: 96), blackPoint: 0, whitePoint: 1,
            gamma: 1, redMode: false
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 96, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let queue = try #require(renderer.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let resources = renderer.encode(frame: frame, params: params, descriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(resources != nil)

        var pixels = [UInt8](repeating: 0, count: 128 * 96 * 4)
        target.getBytes(&pixels, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 96), mipmapLevel: 0)
        func red(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 128 + x) * 4 + 2] }

        #expect(red(81, 41) > 200)
        #expect(red(20, 80) < 10)
        // Just outside the block on screen (block spans about 72...90 x 32...50).
        #expect(red(100, 41) < 10)
        #expect(red(81, 60) < 10)
    }
}
