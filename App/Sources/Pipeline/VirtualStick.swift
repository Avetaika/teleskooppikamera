import SwiftUI
import TeleskooppiCore

/// Maps a touch offset inside the virtual stick to a mount stick vector (x right, y up) with
/// magnitude limited to 1.
enum VirtualStick {
    static func vector(fromOffset offset: CGSize, radius: CGFloat) -> Vec2 {
        guard radius > 0 else { return .zero }
        // Screen y points down, the mount stick's y points up.
        let raw = Vec2(Double(offset.width / radius), Double(-offset.height / radius))
        let length = raw.length
        return length > 1 ? raw / length : raw
    }
}

/// On-screen stick for the synthetic source in the dev menu (drives `SimulatedMount`).
struct VirtualStickView: View {
    var radius: CGFloat = 80
    var onChange: (Vec2) -> Void

    @State private var knob: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .stroke(NightTheme.red, lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(NightTheme.dimRed)
                .overlay(Circle().stroke(NightTheme.red, lineWidth: 2))
                .frame(width: 56, height: 56)
                .offset(knob)
        }
        .frame(width: radius * 2 + 16, height: radius * 2 + 16)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = radius + 8
                    let offset = CGSize(width: value.location.x - center, height: value.location.y - center)
                    let v = VirtualStick.vector(fromOffset: offset, radius: radius)
                    knob = CGSize(width: v.x * radius, height: -v.y * radius)
                    onChange(v)
                }
                .onEnded { _ in
                    knob = .zero
                    onChange(.zero)
                }
        )
        .accessibilityLabel(Text("Virtuaalitatti"))
    }
}
