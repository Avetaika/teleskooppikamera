import SwiftUI
import TeleskooppiCore

/// Display panel: rotation, flips, zoom, stretch, night mode, brightness, optical center.
struct DisplayPanel: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                rotationSection
                flipSection
                stretchSection
                nightSection
                centerSection
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NightTheme.dimRed, lineWidth: 2))
    }

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            NightSliderRow(
                title: Text("Kierto \(model.display.rotationDegrees, specifier: "%.1f")°"),
                value: Binding(
                    get: { model.display.rotationDegrees },
                    set: { value in model.updateDisplay { $0.setRotation(degrees: value) } }
                ),
                range: DisplaySettings.rotationRange,
                step: 0.1
            )
            HStack(spacing: 8) {
                Button("−1°") { model.updateDisplay { $0.setRotation(degrees: $0.rotationDegrees - 1) } }
                Button("0°") { model.updateDisplay { $0.setRotation(degrees: 0) } }
                Button("+1°") { model.updateDisplay { $0.setRotation(degrees: $0.rotationDegrees + 1) } }
                Button("+90°") { model.updateDisplay { $0.setRotation(degrees: $0.rotationDegrees + 90) } }
            }
            .buttonStyle(NightButtonStyle(font: .headline))
        }
    }

    private var flipSection: some View {
        HStack(spacing: 8) {
            Button("Peilaa vaaka") { model.updateDisplay { $0.flipHorizontal.toggle() } }
                .buttonStyle(NightButtonStyle(isSelected: model.display.flipHorizontal, font: .headline))
            Button("Peilaa pysty") { model.updateDisplay { $0.flipVertical.toggle() } }
                .buttonStyle(NightButtonStyle(isSelected: model.display.flipVertical, font: .headline))
        }
    }

    private var stretchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            NightSliderRow(
                title: Text("Zoom \(model.display.zoom, specifier: "%.2f")×"),
                value: Binding(
                    get: { model.display.zoom },
                    set: { value in model.updateDisplay { $0.zoom = value } }
                ),
                range: DisplaySettings.zoomRange
            )
            NightSliderRow(
                title: Text("Mustapiste \(model.display.blackPoint, specifier: "%.2f")"),
                value: Binding(
                    get: { model.display.blackPoint },
                    set: { value in model.updateDisplay { $0.blackPoint = value } }
                ),
                range: 0...0.95
            )
            NightSliderRow(
                title: Text("Valkopiste \(model.display.whitePoint, specifier: "%.2f")"),
                value: Binding(
                    get: { model.display.whitePoint },
                    set: { value in model.updateDisplay { $0.whitePoint = value } }
                ),
                range: 0.05...1
            )
            NightSliderRow(
                title: Text("Gamma \(model.display.gamma, specifier: "%.2f")"),
                value: Binding(
                    get: { model.display.gamma },
                    set: { value in model.updateDisplay { $0.gamma = value } }
                ),
                range: 0.3...3
            )
            Button("Nollaa venytys") {
                model.updateDisplay {
                    $0.blackPoint = 0
                    $0.whitePoint = 1
                    $0.gamma = 1
                }
            }
            .buttonStyle(NightButtonStyle(font: .headline))
        }
    }

    private var nightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.updateDisplay { $0.redMode.toggle() }
            } label: {
                Text(model.display.redMode ? "Punatila: päällä" : "Punatila: pois")
            }
            .buttonStyle(NightButtonStyle(isSelected: model.display.redMode, font: .headline))

            NightSliderRow(
                title: Text("Näytön kirkkaus \(Int(((model.display.brightness ?? model.systemBrightness) * 100).rounded())) %"),
                value: Binding(
                    get: { model.display.brightness ?? model.systemBrightness },
                    set: { value in model.updateDisplay { $0.brightness = value } }
                ),
                range: 0...1
            )
            if model.display.brightness != nil {
                Button("Käytä järjestelmän kirkkautta") {
                    model.updateDisplay { $0.brightness = nil }
                }
                .buttonStyle(NightButtonStyle(font: .headline))
            }
        }
    }

    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aseta optinen keskipiste painamalla kuvaa sormella noin sekunnin. Ristikko siirtyy näytön keskelle.")
                .font(.footnote)
                .foregroundStyle(NightTheme.red)
            Button("Keskitä kuva") {
                model.updateDisplay { $0.resetOpticalCenter() }
            }
            .buttonStyle(NightButtonStyle(font: .headline))
            .disabled(model.display.opticalCenter == nil)
        }
    }
}

