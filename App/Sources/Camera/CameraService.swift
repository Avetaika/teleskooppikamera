import AVFoundation
import CoreMedia
import ImageIO

enum CameraAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "Takakameraa (laajakulma) ei löytynyt.")
        case .cannotAddInput: String(localized: "Kameraa ei voitu liittää kuvausistuntoon.")
        }
    }
}

/// Receives sample buffers from `AVCaptureVideoDataOutput` on the frame queue and forwards them
/// as `Frame`s.
final class VideoFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Frame) -> Void)?
    private var onDrop: (@Sendable () -> Void)?

    func setHandler(_ handler: (@Sendable (Frame) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func setDropHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { self.onDrop = handler }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = lock.withLock { self.handler }
        guard let handler else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var frame = Frame(pixelBuffer: pixelBuffer, timestamp: pts)
        let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any]
        frame.exposureSeconds = exif?[kCGImagePropertyExifExposureTime as String] as? Double
        if let speeds = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let first = speeds.first {
            frame.iso = Float(first)
        }
        handler(frame)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let onDrop = lock.withLock { self.onDrop }
        onDrop?()
    }
}

/// Owns the `AVCaptureSession` for the physical back wide-angle camera (D-14).
///
/// Threading: every access to the session, the device and the outputs happens on the private
/// serial `queue` (wrapped in async functions for callers). Frames are delivered on `frameQueue`.
final class CameraService: @unchecked Sendable {
    let session = AVCaptureSession()
    let frameDelegate = VideoFrameDelegate()

    private let queue = DispatchQueue(label: "fi.avetaika.teleskooppikamera.camera-session")
    private let frameQueue = DispatchQueue(label: "fi.avetaika.teleskooppikamera.camera-frames", qos: .userInteractive)
    private let log = AppLog.camera

    // Queue-confined state.
    private var device: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var observers: [NSObjectProtocol] = []
    private var currentExposure: ExposureControl = .auto
    private var currentFocus: FocusControl = .auto

    init() {
        observeSessionNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Permission

    static var authorization: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Lifecycle

    /// Configures the session on first use and starts it. Safe to call repeatedly.
    func start() async throws {
        try await onQueueThrowing {
            try self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
                self.log.notice("Session started (running=\(self.session.isRunning))")
            }
        }
    }

    func stop() async {
        await onQueue {
            if self.session.isRunning {
                self.session.stopRunning()
                self.log.notice("Session stopped")
            }
        }
    }

    /// Re-applies the base device configuration (format, HDR off, tone mapping) and the last
    /// exposure/focus request. Needed after `CapabilityProbe`, which changes the active format.
    func reconfigure() async {
        await onQueue {
            guard let device = self.device else { return }
            self.applyBaseDeviceConfiguration(device)
            self.applyExposureOnQueue(self.currentExposure, device: device)
            self.applyFocusOnQueue(self.currentFocus, device: device)
        }
    }

    /// Runs `body` on the session queue with the configured session, device and photo output.
    /// Used by `CapabilityProbe`; later phases will add dedicated APIs instead.
    func withConfiguredDevice<T: Sendable>(
        _ body: @escaping @Sendable (AVCaptureSession, AVCaptureDevice, AVCapturePhotoOutput) throws -> T
    ) async throws -> T {
        try await onQueueThrowing {
            try self.configureIfNeeded()
            guard let device = self.device else { throw CameraError.noCamera }
            return try body(self.session, device, self.photoOutput)
        }
    }

    // MARK: - Frames

    func setFrameHandler(_ handler: (@Sendable (Frame) -> Void)?) {
        frameDelegate.setHandler(handler)
    }

    func setDropHandler(_ handler: (@Sendable () -> Void)?) {
        frameDelegate.setDropHandler(handler)
    }

    // MARK: - Controls

    func applyExposure(_ control: ExposureControl) async {
        await onQueue {
            self.currentExposure = control
            guard let device = self.device else { return }
            self.applyExposureOnQueue(control, device: device)
        }
    }

    /// Fire-and-forget variants for UI callers. `queue.async` is enqueued synchronously, so rapid
    /// slider changes reach the device in order (separate `Task`s would not guarantee that).
    func submitExposure(_ control: ExposureControl) {
        queue.async {
            self.currentExposure = control
            guard let device = self.device else { return }
            self.applyExposureOnQueue(control, device: device)
        }
    }

    func submitFocus(_ control: FocusControl) {
        queue.async {
            self.currentFocus = control
            guard let device = self.device else { return }
            self.applyFocusOnQueue(control, device: device)
        }
    }

    func applyFocus(_ control: FocusControl) async {
        await onQueue {
            self.currentFocus = control
            guard let device = self.device else { return }
            self.applyFocusOnQueue(control, device: device)
        }
    }

