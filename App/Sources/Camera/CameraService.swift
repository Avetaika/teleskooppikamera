import AVFoundation
import CoreMedia

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

/// Owns the `AVCaptureSession` for the physical back wide-angle camera (D-14).
///
/// Threading: every access to the session, the device and the outputs happens on the private
/// serial `queue` (wrapped in async functions for callers). The only exception is that the
/// preview layer is attached to `session` on the main thread, which AVFoundation allows.
/// Phase 0 uses `AVCaptureVideoPreviewLayer` (D-04 allows it temporarily).
final class CameraService: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "fi.avetaika.teleskooppikamera.camera-session")
    private let log = AppLog.camera

    // Queue-confined state.
    private var device: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()
    private var observers: [NSObjectProtocol] = []

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

    // MARK: - Configuration (queue only)

    private func configureIfNeeded() throws {
        guard device == nil else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        // The photo output is only needed in phase 0 to query RAW/bracketing capabilities.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else {
            log.error("Cannot add AVCapturePhotoOutput")
        }

        if let format = Self.preferredPreviewFormat(camera.formats) {
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.unlockForConfiguration()
            log.notice("Active format: \(Self.summary(of: format))")
        } else {
            log.notice("No 4:3 420f format found; keeping preset \(session.sessionPreset.rawValue)")
        }

        device = camera
        log.notice("Configured \(camera.localizedName) (\(camera.deviceType.rawValue)), \(camera.formats.count) formats")
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

    /// 4:3, 8-bit 420f, ≥ 30 fps; prefers 1920x1440 (D-14).
    static func preferredPreviewFormat(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
        let candidates = formats.filter { format in
            isFourByThree420f(format) && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        if let exact = candidates.first(where: { dimensions(of: $0).width == 1920 }) { return exact }
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
