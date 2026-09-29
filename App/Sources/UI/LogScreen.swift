import SwiftUI

/// Shows `Documents/app-log.txt` and lets the user share it (no debugger is available, plan.md 6.1).
struct LogScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Sovelluksen loki")
                .font(.title2.bold())
                .foregroundStyle(NightTheme.red)

            ScrollView {
                Group {
                    if text.isEmpty {
                        Text("Loki on tyhjä.")
                    } else {
                        Text(verbatim: text)
                    }
                }
                .nightMonospaced()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Päivitä", systemImage: "arrow.clockwise")
                }
                ShareLink(item: AppFiles.logFile) {
                    Label("Jaa", systemImage: "square.and.arrow.up")
                }
                .disabled(text.isEmpty)
            }
            .buttonStyle(NightButtonStyle())

            Button {
                dismiss()
            } label: {
                Label("Sulje", systemImage: "xmark")
            }
            .buttonStyle(NightButtonStyle())
        }
        .padding()
        .background(NightTheme.background.ignoresSafeArea())
        .task { await reload() }
    }

    private func reload() async {
        text = await Task.detached { AppLog.file.readAll() }.value
    }
}
