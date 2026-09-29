import Foundation
import TeleskooppiCore

// teleskooppi-cli: development tool for the platform-independent core (plan 3.1).
// Argument parsing is hand-rolled on purpose (no package dependencies).

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

/// Minimal `--key value` / `--flag` parser.
struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ args: ArraySlice<String>, flagNames: Set<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    values[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if flagNames.contains(key) {
                    flags.insert(key)
                } else if let v = it.next() {
                    values[key] = v
                } else {
                    throw CLIError(description: "missing value for --\(key)")
                }
            } else {
                positional.append(a)
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { values[name] }

    func double(_ name: String) throws -> Double? {
        guard let s = values[name] else { return nil }
        guard let v = Double(s) else { throw CLIError(description: "--\(name): not a number: \(s)") }
        return v
    }

    func int(_ name: String) throws -> Int? {
        guard let s = values[name] else { return nil }
        guard let v = Int(s) else { throw CLIError(description: "--\(name): not an integer: \(s)") }
        return v
    }

    var allKeys: Set<String> { Set(values.keys).union(flags) }
}

func fmt(_ v: Double, _ decimals: Int = 2) -> String {
    String(format: "%.\(decimals)f", v)
}

func describe(_ p: CalibrationPrompt) -> String {
    switch p {
    case .centerStar: return "centerStar"
    case .holdStill: return "holdStill"
    case .pressAndHold(let d): return "pressAndHold(\(d.rawValue))"
    case .stop: return "STOP"
    case .releaseAndWait: return "releaseAndWait"
    case .done: return "done"
    case .failed(let f): return "failed(\(f))"
    }
}

let usage = """
teleskooppi-cli \(TeleskooppiCore.version)

USAGE
  teleskooppi-cli simulate [options]   Simulated two-move calibration (writes PGM frames + summary)
  teleskooppi-cli sun [options]        Sun azimuth / altitude (default: now, Helsinki)
  teleskooppi-cli version

SIMULATE OPTIONS
  --seed N            RNG seed (default 1)
  --random            draw all unspecified parameters from the plan 4.8 test ranges (seeded)
  --theta DEG         true display rotation (default: random from seed)
  --mirror | --no-mirror
  --backlash ARCMIN   backlash per axis (default 5)
  --drift ARCSEC_S    sidereal drift magnitude, tracking off (default 10)
  --jitter PX         seeing jitter sigma (default 1)
  --level N           SynScan speed level 2-6 (default 3 = 16x)
  --alt DEG           altitude (default 35)
  --misalign DEG      stick misalignment for both pushes (default 0)
  --analog            analog stick response (cross-talk) instead of on/off axes
  --dropout P         per-frame star loss probability (default 0)
  --out DIR           output directory (default sim-out)
  --no-images         skip PGM output
  --runs N            batch mode: N seeded random scenarios, print statistics only

SUN OPTIONS
  --date ISO8601      e.g. 2026-09-29T15:30:00Z (default: now)
  --lat DEG --lon DEG (default Helsinki 60.17, 24.94)
"""

// MARK: - simulate

func buildScenario(_ args: Arguments) throws -> CalibrationScenario {
    let seed = UInt64(try args.int("seed") ?? 1)
    var sc: CalibrationScenario
    if args.flag("random") {
        sc = CalibrationScenario.random(seed: seed)
    } else {
        var rng = SplitMix64(seed: seed)
        sc = CalibrationScenario(seed: seed)
        sc.optics.displayRotation = rng.uniform(0...(2 * .pi))
        sc.optics.mirrored = false
        let driftDir = rng.uniform(0...(2 * .pi))
        sc.mount.driftArcsecPerSecond = Vec2.unit(angle: driftDir) * 10
        sc.mount.backlash = Vec2(300, 300)
        sc.mount.backlashEngagement = Vec2(rng.uniform(-1...1), rng.uniform(-1...1))
    }
    if let v = try args.double("theta") { sc.optics.displayRotation = AngleMath.radians(v) }
    if args.flag("mirror") { sc.optics.mirrored = true }
    if args.flag("no-mirror") { sc.optics.mirrored = false }
    if let v = try args.double("backlash") { sc.mount.backlash = Vec2(v * 60, v * 60) }
    if let v = try args.double("drift") {
        let dir = sc.mount.driftArcsecPerSecond.length > 0 ? sc.mount.driftArcsecPerSecond.normalized : Vec2(1, 0)
        sc.mount.driftArcsecPerSecond = dir * v
    }
    if let v = try args.double("jitter") { sc.jitterSigma = v }
    if let v = try args.int("level") {
        guard let m = SynScanSpeed.multiplier(level: v) else { throw CLIError(description: "--level must be 2...6") }
        sc.mount.speedMultiplier = m
    }
    if let v = try args.double("alt") { sc.mount.altitudeDegrees = v }
    if let v = try args.double("misalign") {
        sc.misalignmentUp = AngleMath.radians(v)
        sc.misalignmentRight = AngleMath.radians(v)
    }
    if args.flag("analog") { sc.mount.stickResponse = .analog }
    if let v = try args.double("dropout") { sc.dropoutProbability = v }
    return sc
}

