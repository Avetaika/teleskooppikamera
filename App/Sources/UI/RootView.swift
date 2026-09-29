import SwiftUI
import UIKit

/// Phase 0 main screen: live camera, versions, and entry points to the capability report and log.
struct RootView: View {
    let model: AppModel

    @State private var showReport = false
    @State private var showLog = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            NightTheme.background.ignoresSafeArea()

            if !AppInfo.isRunningTests {
                CameraPreviewView(session: model.camera.session, isRunning: model.cameraState == .running)
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                header
                Spacer()
                status
                HStack(spacing: 12) {
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
                .buttonStyle(NightButtonStyle())
            }
            .padding()
        }
        .task { await model.startCamera() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .fullScreenCover(isPresented: $showReport) {
            CapabilityScreen(model: model)
        }
        .fullScreenCover(isPresented: $showLog) {
            LogScreen()
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Teleskooppikamera · vaihe 0")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            Text(verbatim: AppInfo.summary)
                .nightMonospaced()
        }
        .padding(8)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var status: some View {
        switch model.cameraState {
        case .running:
            EmptyView()
        case .idle, .requestingPermission:
            statusText(Text("Käynnistetään kameraa…"))
        case .denied:
            VStack(spacing: 12) {
                statusText(Text("Kameran käyttö on estetty. Salli se Asetuksissa (Teleskooppi → Kamera)."))
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Avaa Asetukset", systemImage: "gear")
                }
                .buttonStyle(NightButtonStyle())
            }
        case .unavailable(let message):
            statusText(Text("Kamera ei ole käytettävissä: \(message)"))
        }
    }

    private func statusText(_ text: Text) -> some View {
        text
            .font(.body)
            .foregroundStyle(NightTheme.red)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}
