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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(NightTheme.red)
            .frame(maxWidth: .infinity, minHeight: NightTheme.buttonHeight)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(configuration.isPressed ? NightTheme.dimRed.opacity(0.6) : Color.black.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(NightTheme.red, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    /// Small red monospaced text used for versions, reports and logs.
    func nightMonospaced() -> some View {
        font(.system(.caption, design: .monospaced))
            .foregroundStyle(NightTheme.red)
    }
}
