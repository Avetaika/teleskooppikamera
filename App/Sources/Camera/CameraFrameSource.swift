import Foundation

/// The live camera as a `FrameSource` (plan 3.2): frames come from the
/// `AVCaptureVideoDataOutput` owned by `CameraService`, in the sensor's native orientation.
final class CameraFrameSource: FrameSource, @unchecked Sendable {
    let kind = FrameSourceKind.camera
    let service: CameraService

    init(service: CameraService) {
        self.service = service
    }

    func setFrameHandler(_ handler: (@Sendable (Frame) -> Void)?) {
        service.setFrameHandler(handler)
    }

    func start() async throws {
        try await service.start()
    }

    func stop() async {
        await service.stop()
    }
}