    /// Autofocus once, read the lens position and lock it. The caller should point the camera at
    /// a distant target (or a star through the eyepiece). Returns the lens position, or `nil`.
    func calibrateInfinity() async -> Float? {
        let started = await onQueue { () -> Bool in
            guard let device = self.device, device.isFocusModeSupported(.autoFocus) else { return false }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                device.focusMode = .autoFocus
                return true
            } catch {
                self.log.error("Infinity calibration: lockForConfiguration failed: \(error.localizedDescription)")
                return false
            }
        }
        guard started else { return nil }

        // Wait for the focus search to start and finish (at most about 8 s).
        for iteration in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            let adjusting = await onQueue { self.device?.isAdjustingFocus ?? false }
            if iteration >= 3, !adjusting { break }
        }

        let position = await onQueue { () -> Float? in
            guard let device = self.device else { return nil }
            let position = device.lensPosition
            self.currentFocus = .manual(lensPosition: position)
            self.applyFocusOnQueue(self.currentFocus, device: device)
            return position
        }
        log.notice("Infinity calibration: lensPosition=\(position.map { String(format: "%.4f", $0) } ?? "n/a")")
        return position
    }

    func readout() async -> CameraReadout? {
        await onQueue { () -> CameraReadout? in
            guard let device = self.device else { return nil }
            let format = device.activeFormat
            let ranges = format.videoSupportedFrameRateRanges
            return CameraReadout(
                exposureSeconds: device.exposureDuration.seconds,
                iso: device.iso,
                lensPosition: device.lensPosition,
                limits: ExposureLimits(
                    minDuration: format.minExposureDuration.seconds,
                    maxDuration: format.maxExposureDuration.seconds,
                    minISO: format.minISO,
                    maxISO: format.maxISO
                ),
                longestFrameDuration: ranges.map { $0.maxFrameDuration.seconds }.max() ?? 0,
                activeMaxFrameDuration: device.activeVideoMaxFrameDuration.seconds,
                isAdjustingExposure: device.isAdjustingExposure,
                isAdjustingFocus: device.isAdjustingFocus,
                pressureLevel: device.systemPressureState.level.rawValue,
                formatSummary: Self.summary(of: format),
                supportsCustomLensPosition: device.isLockingFocusWithCustomLensPositionSupported
            )
        }
    }

    // MARK: - Configuration (queue only)

    private func configureIfNeeded() throws {
        guard device == nil else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        // The format is chosen by hand below (D-14), not by a preset.
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(frameDelegate, queue: frameQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            log.error("Cannot add AVCaptureVideoDataOutput")
        }

        // The photo output is only needed to query RAW/bracketing capabilities (capability report).
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else {
            log.error("Cannot add AVCapturePhotoOutput")
        }
        session.commitConfiguration()

        device = camera
        configureVideoConnection()
        applyBaseDeviceConfiguration(camera)
        log.notice("Configured \(camera.localizedName) (\(camera.deviceType.rawValue)), \(camera.formats.count) formats")
    }

    /// Connection rotation 0 = native buffer orientation (D-05), no mirroring, no stabilization.
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else {
            log.error("No video connection on the data output")
            return
        }
        if connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        log.notice("Video connection: rotation=\(connection.videoRotationAngle), stabilization active=\(connection.activeVideoStabilizationMode.rawValue)")
    }

    /// Format, HDR off, global tone mapping. Tone mapping is set last because changing the format
    /// resets it (plan 5.2).
    private func applyBaseDeviceConfiguration(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
        } catch {
            log.error("Base configuration: lockForConfiguration failed: \(error.localizedDescription)")
            return
        }
        defer { camera.unlockForConfiguration() }

        if let format = Self.preferredPreviewFormat(camera.formats) {
            camera.activeFormat = format
            log.notice("Active format: \(Self.summary(of: format))")
        } else {
            log.notice("No 4:3 420f format found; keeping the default format")
        }
        camera.activeVideoMinFrameDuration = .invalid
        camera.activeVideoMaxFrameDuration = .invalid

        camera.automaticallyAdjustsVideoHDREnabled = false
        if camera.isVideoHDREnabled {
            camera.isVideoHDREnabled = false
        }
        if camera.isLowLightBoostSupported {
            camera.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
        if camera.activeFormat.isGlobalToneMappingSupported {
            camera.isGlobalToneMappingEnabled = true
        }
        log.notice("Base configuration: HDR=\(camera.isVideoHDREnabled), globalToneMapping=\(camera.isGlobalToneMappingEnabled)")
    }

    private func applyExposureOnQueue(_ control: ExposureControl, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("Exposure: lockForConfiguration failed: \(error.localizedDescription)")
            return
        }
        defer { device.unlockForConfiguration() }

        switch control {
        case .auto:
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        case .locked:
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        case .manual(let duration, let iso):
            guard device.isExposureModeSupported(.custom) else {
                log.error("Custom exposure mode not supported")
                return
            }
            let format = device.activeFormat
            let limits = ExposureLimits(
                minDuration: format.minExposureDuration.seconds,
                maxDuration: format.maxExposureDuration.seconds,
                minISO: format.minISO,
                maxISO: format.maxISO
            )
            let exposure = limits.clamp(duration: duration)
            let sensitivity = limits.clamp(iso: iso)

            // Frame duration first: a frame cannot be shorter than the exposure.
            let ranges = format.videoSupportedFrameRateRanges
            let longest = ranges.map { $0.maxFrameDuration.seconds }.max() ?? ExposurePlanner.baseFrameDuration
            if let frameDuration = ExposurePlanner.maxFrameDuration(forExposure: exposure, longestSupported: longest) {
                let at = ranges.first { $0.maxFrameDuration.seconds >= frameDuration && $0.minFrameDuration.seconds <= frameDuration }
                // Prefer the range's own CMTime at the boundary so the value is exactly supported.
                if let at, frameDuration >= at.maxFrameDuration.seconds {
                    device.activeVideoMaxFrameDuration = at.maxFrameDuration
                } else if at != nil {
                    device.activeVideoMaxFrameDuration = CMTime(seconds: frameDuration, preferredTimescale: 1_000_000)
                } else {
                    log.error("No frame rate range contains \(frameDuration) s; frame duration unchanged")
                }
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
            device.setExposureModeCustom(
                duration: CMTime(seconds: exposure, preferredTimescale: 1_000_000_000),
                iso: sensitivity,
                completionHandler: nil
            )
            log.notice("Manual exposure requested: \(formatExposure(exposure)), ISO \(sensitivity)")
        }
    }

    private func applyFocusOnQueue(_ control: FocusControl, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("Focus: lockForConfiguration failed: \(error.localizedDescription)")
            return
        }
        defer { device.unlockForConfiguration() }

        switch control {
        case .auto:
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        case .locked:
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
        case .manual(let position):
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            } else {
                log.error("Custom lens position not supported")
            }
        }
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        let log = self.log
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            log.error("Session runtime error: \(error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "unknown")")
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            log.notice("Session interrupted, reason=\(reason.map(String.init) ?? "?")")
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { _ in
            log.notice("Session interruption ended")
        })
    }

    // MARK: - Queue helpers

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func onQueueThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Format selection

    static let fullRange420f: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    static func dimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    static func subtype(of format: AVCaptureDevice.Format) -> OSType {
        CMFormatDescriptionGetMediaSubType(format.formatDescription)
    }

    static func isFourByThree420f(_ format: AVCaptureDevice.Format) -> Bool {
        let d = dimensions(of: format)
        return subtype(of: format) == fullRange420f && CaptureFormatting.isFourByThree(width: d.width, height: d.height)
    }

    /// 4:3, 8-bit 420f, ≥ 30 fps; prefers 1920x1440, and among those a format that can also run
    /// at ≤ 1 fps (needed for 1 s exposures; D-14, plan 5.2).
    static func preferredPreviewFormat(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        let candidates = formats.filter { format in
            isFourByThree420f(format) && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        let exact = candidates.filter { dimensions(of: $0).width == 1920 }
        if let slow = exact.first(where: { $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 1.0 } }) {
            return slow
        }
        if let first = exact.first { return first }
        return candidates
            .filter { dimensions(of: $0).width <= 2016 }
            .max { dimensions(of: $0).width < dimensions(of: $1).width }
            ?? candidates.first
    }

    /// 4:3, 420f, supports ≤ 1 fps (for 1 s exposures); prefers 1920x1440.
    static func longExposureFormat(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        let candidates = formats.filter { format in
            isFourByThree420f(format) && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 1.0 }
        }
        return candidates.first(where: { dimensions(of: $0).width == 1920 }) ?? candidates.first
    }

    /// One-line summary, e.g. `1920x1440 420f [1.0–30.0 fps] binned=true`.
    static func summary(of format: AVCaptureDevice.Format) -> String {
        let d = dimensions(of: format)
        let fps = format.videoSupportedFrameRateRanges
            .map { CaptureFormatting.fpsRange(min: $0.minFrameRate, max: $0.maxFrameRate) }
            .joined(separator: ", ")
        return "\(CaptureFormatting.dimensions(width: d.width, height: d.height)) "
            + "\(CaptureFormatting.fourCC(subtype(of: format))) [\(fps)] binned=\(format.isVideoBinned)"
    }
}
