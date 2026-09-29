import SwiftUI
import TeleskooppiCore

/// Detected stars (small circles) and the lock ring, positioned with the shared display
/// transform (D-10). Analysis runs on binned coordinates; `BinningGeometry` maps them back.
struct StarOverlay: View {
    let transform: DisplayTransform
    let analysis: StarAnalysisResult?

    var body: some View {
        Canvas { context, _ in
            guard let analysis else { return }
            func screen(_ p: Vec2) -> CGPoint {
                let s = transform.imageToScreen(analysis.geometry.binnedToImage(p))
                return CGPoint(x: s.x, y: s.y)
            }
            for detection in analysis.candidates {
                let c = screen(detection.position)
                let ring = Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
                context.stroke(ring, with: .color(NightTheme.red.opacity(0.5)), lineWidth: 1)
            }
            if let star = analysis.star {
                let c = screen(star.position)
                let ring = Path(ellipseIn: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
                context.stroke(ring, with: .color(NightTheme.red), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension StarAnalysisResult {
    /// One line for the debug HUD.
    var hudLine: String {
        switch trackState {
        case nil:
            return "tähdet \(candidates.count)"
        case .searching?:
            return "haetaan tähteä · ehdokkaita \(candidates.count)"
        case .lost?:
            return "tähti kadonnut"
        case .locked?:
            if let star {
                return String(format: "lukittu SNR %.1f HFR %.2f%@", star.snr, star.hfr, star.saturated ? " KYLLÄINEN" : "")
            }
            return "lukittu (ei havaintoa)"
        }
    }
}
