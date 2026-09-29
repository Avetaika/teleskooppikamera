import CoreVideo
import Foundation

/// One video frame in the camera's native buffer orientation (D-05): bi-planar 4:2:0 YCbCr,
/// full range (`420f`). Shared by the camera and the synthetic source so the renderer has a
/// single path.
struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Presentation time on the host clock in seconds (same timebase as `CACurrentMediaTime()`).
    let timestamp: Double
    var exposureSeconds: Double?
    var iso: Float?

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

enum FrameSourceKind: String, CaseIterable, Sendable, Identifiable {
    case camera
    case synthetic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: String(localized: "Kamera")
        case .synthetic: String(localized: "Synteettinen taivas")
        }
    }
}

/// A producer of frames (plan 3.2): the live camera, a recording (phase 3) or the synthetic sky.
///
/// Frames are delivered on the source's own queue; the handler must be cheap and must not block.
protocol FrameSource: AnyObject, Sendable {
    var kind: FrameSourceKind { get }
    func setFrameHandler(_ handler: (@Sendable (Frame) -> Void)?)
    func start() async throws
    func stop() async
}
