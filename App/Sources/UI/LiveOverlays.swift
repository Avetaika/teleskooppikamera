import SwiftUI
import TeleskooppiCore
import UIKit

/// Crosshair at the optical center, positioned with the same `DisplayTransform` as the image
/// (D-10). The optical center is always recentered on the screen, so the crosshair is at the
/// screen center; going through the transform keeps it correct if that ever changes.
struct CrosshairOverlay: View {
    let transform: DisplayTransform

    var body: some View {
        Canvas { context, _ in
            let c = transform.imageToScreen(transform.opticalCenter)
            let center = CGPoint(x: c.x, y: c.y)
            let color = GraphicsContext.Shading.color(NightTheme.red.opacity(0.9))

            var arms = Path()
            let gap: CGFloat = 10
            let arm: CGFloat = 46
            arms.move(to: CGPoint(x: center.x - arm, y: center.y))
            arms.addLine(to: CGPoint(x: center.x - gap, y: center.y))
            arms.move(to: CGPoint(x: center.x + gap, y: center.y))
            arms.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            arms.move(to: CGPoint(x: center.x, y: center.y - arm))
            arms.addLine(to: CGPoint(x: center.x, y: center.y - gap))
            arms.move(to: CGPoint(x: center.x, y: center.y + gap))
            arms.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            context.stroke(arms, with: color, lineWidth: 1.5)

            for radius: CGFloat in [70, 140] {
                let ring = Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
                ))
                context.stroke(ring, with: .color(NightTheme.red.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Transparent UIKit layer with a long-press recognizer that reports the touch location. A long
/// press (not a tap) sets the optical center, to avoid accidental changes (plan phase 2).
struct LongPressLocationView: UIViewRepresentable {
    var minimumDuration: TimeInterval = 0.8
    var onLongPress: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = 30
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onLongPress = onLongPress
    }

    @MainActor
    final class Coordinator: NSObject {
        var onLongPress: (CGPoint) -> Void

        init(onLongPress: @escaping (CGPoint) -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress(recognizer.location(in: view))
        }
    }
}

/// Live status lines at the top of the screen.
struct StatusHUD: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.sun.isWarning {
                Text(model.sun.warningText)
                    .font(.headline)
                    .foregroundStyle(Color.black)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NightTheme.red, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 6) {
                Text(model.sun.summary)
                if model.display.isManual {
                    Text("KÄSI \(model.display.rotationDegrees, specifier: "%.1f")°")
                        .fontWeight(.bold)
                }
                if model.sourceKind == .synthetic {
                    Text("SYNTEETTINEN").fontWeight(.bold)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(NightTheme.red)
            .nightPlate()

            if let readout = model.controls.readout, model.sourceKind == .camera {
                Text("\(formatExposure(readout.exposureSeconds)) · ISO \(Int(readout.iso.rounded())) · linssi \(readout.lensPosition, specifier: "%.3f")")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(NightTheme.red)
                    .nightPlate()
            }
        }
    }
}

/// Performance lines (dev menu toggle): fps, latency estimate, thermal state, battery.
struct PerformanceOverlay: View {
    let model: AppModel

    var body: some View {
        let perf = model.performance
        let status = model.deviceStatus
        VStack(alignment: .leading, spacing: 2) {
            Text("kamera \(perf.captureFps, specifier: "%.1f") fps · piirto \(perf.renderFps, specifier: "%.1f") fps")
            Text("viive \(perf.latencyMs, specifier: "%.0f") ms (max \(perf.maxLatencyMs, specifier: "%.0f")) · pudotettu \(perf.droppedFrames)")
            Text("lämpö \(status.thermalState) · paine \(model.controls.readout?.pressureLevel ?? "–")")
            Text("akku \(Int(status.batteryLevel * 100)) % \(status.batteryState)\(status.lowPowerMode ? " · virransäästö" : "")")
            if model.sourceKind == .synthetic {
                Text("synteettinen kuva \(model.syntheticRenderMilliseconds, specifier: "%.0f") ms/kuva")
            }
        }
        .nightMonospaced()
        .nightPlate()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
