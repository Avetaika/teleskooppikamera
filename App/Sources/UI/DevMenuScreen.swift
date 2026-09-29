import SwiftUI
import TeleskooppiCore

/// Development menu: frame source selection, virtual stick for the synthetic sky, performance
/// overlay, and the phase 0 capability report and log.
struct DevMenuScreen: View {
    let model: AppModel
    @Binding var showPerformanceOverlay: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Kehitysvalikko")
                        .font(.title2.bold())
                        .foregroundStyle(NightTheme.red)
                    Spacer()
                    Button("Sulje") { dismiss() }
                        .buttonStyle(NightButtonStyle(font: .headline))
                        .frame(width: 120)
                }

                Text(verbatim: AppInfo.summary)
                    .nightMonospaced()

                sourceSection
                if model.sourceKind == .synthetic {
                    syntheticSection
                }
                performanceSection
                toolsSection
            }
            .padding()
        }
        .background(NightTheme.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $showReport) { CapabilityScreen(model: model) }
        .fullScreenCover(isPresented: $showLog) { LogScreen() }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kuvalähde")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            HStack(spacing: 8) {
                ForEach(FrameSourceKind.allCases) { kind in
                    Button(kind.title) {
                        Task { await model.selectSource(kind) }
                    }
                    .buttonStyle(NightButtonStyle(isSelected: model.sourceKind == kind, font: .headline))
                }
            }
        }
    }

    private var syntheticSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtuaalitatti")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            Text("Siirtää simuloitua jalustaa. Simuloidun optiikan oikea kierto on \(SyntheticFrameSource.groundTruthRotationDegrees, specifier: "%.0f")°: kun kuvan kierto on se, tatti ylös liikuttaa tähtiä ruudulla alas.")
                .font(.footnote)
                .foregroundStyle(NightTheme.red)
            HStack {
                Spacer()
                VirtualStickView { model.setStick($0) }
                Spacer()
            }
        }
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suorituskyky")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            PerformanceOverlay(model: model)
            if let readout = model.controls.readout {
                Text(verbatim: "formaatti: \(readout.formatSummary)")
                    .nightMonospaced()
                Text(verbatim: "kehysväli max: \(formatExposure(readout.activeMaxFrameDuration)) (tuettu \(formatExposure(readout.longestFrameDuration)))")
                    .nightMonospaced()
            }
            Text(verbatim: "kuva \(Int(model.imageSize.width))×\(Int(model.imageSize.height)) · kuvia yhteensä \(model.performance.totalFrames)")
                .nightMonospaced()
            HStack(spacing: 8) {
                Button(showPerformanceOverlay ? "Piilota näkymästä" : "Näytä pääruudulla") {
                    showPerformanceOverlay.toggle()
                }
                .buttonStyle(NightButtonStyle(isSelected: showPerformanceOverlay, font: .headline))
                Button("Nollaa max-viive") { model.resetMaximumLatency() }
                    .buttonStyle(NightButtonStyle(font: .headline))
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Työkalut")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            Text(verbatim: "fyysinen nappi (D-18): \(model.captureEventCount) tapahtumaa")
                .nightMonospaced()
            HStack(spacing: 8) {
                Button {
                    showReport = true
                } label: {
                    Label("Raportti", systemImage: "list.bullet.rectangle")
                }
                Button {
                    showLog = true
                } label: {
                    Label("Loki", systemImage: "doc.text")
                }
            }
            .buttonStyle(NightButtonStyle(font: .headline))
        }
    }
}
