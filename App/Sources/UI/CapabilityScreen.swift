import SwiftUI

/// Runs the capability probe and shows/shares the resulting text file.
struct CapabilityScreen: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Kyvykkyysraportti")
                .font(.title2.bold())
                .foregroundStyle(NightTheme.red)

            ScrollView {
                Group {
                    if let report = model.lastReport {
                        Text(verbatim: report.text)
                    } else {
                        Text("Raportti mittaa kameran formaatit, valotusrajat, ISO:n, RAW-tuen ym. ja kokeilee 1 s:n valotusta. Tulos tallentuu Tiedostot-sovellukseen (Teleskooppi-kansio).")
                    }
                }
                .nightMonospaced()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

            if model.isGeneratingReport {
                HStack(spacing: 8) {
                    ProgressView().tint(NightTheme.red)
                    Text("Mitataan… (noin 10 s)")
                        .foregroundStyle(NightTheme.red)
                }
            }
            if let error = model.reportError {
                Text("Tallennus epäonnistui: \(error)")
                    .foregroundStyle(NightTheme.red)
            }
            if let url = model.lastReport?.url {
                Text(verbatim: url.lastPathComponent)
                    .nightMonospaced()
            }

            Button {
                Task { await model.generateReport() }
            } label: {
                Label("Luo raportti", systemImage: "gauge.with.dots.needle.33percent")
            }
            .buttonStyle(NightButtonStyle())
            .disabled(model.isGeneratingReport)

            HStack(spacing: 12) {
                if let url = model.lastReport?.url {
                    ShareLink(item: url) {
                        Label("Jaa", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(NightButtonStyle())
                }
                Button {
                    dismiss()
                } label: {
                    Label("Sulje", systemImage: "xmark")
                }
                .buttonStyle(NightButtonStyle())
            }
        }
        .padding()
        .background(NightTheme.background.ignoresSafeArea())
    }
}
