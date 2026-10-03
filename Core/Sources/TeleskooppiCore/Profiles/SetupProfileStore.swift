import Foundation

public protocol SetupProfileStore: Sendable {
    func loadAll() throws -> [SetupProfile]
    func save(_ profile: SetupProfile) throws
    func delete(id: UUID) throws
    /// Id of the profile used last, if any.
    func lastUsedID() throws -> UUID?
    func setLastUsedID(_ id: UUID?) throws
}

/// In-memory store for tests and previews.
public final class InMemoryProfileStore: SetupProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [UUID: SetupProfile] = [:]
    private var lastUsed: UUID?

    public init(_ initial: [SetupProfile] = []) {
        for p in initial { profiles[p.id] = p }
    }

    public func loadAll() throws -> [SetupProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.values.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    public func save(_ profile: SetupProfile) throws {
        lock.lock(); defer { lock.unlock() }
        profiles[profile.id] = profile
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        profiles[id] = nil
        if lastUsed == id { lastUsed = nil }
    }

    public func lastUsedID() throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return lastUsed
    }

    public func setLastUsedID(_ id: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        lastUsed = id
    }
}

public enum ProfileStoreError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Versioned on-disk document. Current schema: v2 (v1 had no `lastUsedID` and called the
/// adapter note `adapterPosition`).
struct ProfileDocument: Codable {
    static let currentVersion = 2
    var version: Int
    var lastUsedID: UUID?
    var profiles: [SetupProfile]
}

/// JSON file store with atomic writes and schema migration.
public final class JSONFileProfileStore: SetupProfileStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func readDocument() throws -> ProfileDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProfileDocument(version: ProfileDocument.currentVersion, lastUsedID: nil, profiles: [])
        }
        return try Self.migrate(try Data(contentsOf: url))
    }

    /// Decodes any supported schema version into the current document.
    static func migrate(_ data: Data) throws -> ProfileDocument {
        struct Header: Decodable { var version: Int }
        let version = try makeDecoder().decode(Header.self, from: data).version
        switch version {
        case 1:
            struct V1Profile: Decodable {
                var id: UUID
                var name: String
                var eyepiece: EyepieceProfile
                var opticalCenter: Vec2?
                var fieldRadius: Double?
                var calibration: CalibrationResult?
                var camera: CameraSettingsSnapshot?
                var adapterPosition: String?
                var createdAt: Date
                var updatedAt: Date?
            }
            struct V1Document: Decodable { var profiles: [V1Profile] }
            let doc = try makeDecoder().decode(V1Document.self, from: data)
            let profiles = doc.profiles.map {
                SetupProfile(id: $0.id, name: $0.name, eyepiece: $0.eyepiece, opticalCenter: $0.opticalCenter,
                             fieldRadius: $0.fieldRadius, calibration: $0.calibration, camera: $0.camera,
                             adapterNote: $0.adapterPosition ?? "", createdAt: $0.createdAt,
                             updatedAt: $0.updatedAt)
            }
            return ProfileDocument(version: ProfileDocument.currentVersion, lastUsedID: nil, profiles: profiles)
        case ProfileDocument.currentVersion:
            return try makeDecoder().decode(ProfileDocument.self, from: data)
        default:
            throw ProfileStoreError.unsupportedVersion(version)
        }
    }

    private func write(_ document: ProfileDocument) throws {
        let data = try Self.makeEncoder().encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func mutate(_ change: (inout ProfileDocument) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try readDocument()
        change(&doc)
        doc.version = ProfileDocument.currentVersion
        try write(doc)
    }

    public func loadAll() throws -> [SetupProfile] {
        lock.lock(); defer { lock.unlock() }
        return try readDocument().profiles
    }

    public func save(_ profile: SetupProfile) throws {
        try mutate { doc in
            if let i = doc.profiles.firstIndex(where: { $0.id == profile.id }) {
                doc.profiles[i] = profile
            } else {
                doc.profiles.append(profile)
            }
        }
    }

    public func delete(id: UUID) throws {
        try mutate { doc in
            doc.profiles.removeAll { $0.id == id }
            if doc.lastUsedID == id { doc.lastUsedID = nil }
        }
    }

    public func lastUsedID() throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return try readDocument().lastUsedID
    }

    public func setLastUsedID(_ id: UUID?) throws {
        try mutate { $0.lastUsedID = id }
    }
}
