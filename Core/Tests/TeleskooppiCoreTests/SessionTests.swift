import Foundation
import Testing
@testable import TeleskooppiCore

/// Phase 3 (D-11): recording format round trip and replay.
@Suite struct SessionFormatTests {
    static func makeMeta() -> SessionMeta {
        let calibration = CalibrationResult(
            stickToImage: Mat2(a: 1.5, b: -20.25, c: 18.125, d: 2.75), displayRotation: 0.7, mirrored: false,
            orthogonalityError: 0.01, lineResidual: 0.4, repeatability: nil, opticalCenter: Vec2(480, 360),
            fieldRadius: 380, driftVelocity: Vec2(0.1, -0.2), quality: .good, isQuick: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        return SessionMeta(
            createdAt: Date(timeIntervalSince1970: 1_800_000_123),
            device: DeviceInfo(model: "iPhone18,1", systemVersion: "26.5", appVersion: "0.3.0", camera: "back wide"),
            format: FrameFormat(width: 64, height: 48, binning: 2, frameRate: 10),
            profile: SessionProfile(eyepiece: "25 mm", speedLevel: 3, opticalCenter: Vec2(32, 24), fieldRadius: 22),
            calibration: calibration, notes: "test / notes with \"quotes\" and \u{00E4}\u{00F6}")
    }

    static func makeFrames(count: Int) -> [SessionFrame] {
        var rng = SplitMix64(seed: 42)
        return (0..<count).map { i in
            // Alternate tight and padded strides to exercise both layouts.
            let stride = i % 2 == 0 ? 64 : 67
            var img = GrayImage8(width: 64, height: 48, stride: stride)
            for k in 0..<img.pixels.count { img.pixels[k] = UInt8(truncatingIfNeeded: rng.next() >> 56) }
            return SessionFrame(meta: FrameMeta(timestamp: 0.1 * Double(i) + 1e-9, exposure: 1.0 / 30,
                                                iso: 800 + Float(i), lensPosition: 0.99),
                                image: img)
        }
    }

    static func write(_ frames: [SessionFrame], events: [SessionEvent], meta: SessionMeta, to dir: URL) throws {
        let w = try SessionWriter(directory: dir, meta: meta)
        for (i, f) in frames.enumerated() {
            try w.append(f.image, meta: f.meta)
            for e in events where Int(e.t * 10 + 0.5) == i { try w.appendEvent(e) }
        }
        try w.finish()
    }

    @Test func directoryNameIsUTCTimestamp() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-29T15:30:45Z"))
        #expect(SessionFormat.directoryName(for: date) == "session-20260929-153045.tcs")
        let parent = try temporaryDirectory("dirname")
        defer { try? FileManager.default.removeItem(at: parent) }
        let w = try SessionWriter.create(in: parent, date: date, meta: Self.makeMeta())
        #expect(w.directory.lastPathComponent == "session-20260929-153045.tcs")
        try w.finish()
    }

    @Test func headerLayoutIsLittleEndian() throws {
        let dir = try temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("s.tcs", isDirectory: true)
        var img = GrayImage8(width: 5, height: 3, fill: 7)
        img[4, 2] = 200
        let w = try SessionWriter(directory: target, meta: Self.makeMeta())
        try w.append(img, meta: FrameMeta(timestamp: 1.5, exposure: 0.25, iso: 400, lensPosition: 0.5))
        try w.finish()
        let bytes = [UInt8](try Data(contentsOf: target.appendingPathComponent("frames.bin")))
        #expect(bytes.count == 48 + 15)
        #expect(Array(bytes[0..<4]) == [0x54, 0x43, 0x53, 0x46])
        #expect(Array(bytes[4..<6]) == [1, 0])
        #expect(Array(bytes[6..<8]) == [48, 0])
        // 1.5 = 0x3FF8000000000000 -> little-endian bytes 00 00 00 00 00 00 F8 3F
        #expect(Array(bytes[8..<16]) == [0, 0, 0, 0, 0, 0, 0xF8, 0x3F])
        // 0.25 = 0x3FD0000000000000
        #expect(Array(bytes[16..<24]) == [0, 0, 0, 0, 0, 0, 0xD0, 0x3F])
        // 400.0f = 0x43C80000
        #expect(Array(bytes[24..<28]) == [0, 0, 0xC8, 0x43])
        #expect(Array(bytes[32..<36]) == [5, 0, 0, 0])
        #expect(Array(bytes[36..<40]) == [3, 0, 0, 0])
        #expect(Array(bytes[40..<44]) == [5, 0, 0, 0])
        #expect(Array(bytes[44..<48]) == [15, 0, 0, 0])
        #expect(bytes[48 + 14] == 200)
    }

