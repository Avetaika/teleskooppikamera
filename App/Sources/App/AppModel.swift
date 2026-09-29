import CoreGraphics
import Foundation
import Observation
import QuartzCore
import SwiftUI
import TeleskooppiCore

/// Receives frames from the active source on its own queue: feeds the renderer and the
/// performance counters, and reports image size changes to the main actor.
final class FrameSink: @unchecked Sendable {
    private let renderer: FrameRenderer?
    private let monitor: PerformanceMonitor
    private let onSizeChange: @Sendable (CGSize) -> Void
    private let lock = NSLock()
    private var lastSize = CGSize.zero

    init(renderer: FrameRenderer?, monitor: PerformanceMonitor, onSizeChange: @escaping @Sendable (CGSize) -> Void) {
        self.renderer = renderer
        self.monitor = monitor
        self.onSizeChange = onSizeChange
    }

    func receive(_ frame: Frame) {
        monitor.frameArrived(at: CACurrentMediaTime())
        renderer?.submit(frame)
        let size = CGSize(width: frame.width, height: frame.height)
        let changed = lock.withLock { () -> Bool in
            guard size != lastSize else { return false }
            lastSize = size
            return true
        }
        if changed { onSizeChange(size) }
    }

    func resetSize() {
        lock.withLock { lastSize = .zero }
    }
}

/// Device state shown in the dev menu performance overlay.
struct DeviceStatus: Equatable, Sendable {
    var thermalState = "nominal"
    var batteryLevel: Float = -1
    var batteryState = "unknown"
    var lowPowerMode = false
}

