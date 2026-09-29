import Foundation
import Observation
import SwiftUI

/// Main-actor state for the phase 0 UI.
@MainActor
@Observable
final class AppModel {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case running
        case denied
        case unavailable(String)
    }

    struct SavedReport: Equatable {
        var url: URL?
        var text: String
    }

    private(set) var cameraState: CameraState = .idle
    private(set) var isGeneratingReport = false
    private(set) var lastReport: SavedReport?
    private(set) var reportError: String?

    let camera = CameraService()

    private let log = AppLog.app

    func startCamera() async {
        guard !AppInfo.isRunningTests else {
            cameraState = .unavailable("unit tests")
            return
        }
        switch CameraService.authorization {
        case .authorized:
            break
        case .denied:
            cameraState = .denied
            log.notice("Camera permission denied")
            return
        case .notDetermined:
            cameraState = .requestingPermission
            let granted = await CameraService.requestAccess()
            log.notice("Camera permission request: granted=\(granted)")
            guard granted else {
                cameraState = .denied
                return
            }
        }
        do {
            try await camera.start()
            cameraState = .running
        } catch {
            log.error("Camera start failed: \(error.localizedDescription)")
            cameraState = .unavailable(error.localizedDescription)
        }
    }

    func stopCamera() async {
        guard cameraState == .running else { return }
        await camera.stop()
        cameraState = .idle
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await startCamera() }
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await stopCamera() }
        default:
            break
        }
    }

    /// Runs the capability probe (about 5–10 s, including the 1 s exposure test) and writes
    /// `Documents/capability-<timestamp>.txt`.
    func generateReport() async {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        reportError = nil
        defer { isGeneratingReport = false }

        log.notice("Capability report started")
        let context = DeviceContext.current()
        let report = await CapabilityProbe.run(camera: camera, context: context)
        let text = report.rendered()
        let url = AppFiles.documents.appending(path: CapabilityReport.fileName(for: report.createdAt))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastReport = SavedReport(url: url, text: text)
            log.notice("Capability report written: \(url.lastPathComponent) (\(text.utf8.count) bytes)")
        } catch {
            reportError = error.localizedDescription
            lastReport = SavedReport(url: nil, text: text)
            log.error("Capability report write failed: \(error.localizedDescription)")
        }
    }
}