    @Test func roundTripIsByteIdentical() throws {
        let root = try temporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = Self.makeFrames(count: 12)
        let events = [
            SessionEvent(t: 0.0, type: SessionEvent.calibrationStart),
            SessionEvent(t: 0.1, type: SessionEvent.starSelect, values: ["x": 31.5, "y": 24.25]),
            SessionEvent(t: 0.3, type: SessionEvent.prompt, text: ["prompt": "pressAndHold(up)"]),
            SessionEvent(t: 0.9, type: SessionEvent.note, text: ["note": "line1\nline2"], values: ["level": 3]),
            SessionEvent(t: 1.1, type: SessionEvent.calibrationEnd),
        ]
        let a = root.appendingPathComponent("a.tcs", isDirectory: true)
        let b = root.appendingPathComponent("b.tcs", isDirectory: true)
        try Self.write(frames, events: events, meta: Self.makeMeta(), to: a)

        let reader = try SessionReader(directory: a)
        #expect(reader.frameCount == 12)
        #expect(!reader.isTruncated)
        #expect(reader.meta.frameCount == 12)
        #expect(reader.meta.calibration == Self.makeMeta().calibration)
        #expect(reader.meta.notes == Self.makeMeta().notes)
        #expect(try reader.events() == events)

        // Random access, in reverse order.
        for i in stride(from: 11, through: 0, by: -1) {
            let f = try reader.frame(at: i)
            #expect(f.meta == frames[i].meta)
            #expect(f.image == frames[i].image)
        }
        #expect(throws: SessionError.frameIndexOutOfRange(12)) { _ = try reader.frame(at: 12) }

        // Rewrite what was read and compare all three files byte for byte.
        let w = try SessionWriter(directory: b, meta: reader.meta)
        var pending = try reader.events()[...]
        for i in 0..<reader.frameCount {
            let f = try reader.frame(at: i)
            try w.append(f.image, meta: f.meta)
            while let e = pending.first, Int(e.t * 10 + 0.5) == i {
                try w.appendEvent(e)
                pending = pending.dropFirst()
            }
        }
        try w.finish()
        for name in [SessionFormat.metaFileName, SessionFormat.framesFileName, SessionFormat.eventsFileName] {
            let da = try Data(contentsOf: a.appendingPathComponent(name))
            let db = try Data(contentsOf: b.appendingPathComponent(name))
            #expect(da == db, "\(name) differs")
        }
    }

