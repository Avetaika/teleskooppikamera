import Foundation

/// Well-known file locations. `Documents/` is visible in the Files app and in iTunes/Finder
/// file sharing (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
enum AppFiles {
    static var documents: URL { URL.documentsDirectory }

    static var logFile: URL { documents.appending(path: "app-log.txt") }

    static var previousLogFile: URL { documents.appending(path: "app-log.previous.txt") }

    /// Timestamp used in file names, e.g. `20260929-213005`. Uses the POSIX locale so the
    /// name is stable regardless of the user's region settings.
    static func fileTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
