import QuartzCore
import SwiftUI
import TeleskooppiCore

/// Calibration flow over the live view (plan 4.6): big red-on-black text, buttons >= 64 pt,
/// full-screen STOP flash, result and failure cards. Nothing here decides anything; the core
/// state machine does (see `CalibrationController`).
struct CalibrationOverlay: View {
    let controller: CalibrationController
    /// Virtual stick for the synthetic source; `nil` with a real mount.
    var onVirtualStick: ((Vec2) -> Void)?

    var body: some View {
        let screen = controller.screen
        ZStack {
            if screen == .stop {
                StopFlash(onAcknowledge: { controller.acknowledgeStop() })
            } else {
                VStack(spacing: 10) {
                    banner(screen)
                    Spacer(minLength: 0)
                    if let onVirtualStick, controller.isRunning {
                        VirtualStickView(onChange: onVirtualStick)
                    }
                    card(screen)
                }
                .padding(.horizontal, 12)
                .padding(.top, 64)
                .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: screen)
    }

    // MARK: - Banner (instruction)

    @ViewBuilder
    private func banner(_ screen: CalibrationScreen) -> some View {
        switch screen {
        case .intro, .result, .failure, .stop:
            EmptyView()
        default:
            VStack(spacing: 4) {
                Text("Kalibrointi \(min(controller.moveIndex + 1, controller.moveCount))/\(controller.moveCount)")
                    .font(.system(.footnote, design: .monospaced))
                headline(screen)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                detail(screen)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if case .press = screen {
                    ProgressView(value: min(max(controller.progress, 0), 1))
                        .tint(NightTheme.red)
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(NightTheme.red)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func headline(_ screen: CalibrationScreen) -> Text {
        switch screen {
        case .pickStar: Text("Napauta tähteä")
        case .centerStar: Text("Tähti lähemmäs ristikkoa")
        case .holdStill: Text("Älä koske tattiin")
        case .press(.up): Text("Pidä tattia YLÖS")
        case .press(.right): Text("Pidä tattia OIKEALLE")
        case .press(.down): Text("Pidä tattia ALAS")
        case .press(.left): Text("Pidä tattia VASEMMALLE")
        case .release: Text("Päästä irti")
        case .intro, .stop, .result, .failure: Text("")
        }
    }

    private func detail(_ screen: CalibrationScreen) -> Text {
        switch screen {
        case .pickStar: Text("Napauta kirkasta tähteä lähellä ristikkoa.")
        case .centerStar: Text("Siirrä kirkas tähti ristikon lähelle (alle 40 % säteestä).")
        case .holdStill: Text("Mitataan paikallaanoloa ja ajelehtimista.")
        case .press: Text("Pidä pohjassa, kunnes ruutu sanoo STOP.")
        case .release: Text("Odotetaan, että kuva pysähtyy.")
        case .intro, .stop, .result, .failure: Text("")
        }
    }

    // MARK: - Bottom card

    @ViewBuilder
    private func card(_ screen: CalibrationScreen) -> some View {
        switch screen {
        case .intro:
            VStack(spacing: 10) {
                Text("Kalibrointi")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Seuranta päälle ja hidas nopeustaso (3–4). Napauta kirkasta tähteä ristikon lähellä ja paina Kalibroi. Tee sitten kuten ruutu käskee: tatti ylös, STOP, tatti oikealle, STOP.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if controller.calibration != nil {
                    Button("Pikakalibrointi (1 liike)") { controller.startQuick() }
                        .buttonStyle(NightButtonStyle(font: .title.weight(.heavy)))
                    Button("Täysi kalibrointi") { controller.start() }
                        .buttonStyle(NightButtonStyle())
                } else {
                    Button("Kalibroi") { controller.start() }
                        .buttonStyle(NightButtonStyle(font: .title.weight(.heavy)))
                }
                Button("Peruuta") { controller.cancel() }
                    .buttonStyle(NightButtonStyle())
            }
            .foregroundStyle(NightTheme.red)
            .padding(12)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        case .result:
            if case .done(let result) = controller.prompt {
                ResultCard(result: result, controller: controller)
            }
        case .failure:
            if case .failed(let failure) = controller.prompt {
                FailureCard(failure: failure, controller: controller)
            }
        default:
            Button("Peruuta") { controller.cancel() }
                .buttonStyle(NightButtonStyle())
        }
    }
}

// MARK: - STOP

/// Full-screen STOP: alternating red and black, large text. A tap acknowledges (the core moves
/// on by itself when the star has stopped).
private struct StopFlash: View {
    let onAcknowledge: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { timeline in
            let on = Int(timeline.date.timeIntervalSinceReferenceDate / 0.25) % 2 == 0
            ZStack {
                (on ? NightTheme.red : Color.black).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("STOP")
                        .font(.system(size: 150, weight: .black, design: .rounded))
                    Text("Päästä tatti irti")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(on ? Color.black : NightTheme.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onAcknowledge)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("STOP, päästä tatti irti"))
    }
}

// MARK: - Result

private struct ResultCard: View {
    let result: CalibrationResult
    let controller: CalibrationController

    var body: some View {
        let level = CalibrationScreenMapper.qualityLevel(for: result)
        VStack(spacing: 8) {
            if result.isQuick {
                Text("Pikakalibrointi valmis")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
            } else {
                Text("Kalibrointi valmis")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
            }
            if let name = controller.profileName {
                Text("Profiili: \(name)").font(.headline)
            }
            Text("Kuvan kierto \(result.displayRotationDegrees, specifier: "%.1f")°")
                .font(.title2.weight(.semibold))
            Text("Tatti ylös = ruutu ylös.")
                .font(.body)
            if result.mirrored {
                Text("Kuva on peilattu. Tarkista SynScanin suuntien kääntöasetukset. Tatti ja ruutu täsmäävät, mutta kuva ei vastaa taivasta paljain silmin.")
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Circle().fill(color(level)).frame(width: 22, height: 22)
                qualityText(level)
                    .font(.title3.weight(.bold))
                Text("kohtisuoruus \(AngleMath.degrees(result.orthogonalityError), specifier: "%.1f")°")
                    .font(.system(.callout, design: .monospaced))
            }
            Button("Valmis") { controller.accept() }
                .buttonStyle(NightButtonStyle(font: .title.weight(.heavy)))
            Button("Kalibroi uudelleen") { controller.retry() }
                .buttonStyle(NightButtonStyle())
        }
        .foregroundStyle(NightTheme.red)
        .padding(12)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(_ level: CalibrationQualityLevel) -> Color {
        switch level {
        case .green: Color(red: 0.15, green: 0.65, blue: 0.20)
        case .yellow: Color(red: 0.85, green: 0.65, blue: 0.10)
        case .red: NightTheme.red
        }
    }

    private func qualityText(_ level: CalibrationQualityLevel) -> Text {
        switch level {
        case .green: Text("HYVÄ")
        case .yellow: Text("HUOMIO")
        case .red: Text("HUONO")
        }
    }
}

// MARK: - Failure

private struct FailureCard: View {
    let failure: CalibrationFailure
    let controller: CalibrationController

    var body: some View {
        VStack(spacing: 10) {
            Text("Kalibrointi epäonnistui")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            if let name = controller.profileName {
                Text("Profiili: \(name)").font(.headline)
            }
            message
                .font(.title3)
                .multilineTextAlignment(.center)
            Button("Yritä uudelleen") { controller.retry() }
                .buttonStyle(NightButtonStyle(font: .title.weight(.heavy)))
            Button("Peruuta") { controller.cancel() }
                .buttonStyle(NightButtonStyle())
        }
        .foregroundStyle(NightTheme.red)
        .padding(12)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
    }

    private var message: Text {
        switch failure {
        case .starLost:
            Text("Tähti katosi. Valitse kirkkaampi tähti, tai tarkenna kuva, ja yritä uudelleen.")
        case .noMotionDetected:
            Text("Tähti ei liikkunut. Paina tattia ja pidä se pohjassa. Tarkista, että jalusta on päällä ja nopeustaso ei ole 1.")
        case .notSettled:
            Text("Kuva ei rauhoittunut. Älä koske putkeen tai jalustaan, odota hetki ja yritä uudelleen.")
        case .moveTooShort(let displacement, let target):
            Text("Liike jäi liian lyhyeksi (\(displacement, specifier: "%.0f") / \(target, specifier: "%.0f") px). Pidä tattia pohjassa, kunnes ruutu sanoo STOP.")
        case .nearEdge:
            Text("Tähti meni liian lähelle kentän reunaa. Aloita tähdestä, joka on lähempänä ristikkoa.")
        case .orthogonalityBad(let degrees):
            Text("Liikkeet eivät olleet kohtisuorassa (poikkeama \(degrees, specifier: "%.0f")°). Paina tatti suoraan ylös ja sitten suoraan oikealle.")
        case .degenerate:
            Text("Liikkeitä ei voitu erottaa toisistaan. Paina ensin suoraan ylös, sitten suoraan oikealle.")
        case .timeout:
            Text("Liike kesti liian kauan. Pienennä nopeustasoa tai pidä tattia pohjassa pidempään.")
        }
    }
}
