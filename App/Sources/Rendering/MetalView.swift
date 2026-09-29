import MetalKit
import SwiftUI

/// Hosts an `MTKView` that draws frames on demand (D-04): the view redraws when a new frame
/// arrives or when the display parameters change, so a 1 s exposure costs almost no GPU time.
struct MetalView: UIViewRepresentable {
    let renderer: FrameRenderer?
    let params: RenderParams

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer?.setParams(params)
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let renderer: FrameRenderer?

        init(renderer: FrameRenderer?) {
            self.renderer = renderer
        }

        func attach(_ view: MTKView) {
            renderer?.setFrameNotifier { [weak view] in
                Task { @MainActor in view?.setNeedsDisplay() }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // The GPU rejects work submitted from the background.
            guard UIApplication.shared.applicationState != .background else { return }
            guard let renderer,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            renderer.draw(descriptor: descriptor, drawable: drawable)
        }
    }
}