func runBatch(runs: Int, firstSeed: UInt64) {
    var errors = [Double]()
    var mirrorWrong = 0
    var failures = [String: Int]()
    var durations = [Double]()
    let start = Date()
    for i in 0..<runs {
        let sc = CalibrationScenario.random(seed: firstSeed + UInt64(i))
        let out = CalibrationSimulation(scenario: sc).run()
        if let e = out.rotationError {
            errors.append(AngleMath.degrees(e))
            durations.append(out.duration)
            if out.mirrorCorrect == false { mirrorWrong += 1 }
        } else {
            let key = out.failure.map { String(describing: $0) } ?? "unknown"
            failures[key, default: 0] += 1
        }
    }
    let elapsed = Date().timeIntervalSince(start)
    print("runs: \(runs)  succeeded: \(errors.count)  mirror wrong: \(mirrorWrong)  wall time: \(fmt(elapsed)) s")
    if !errors.isEmpty {
        print("rotation error [deg]: median \(fmt(Statistics.median(errors) ?? 0, 3))"
            + "  p95 \(fmt(Statistics.percentile(errors, 95) ?? 0, 3))"
            + "  max \(fmt(errors.max() ?? 0, 3))")
        print("calibration duration [s]: median \(fmt(Statistics.median(durations) ?? 0, 1))"
            + "  p95 \(fmt(Statistics.percentile(durations, 95) ?? 0, 1))")
    }
    for (k, v) in failures.sorted(by: { $0.key < $1.key }) { print("failure \(k): \(v)") }
}

// Simple raster drawing for the track plot.
struct Canvas {
    var image: GrayImage8

    mutating func plot(_ p: Vec2, _ v: UInt8, radius: Int = 0) {
        let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
        for dy in -radius...radius {
            for dx in -radius...radius where image.contains(cx + dx, cy + dy) {
                image[cx + dx, cy + dy] = max(image[cx + dx, cy + dy], v)
            }
        }
    }

    mutating func line(_ a: Vec2, _ b: Vec2, _ v: UInt8) {
        let n = max(Int((b - a).length.rounded(.up)), 1)
        for i in 0...n { plot(a + (b - a) * (Double(i) / Double(n)), v) }
    }

    mutating func circle(_ c: Vec2, _ r: Double, _ v: UInt8) {
        let n = max(Int(2 * .pi * r), 8)
        for i in 0..<n { plot(c + Vec2.unit(angle: 2 * .pi * Double(i) / Double(n)) * r, v) }
    }
}

