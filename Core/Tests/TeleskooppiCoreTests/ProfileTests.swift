import Foundation
import Testing
@testable import TeleskooppiCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("profiles.json")
}

private func prepare(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

struct ProfileTests {
    @Test func derivedOptics25mm() {
        let e = EyepieceProfile(focalLengthMM: 25)
        #expect(abs(e.magnification - 30) < 1e-9)
        #expect(abs(e.trueFOVDegrees - 1.7333) < 1e-3)
        #expect(abs(e.exitPupilMM - 5) < 1e-9)
        #expect(e.label == "25 mm")
    }

    @Test func barlowDoublesMagnification() {
        let e = EyepieceProfile(focalLengthMM: 10, barlowFactor: 2)
        #expect(abs(e.magnification - 150) < 1e-9)
        #expect(abs(e.exitPupilMM - 1) < 1e-9)
        #expect(e.label == "10 mm + 2x")
        #expect(abs(e.plateScaleArcsecPerPixel(fieldDiameterPixels: 1000) - e.trueFOVDegrees * 3.6) < 1e-9)
    }

    @Test func defaultsCoverAllEyepieces() {
        let d = SetupProfile.defaults()
        #expect(Set(d.map(\.eyepiece.focalLengthMM)) == [25, 10, 9, 6])
        #expect(Set(d.map(\.id)).count == d.count)
        #expect(d.contains { $0.eyepiece.barlowFactor == 2 })
    }

    @Test func fileStoreRoundTrip() throws {
        let store = JSONFileProfileStore(url: tempURL())
        #expect(try store.loadAll().isEmpty)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = CalibrationResult(stickToImage: Mat2(a: 1, b: 2, c: 3, d: 4), displayRotation: 0.5, mirrored: true,
                                    orthogonalityError: 0.01, lineResidual: 0.2,
                                    opticalCenter: Vec2(900, 700), fieldRadius: 600, createdAt: t0)
        var p = SetupProfile(name: "Test", eyepiece: EyepieceProfile(focalLengthMM: 9), opticalCenter: Vec2(10, 20),
                             fieldRadius: 500, calibration: cal,
                             camera: CameraSettingsSnapshot(preset: "centering"), adapterNote: "slot 3",
                             createdAt: t0)
        p.lastUsedAt = t0.addingTimeInterval(100)
        try store.save(p)
        try store.setLastUsedID(p.id)
        let loaded = try JSONFileProfileStore(url: store.url).loadAll()
        #expect(loaded == [p])
        #expect(try store.lastUsedID() == p.id)
        try store.delete(id: p.id)
        #expect(try store.loadAll().isEmpty)
        #expect(try store.lastUsedID() == nil)
    }

    @Test func migratesV1() throws {
        let v1 = """
        {"version":1,"profiles":[{"id":"00000000-0000-0000-0000-000000000025","name":"25 mm",
        "eyepiece":{"focalLengthMM":25,"barlowFactor":1,"apparentFOVDegrees":52,
        "telescope":{"apertureMM":150,"focalLengthMM":750}},
        "adapterPosition":"notch 2","createdAt":"2026-09-30T20:00:00Z"}]}
        """
        let url = tempURL()
        try prepare(url, contents: v1)
        let store = JSONFileProfileStore(url: url)
        let profiles = try store.loadAll()
        #expect(profiles.count == 1)
        #expect(profiles[0].adapterNote == "notch 2")
        #expect(profiles[0].eyepiece.magnification == 30)
        try store.setLastUsedID(profiles[0].id)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"version\" : 2"))
        #expect(try store.lastUsedID() == profiles[0].id)
    }

    @Test func rejectsFutureVersion() throws {
        let url = tempURL()
        try prepare(url, contents: "{\"version\":99,\"profiles\":[]}")
        #expect(throws: ProfileStoreError.unsupportedVersion(99)) {
            try JSONFileProfileStore(url: url).loadAll()
        }
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryProfileStore(SetupProfile.defaults())
        let first = try store.loadAll()[0]
        try store.setLastUsedID(first.id)
        try store.delete(id: first.id)
        #expect(try store.lastUsedID() == nil)
        #expect(try store.loadAll().count == SetupProfile.defaults().count - 1)
    }
}