/// Camera panel: exposure duration, ISO, focus, infinity calibration.
struct CameraPanel: View {
    let model: AppModel

    private var controls: CameraControlModel { model.controls }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                exposureSection
                focusSection
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NightTheme.dimRed, lineWidth: 2))
    }

    private var exposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Valotus")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            modePicker(selected: controls.settings.exposureMode) { controls.setExposureMode($0) }

            if controls.settings.exposureMode == .manual {
                let limits = controls.limits
                NightSliderRow(
                    title: Text("Valotusaika \(formatExposure(controls.settings.manualDuration))"),
                    value: Binding(
                        get: {
                            LogScale.unit(value: controls.settings.manualDuration, min: limits.minDuration, max: limits.maxDuration)
                        },
                        set: { unit in
                            controls.setManualDuration(LogScale.value(unit: unit, min: limits.minDuration, max: limits.maxDuration))
                        }
                    ),
                    range: 0...1
                )
                NightSliderRow(
                    title: Text("ISO \(Int(controls.settings.manualISO.rounded()))"),
                    value: Binding(
                        get: {
                            LogScale.unit(value: Double(controls.settings.manualISO), min: Double(limits.minISO), max: Double(limits.maxISO))
                        },
                        set: { unit in
                            controls.setManualISO(Float(LogScale.value(unit: unit, min: Double(limits.minISO), max: Double(limits.maxISO))))
                        }
                    ),
                    range: 0...1
                )
            }
            if let readout = controls.readout {
                Text("Nyt: \(formatExposure(readout.exposureSeconds)), ISO \(Int(readout.iso.rounded())). Rajat \(formatExposure(readout.limits.minDuration))–\(formatExposure(readout.limits.maxDuration)), ISO \(Int(readout.limits.minISO))–\(Int(readout.limits.maxISO)).")
                    .nightMonospaced()
            }
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tarkennus")
                .font(.headline)
                .foregroundStyle(NightTheme.red)
            modePicker(selected: controls.settings.focusMode) { controls.setFocusMode($0) }

            if controls.settings.focusMode == .manual {
                NightSliderRow(
                    title: Text("Linssin paikka \(controls.settings.manualLensPosition, specifier: "%.3f")"),
                    value: Binding(
                        get: { Double(controls.settings.manualLensPosition) },
                        set: { controls.setLensPosition(Float($0)) }
                    ),
                    range: 0...1
                )
            }
            HStack(spacing: 8) {
                Button("Ääretön") { controls.goToInfinity() }
                    .disabled(controls.infinityLensPosition == nil)
                Button(controls.isCalibratingInfinity ? "Tarkennetaan…" : "Kalibroi ääretön") {
                    controls.calibrateInfinity()
                }
                .disabled(controls.isCalibratingInfinity)
            }
            .buttonStyle(NightButtonStyle(font: .headline))

            if let infinity = controls.infinityLensPosition {
                Text("Tallennettu ääretön: \(infinity, specifier: "%.3f")")
                    .nightMonospaced()
            }
            Text("Kalibrointi: osoita kaukaiseen kohteeseen tai tähteen okulaarin läpi. Automaattitarkennus ajetaan kerran ja arvo lukitaan.")
                .font(.footnote)
                .foregroundStyle(NightTheme.red)
        }
    }

    private func modePicker(selected: ControlMode, action: @escaping (ControlMode) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(ControlMode.allCases) { mode in
                Button(mode.title) { action(mode) }
                    .buttonStyle(NightButtonStyle(isSelected: selected == mode, font: .headline))
            }
        }
    }
}
