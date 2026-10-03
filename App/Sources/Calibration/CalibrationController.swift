import CoreGraphics
import Foundation
import Observation
import QuartzCore
import TeleskooppiCore

/// Geometry the calibration and guidance need from the app model.
struct CalibrationContext: Equatable {
    var imageSize: CGSize
    var opticalCenter: Vec2
    /// True for the synthetic sky: the star nearest the crosshair is picked automatically.
    var isSynthetic = false

    /// Radius of the eyepiece circle in image pixels (it is about as tall as the image, D-14).
    var fieldRadius: Double { 0.46 * Double(min(imageSize.width, imageSize.height)) }
}

/// Drives the calibration state machine from tracker output, publishes the prompts for the UI and
/// computes guidance once a calibration exists (phase 5). All logic is in Core; this is glue.
@MainActor
@Observable
final class CalibrationController {
    static let invertedKey = "guidance.inverted.v1"

    // Published state
    private(set) var prompt: CalibrationPrompt?
    private(set) var progress = 0.0
    private(set) var moveIndex = 0
    private(set) var stopAcknowledged = false
    private(set) var starSelected = false
    private(set) var panelVisible = false
    private(set) var calibration: CalibrationResult?
    /// True while a one-move quick calibration (D-06) is running or was the last one started.
    private(set) var isQuick = false
    private(set) var guidanceState = GuidanceDisplayState()
    private(set) var lastGuidance: GuidanceOutput?
    /// Convention setting (D-09): arrow flipped when true.
    private(set) var invertedConvention: Bool

    func setInverted(_ inverted: Bool) {
        guard inverted != invertedConvention else { return }
        invertedConvention = inverted
        defaults.set(inverted, forKey: Self.invertedKey)
        engine.config.convention = inverted ? .inverted : .window
        engine.reset()
        guidanceState = GuidanceDisplayState()
    }

    // Wiring (set by AppModel)
    @ObservationIgnored var contextProvider: @MainActor () -> CalibrationContext = {
        CalibrationContext(imageSize: CGSize(width: 1920, height: 1440), opticalCenter: Vec2(959.5, 719.5))
    }
    /// Selects the star nearest to a point in binned coordinates; `nil` clears the selection.
    @ObservationIgnored var selectStar: @MainActor (Vec2?) -> Void = { _ in }
    /// Called when the need for star detection may have changed.
    @ObservationIgnored var detectionNeedChanged: @MainActor () -> Void = {}
    /// Called with a new calibration so the display can rotate to it (animated).
    /// Name of the profile being calibrated, shown in the result and failure cards.
    @ObservationIgnored var profileNameProvider: @MainActor () -> String? = { nil }
    @ObservationIgnored var applyToDisplay: @MainActor (CalibrationResult) -> Void = { _ in }

    @ObservationIgnored private var session: CalibrationSession?
    @ObservationIgnored private var engine: GuidanceEngine
    @ObservationIgnored private var engineRadius = 0.0
    @ObservationIgnored private let store: CalibrationPersisting
    @ObservationIgnored private let feedback: CalibrationFeedbackProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastAutoSelect = -Double.infinity

    init(store: CalibrationPersisting = UserDefaultsCalibrationStore(),
         feedback: CalibrationFeedbackProviding? = nil,
         defaults: UserDefaults = .standard) {
        self.store = store
        self.feedback = feedback ?? DeviceCalibrationFeedback()
        self.defaults = defaults
        let inverted = defaults.bool(forKey: Self.invertedKey)
        self.invertedConvention = inverted
        self.engine = GuidanceEngine(config: GuidanceConfig(toleranceRadius: 10, convention: inverted ? .inverted : .window))
        self.calibration = store.load()
    }

    // MARK: - Derived state

    var isRunning: Bool {
        guard session != nil, let prompt else { return session != nil }
        return !prompt.isTerminal
    }

    /// Detection must run while calibrating or when guidance is active.
    var needsDetection: Bool { session != nil || calibration != nil }

    var screen: CalibrationScreen {
        CalibrationScreenMapper.screen(for: prompt, starSelected: starSelected, stopAcknowledged: stopAcknowledged)
    }

    var moveCount: Int { session?.moves.count ?? 2 }

    // MARK: - Commands

    func showPanel() {
        panelVisible = true
        detectionNeedChanged()
    }

    var profileName: String? { profileNameProvider() }

    /// Full two-move calibration (UP, RIGHT).
    func start() {
        begin(quick: false)
    }

    /// One-move calibration (UP only) against the stored calibration (D-06). Falls back to the full
    /// calibration when there is nothing to build on.
    func startQuick() {
        begin(quick: calibration != nil)
    }

    /// Reloads the active profile's calibration (after a profile switch). Aborts a running session.
    func reloadFromStore() {
        if session != nil || panelVisible { cancel() }
        calibration = store.load()
        resetGuidance()
        detectionNeedChanged()
    }

