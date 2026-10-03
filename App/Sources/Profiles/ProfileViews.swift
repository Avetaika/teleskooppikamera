import SwiftUI
import TeleskooppiCore

/// The single entry point in `RootView`: a button that opens the profile sheet.
struct ProfileEntryButton: View {
    let model: AppModel
    @State private var manager = ProfileManager()
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            VStack(spacing: 0) {
                Image(systemName: "eyeglasses").font(.title3.weight(.bold))
                Text(manager.active?.eyepiece.label ?? String(localized: "Okulaari"))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .buttonStyle(NightButtonStyle(font: .title2))
        .frame(width: NightTheme.buttonHeight)
        .accessibilityLabel(Text("Okulaariprofiilit"))
        .onAppear {
            manager.onActivate = { [weak model] profile in model?.applyProfile(profile) }
        }
        .fullScreenCover(isPresented: $showSheet) {
            ProfileSheet(manager: manager, model: model, isPresented: $showSheet)
        }
    }
}

/// Start choices and the profile picker. Big buttons only (gloves).
struct ProfileSheet: View {
    let manager: ProfileManager
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var showNew = false

    var body: some View {
        ZStack {
            NightTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    Text("Okulaari ja kalibrointi")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(NightTheme.red)
                    startChoices
                    Divider().overlay(NightTheme.red.opacity(0.5))
                    ForEach(manager.profiles) { profile in
                        ProfileRow(profile: profile, isActive: profile.id == manager.activeID) {
                            manager.activate(id: profile.id)
                            isPresented = false
                        }
                    }
                    Button("Uusi profiili") { showNew = true }
                        .buttonStyle(NightButtonStyle())
                    Button("Sulje") {
                        manager.updateActive(opticalCenter: model.display.opticalCenter, fieldRadius: nil,
                                             camera: model.currentCameraSnapshot())
                        isPresented = false
                    }
                    .buttonStyle(NightButtonStyle())
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showNew) {
            NewProfileForm(manager: manager, isPresented: $showNew, onCreated: { isPresented = false })
        }
    }

    @ViewBuilder
    private var startChoices: some View {
        Button("Käytä edellistä") {
            manager.start(.usePrevious)
            isPresented = false
        }
        .buttonStyle(NightButtonStyle())
        .disabled(!manager.canUsePrevious)
        Button("Pikakalibrointi") {
            manager.start(.quickCalibrate)
            isPresented = false
        }
        .buttonStyle(NightButtonStyle())
        .disabled(!manager.canQuickCalibrate)
        Button("Kalibroi uudelleen") {
            manager.start(.recalibrate)
            isPresented = false
        }
        .buttonStyle(NightButtonStyle())
    }
}

struct ProfileRow: View {
    let profile: SetupProfile
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(profile.name).font(.title3.weight(.bold))
                Text(Self.details(profile.eyepiece))
                    .font(.footnote)
                Text(profile.calibration == nil ? String(localized: "Ei kalibroitu") : String(localized: "Kalibroitu"))
                    .font(.caption2)
            }
        }
        .buttonStyle(NightButtonStyle(isSelected: isActive))
    }

    static func details(_ e: EyepieceProfile) -> String {
        let mag = String(format: "%.0f×", e.magnification)
        let tfov = String(format: "%.2f°", e.trueFOVDegrees)
        let pupil = String(format: "%.1f mm", e.exitPupilMM)
        return "\(mag) · \(String(localized: "kenttä")) \(tfov) · \(String(localized: "pupilli")) \(pupil)"
    }
}

struct NewProfileForm: View {
    let manager: ProfileManager
    @Binding var isPresented: Bool
    var onCreated: () -> Void
    @State private var focal = 25.0
    @State private var barlow = 1.0
    @State private var afov = EyepieceProfile.defaultApparentFOV
    @State private var note = ""

    private var preview: EyepieceProfile {
        EyepieceProfile(focalLengthMM: focal, barlowFactor: barlow, apparentFOVDegrees: afov)
    }

    var body: some View {
        ZStack {
            NightTheme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Uusi profiili").font(.title2.weight(.bold)).foregroundStyle(NightTheme.red)
                Stepper(value: $focal, in: 2...60, step: 1) {
                    Text("Okulaari \(focal, specifier: "%.0f") mm")
                }
                Stepper(value: $barlow, in: 1...3, step: 1) {
                    Text("Barlow \(barlow, specifier: "%.0f")×")
                }
                Stepper(value: $afov, in: 30...100, step: 1) {
                    Text("Näennäinen kenttä \(afov, specifier: "%.0f")°")
                }
                TextField("Adapterin asento", text: $note)
                    .textFieldStyle(.roundedBorder)
                Text(ProfileRow.details(preview)).font(.footnote)
                Spacer()
                Button("Luo") {
                    if manager.createProfile(name: nil, focalLengthMM: focal, barlowFactor: barlow,
                                             apparentFOV: afov, adapterNote: note) != nil {
                        isPresented = false
                        onCreated()
                    }
                }
                .buttonStyle(NightButtonStyle())
                Button("Peruuta") { isPresented = false }
                    .buttonStyle(NightButtonStyle())
            }
            .foregroundStyle(NightTheme.red)
            .padding(16)
        }
    }
}