func simulate(_ args: Arguments) throws {
    if let runs = try args.int("runs") {
        runBatch(runs: runs, firstSeed: UInt64(try args.int("seed") ?? 1))
        return
    }
    let sc = try buildScenario(args)
    let writeImages = !args.flag("no-images")
    let outDir = URL(fileURLWithPath: args.string("out") ?? "sim-out", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let sim = CalibrationSimulation(scenario: sc)
    var starRng = SplitMix64(seed: sc.seed &+ 0x5EED)
    let fieldArcsec = sc.optics.fieldRadius * sc.optics.plateScale
    var field = StarField.random(count: 700, radiusArcsec: fieldArcsec * 2.2, brightest: 6, faintest: 12,
                                 rng: &starRng)
    field.stars.append(SimulatedStar(position: sim.guideStar, magnitude: 3.5))
    let sky = SyntheticSky(optics: sc.optics, field: field)

    var frames: [SimulationFrame] = []
    var lastKind = ""
    var written: [String] = []
    var noiseRng = SplitMix64(seed: sc.seed &+ 0xF00D)
    let outcome = sim.run { frame in
        frames.append(frame)
        let kind = describe(frame.prompt)
        guard writeImages, kind != lastKind else { return }
        lastKind = kind
        let index = String(written.count)
        let padded = String(repeating: "0", count: max(0, 3 - index.count)) + index
        let slug = kind.replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "")
        let name = "frame-\(padded)-\(slug).pgm"
        let img = sky.render(boresight: frame.boresight, imageOffset: frame.jitter, rng: &noiseRng)
        do {
            try PGM.write(img, to: outDir.appendingPathComponent(name))
            written.append(name)
        } catch {
            FileHandle.standardError.write(Data("warning: could not write \(name): \(error)\n".utf8))
        }
    }

    // Track plot: field stop, crosshair, samples, fitted move directions.
    if writeImages {
        var canvas = Canvas(image: GrayImage8(width: sc.optics.imageWidth, height: sc.optics.imageHeight))
        let c = sc.optics.opticalCenter
        canvas.circle(c, sc.optics.fieldRadius, 90)
        canvas.line(c - Vec2(15, 0), c + Vec2(15, 0), 160)
        canvas.line(c - Vec2(0, 15), c + Vec2(0, 15), 160)
        for f in frames {
            if let s = f.sample { canvas.plot(s.p, 255, radius: 1) }
            canvas.plot(f.truePosition, 120)
        }
        if let r = outcome.result {
            let start = frames.first?.sample?.p ?? c
            canvas.line(start, start + r.mUp.normalized * 200, 200)
            canvas.line(start, start + r.mRight.normalized * 200, 200)
        }
        try PGM.write(canvas.image, to: outDir.appendingPathComponent("track.pgm"))
        written.append("track.pgm")
    }

    var lines: [String] = []
    lines.append("teleskooppi-cli simulate (core \(TeleskooppiCore.version))")
    lines.append("seed: \(sc.seed)")
    lines.append("truth: theta \(fmt(AngleMath.degrees(sc.optics.displayRotation))) deg, mirrored \(sc.optics.mirrored)")
    lines.append("mount: \(fmt(sc.mount.speedMultiplier, 0))x, alt \(fmt(sc.mount.altitudeDegrees, 1)) deg, "
        + "backlash \(fmt(sc.mount.backlash.x / 60, 1))'/\(fmt(sc.mount.backlash.y / 60, 1))', "
        + "drift \(fmt(sc.mount.driftArcsecPerSecond.length, 1))\"/s, response \(sc.mount.stickResponse)")
    lines.append("user: misalignment up \(fmt(AngleMath.degrees(sc.misalignmentUp), 1)) deg, "
        + "right \(fmt(AngleMath.degrees(sc.misalignmentRight), 1)) deg, reaction \(fmt(sc.reactionTime)) s")
    lines.append("noise: jitter \(fmt(sc.jitterSigma)) px, dropout \(fmt(sc.dropoutProbability, 3))")
    lines.append("expected M: \(outcome.expectedStickToImage)")
    lines.append("prompts:")
    for entry in outcome.promptLog { lines.append("  t=\(fmt(entry.time, 1)) s  \(describe(entry.prompt))") }
    if let r = outcome.result {
        lines.append("RESULT: theta \(fmt(r.displayRotationDegrees)) deg, mirrored \(r.mirrored), quality \(r.quality.rawValue)")
        lines.append("  M: \(r.stickToImage)")
        lines.append("  rotation error: \(fmt(AngleMath.degrees(outcome.rotationError ?? 0), 3)) deg, "
            + "mirror correct: \(outcome.mirrorCorrect ?? false)")
        lines.append("  orthogonality error: \(fmt(AngleMath.degrees(r.orthogonalityError))) deg, "
            + "line residual \(fmt(r.lineResidual)) px, drift \(r.driftVelocity) px/s")
        lines.append("  |m_R|/|m_U| = \(fmt(r.axisRateRatio, 3)) (cos alt = "
            + "\(fmt(cos(AngleMath.radians(sc.mount.altitudeDegrees)), 3)))")
    } else {
        let reason = outcome.failure.map { String(describing: $0) } ?? "unknown"
        lines.append("FAILED: \(reason)")
    }
    lines.append("duration: \(fmt(outcome.duration, 1)) s simulated")
    if writeImages { lines.append("files: \(written.joined(separator: ", "))") }
    let text = lines.joined(separator: "\n") + "\n"
    print(text, terminator: "")
    try Data(text.utf8).write(to: outDir.appendingPathComponent("summary.txt"))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    struct Summary: Encodable {
        var scenario: CalibrationScenario
        var result: CalibrationResult?
        var failure: CalibrationFailure?
        var rotationErrorDegrees: Double?
        var mirrorCorrect: Bool?
        var durationSeconds: Double
    }
    let summary = Summary(scenario: sc, result: outcome.result, failure: outcome.failure,
                          rotationErrorDegrees: outcome.rotationError.map(AngleMath.degrees),
                          mirrorCorrect: outcome.mirrorCorrect, durationSeconds: outcome.duration)
    try encoder.encode(summary).write(to: outDir.appendingPathComponent("summary.json"))
    print("wrote \(outDir.path)")
}

// MARK: - sun

func sun(_ args: Arguments) throws {
    var date = Date()
    if let s = args.string("date") {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: s) else { throw CLIError(description: "--date: expected ISO 8601, e.g. 2026-09-29T15:30:00Z") }
        date = d
    }
    let loc = GeoLocation(latitude: try args.double("lat") ?? GeoLocation.helsinki.latitude,
                          longitude: try args.double("lon") ?? GeoLocation.helsinki.longitude)
    let p = SolarPosition(date: date, location: loc)
    print("date (UTC): \(ISO8601DateFormatter().string(from: date))")
    print("location: \(fmt(loc.latitude, 3)) N, \(fmt(loc.longitude, 3)) E")
    print("azimuth: \(fmt(p.azimuth)) deg, altitude: \(fmt(p.altitude)) deg (apparent \(fmt(p.apparentAltitude)) deg)")
    if p.isInWarningSector { print("WARNING: the sun is up in the west/north-west sector (plan 8).") }
}

// MARK: - main

let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
do {
    switch command {
    case "simulate":
        let flags: Set<String> = ["random", "mirror", "no-mirror", "analog", "no-images"]
        try simulate(Arguments(argv.dropFirst(2), flagNames: flags))
    case "sun":
        try sun(Arguments(argv.dropFirst(2), flagNames: []))
    case "version", "--version":
        print("teleskooppi-cli \(TeleskooppiCore.version)")
    case "help", "--help", "-h":
        print(usage)
    default:
        FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
