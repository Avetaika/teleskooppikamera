import AVKit
import SwiftUI
import UIKit

/// Main screen (phase 2): Metal live view with crosshair, status HUD, control panels and the
/// exposure presets. Black and red only; buttons are at least 64 pt tall.
struct RootView: View {
    let model: AppModel

    private enum Panel {
        case display
        case camera
    }

    @State private var panel: Panel?
    @State private var showDevMenu = false
    @AppStorage("showPerformanceOverlay") private var showPerformanceOverlay = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            NightTheme.background.ignoresSafeArea()

            liveView
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    StatusHUD(model: model)
                    Button {
                        showDevMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2.weight(.bold))
                    }
                    .buttonStyle(NightButtonStyle(font: .title2))
                    .frame(width: NightTheme.buttonHeight)
                    .accessibilityLabel(Text("Kehitysvalikko"))
                }
                if showPerformanceOverlay {
                    PerformanceOverlay(model: model)
                }
                Spacer(minLength: 0)
                status
                panelView
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .task { await model.startCurrentSource() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .fullScreenCover(isPresented: $showDevMenu) {
            DevMenuScreen(model: model, showPerformanceOverlay: $showPerformanceOverlay)
        }
        // Volume buttons, Camera Control and AirPods clicks (D-18). Placeholder: logs the event.
        .onCameraCaptureEvent { event in
            let phase = event.phase
            let raw = phase.rawValue
            let isEnd = phase == .ended
            Task { @MainActor in
                model.handleCaptureEvent(phaseRawValue: raw, isEnd: isEnd)
            }
        }
    }

    // MARK: - Live view

    private var liveView: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if !AppInfo.isRunningTests {
                    MetalView(renderer: model.renderer, params: model.renderParams(viewSize: size))
                }
                CrosshairOverlay(transform: model.transform(viewSize: size))
                LongPressLocationView { point in
                    model.setOpticalCenter(atScreen: point, viewSize: size)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: - Bottom controls

    private var bottomBar: some View {
        HStack(spacing: 6) {
            ForEach(CameraPreset.allCases) { preset in
                Button(preset.title) { model.controls.applyPreset(preset) }
                    .buttonStyle(NightButtonStyle(
                        isSelected: model.controls.settings.activePreset == preset, font: .subheadline.weight(.bold)
                    ))
            }
            Button("Kuva") { toggle(.display) }
                .buttonStyle(NightButtonStyle(isSelected: panel == .display, font: .subheadline.weight(.bold)))
            Button("Kamera") { toggle(.camera) }
                .buttonStyle(NightButtonStyle(isSelected: panel == .camera, font: .subheadline.weight(.bold)))
        }
    }

    private func toggle(_ target: Panel) {
        panel = panel == target ? nil : target
    }

    @ViewBuilder
    private var panelView: some View {
        switch panel {
        case .display:
            DisplayPanel(model: model)
                .frame(maxHeight: 380)
        case .camera:
            CameraPanel(model: model)
                .frame(maxHeight: 380)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.sourceKind {
        case .synthetic:
            EmptyView()
        case .camera:
            cameraStatus
        }
    }

    @ViewBuilder
    private var cameraStatus: some View {
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
