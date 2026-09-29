import Foundation
import os

/// Severity of an app log entry. Only `.notice` and above are recorded: without a debugger
/// the log must stay short enough to read on the phone (plan.md 6.1).
enum LogLevel: String, Sendable {
    case notice = "NOTICE"
    case error = "ERROR"
    case fault = "FAULT"
}

/// Logs to the unified system log (`os.Logger`, visible with `idevicesyslog`) and appends the
/// same line to `Documents/app-log.txt`, which can be viewed and shared inside the app.
struct AppLogger: Sendable {
    let category: String
    private let logger: Logger
    private let file: LogFile

    init(category: String, file: LogFile = AppLog.file) {
        self.category = category
        self.logger = Logger(subsystem: AppLog.subsystem, category: category)
        self.file = file
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        file.append(level: .notice, category: category, message: message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file.append(level: .error, category: category, message: message)
    }

    func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        file.append(level: .fault, category: category, message: message)
    }
}

enum AppLog {
    static let subsystem = "fi.avetaika.teleskooppikamera"
    static let file = LogFile(url: AppFiles.logFile, previousURL: AppFiles.previousLogFile)

    static let app = AppLogger(category: "app")
    static let camera = AppLogger(category: "camera")
    static let report = AppLogger(category: "report")
}

/// Append-only text log file. All file access happens on a private serial queue, so the
/// type can be shared freely between threads and actors.
final class LogFile: @unchecked Sendable {
    let url: URL
    let previousURL: URL
    /// When the file grows beyond this, it is moved to `previousURL` and a new file started.
    let maxBytes: Int

    private let queue = DispatchQueue(label: "fi.avetaika.teleskooppikamera.logfile")
    // Accessed only on `queue`.
    private let timestampFormatter: DateFormatter

    init(url: URL, previousURL: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.previousURL = previousURL
        self.maxBytes = maxBytes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.timestampFormatter = formatter
    }

    func append(level: LogLevel, category: String, message: String, date: Date = .now) {
        queue.async {
            let line = "\(self.timestampFormatter.string(from: date)) \(level.rawValue) [\(category)] \(message)\n"
            self.write(Data(line.utf8))
        }
    }

    /// Returns the current log text (at most the last `maxCharacters` characters).
    func readAll(maxCharacters: Int = 200_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return "" }
            let text = String(decoding: data, as: UTF8.self)
            guard text.count > maxCharacters else { return text }
            return "…\n" + String(text.suffix(maxCharacters))
        }
    }

    /// Removes the current and previous log files.
    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    // MARK: - Private (queue only)

    private func write(_ data: Data) {
        let fm = FileManager.default
        rotateIfNeeded(fm)
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Nothing sensible to do: the entry is still in the unified system log.
        }
    }

    private func rotateIfNeeded(_ fm: FileManager) {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > maxBytes else { return }
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: url, to: previousURL)
    }
}
