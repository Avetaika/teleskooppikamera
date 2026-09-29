import Foundation

// Recording format (D-11): a directory `session-YYYYMMDD-HHMMSS.tcs/` containing
//
//   meta.json     SessionMeta (device, format, profile, calibration, notes)
//   frames.bin    a sequence of frames, each a fixed 48-byte header followed by the 8-bit luma payload
//   events.jsonl  one JSON object (SessionEvent) per line
//
// frames.bin header (all integers little-endian, floats as IEEE-754 bit patterns):
//
//   off  size  field
//     0     4  magic "TCSF"
//     4     2  version (1)
//     6     2  header size in bytes (48; readers skip unknown extra bytes)
//     8     8  timestamp, seconds (Float64)
//    16     8  exposure, seconds (Float64)
//    24     4  ISO (Float32)
//    28     4  lens position (Float32)
//    32     4  width
//    36     4  height
//    40     4  stride (bytes = pixels, 8-bit)
//    44     4  payload size in bytes (= stride * height)

public enum SessionFormat {
    public static let magic: [UInt8] = [0x54, 0x43, 0x53, 0x46]  // "TCSF"
    public static let version: UInt16 = 1
    public static let headerSize = 48
    public static let metaFileName = "meta.json"
    public static let framesFileName = "frames.bin"
    public static let eventsFileName = "events.jsonl"
    public static let directoryExtension = "tcs"

    /// `session-YYYYMMDD-HHMMSS.tcs` (UTC).
    public static func directoryName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        return "session-\(String(format: "%04d", c.year ?? 0))\(two(c.month))\(two(c.day))-"
            + "\(two(c.hour))\(two(c.minute))\(two(c.second)).\(directoryExtension)"
    }

    static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case notADirectory(String)
    case alreadyExists(String)
    case missingFile(String)
    case badMagic(frame: Int)
    case unsupportedVersion(UInt16)
    case corruptHeader(frame: Int)
    case frameIndexOutOfRange(Int)
    case truncatedFrame(Int)
    case invalidImage
    case finished
    case malformedEvent(line: Int)

    public var description: String {
        switch self {
        case .notADirectory(let p): return "not a session directory: \(p)"
        case .alreadyExists(let p): return "session already exists: \(p)"
        case .missingFile(let f): return "missing file: \(f)"
        case .badMagic(let f): return "bad frame magic at frame \(f)"
        case .unsupportedVersion(let v): return "unsupported frame version \(v)"
        case .corruptHeader(let f): return "corrupt frame header at frame \(f)"
        case .frameIndexOutOfRange(let i): return "frame index out of range: \(i)"
        case .truncatedFrame(let i): return "truncated frame \(i)"
        case .invalidImage: return "invalid image"
        case .finished: return "session writer already finished"
        case .malformedEvent(let l): return "malformed event on line \(l)"
        }
    }
}

// MARK: - Metadata

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    public var camera: String?

    public init(model: String, systemVersion: String, appVersion: String, camera: String? = nil) {
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.camera = camera
    }
}

public struct FrameFormat: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: String
    /// Binning applied to the sensor image (2 = 1920x1440 -> 960x720).
    public var binning: Int
    /// Nominal recording rate (Hz).
    public var frameRate: Double

    public init(width: Int, height: Int, pixelFormat: String = "luma8", binning: Int = 2, frameRate: Double = 10) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.binning = binning
        self.frameRate = frameRate
    }
}

/// Setup information needed to analyse the recording later.
public struct SessionProfile: Codable, Equatable, Sendable {
    public var eyepiece: String?
    /// SynScan speed level used for the moves (2...6), if known.
    public var speedLevel: Int?
    public var opticalCenter: Vec2?
    public var fieldRadius: Double?

    public init(eyepiece: String? = nil, speedLevel: Int? = nil, opticalCenter: Vec2? = nil, fieldRadius: Double? = nil) {
        self.eyepiece = eyepiece
        self.speedLevel = speedLevel
        self.opticalCenter = opticalCenter
        self.fieldRadius = fieldRadius
    }
}

