import CoreGraphics
import Foundation
import Testing
import TeleskooppiCore
@testable import Teleskooppikamera

// Phase 3/4 tests: recording, binning, rate limiting, detection and tap selection. Nothing
// here touches the camera.

private func starImage(x: Double, y: Double, amplitude: Double = 180, sigma: Double = 1.8) -> GrayImage8 {
    let width = 960
    let height = 720
    var pixels = [UInt8](repeating: 0, count: width * height)
    var state: UInt64 = 12345
    for j in 0..<height {
        for i in 0..<width {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double((state >> 33) % 5) - 2
            let dx = Double(i) - x
            let dy = Double(j) - y
            let value = 30 + noise + amplitude * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            pixels[j * width + i] = UInt8(max(0, min(255, value.rounded())))
        }
    }
    return GrayImage8(width: width, height: height, pixels: pixels)
}

struct Phase34Tests {
    @Test func recorderRoundTripsThroughCoreReader() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "tc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let recorder = SessionRecorder()
        let device = DeviceInfo(model: "test", systemVersion: "26.0", appVersion: "0")
        recorder.start(parent: parent, rate: 10, notes: "start", device: device, now: 0)
        #expect(recorder.isRecording)

        var images = [GrayImage8]()
        for k in 0..<3 {
            let pixels = (0..<(16 * 12)).map { UInt8(($0 &* 7 &+ k &* 31) % 256) }
            let image = GrayImage8(width: 16, height: 12, pixels: pixels)
            images.append(image)
            recorder.offer(image, meta: FrameMeta(
                timestamp: 100 + Double(k) * 0.1, exposure: 0.01, iso: Float(100 * (k + 1)), lensPosition: 0.8
            ))
        }
        let url = try #require(recorder.stop(notes: "final notes"))
        #expect(!recorder.isRecording)

        let reader = try SessionReader(directory: url)
        #expect(reader.frameCount == 3)
        #expect(reader.meta.notes == "final notes")
        #expect(reader.meta.format.frameRate == 10)
        for k in 0..<3 {
            let frame = try reader.frame(at: k)
            #expect(frame.image == images[k])
            #expect(frame.meta.iso == Float(100 * (k + 1)))
            #expect(frame.meta.lensPosition == 0.8)
        }
    }

    @Test func recorderNeverQueuesUnboundedFrames() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "tc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let recorder = SessionRecorder()
        recorder.start(parent: parent, rate: 10, notes: "", device: DeviceInfo(model: "t", systemVersion: "1", appVersion: "0"))
        let image = GrayImage8(width: 960, height: 720, fill: 7)
        for k in 0..<10 { recorder.offer(image, meta: FrameMeta(timestamp: Double(k))) }
        let status = recorder.status(now: 1)
        #expect(status.dropped + status.frames + SessionRecorder.maxPending >= 10)
        let url = try #require(recorder.stop(notes: ""))
        let reader = try SessionReader(directory: url)
        #expect(reader.frameCount >= SessionRecorder.maxPending && reader.frameCount <= 10)
    }

    @Test func rateLimiterPassesEveryThirdFrameOf30Fps() {
        var limiter = MinIntervalLimiter(minInterval: 0.1)
        var passed = 0
        for k in 0..<90 { if limiter.allow(Double(k) / 30) { passed += 1 } }
        #expect(passed == 30)
        var fast = MinIntervalLimiter(minInterval: 1.0 / 15)
        var fastPassed = 0
        for k in 0..<90 { if fast.allow(Double(k) / 30) { fastPassed += 1 } }
        #expect(fastPassed == 45)
        // A restarted clock is accepted immediately.
        #expect(limiter.allow(0))
    }

    @Test func binningAveragesTwoByTwoBlocks() {
        let pixels: [UInt8] = [
            0, 1, 10, 20,
            2, 5, 30, 41,
        ]
        let out = LumaBinning.bin(pixels, width: 4, height: 2, stride: 4, factor: 2)
        #expect(out.width == 2 && out.height == 1)
        #expect(out[0, 0] == 2)  // (0+1+2+5+2)>>2 = 2
        #expect(out[1, 0] == 25)  // (10+20+30+41+2)>>2 = 25
    }

    @Test func binningReadsPixelBufferLumaPlane() throws {
        let width = 1400
        let height = 100
        let pixels = (0..<(width * height)).map { UInt8(($0 % width * 3 + $0 / width * 5) % 256) }
        let image = GrayImage8(width: width, height: height, pixels: pixels)
        let buffer = try #require(SyntheticFrames.makePixelBuffer(from: image))
        let binned = try #require(LumaBinning.binned(buffer))
        #expect(binned.width == 700 && binned.height == 50)
        let expected = LumaBinning.bin(pixels, width: width, height: height, stride: width, factor: 2)
        #expect(binned == expected)
    }

    @Test func binningGeometryRoundTrips() {
        let geometry = BinningGeometry(factor: 2)
        let binned = Vec2(10, 20)
        let image = geometry.binnedToImage(binned)
        #expect(abs(image.x - 20.5) < 1e-9 && abs(image.y - 40.5) < 1e-9)
        let back = geometry.imageToBinned(image)
        #expect(abs(back.x - 10) < 1e-9 && abs(back.y - 20) < 1e-9)
        #expect(BinningGeometry(factor: 1).binnedToImage(binned) == binned)
    }

    @Test func tapMapsThroughDisplayTransformToBinnedStar() {
        var settings = DisplaySettings()
        settings.setRotation(degrees: 37)
        let imageSize = CGSize(width: 1920, height: 1440)
        let viewSize = CGSize(width: 393, height: 852)
        let transform = settings.transform(imageSize: imageSize, viewSize: viewSize)

        let star = Vec2(1000, 700)  // native image pixels
        let screen = transform.imageToScreen(star)
        let binned = StarSelection.binnedPoint(
            fromScreen: CGPoint(x: screen.x, y: screen.y), transform: transform, factor: 2
        )
        #expect(abs(binned.x - 499.75) < 1e-6)
        #expect(abs(binned.y - 349.75) < 1e-6)
    }

    @Test func analyzerFindsAndLocksSyntheticStar() {
        let image = starImage(x: 400.3, y: 300.6)
        var analyzer = StarAnalyzer()
        let geometry = BinningGeometry(factor: 2)
        let first = analyzer.process(image, time: 0, geometry: geometry, binMilliseconds: 0)
        #expect(first.trackState == nil)
        let found = first.candidates.first
        #expect(found != nil)
        if let found {
            #expect(abs(found.position.x - 400.3) < 0.75 && abs(found.position.y - 300.6) < 0.75)
        }
        #expect(first.detectMilliseconds >= 0)

        analyzer.select(near: Vec2(402, 303))
        _ = analyzer.process(image, time: 0.2, geometry: geometry, binMilliseconds: 0)
        let locked = analyzer.process(image, time: 0.27, geometry: geometry, binMilliseconds: 0)
        #expect(locked.trackState == .locked)
        #expect(locked.star != nil)
        #expect(analyzer.isLocked)

        analyzer.select(near: nil)
        #expect(!analyzer.isLocked)
    }
}
