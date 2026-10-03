import Foundation
import Testing
import TeleskooppiCore
@testable import Teleskooppikamera

// Phase 5 tests: calibration screen mapping, guidance glyphs, fade state, persistence.

private func sampleResult(orthogonality: Double = 0.02, quality: CalibrationQuality = .good) -> CalibrationResult {
    CalibrationResult(
        stickToImage: Mat2(columns: Vec2(-12, 1), Vec2(0.5, 14)), displayRotation: 0.61, mirrored: false,
        orthogonalityError: orthogonality, lineResidual: 0.4, opticalCenter: Vec2(100, 80),
        fieldRadius: 160, driftVelocity: Vec2(0.1, -0.2), quality: quality,
        createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
    )
}

/// Stick right -> image left, stick up -> image down: the calibrated, unmirrored telescope.
private let calibratedM = Mat2(columns: Vec2(-1, 0), Vec2(0, 1))

private final class MemoryStore: CalibrationPersisting {
    var stored: CalibrationResult?
    func load() -> CalibrationResult? { stored }
    func save(_ calibration: CalibrationResult?) { stored = calibration }
}

struct Phase5Tests {
    // MARK: Prompt -> screen

    @Test func promptsMapToScreens() {
        let map = CalibrationScreenMapper.self
        #expect(map.screen(for: nil, starSelected: false, stopAcknowledged: false) == .intro)
        #expect(map.screen(for: .centerStar, starSelected: false, stopAcknowledged: false) == .pickStar)
        #expect(map.screen(for: .centerStar, starSelected: true, stopAcknowledged: false) == .centerStar)
        #expect(map.screen(for: .holdStill, starSelected: true, stopAcknowledged: false) == .holdStill)
        #expect(map.screen(for: .pressAndHold(.up), starSelected: true, stopAcknowledged: false) == .press(.up))
        #expect(map.screen(for: .stop, starSelected: true, stopAcknowledged: false) == .stop)
        #expect(map.screen(for: .stop, starSelected: true, stopAcknowledged: true) == .release)
        #expect(map.screen(for: .releaseAndWait, starSelected: true, stopAcknowledged: false) == .release)
        #expect(map.screen(for: .done(sampleResult()), starSelected: true, stopAcknowledged: false) == .result)
        #expect(map.screen(for: .failed(.nearEdge), starSelected: true, stopAcknowledged: false) == .failure)
    }

    @Test func qualityLevels() {
        #expect(CalibrationScreenMapper.qualityLevel(for: sampleResult(orthogonality: AngleMath.radians(2))) == .green)
        #expect(CalibrationScreenMapper.qualityLevel(for: sampleResult(orthogonality: AngleMath.radians(6))) == .yellow)
        #expect(CalibrationScreenMapper.qualityLevel(for: sampleResult(orthogonality: AngleMath.radians(12))) == .red)
        let warned = sampleResult(orthogonality: AngleMath.radians(1), quality: .warning)
        #expect(CalibrationScreenMapper.qualityLevel(for: warned) == .yellow)
    }

    @Test func hardwareTriggerActions() {
        typealias T = CalibrationTriggerAction
        #expect(T.action(prompt: nil, panelVisible: false, stopAcknowledged: false) == .startCalibration)
        #expect(T.action(prompt: nil, panelVisible: true, stopAcknowledged: false) == .startCalibration)
        #expect(T.action(prompt: .stop, panelVisible: true, stopAcknowledged: false) == .acknowledgeStop)
        #expect(T.action(prompt: .stop, panelVisible: true, stopAcknowledged: true) == .none)
        #expect(T.action(prompt: .pressAndHold(.up), panelVisible: true, stopAcknowledged: false) == .none)
        #expect(T.action(prompt: .done(sampleResult()), panelVisible: true, stopAcknowledged: false) == .accept)
        #expect(T.action(prompt: .failed(.timeout), panelVisible: true, stopAcknowledged: false) == .retry)
    }

    // MARK: Arrow glyphs

    @Test func eightDirectionsWindowAndInverted() {
        let center = Vec2(100, 100)
        for arrow in StickDir8.allCases {
            // The star is where the arrow points on screen (window convention, D-09).
            let star = center + arrow.screenVector * 20

            var window = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 3, convention: .window))
            let w = window.guide(target: star, center: center, stickToImage: calibratedM)
            #expect(w.arrow == arrow)

