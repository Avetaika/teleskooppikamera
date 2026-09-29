import SwiftUI

/// Night-vision friendly colours: black background, red content only.
enum NightTheme {
    static let red = Color(red: 0.90, green: 0.12, blue: 0.10)
    static let dimRed = Color(red: 0.50, green: 0.05, blue: 0.04)
    static let background = Color.black

    /// Minimum touch target for gloved use (plan.md: big buttons ≥ 60 pt).
    static let buttonHeight: CGFloat = 64
}

struct NightButtonStyle: ButtonStyle {
    var isSelected = false
    var font: Font = .title3.weight(.semibold)

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(NightTheme.red)
            .opacity(isEnabled ? 1 : 0.4)
            .frame(maxWidth: .infinity, minHeight: NightTheme.buttonHeight)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(NightTheme.red, lineWidth: isSelected ? 4 : 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return NightTheme.dimRed.opacity(0.6) }
        if isSelected { return NightTheme.dimRed.opacity(0.45) }
        return Color.black.opacity(0.75)
    }
}

/// A red slider with a caption; the row is at least 60 pt tall for gloved fingers.
struct NightSliderRow: View {
    let title: Text
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
                .font(.callout.weight(.semibold))
                .foregroundStyle(NightTheme.red)
            Group {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
            }
            .tint(NightTheme.red)
            .frame(minHeight: 44)
        }
    }
}

extension View {
    /// Small red monospaced text used for versions, reports and logs.
    func nightMonospaced() -> some View {
        font(.system(.caption, design: .monospaced))
            .foregroundStyle(NightTheme.red)
    }

    /// Semi-transparent black plate behind overlay text.
    func nightPlate() -> some View {
        padding(8)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}