public struct SessionMeta: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var device: DeviceInfo
    public var format: FrameFormat
    public var profile: SessionProfile?
    /// Calibration active during (or produced by) the recording.
    public var calibration: CalibrationResult?
    public var notes: String
    /// Set when the writer finishes.
    public var frameCount: Int?

    public init(createdAt: Date = Date(), device: DeviceInfo, format: FrameFormat, profile: SessionProfile? = nil,
                calibration: CalibrationResult? = nil, notes: String = "", frameCount: Int? = nil) {
        formatVersion = Int(SessionFormat.version)
        self.createdAt = createdAt
        self.device = device
        self.format = format
        self.profile = profile
        self.calibration = calibration
        self.notes = notes
        self.frameCount = frameCount
    }
}

/// Per-frame camera data stored in the frame header.
public struct FrameMeta: Codable, Equatable, Sendable {
    /// Seconds (monotonic, mid-exposure).
    public var timestamp: Double
    /// Exposure time in seconds.
    public var exposure: Double
    public var iso: Float
    public var lensPosition: Float

    public init(timestamp: Double, exposure: Double = 0, iso: Float = 0, lensPosition: Float = 0) {
        self.timestamp = timestamp
        self.exposure = exposure
        self.iso = iso
        self.lensPosition = lensPosition
    }
}

public struct SessionFrame: Sendable, Equatable {
    public var meta: FrameMeta
    public var image: GrayImage8

    public init(meta: FrameMeta, image: GrayImage8) {
        self.meta = meta
        self.image = image
    }
}

/// UI, calibration and detection events (one JSON line each).
public struct SessionEvent: Codable, Equatable, Sendable {
    /// Same time base as the frame timestamps.
    public var t: Double
    public var type: String
    public var text: [String: String]?
    public var values: [String: Double]?

    public init(t: Double, type: String, text: [String: String]? = nil, values: [String: Double]? = nil) {
        self.t = t
        self.type = type
        self.text = text
        self.values = values
    }

    /// Calibration analysis window (replay only feeds `CalibrationSession` between these).
    public static let calibrationStart = "calibration.start"
    public static let calibrationEnd = "calibration.end"
    /// The user tapped a star to lock on: `values["x"]`, `values["y"]`.
    public static let starSelect = "star.select"
    /// Prompt change: `text["prompt"]`.
    public static let prompt = "prompt"
    /// Free-form note: `text["note"]`.
    public static let note = "note"
}

// MARK: - Little-endian helpers

private func appendLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
}

