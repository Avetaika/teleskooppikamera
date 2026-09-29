import Foundation
import TeleskooppiCore

/// Version information shown on screen, written to the log and to every capability report.
enum AppInfo {
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Version of the linked `TeleskooppiCore` package.
    static var coreVersion: String { TeleskooppiCore.version }

    /// e.g. `app 0.1.0 (12) · core 0.0.1`
    static var summary: String {
        "app \(marketingVersion) (\(buildNumber)) · core \(coreVersion)"
    }

    /// True when the process is hosting unit tests (simulator in CI has no camera).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Hardware model identifier, e.g. `iPhone18,3`.
    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