            var inverted = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 3, convention: .inverted))
            let i = inverted.guide(target: star, center: center, stickToImage: calibratedM)
            #expect(i.arrow == StickDir8(rawValue: (arrow.rawValue + 4) % 8))
        }
    }

    @Test func labelsAndRotation() {
        #expect(GuidanceText.label(for: .left) == "TATTI ←")
        #expect(GuidanceText.label(for: .upLeft) == "TATTI ↖")
        #expect(GuidanceText.label(for: .downRight) == "TATTI ↘")
        #expect(abs(GuidanceText.screenRotationDegrees(for: .up)) < 1e-6)
        #expect(abs(GuidanceText.screenRotationDegrees(for: .right) - 90) < 1e-6)
        #expect(abs(GuidanceText.screenRotationDegrees(for: .left) + 90) < 1e-6)
        #expect(abs(abs(GuidanceText.screenRotationDegrees(for: .down)) - 180) < 1e-6)
        #expect(GuidanceText.format(2.34) == "2,3")
    }

    @Test func secondsText() {
        var engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 3))
        let out = engine.guide(target: Vec2(100 - 30, 100), center: Vec2(100, 100), stickToImage: calibratedM)
        #expect(out.arrow == .left)
        #expect(GuidanceText.seconds(for: out, arrow: .left) == "30,0 s")
    }

    // MARK: Fade and hysteresis

    @Test func okFadesAndToleranceHasHysteresis() {
        let center = Vec2(100, 100)
        var engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 3))
        var state = GuidanceDisplayState()

        let far = engine.guide(target: center + Vec2(-30, 0), center: center, stickToImage: calibratedM)
        state.update(output: far, calibrated: true, now: 0)
        #expect(state.mode == .arrow(.left))
        #expect(state.opacity(now: 0) == GuidanceDisplayState.arrowOpacity)

        let inside = engine.guide(target: center + Vec2(-2, 0), center: center, stickToImage: calibratedM)
        state.update(output: inside, calibrated: true, now: 1)
        #expect(state.mode == .ok)
        #expect(state.opacity(now: 1) == 1)
        #expect(state.opacity(now: 1 + GuidanceDisplayState.okHold) == 1)
        let resting = state.opacity(now: 1 + GuidanceDisplayState.okHold + GuidanceDisplayState.okFade + 1)
        #expect(abs(resting - GuidanceDisplayState.okRestingOpacity) < 1e-9)

        // Between r_ok (3) and 1.5 r_ok (4.5) the OK state is kept.
        let wobble = engine.guide(target: center + Vec2(-4, 0), center: center, stickToImage: calibratedM)
        state.update(output: wobble, calibrated: true, now: 2)
        #expect(state.mode == .ok)
        let out = engine.guide(target: center + Vec2(-6, 0), center: center, stickToImage: calibratedM)
        state.update(output: out, calibrated: true, now: 3)
        #expect(state.mode == .arrow(.left))
    }

    @Test func lostStarGraceThenAxisMarkersAndHiddenWhenUncalibrated() {
        let center = Vec2(100, 100)
        var engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 3))
        var state = GuidanceDisplayState()
        let far = engine.guide(target: center + Vec2(0, -30), center: center, stickToImage: calibratedM)
        state.update(output: far, calibrated: true, now: 10)
        #expect(state.mode == .arrow(.up))
        state.update(output: nil, calibrated: true, now: 10.3)
        #expect(state.mode == .arrow(.up))
        state.update(output: nil, calibrated: true, now: 11)
        #expect(state.mode == .noStar)
        state.update(output: nil, calibrated: false, now: 12)
        #expect(state.mode == .hidden)
        #expect(state.opacity(now: 12) == 0)
    }

    // MARK: Persistence and controller

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "tk-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCalibrationStore(defaults: defaults)
        #expect(store.load() == nil)
        let result = sampleResult()
        store.save(result)
        #expect(store.load() == result)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test func appliedCalibrationClearsManualFlag() {
        var settings = DisplaySettings()
        settings.rotationDegrees = 35
        #expect(settings.isManual)
        settings.appliedCalibration = AppliedCalibration(rotationDegrees: 35, mirrored: false)
        #expect(!settings.isManual)
        settings.rotationDegrees = 40
        #expect(settings.isManual)
        settings.rotationDegrees = -325
        settings.appliedCalibration = AppliedCalibration(rotationDegrees: 35, mirrored: false)
        #expect(!settings.isManual)
    }

    @MainActor
    @Test func controllerStartsCancelsAndPersistsConvention() throws {
        let suite = "tk-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryStore()
        store.stored = sampleResult()
        let controller = CalibrationController(store: store, feedback: SilentCalibrationFeedback(), defaults: defaults)

        #expect(controller.calibration == sampleResult())
        #expect(!controller.panelVisible)
        controller.hardwareTrigger()
        #expect(controller.panelVisible)
        #expect(controller.prompt == .centerStar)
        #expect(controller.screen == .pickStar)
        controller.hardwareTrigger()
        #expect(controller.prompt == .centerStar)
        controller.cancel()
        #expect(!controller.panelVisible)
        #expect(controller.prompt == nil)

        controller.setInverted(true)
        #expect(defaults.bool(forKey: CalibrationController.invertedKey))
        controller.forgetCalibration()
        #expect(store.stored == nil)
        #expect(!controller.needsDetection)
    }
}
