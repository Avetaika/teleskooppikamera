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
                        model.toggleRecording()
                    } label: {
                        Image(systemName: model.recording.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2.weight(.bold))
                    }
                    .buttonStyle(NightButtonStyle(isSelected: model.recording.isRecording, font: .title2))
                    .frame(width: NightTheme.buttonHeight)
                    .disabled(model.sourceKind == .replay)
                    .accessibilityLabel(Text("Nauhoitus"))
                    Button {
                        showDevMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2.weight(.bold))
                    }
                    .buttonStyle(NightButtonStyle(font: .title2))
                    .frame(width: NightTheme.buttonHeight)
                    .accessibilityLabel(Text("Kehitysvalikko"))
                    ProfileEntryButton(model: model)
                }
                if showPerformanceOverlay {
                    PerformanceOverlay(model: model)
                }
                Spacer(minLength: 0)
                if model.sourceKind == .synthetic, model.calibration.calibration != nil {
                    VirtualStickView { model.setStick($0) }
                }
                status
                panelView
                calibrationRow
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .opacity(model.calibration.panelVisible ? 0 : 1)
            .allowsHitTesting(!model.calibration.panelVisible)

            if model.calibration.panelVisible {
                CalibrationOverlay(
                    controller: model.calibration,
                    onVirtualStick: model.sourceKind == .synthetic ? { model.setStick($0) } : nil
                )
            }
        }
        .task { await model.startCurrentSource() }
        .onChange(of: showPerformanceOverlay, initial: true) { _, enabled in
            model.setPerformanceOverlay(enabled)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .fullScreenCover(isPresented: $showDevMenu) {
            DevMenuScreen(model: model, showPerformanceOverlay: $showPerformanceOverlay)
        }
        // Volume buttons, Camera Control and AirPods clicks (D-18). Placeholder: logs the event.
        .onCameraCaptureEvent { event in
            let phase = event.phase
            let raw = Int(phase.rawValue)
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
                if showPerformanceOverlay || model.calibration.needsDetection {
                    StarOverlay(transform: model.transform(viewSize: size), analysis: model.analysis)
                }
                if model.calibration.calibration != nil, !model.calibration.panelVisible {
                    GuidanceOverlay(controller: model.calibration, transform: model.transform(viewSize: size))
                }
                LongPressLocationView(
                    onLongPress: { point in model.setOpticalCenter(atScreen: point, viewSize: size) },
                    onTap: { point in model.selectStar(atScreen: point, viewSize: size) }
                )
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

    /// "Kalibroi" and, after a manual change, the way back to the calibrated view.
    private var calibrationRow: some View {
        HStack(spacing: 6) {
            Button("Kalibroi") { model.calibration.showPanel() }
                .buttonStyle(NightButtonStyle(
                    isSelected: model.calibration.calibration == nil, font: .headline.weight(.heavy)
                ))
            if let suggestion = model.profiles.suggestion {
                switch suggestion {
                case .quick:
                    Button("Okulaari vaihtui: Pikakalibrointi") { model.profiles.start(.quickCalibrate) }
                        .buttonStyle(NightButtonStyle(isSelected: true, font: .subheadline.weight(.bold)))
                case .full:
                    Button("Okulaari vaihtui: Kalibroi") { model.profiles.start(.recalibrate) }
                        .buttonStyle(NightButtonStyle(isSelected: true, font: .subheadline.weight(.bold)))
                }
            }
            if let calibrated = model.calibration.calibration, model.display.isManual {
                Button("Käytä kalibrointia") { model.applyCalibrationToDisplay(calibrated) }
                    .buttonStyle(NightButtonStyle(font: .subheadline.weight(.bold)))
            }
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
        case .synthetic, .replay:
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
