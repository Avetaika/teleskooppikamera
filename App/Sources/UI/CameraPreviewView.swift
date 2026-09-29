import AVFoundation
import SwiftUI
import UIKit

/// Live camera image via `AVCaptureVideoPreviewLayer` (phase 0 only; D-04 replaces this with
/// `AVCaptureVideoDataOutput` + Metal in phase 2).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Changing this re-runs layout so the rotation is applied once the connection exists.
    var isRunning: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setNeedsLayout()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The UI is locked to portrait (D-13), so the preview is always rotated 90°.
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}
