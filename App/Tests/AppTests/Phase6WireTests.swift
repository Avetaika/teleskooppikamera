import Foundation
import Testing
import TeleskooppiCore
@testable import Teleskooppikamera

// Phase 6 wiring: calibration persisted per profile, quick-calibration mode, profile switch.

@MainActor
struct Phase6WireTests {
    private func calibration(rotation: Double = 0.5, center: Vec2 = Vec2(900, 700)) -> CalibrationResult {
        CalibrationResult(stickToImage: Mat2(columns: Vec2(-1, 0), Vec2(0, 1)), displayRotation: rotation,
                          mirrored: false, orthogonalityError: 0, lineResidual: 0.3, opticalCenter: center,
                          fieldRadius: 500, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private func makeController(_ manager: ProfileManager) -> (CalibrationController, ActiveProfileCalibrationStore) {
        let store = ActiveProfileCalibrationStore(manager: manager)
        let controller = CalibrationController(store: store, feedback: SilentCalibrationFeedback(),
                                               defaults: UserDefaults(suiteName: "phase6.\(UUID().uuidString)") ?? .standard)
        return (controller, store)
    }

    // MARK: Adapter

    @Test func adapterAdoptsDefaultProfileAndStoresPerProfile() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let store = ActiveProfileCalibrationStore(manager: manager)
        #expect(store.load() == nil)
        store.save(calibration())
        let first = manager.activeID
        #expect(first != nil)
        #expect(manager.active?.calibration == calibration())
        #expect(store.load() == calibration())

        let other = manager.profiles.first { $0.id != first }!.id
        manager.activate(id: other)
        #expect(store.load() == nil)
        store.save(calibration(rotation: 1.2))
        manager.activate(id: first!)
        #expect(store.load() == calibration())

        store.save(nil)
        #expect(manager.profile(id: first!)?.calibration == nil)
        #expect(manager.profile(id: other)?.calibration?.displayRotation == 1.2)
    }

    @Test func legacySlotMigratesOnce() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let store = ActiveProfileCalibrationStore(manager: manager)
        let suite = UserDefaults(suiteName: "phase6.legacy.\(UUID().uuidString)") ?? .standard
        let legacy = UserDefaultsCalibrationStore(defaults: suite, key: "legacy")
        legacy.save(calibration())
        store.migrateLegacy(from: legacy)
        #expect(store.load() == calibration())
        #expect(legacy.load() == nil)
    }

    // MARK: Quick mode

    @Test func quickModeIsOneMoveAndRetryKeepsIt() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let (controller, store) = makeController(manager)
        // Nothing stored: quick falls back to the full two-move calibration.
        controller.startQuick()
        #expect(!controller.isQuick)
        #expect(controller.moveCount == 2)
        controller.cancel()

        store.save(calibration())
        controller.reloadFromStore()
        controller.startQuick()
        #expect(controller.isQuick)
        #expect(controller.moveCount == 1)
        #expect(controller.prompt == .centerStar)
        #expect(controller.screen == .pickStar)
        controller.retry()
        #expect(controller.isQuick && controller.moveCount == 1)
        controller.start()
        #expect(!controller.isQuick && controller.moveCount == 2)
    }

    @Test func startScreenQuickChoiceStartsQuickOnlyWithCalibration() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let (controller, store) = makeController(manager)
        manager.onQuickCalibrate = { controller.startQuick() }
        manager.onRecalibrate = { controller.start() }
        manager.onActivate = { _ in controller.reloadFromStore() }
        manager.activate(id: manager.profiles[0].id)
        #expect(manager.start(.quickCalibrate) == .recalibrate)
        #expect(controller.moveCount == 2)

        store.save(calibration())
        controller.reloadFromStore()
        #expect(manager.start(.quickCalibrate) == .quickCalibrate)
        #expect(controller.isQuick)
    }

    // MARK: Profile switch

    @Test func switchingProfileLoadsItsCalibrationAndSuggestsQuick() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let (controller, store) = makeController(manager)
        var activated: [SetupProfile] = []
        manager.onActivate = { profile in
            activated.append(profile)
            controller.reloadFromStore()
        }
        let a = manager.profiles[0].id
        let b = manager.profiles[1].id
        manager.activate(id: a)
        #expect(manager.suggestion == nil)
        store.save(calibration(rotation: 0.3, center: Vec2(800, 600)))
        controller.reloadFromStore()

        manager.activate(id: b)
        #expect(controller.calibration == nil)
        #expect(manager.suggestion == .full)
        store.save(calibration(rotation: 2.0, center: Vec2(1000, 760)))
        #expect(manager.suggestion == nil)

        manager.activate(id: a)
        #expect(controller.calibration?.displayRotation == 0.3)
        #expect(activated.last?.opticalCenter == Vec2(800, 600))
        #expect(manager.suggestion == .quick)
        _ = manager.start(.quickCalibrate)
        #expect(manager.suggestion == nil)
    }

    @Test func switchingProfileAbortsRunningCalibration() {
        let manager = ProfileManager(store: InMemoryProfileStore())
        let (controller, _) = makeController(manager)
        manager.activate(id: manager.profiles[0].id)
        controller.start()
        #expect(controller.isRunning)
        controller.reloadFromStore()
        #expect(!controller.isRunning)
        #expect(!controller.panelVisible)
    }
}
