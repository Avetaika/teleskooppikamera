import UIKit

/// In-app screen brightness with restore on background (plan 5.2: minimum is 1 nit at 0).
///
/// `UIScreen.brightness` changes the system setting until it is reset, so the original value is
/// remembered when the override starts and restored when the app leaves the foreground.
@MainActor
final class BrightnessController {
    private var original: CGFloat?
    private var override: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    /// Current effective brightness (0...1).
    var currentBrightness: Double {
        Double(screen?.brightness ?? 0.5)
    }

    /// Applies `value` (0...1) as the in-app brightness, or stops overriding for `nil`.
    func setOverride(_ value: Double?) {
        guard let screen else { return }
        guard let value else {
            override = nil
            restore()
            return
        }
        if original == nil { original = screen.brightness }
        override = CGFloat(min(max(value, 0), 1))
        screen.brightness = override!
    }

    /// Restores the system brightness (app went to the background).
    func restore() {
        guard let screen else { return }
        if let original { screen.brightness = original }
        original = nil
    }

    /// Re-applies the override after returning to the foreground.
    func reapply() {
        guard let screen, let override else { return }
        if original == nil { original = screen.brightness }
        screen.brightness = override
    }
}
