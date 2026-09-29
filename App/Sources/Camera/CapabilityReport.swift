import Foundation

/// Plain-text camera capability report (phase 0, docs/device-iphone17.md).
///
/// The model is deliberately free of AVFoundation types so that formatting can be unit
/// tested in the simulator, which has no camera.
struct CapabilityReport: Sendable, Equatable {
    struct Section: Sendable, Equatable {
        var title: String
        var lines: [String]

        init(_ title: String, lines: [String] = []) {
            self.title = title
            self.lines = lines
        }

        /// Appends `key: value`.
        mutating func add(_ key: String, _ value: some CustomStringConvertible) {
            lines.append("\(key): \(value.description)")
        }

        /// Appends a free-form line.
        mutating func note(_ text: String) {
            lines.append(text)
        }
    }

    var createdAt: Date
    var sections: [Section]

    init(createdAt: Date = .now, sections: [Section] = []) {
        self.createdAt = createdAt
        self.sections = sections
    }

    /// `capability-20260929-213005.txt`
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        "capability-\(AppFiles.fileTimestamp(date, timeZone: timeZone)).txt"
    }

    func rendered(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let stamp = formatter.string(from: createdAt)
        var out = "TELESKOOPPIKAMERA – CAPABILITY REPORT\n"
        out += "created: \(stamp)\n"
        for section in sections {
            out += "\n== \(section.title) ==\n"
            for line in section.lines {
                out += line + "\n"
            }
        }
        return out
    }
}

/// Small formatting helpers shared by the report and the log.
enum CaptureFormatting {
    /// Four-character code as text, e.g. `0x34323066` → `420f`. Non-printable codes are
    /// shown in hex.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return String(format: "0x%08X", code)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Seconds with enough precision for exposure times (1/8000 s … 1 s).
    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        return String(format: "%.6f s", value)
    }

    /// Frame rate range, e.g. `1.0–30.0 fps`.
    static func fpsRange(min: Double, max: Double) -> String {
        String(format: "%.1f–%.1f fps", min, max)
    }

    static func dimensions(width: Int32, height: Int32) -> String {
        "\(width)x\(height)"
    }

    /// True for 4:3 frames such as 1920x1440 or 4032x3024.
    static func isFourByThree(width: Int32, height: Int32) -> Bool {
        Int(width) * 3 == Int(height) * 4
    }

    static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }

    static func colorSpaceName(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: "sRGB"
        case 1: "P3_D65"
        case 2: "HLG_BT2020"
        case 3: "appleLog"
        default: "colorSpace(\(rawValue))"
        }
    }
}
