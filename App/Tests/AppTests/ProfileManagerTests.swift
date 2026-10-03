import Foundation
import Testing
import TeleskooppiCore
@testable import Teleskooppikamera

@MainActor
struct ProfileManagerTests {
    private func makeCalibration() -> CalibrationResult {
        CalibrationResult(stickToImage: Mat2(a: 1, b: 0, c: 0, d: 1), displayRotation: 0, mirrored: false,
                          orthogonalityError: 0, lineResidual: 0, opticalCenter: Vec2(800, 600), fieldRadius: 500)
    }

    @Test func seedsDefaultsOnFirstLaunch() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        #expect(manager.profiles.count == SetupProfile.defaults().count)
        #expect(manager.active == nil)
        #expect(!manager.canUsePrevious)
    }

    @Test func useWithoutCalibrationFallsBackToRecalibrate() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        var recalibrations = 0
        manager.onRecalibrate = { recalibrations += 1 }
        manager.activate(id: manager.profiles[0].id)
        let taken = manager.start(.usePrevious)
        #expect(taken == .recalibrate)
        #expect(recalibrations == 1)
    }

    @Test func savedCalibrationEnablesPreviousAndQuick() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let id = manager.profiles[0].id
        manager.activate(id: id)
        manager.save(makeCalibration(), profileID: id)
        #expect(manager.load(profileID: id)?.opticalCenter == Vec2(800, 600))
        #expect(manager.canUsePrevious)
        var quick = 0
        manager.onQuickCalibrate = { quick += 1 }
        #expect(manager.start(.quickCalibrate) == .quickCalibrate)
        #expect(quick == 1)
        #expect(manager.start(.usePrevious) == .usePrevious)
    }

    @Test func activationAppliesProfileAndPersistsLastUsed() throws {
        let store = InMemoryProfileStore()
        let manager = ProfileManager(store: store)
        var applied: [UUID] = []
        manager.onActivate = { applied.append($0.id) }
        let id = manager.profiles[1].id
        manager.activate(id: id)
        #expect(applied == [id])
        #expect(try store.lastUsedID() == id)
        let reloaded = ProfileManager(store: store)
        #expect(reloaded.activeID == id)
    }

    @Test func createProfileValidatesAndActivates() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        #expect(manager.createProfile(name: nil, focalLengthMM: 0) == nil)
        #expect(manager.createProfile(name: nil, focalLengthMM: 15, barlowFactor: 0.5) == nil)
        let p = manager.createProfile(name: " ", focalLengthMM: 15, barlowFactor: 2)
        #expect(p?.name == "15 mm + 2x")
        #expect(manager.activeID == p?.id)
    }

    @Test func updateActiveStoresCentreAndCamera() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        manager.activate(id: manager.profiles[0].id)
        manager.updateActive(opticalCenter: Vec2(10, 20), fieldRadius: 300,
                             camera: CameraSettingsSnapshot(iso: 800, preset: "centering"))
        #expect(manager.active?.opticalCenter == Vec2(10, 20))
        #expect(manager.active?.fieldRadius == 300)
        #expect(manager.active?.camera?.preset == "centering")
    }

    @Test func deleteClearsActive() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let id = manager.profiles[0].id
        manager.activate(id: id)
        manager.delete(id: id)
        #expect(manager.activeID == nil)
        #expect(manager.profile(id: id) == nil)
    }

    @Test func cameraSnapshotRoundTrip() {
        var settings = CameraSettings()
        settings.manualISO = 3200
        settings.manualDuration = 0.5
        settings.activePreset = .centering
        let snap = settings.snapshot
        #expect(snap.iso == 3200)
        #expect(snap.preset == "centering")
    }
}
