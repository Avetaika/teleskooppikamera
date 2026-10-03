import QuartzCore
import SwiftUI
import TeleskooppiCore

/// Large dim red guidance: 8-way arrow with `TATTI ←`, seconds estimate, "OK" inside the
/// tolerance, and axis markers around the crosshair while no star is tracked (plan 4.5).
struct GuidanceOverlay: View {
    let controller: CalibrationController
    let transform: DisplayTransform

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            content(now: CACurrentMediaTime())
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(now: Double) -> some View {
        let state = controller.guidanceState
        let opacity = state.opacity(now: now)
        ZStack {
            switch state.mode {
            case .hidden:
                EmptyView()
            case .arrow(let arrow):
                arrowView(arrow)
                    .opacity(opacity)
            case .ok:
                Text("OK")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(NightTheme.red)
                    .opacity(opacity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 170)
            case .noStar:
                if let calibration = controller.calibration {
                    axisMarkers(calibration: calibration)
                        .opacity(opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func arrowView(_ arrow: StickDir8) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 120, weight: .black))
                .rotationEffect(.degrees(GuidanceText.screenRotationDegrees(for: arrow)))
                .frame(height: 150)
            Text(verbatim: GuidanceText.label(for: arrow))
                .font(.system(size: 44, weight: .heavy, design: .rounded))
            if let output = controller.lastGuidance {
                Text(verbatim: "≈ " + GuidanceText.seconds(for: output, arrow: arrow))
                    .font(.system(.body, design: .monospaced))
            }
        }
        .foregroundStyle(NightTheme.red)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 150)
    }

    private func axisMarkers(calibration: CalibrationResult) -> some View {
        let convention: GuidanceConvention = controller.invertedConvention ? .inverted : .window
        let directions = GuidanceEngine.axisMarkerDirections(
            stickToImage: calibration.stickToImage, display: transform, convention: convention
        )
        let c = transform.imageToScreen(transform.opticalCenter)
        let radius = 112.0
        return ZStack {
            ForEach(StickDirection.allCases, id: \.self) { direction in
                if let v = directions[direction] {
                    marker(direction)
                        .position(x: c.x + v.x * radius, y: c.y + v.y * radius)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ direction: StickDirection) -> some View {
        let text: Text = switch direction {
        case .up: Text("YLÖS")
        case .right: Text("OIK")
        case .down: Text("ALAS")
        case .left: Text("VAS")
        }
        text
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(NightTheme.red)
            .padding(.horizontal, 6)
            .background(Color.black.opacity(0.5), in: Capsule())
    }
}
