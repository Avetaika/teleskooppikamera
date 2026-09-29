import SwiftUI

@main
struct TeleskooppikameraApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let device = UIDevice.current
        AppLog.app.notice("App start: \(AppInfo.summary), \(device.systemName) \(device.systemVersion), \(AppInfo.hardwareModel)")
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}