private func readLE<T: FixedWidthInteger & UnsignedInteger>(_ bytes: [UInt8], _ offset: Int, _ type: T.Type) -> T {
    var v: T = 0
    for i in 0..<(T.bitWidth / 8) { v |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
    return v
}

// MARK: - Writer

/// Streams a session to disk: every `append` writes straight to `frames.bin` (nothing is buffered
/// in memory), every event to `events.jsonl`. `meta.json` is written at creation and rewritten by
/// `finish()` with the frame count. Thread-safe.
public final class SessionWriter: @unchecked Sendable {
    public let directory: URL
    public private(set) var meta: SessionMeta
    public private(set) var frameCount = 0
    private let lock = NSLock()
    private var framesHandle: FileHandle?
    private var eventsHandle: FileHandle?
    private let metaEncoder = SessionFormat.makeEncoder(pretty: true)
    private let lineEncoder = SessionFormat.makeEncoder(pretty: false)

    /// Creates `directory` (which must not already contain a session).
    public init(directory: URL, meta: SessionMeta) throws {
        self.directory = directory
        self.meta = meta
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let framesURL = directory.appendingPathComponent(SessionFormat.framesFileName)
        let eventsURL = directory.appendingPathComponent(SessionFormat.eventsFileName)
        if fm.fileExists(atPath: framesURL.path) { throw SessionError.alreadyExists(directory.path) }
        guard fm.createFile(atPath: framesURL.path, contents: nil),
              fm.createFile(atPath: eventsURL.path, contents: nil) else {
            throw SessionError.missingFile(directory.path)
        }
        framesHandle = try FileHandle(forWritingTo: framesURL)
        eventsHandle = try FileHandle(forWritingTo: eventsURL)
        try writeMeta()
    }

    /// Creates `<parent>/session-YYYYMMDD-HHMMSS.tcs` named after `date` (UTC).
    public static func create(in parent: URL, date: Date = Date(), meta: SessionMeta) throws -> SessionWriter {
        try SessionWriter(directory: parent.appendingPathComponent(SessionFormat.directoryName(for: date),
                                                                   isDirectory: true), meta: meta)
    }

    deinit {
        try? framesHandle?.close()
        try? eventsHandle?.close()
    }

    private func writeMeta() throws {
        let data = try metaEncoder.encode(meta)
        try data.write(to: directory.appendingPathComponent(SessionFormat.metaFileName), options: .atomic)
    }

    /// Appends one frame. `image` must be non-empty with `stride >= width`.
    public func append(_ image: GrayImage8, meta frameMeta: FrameMeta) throws {
        guard image.width > 0, image.height > 0, image.stride >= image.width else { throw SessionError.invalidImage }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = framesHandle else { throw SessionError.finished }
        let payload = image.stride * image.height
        var header = [UInt8]()
        header.reserveCapacity(SessionFormat.headerSize)
        header.append(contentsOf: SessionFormat.magic)
        appendLE(SessionFormat.version, to: &header)
        appendLE(UInt16(SessionFormat.headerSize), to: &header)
        appendLE(frameMeta.timestamp.bitPattern, to: &header)
        appendLE(frameMeta.exposure.bitPattern, to: &header)
        appendLE(frameMeta.iso.bitPattern, to: &header)
        appendLE(frameMeta.lensPosition.bitPattern, to: &header)
        appendLE(UInt32(image.width), to: &header)
        appendLE(UInt32(image.height), to: &header)
        appendLE(UInt32(image.stride), to: &header)
        appendLE(UInt32(payload), to: &header)
        var data = Data(header)
        data.append(contentsOf: image.pixels.prefix(payload))
        if image.pixels.count < payload { data.append(Data(count: payload - image.pixels.count)) }
        try handle.write(contentsOf: data)
        frameCount += 1
    }

    public func appendEvent(_ event: SessionEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = eventsHandle else { throw SessionError.finished }
        var line = try lineEncoder.encode(event)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    /// Modifies the metadata (e.g. notes, calibration) and rewrites `meta.json`.
    public func updateMeta(_ change: (inout SessionMeta) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        change(&meta)
        try writeMeta()
    }

    /// Writes the final `meta.json` (with the frame count) and closes the files.
    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard framesHandle != nil else { return }
        meta.frameCount = frameCount
        try writeMeta()
        try framesHandle?.close()
        try eventsHandle?.close()
        framesHandle = nil
        eventsHandle = nil
    }
}

// MARK: - Reader

/// Random access reader. Opening scans the frame headers once (no pixel data is read) and builds an
/// index; `frame(at:)` then seeks directly. A partially written last frame (crash, full disk) is
/// ignored and reported by `isTruncated`. Thread-safe.
public final class SessionReader: @unchecked Sendable {
    public struct IndexEntry: Sendable, Equatable {
        public var offset: UInt64
        public var meta: FrameMeta
        public var width: Int
        public var height: Int
        public var stride: Int
        public var payloadOffset: UInt64
    }

    public let directory: URL
    public let meta: SessionMeta
    public let index: [IndexEntry]
    public let isTruncated: Bool
    private let lock = NSLock()
    private let handle: FileHandle

    public init(directory: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw SessionError.notADirectory(directory.path)
        }
        self.directory = directory
        let metaURL = directory.appendingPathComponent(SessionFormat.metaFileName)
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw SessionError.missingFile(SessionFormat.metaFileName)
        }
        meta = try SessionFormat.makeDecoder().decode(SessionMeta.self, from: Data(contentsOf: metaURL))
        let framesURL = directory.appendingPathComponent(SessionFormat.framesFileName)
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw SessionError.missingFile(SessionFormat.framesFileName)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let h = try FileHandle(forReadingFrom: framesURL)
        handle = h

        var entries = [IndexEntry]()
        var offset: UInt64 = 0
        var truncated = false
        let fixed = UInt64(SessionFormat.headerSize)
        while offset < size {
            if size - offset < fixed {
                truncated = true
                break
            }
            try h.seek(toOffset: offset)
            guard let data = try h.read(upToCount: SessionFormat.headerSize), data.count == SessionFormat.headerSize else {
                truncated = true
                break
            }
            let b = [UInt8](data)
            guard Array(b[0..<4]) == SessionFormat.magic else { throw SessionError.badMagic(frame: entries.count) }
            let version = readLE(b, 4, UInt16.self)
            guard version == SessionFormat.version else { throw SessionError.unsupportedVersion(version) }
            let headerSize = UInt64(readLE(b, 6, UInt16.self))
            let width = Int(readLE(b, 32, UInt32.self))
            let height = Int(readLE(b, 36, UInt32.self))
            let stride = Int(readLE(b, 40, UInt32.self))
            let payload = UInt64(readLE(b, 44, UInt32.self))
            guard headerSize >= fixed, width > 0, height > 0, stride >= width,
                  payload == UInt64(stride) * UInt64(height) else {
                throw SessionError.corruptHeader(frame: entries.count)
            }
            if offset + headerSize + payload > size {
                truncated = true
                break
            }
            let fm = FrameMeta(timestamp: Double(bitPattern: readLE(b, 8, UInt64.self)),
                               exposure: Double(bitPattern: readLE(b, 16, UInt64.self)),
                               iso: Float(bitPattern: readLE(b, 24, UInt32.self)),
                               lensPosition: Float(bitPattern: readLE(b, 28, UInt32.self)))
            entries.append(IndexEntry(offset: offset, meta: fm, width: width, height: height, stride: stride,
                                      payloadOffset: offset + headerSize))
            offset += headerSize + payload
        }
        index = entries
        isTruncated = truncated
    }

    deinit {
        try? handle.close()
    }

    public var frameCount: Int { index.count }

    /// Timestamp of the first / last frame.
    public var duration: Double {
        guard let a = index.first, let b = index.last else { return 0 }
        return b.meta.timestamp - a.meta.timestamp
    }

    public func frameMeta(at i: Int) throws -> FrameMeta {
        guard index.indices.contains(i) else { throw SessionError.frameIndexOutOfRange(i) }
        return index[i].meta
    }

    /// Reads the frame at `i` (0-based).
    public func frame(at i: Int) throws -> SessionFrame {
        guard index.indices.contains(i) else { throw SessionError.frameIndexOutOfRange(i) }
        let e = index[i]
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: e.payloadOffset)
        let count = e.stride * e.height
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw SessionError.truncatedFrame(i)
        }
        let image = GrayImage8(width: e.width, height: e.height, stride: e.stride, pixels: [UInt8](data))
        return SessionFrame(meta: e.meta, image: image)
    }

    /// All events, in file order. A malformed last line (interrupted write) is ignored.
    public func events() throws -> [SessionEvent] {
        let url = directory.appendingPathComponent(SessionFormat.eventsFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = SessionFormat.makeDecoder()
        var out = [SessionEvent]()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (i, line) in lines.enumerated() {
            do {
                out.append(try decoder.decode(SessionEvent.self, from: Data(line)))
            } catch {
                if i == lines.count - 1 { break }
                throw SessionError.malformedEvent(line: i + 1)
            }
        }
        return out
    }
}