/// Main-actor state of the app: source selection, display settings, sun reminder, performance
/// and the phase 0 capability report.
@MainActor
@Observable
final class AppModel {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case running
        case denied
        case unavailable(String)
    }

    struct SavedReport: Equatable {
        var url: URL?
        var text: String
    }

    // Camera and source
    private(set) var cameraState: CameraState = .idle
    private(set) var sourceKind: FrameSourceKind = .camera
    private(set) var isSourceRunning = false
    /// Size of the frames in image pixels (native buffer orientation, D-05).
    private(set) var imageSize = CGSize(width: 1920, height: 1440)

    // Display and safety
    private(set) var display: DisplaySettings
    private(set) var sun = SunReminder()

    // Diagnostics
    private(set) var performance = PerformanceSnapshot()
    private(set) var deviceStatus = DeviceStatus()
    private(set) var syntheticRenderMilliseconds = 0.0
    private(set) var captureEventCount = 0

    // Capability report (phase 0)
    private(set) var isGeneratingReport = false
    private(set) var lastReport: SavedReport?
    private(set) var reportError: String?

    let camera: CameraService
    let syntheticSource: SyntheticFrameSource
    let renderer: FrameRenderer?
    let controls: CameraControlModel

    private let cameraSource: CameraFrameSource
    private let monitor: PerformanceMonitor
    private let sink: FrameSink
    private let brightness = BrightnessController()
    private var ticker: Task<Void, Never>?
    private var isStartingSource = false
    private let log = AppLog.app

    init() {
        let monitor = PerformanceMonitor()
        self.monitor = monitor
        let renderer = AppInfo.isRunningTests ? nil : FrameRenderer(performance: monitor)
        let camera = CameraService()
        let box = SizeCallbackBox()

        self.camera = camera
        self.cameraSource = CameraFrameSource(service: camera)
        self.syntheticSource = SyntheticFrameSource()
        self.renderer = renderer
        self.controls = CameraControlModel(camera: camera)
        self.display = DisplaySettings.load()
        self.sink = FrameSink(renderer: renderer, monitor: monitor) { size in box.call(size) }

        box.set { [weak self] size in
            Task { @MainActor in self?.frameSizeChanged(size) }
        }
        let sink = self.sink
        cameraSource.setFrameHandler { sink.receive($0) }
        syntheticSource.setFrameHandler { sink.receive($0) }
        camera.setDropHandler { monitor.frameDropped() }
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: - Sources

    func startCurrentSource() async {
        guard !AppInfo.isRunningTests else {
            cameraState = .unavailable("unit tests")
            return
        }
        guard !isStartingSource else { return }
        isStartingSource = true
        defer { isStartingSource = false }

        switch sourceKind {
        case .camera:
            await startCamera()
        case .synthetic:
            do {
                try await syntheticSource.start()
                isSourceRunning = true
                log.notice("Synthetic source started")
            } catch {
                log.error("Synthetic source failed: \(error.localizedDescription)")
            }
        }
    }

    func stopCurrentSource() async {
        switch sourceKind {
        case .camera:
            guard cameraState == .running else { return }
            await cameraSource.stop()
            cameraState = .idle
        case .synthetic:
            await syntheticSource.stop()
        }
        isSourceRunning = false
    }

    func selectSource(_ kind: FrameSourceKind) async {
        guard kind != sourceKind else { return }
        await stopCurrentSource()
        sink.resetSize()
        sourceKind = kind
        log.notice("Frame source: \(kind.rawValue)")
        await startCurrentSource()
    }

    private func startCamera() async {
        // `.task` and the scene phase change can both call this at launch.
        guard cameraState != .requestingPermission else { return }
        switch CameraService.authorization {
        case .authorized:
            break
        case .denied:
            cameraState = .denied
            log.notice("Camera permission denied")
            return
        case .notDetermined:
            cameraState = .requestingPermission
            let granted = await CameraService.requestAccess()
            log.notice("Camera permission request: granted=\(granted)")
            guard granted else {
                cameraState = .denied
                return
            }
        }
        do {
            try await cameraSource.start()
            cameraState = .running
            isSourceRunning = true
            await controls.applyAll()
        } catch {
            log.error("Camera start failed: \(error.localizedDescription)")
            cameraState = .unavailable(error.localizedDescription)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            brightness.reapply()
            if let value = display.brightness { brightness.setOverride(value) }
            startTicker()
            Task { await startCurrentSource() }
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            brightness.restore()
            stopTicker()
            Task { await stopCurrentSource() }
        default:
            break
        }
    }

    // MARK: - Display

    /// Applies `change` to the display settings, normalizes and persists them.
    func updateDisplay(_ change: (inout DisplaySettings) -> Void) {
        var next = display
        change(&next)
        next.normalizeStretch()
        guard next != display else { return }
        let brightnessChanged = next.brightness != display.brightness
        display = next
        next.save()
        if brightnessChanged { brightness.setOverride(next.brightness) }
    }

    /// Long-press handler: the touched image point becomes the optical center (D-17).
    func setOpticalCenter(atScreen point: CGPoint, viewSize: CGSize) {
        let size = imageSize
        updateDisplay { $0.setOpticalCenter(atScreen: point, imageSize: size, viewSize: viewSize) }
        log.notice("Optical center set to \(display.opticalCenter.map { "\($0)" } ?? "image center")")
    }

    var systemBrightness: Double { brightness.currentBrightness }

    func transform(viewSize: CGSize) -> DisplayTransform {
        display.transform(imageSize: imageSize, viewSize: viewSize)
    }

    func renderParams(viewSize: CGSize) -> RenderParams {
        RenderMath.params(
            transform: transform(viewSize: viewSize), viewSize: viewSize,
            blackPoint: display.blackPoint, whitePoint: display.whitePoint,
            gamma: display.gamma, redMode: display.redMode
        )
    }

    private func frameSizeChanged(_ size: CGSize) {
        guard size != imageSize else { return }
        log.notice("Frame size: \(Int(size.width))x\(Int(size.height))")
        imageSize = size
        // A stored optical center from a differently sized source may lie outside the image.
        if let center = display.opticalCenter,
           center.x > Double(size.width) - 1 || center.y > Double(size.height) - 1 {
            updateDisplay { $0.resetOpticalCenter() }
        }
    }

    // MARK: - Synthetic source

    func setStick(_ value: Vec2) {
        syntheticSource.setStick(value)
    }

    // MARK: - Hardware buttons

    /// Placeholder for the volume / Camera Control / AirPods click events (D-18). Calibration
    /// will use this later as "calibrate / next / acknowledge STOP".
    func handleCaptureEvent(phaseRawValue: Int, isEnd: Bool) {
        captureEventCount += 1
        log.notice("Capture event: phase=\(phaseRawValue) end=\(isEnd) total=\(captureEventCount) (placeholder, D-18)")
    }

    // MARK: - Periodic refresh

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(iteration)
                iteration += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick(_ iteration: Int) async {
        if iteration % 60 == 0 { sun = SunReminder() }
        performance = monitor.snapshot(now: CACurrentMediaTime())
        syntheticRenderMilliseconds = syntheticSource.renderMilliseconds
        deviceStatus = Self.readDeviceStatus()
        if sourceKind == .camera, cameraState == .running {
            await controls.refresh()
        }
    }

    func resetMaximumLatency() {
        monitor.resetMaximum()
    }

    private static func readDeviceStatus() -> DeviceStatus {
        let device = UIDevice.current
        return DeviceStatus(
            thermalState: CaptureFormatting.thermalState(ProcessInfo.processInfo.thermalState),
            batteryLevel: device.batteryLevel,
            batteryState: {
                switch device.batteryState {
                case .unplugged: "unplugged"
                case .charging: "charging"
                case .full: "full"
                case .unknown: "unknown"
                @unknown default: "other"
                }
            }(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    // MARK: - Capability report (phase 0)

    /// Runs the capability probe (about 5–10 s, including the 1 s exposure test) and writes
    /// `Documents/capability-<timestamp>.txt`.
    func generateReport() async {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        reportError = nil
        defer { isGeneratingReport = false }

        if sourceKind != .camera { await selectSource(.camera) }
        log.notice("Capability report started")
        let context = DeviceContext.current()
        let report = await CapabilityProbe.run(camera: camera, context: context)
        // The probe changes the active format and exposure: restore the live view configuration.
        await camera.reconfigure()
        let text = report.rendered()
        let url = AppFiles.documents.appending(path: CapabilityReport.fileName(for: report.createdAt))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastReport = SavedReport(url: url, text: text)
            log.notice("Capability report written: \(url.lastPathComponent) (\(text.utf8.count) bytes)")
        } catch {
            reportError = error.localizedDescription
            lastReport = SavedReport(url: nil, text: text)
            log.error("Capability report write failed: \(error.localizedDescription)")
        }
    }
}

/// Lets `FrameSink` (created before `self` exists) call back into the model later.
private final class SizeCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (CGSize) -> Void)?

    func set(_ callback: @escaping @Sendable (CGSize) -> Void) {
        lock.withLock { self.callback = callback }
    }

    func call(_ size: CGSize) {
        let callback = lock.withLock { self.callback }
        callback?(size)
    }
}