    @Test func truncatedLastFrameIsIgnored() throws {
        let root = try temporaryDirectory("truncated")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("t.tcs", isDirectory: true)
        try Self.write(Self.makeFrames(count: 4), events: [], meta: Self.makeMeta(), to: dir)
        let url = dir.appendingPathComponent(SessionFormat.framesFileName)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x54, count: 30))  // partial header
        try handle.close()
        let reader = try SessionReader(directory: dir)
        #expect(reader.frameCount == 4)
        #expect(reader.isTruncated)
        _ = try reader.frame(at: 3)
    }

    @Test func rejectsForeignFiles() throws {
        let root = try temporaryDirectory("foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("f.tcs", isDirectory: true)
        try Self.write(Self.makeFrames(count: 2), events: [], meta: Self.makeMeta(), to: dir)
        let url = dir.appendingPathComponent(SessionFormat.framesFileName)
        var data = try Data(contentsOf: url)
        data[0] = 0x00
        try data.write(to: url)
        #expect(throws: SessionError.badMagic(frame: 0)) { _ = try SessionReader(directory: dir) }
        #expect(throws: SessionError.self) { _ = try SessionReader(directory: root.appendingPathComponent("missing")) }
    }

    @Test func writerRefusesExistingSession() throws {
        let root = try temporaryDirectory("exists")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("e.tcs", isDirectory: true)
        try Self.write(Self.makeFrames(count: 1), events: [], meta: Self.makeMeta(), to: dir)
        #expect(throws: SessionError.self) { _ = try SessionWriter(directory: dir, meta: Self.makeMeta()) }
    }
}

@Suite struct SessionReplayTests {
    /// A scenario (scaled sensor, gentle noise) whose ground-truth calibration succeeds.
    static func workingScenario(scale: Double) -> CalibrationScenario {
        for seed in UInt64(1)...120 {
            var sc = CalibrationScenario.random(seed: seed)
            sc.jitterSigma = 0.5
            let scaled = sc.scaled(by: scale)
            if let r = CalibrationSimulation(scenario: scaled).run().result, r.quality == .good { return sc }
        }
        return CalibrationScenario.random(seed: 1)
    }

    @Test func replayOfSimulatedRecordingReproducesCalibration() throws {
        let scale = 0.3
        let sc = Self.workingScenario(scale: scale)
        let root = try temporaryDirectory("replay")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = SimulatedSessionOptions()
        options.scale = scale
        let clock = ContinuousClock()
        var recorded: (directory: URL, outcome: CalibrationRunOutcome)?
        let recordTime = try clock.measure { recorded = try SimulatedSession.record(scenario: sc, in: root, options: options) }
        let (dir, truthRun) = try #require(recorded)
        let truth = try #require(truthRun.result, "ground-truth run must succeed")

        let reader = try SessionReader(directory: dir)
        #expect(reader.frameCount > 100)
        #expect(reader.meta.frameCount == reader.frameCount)
        // (Dates are stored with one-second resolution, so compare the physical content.)
        #expect(reader.meta.calibration?.stickToImage == truth.stickToImage)
        #expect(reader.meta.calibration?.displayRotation == truth.displayRotation)
        #expect(reader.meta.calibration?.mirrored == truth.mirrored)
        let events = try reader.events()
        #expect(events.contains { $0.type == SessionEvent.calibrationStart })
        #expect(events.contains { $0.type == SessionEvent.calibrationEnd })
        #expect(events.contains { $0.type == SessionEvent.starSelect })

        var replayed: ReplayReport?
        let replayTime = try clock.measure { replayed = try SessionReplay.run(reader) }
        let report = try #require(replayed)
        let result = try #require(report.result, "replay failed: \(String(describing: report.failure)), prompts \(report.promptLog.map { $0.prompt.summary })")
        let vsTruth = AngleMath.degrees(abs(AngleMath.difference(result.displayRotation, sc.scaled(by: scale).optics.displayRotation)))
        let vsRun = AngleMath.degrees(abs(AngleMath.difference(result.displayRotation, truth.displayRotation)))
        print("[session] recorded \(reader.frameCount) frames (\(SessionReplay.milliseconds(recordTime)) ms), replay "
            + "\(SessionReplay.milliseconds(replayTime)) ms, mean analysis \(report.averageAnalysisMilliseconds) ms/frame; "
            + "rotation error vs truth \(vsTruth) deg, vs ground-truth run \(vsRun) deg, samples \(report.sampleRate)")
        #expect(result.mirrored == sc.optics.mirrored)
        #expect(vsTruth < 3.0)
        #expect(vsRun < 3.0)
        #expect(report.sampleRate > 0.95)
        #expect(report.calibrationStart != nil)
    }
}
