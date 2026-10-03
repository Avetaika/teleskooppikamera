import Foundation
import Observation
import TeleskooppiCore

/// Calibration persistence keyed by profile. Same shape as the `CalibrationPersisting` protocol
/// being defined in `App/Sources/Calibration/`; once that is on main, add a one-line conformance
/// or replace this protocol with it.
@MainActor
protocol ProfileCalibrationPersisting: AnyObject {
    func load(profileID: UUID) -> CalibrationResult?
    func save(_ result: CalibrationResult, profileID: UUID)
}

/// Choices on the start screen.
enum StartChoice: Sendable, CaseIterable {
    /// Reuse the last profile and its calibration as is.
    case usePrevious
    /// Full two-move calibration.
    case recalibrate
    /// One-move quick calibration reusing the stored geometry (D-06).
    case quickCalibrate
}

/// What to suggest after the eyepiece changed.
enum CalibrationSuggestion: Sendable, Equatable {
    /// The new profile already has a calibration: only the phone angle may have changed.
    case quick
    /// The new profile has no calibration yet.
    case full
}

/// Owns the setup profiles: persistence, active profile and the start-screen decisions.
/// Applying a profile to camera/display is delegated to `onActivate`; starting calibration flows to
/// `onRecalibrate` / `onQuickCalibrate` (wired by the calibration UI).
@MainActor
@Observable
final class ProfileManager: ProfileCalibrationPersisting {
    private(set) var profiles: [SetupProfile] = []
    private(set) var activeID: UUID?
    private(set) var lastError: String?
    /// Set after an eyepiece change until a calibration is started or saved.
    private(set) var suggestion: CalibrationSuggestion?

    @ObservationIgnored var onActivate: ((SetupProfile) -> Void)?
    @ObservationIgnored var onRecalibrate: (() -> Void)?
    @ObservationIgnored var onQuickCalibrate: (() -> Void)?

    @ObservationIgnored private let store: any SetupProfileStore
    @ObservationIgnored private let now: () -> Date

    /// `Application Support/profiles.json`.
    static func defaultStoreURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "profiles.json")
    }

    init(store: any SetupProfileStore = JSONFileProfileStore(url: ProfileManager.defaultStoreURL()),
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        load()
    }

    // MARK: - Queries

    var active: SetupProfile? { profiles.first { $0.id == activeID } }

    /// The profile used last, which the start screen offers to reuse.
    var previous: SetupProfile? { active }

    /// "Käytä edellistä" needs a stored calibration.
    var canUsePrevious: Bool { previous?.calibration != nil }

    /// Quick calibration only makes sense on top of an existing calibration.
    var canQuickCalibrate: Bool { active?.calibration != nil }

    func profile(id: UUID) -> SetupProfile? { profiles.first { $0.id == id } }

    // MARK: - Loading

    private func load() {
        do {
            var all = try store.loadAll()
            if all.isEmpty {
                all = SetupProfile.defaults(now: now())
                for p in all { try store.save(p) }
            }
            profiles = all
            if let id = try store.lastUsedID(), all.contains(where: { $0.id == id }) {
                activeID = id
            }
        } catch {
            lastError = "\(error)"
            profiles = SetupProfile.defaults(now: now())
        }
    }

    // MARK: - Start screen

    /// Handles a start-screen choice. Returns the action actually taken (falls back to a full
    /// calibration when the requested shortcut is not possible).
    @discardableResult
    func start(_ choice: StartChoice) -> StartChoice {
        switch choice {
        case .usePrevious:
            if canUsePrevious, let id = activeID {
                activate(id: id)
                return .usePrevious
            }
            return start(.recalibrate)
        case .quickCalibrate:
            if canQuickCalibrate, let id = activeID {
                activate(id: id)
                suggestion = nil
                onQuickCalibrate?()
                return .quickCalibrate
            }
            return start(.recalibrate)
        case .recalibrate:
            if let id = activeID { activate(id: id) }
            suggestion = nil
            onRecalibrate?()
            return .recalibrate
        }
    }

    // MARK: - Activation

    /// Makes a profile active (eyepiece switch) and applies its stored centre and camera settings.
    func activate(id: UUID) {
        guard var profile = profile(id: id) else { return }
        profile.lastUsedAt = now()
        persist(profile)
        if let old = activeID, old != id {
            suggestion = profile.calibration != nil ? .quick : .full
        }
        activeID = id
        do { try store.setLastUsedID(id) } catch { lastError = "\(error)" }
        onActivate?(profile)
    }

    // MARK: - Editing

    /// Creates and activates a new profile. Returns nil for invalid optics.
    @discardableResult
    func createProfile(name: String?, focalLengthMM: Double, barlowFactor: Double = 1,
                       apparentFOV: Double = EyepieceProfile.defaultApparentFOV,
                       adapterNote: String = "") -> SetupProfile? {
        guard focalLengthMM > 0, barlowFactor >= 1, apparentFOV > 0, apparentFOV < 180 else { return nil }
        let eyepiece = EyepieceProfile(focalLengthMM: focalLengthMM, barlowFactor: barlowFactor,
                                       apparentFOVDegrees: apparentFOV)
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let profile = SetupProfile(name: trimmed.isEmpty ? eyepiece.label : trimmed, eyepiece: eyepiece,
                                   adapterNote: adapterNote, createdAt: now())
        persist(profile)
        activate(id: profile.id)
        return profile
    }

    /// Makes the first profile active without applying it (first launch, nothing chosen yet), so a
    /// finished calibration has somewhere to be stored.
    func adoptDefaultActive() {
        guard activeID == nil, let first = profiles.first else { return }
        activeID = first.id
        do { try store.setLastUsedID(first.id) } catch { lastError = "\(error)" }
    }

    func clearCalibration(profileID: UUID) {
        guard var profile = profile(id: profileID) else { return }
        profile.calibration = nil
        profile.updatedAt = now()
        persist(profile)
    }

    func delete(id: UUID) {
        do { try store.delete(id: id) } catch { lastError = "\(error)" }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    /// Stores the current optical centre / field radius / camera settings into the active profile.
    func updateActive(opticalCenter: Vec2?, fieldRadius: Double?, camera: CameraSettingsSnapshot?) {
        guard var profile = active else { return }
        profile.opticalCenter = opticalCenter
        if let fieldRadius { profile.fieldRadius = fieldRadius }
        if let camera { profile.camera = camera }
        profile.updatedAt = now()
        persist(profile)
    }

    private func persist(_ profile: SetupProfile) {
        do { try store.save(profile) } catch { lastError = "\(error)" }
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
    }

    // MARK: - ProfileCalibrationPersisting

    func load(profileID: UUID) -> CalibrationResult? {
        profile(id: profileID)?.calibration
    }

    func save(_ result: CalibrationResult, profileID: UUID) {
        guard var profile = profile(id: profileID) else { return }
        profile.calibration = result
        suggestion = nil
        profile.opticalCenter = result.opticalCenter
        if let radius = result.fieldRadius { profile.fieldRadius = radius }
        profile.updatedAt = now()
        persist(profile)
    }
}