    private func begin(quick: Bool) {
        let context = contextProvider()
        let config = CalibrationConfig(opticalCenter: context.opticalCenter, fieldRadius: context.fieldRadius)
        if quick, let previous = calibration {
            session = CalibrationSession(config: config, mode: .quick(previous: previous))
            isQuick = true
        } else {
            session = CalibrationSession(config: config)
            isQuick = false
        }
        prompt = .centerStar
        progress = 0
        moveIndex = 0
        stopAcknowledged = false
        starSelected = false
        panelVisible = true
        detectionNeedChanged()
    }

    func cancel() {
        session = nil
        prompt = nil
        progress = 0
        stopAcknowledged = false
        panelVisible = false
        selectStar(nil)
        detectionNeedChanged()
    }

    /// Result accepted: close the panel and keep the star selection for guidance.
    func accept() {
        session = nil
        prompt = nil
        panelVisible = false
        resetGuidance()
        detectionNeedChanged()
    }

    func retry() {
        begin(quick: isQuick)
    }

    func acknowledgeStop() {
        stopAcknowledged = true
    }

    func forgetCalibration() {
        calibration = nil
        store.save(nil)
        resetGuidance()
        detectionNeedChanged()
    }

    /// Hardware button (volume, Camera Control, AirPods): calibrate / next / acknowledge (D-18).
    func hardwareTrigger() {
        switch CalibrationTriggerAction.action(
            prompt: prompt, panelVisible: panelVisible, stopAcknowledged: stopAcknowledged
        ) {
        case .startCalibration: start()
        case .acknowledgeStop: acknowledgeStop()
        case .accept: accept()
        case .retry: retry()
        case .none: break
        }
    }

    // MARK: - Tracker input

    /// One analysed frame. Feeds the calibration while it runs, guidance otherwise.
    func receive(_ analysis: StarAnalysisResult) {
        let position = analysis.star.map { analysis.geometry.binnedToImage($0.position) }
        let selected = analysis.trackState != nil
        if starSelected != selected, session != nil { starSelected = selected }

        if var current = session, !(prompt?.isTerminal ?? false) {
            if !selected {
                autoSelectIfWanted(analysis)
                return
            }
            let sample = position.map { TrackSample(t: analysis.frameTime, p: $0) }
            let next = current.feed(sample, at: analysis.frameTime)
            session = current
            apply(next, progress: current.progress, moveIndex: current.moveIndex)
            return
        }
        guard session == nil else { return }
        updateGuidance(position: position, time: analysis.frameTime)
    }

    private func autoSelectIfWanted(_ analysis: StarAnalysisResult) {
        let context = contextProvider()
        guard context.isSynthetic, prompt == .centerStar else { return }
        let now = CACurrentMediaTime()
        guard now - lastAutoSelect > 1 else { return }
        lastAutoSelect = now
        let center = analysis.geometry.imageToBinned(context.opticalCenter)
        let best = analysis.candidates.min { ($0.position - center).length < ($1.position - center).length }
        if let best { selectStar(best.position) }
    }

    private func apply(_ next: CalibrationPrompt, progress newProgress: Double, moveIndex newMove: Int) {
        if abs(newProgress - progress) > 0.01 { progress = newProgress }
        if newMove != moveIndex { moveIndex = newMove }
        guard next != prompt else { return }
        let previous = prompt
        prompt = next
        switch next {
        case .stop:
            stopAcknowledged = false
            feedback.stopSignal()
        case .done(let result):
            feedback.success()
            finish(with: result)
        case .failed:
            feedback.failure()
            selectStar(nil)
        default:
            if case .stop = previous { stopAcknowledged = false }
        }
    }

    private func finish(with result: CalibrationResult) {
        calibration = result
        store.save(result)
        applyToDisplay(result)
        resetGuidance()
    }

    // MARK: - Guidance

    private func resetGuidance() {
        engine.reset()
        guidanceState = GuidanceDisplayState()
        lastGuidance = nil
    }

    private func updateGuidance(position: Vec2?, time: Double) {
        guard let calibration else {
            if guidanceState.mode != .hidden { guidanceState = GuidanceDisplayState() }
            return
        }
        let context = contextProvider()
        if engineRadius != context.fieldRadius {
            engineRadius = context.fieldRadius
            var config = GuidanceConfig.defaults(fieldRadius: context.fieldRadius)
            config.convention = invertedConvention ? .inverted : .window
            engine = GuidanceEngine(config: config)
        }
        var output: GuidanceOutput?
        if let position {
            output = engine.guide(target: position, center: context.opticalCenter, calibration: calibration)
        }
        var next = guidanceState
        // Wall clock, not the frame time: replayed sessions carry their own timestamps.
        next.update(output: output, calibrated: true, now: CACurrentMediaTime())
        if next != guidanceState { guidanceState = next }
        if let output {
            lastGuidance = output
        } else if lastGuidance != nil, next.mode == .noStar {
            lastGuidance = nil
        }
    }
}
