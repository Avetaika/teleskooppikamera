import Foundation
import Testing
@testable import Teleskooppikamera

// These tests run in the simulator, which has no camera: nothing here touches AVFoundation.

struct VersionTests {
    @Test func coreVersionLinks() {
        #expect(!AppInfo.coreVersion.isEmpty)
    }

    @Test func summaryContainsVersions() {
        let summary = AppInfo.summary
        #expect(summary.contains(AppInfo.coreVersion))
        #expect(summary.contains(AppInfo.marketingVersion))
    }
}

struct CapabilityReportTests {
    @Test func rendersHeaderSectionsAndLines() {
        var section = CapabilityReport.Section("Device")
        section.add("maxExposureDuration", CaptureFormatting.seconds(1.0))
        section.add("isAppleProRAWSupported", false)
        section.note("free text")
        let report = CapabilityReport(
            createdAt: Date(timeIntervalSince1970: 0),
            sections: [section, CapabilityReport.Section("Empty")]
        )

        let text = report.rendered(timeZone: TimeZone(identifier: "UTC")!)

        #expect(text.hasPrefix("TELESKOOPPIKAMERA – CAPABILITY REPORT\n"))
        #expect(text.contains("created: 1970-01-01 00:00:00 Z"))
        #expect(text.contains("\n== Device ==\nmaxExposureDuration: 1.000000 s\nisAppleProRAWSupported: false\nfree text\n"))
        #expect(text.contains("\n== Empty ==\n"))
    }

    @Test func fileNameUsesTimestamp() {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
        let name = CapabilityReport.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "capability-20260921-141320.txt")
    }
}

struct CaptureFormattingTests {
    @Test func fourCC() {
        #expect(CaptureFormatting.fourCC(0x3432_3066) == "420f")
        #expect(CaptureFormatting.fourCC(0x7834_3230) == "x420")
        #expect(CaptureFormatting.fourCC(0x0000_0001) == "0x00000001")
    }

    @Test func fourByThree() {
        #expect(CaptureFormatting.isFourByThree(width: 1920, height: 1440))
        #expect(CaptureFormatting.isFourByThree(width: 4032, height: 3024))
        #expect(!CaptureFormatting.isFourByThree(width: 1920, height: 1080))
    }

    @Test func frameRateAndSeconds() {
        #expect(CaptureFormatting.fpsRange(min: 1, max: 30) == "1.0–30.0 fps")
        #expect(CaptureFormatting.seconds(0.25) == "0.250000 s")
        #expect(CaptureFormatting.seconds(.nan) == "n/a")
    }
}

struct LogFileTests {
    @Test func appendsAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = LogFile(url: dir.appending(path: "log.txt"), previousURL: dir.appending(path: "log.old.txt"))
        file.append(level: .notice, category: "test", message: "hello")
        file.append(level: .error, category: "test", message: "boom")

        let text = file.readAll()
        #expect(text.contains("NOTICE [test] hello"))
        #expect(text.contains("ERROR [test] boom"))
        #expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    }

    @Test func rotatesWhenTooLarge() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let previous = dir.appending(path: "log.old.txt")
        let file = LogFile(url: dir.appending(path: "log.txt"), previousURL: previous, maxBytes: 100)
        for i in 0..<10 {
            file.append(level: .notice, category: "test", message: "line \(i) with some padding text")
        }
        _ = file.readAll() // waits for pending writes

        #expect(FileManager.default.fileExists(atPath: previous.path(percentEncoded: false)))
        #expect(file.readAll().contains("line 9"))
    }
}
