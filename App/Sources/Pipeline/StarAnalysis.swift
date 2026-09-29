import CoreGraphics
import Foundation
import TeleskooppiCore

/// Relation between the binned analysis image and the camera's native image (D-05). Binned
/// pixel `i` covers source pixels `f*i ..< f*i+f`, so its center is at `f*i + (f-1)/2`.
struct BinningGeometry: Sendable, Equatable {
    var factor: Int

    private var offset: Double { Double(factor - 1) / 2 }

    func binnedToImage(_ p: Vec2) -> Vec2 {
        Vec2(p.x * Double(factor) + offset, p.y * Double(factor) + offset)
    }

    func imageToBinned(_ p: Vec2) -> Vec2 {
        Vec2((p.x - offset) / Double(factor), (p.y - offset) / Double(factor))
    }
}

/// Tap to star selection: screen point -> image point (shared display transform, D-10) -> binned.
enum StarSelection {
    static func binnedPoint(fromScreen point: CGPoint, transform: DisplayTransform, factor: Int) -> Vec2 {
        let image = transform.screenToImage(Vec2(Double(point.x), Double(point.y)))
        return BinningGeometry(factor: factor).imageToBinned(image)
    }
}

struct StarAnalysisResult: Sendable, Equatable {
    var frameTime: Double
    var geometry: BinningGeometry
    /// Detections in binned coordinates, brightest first (at most `StarAnalyzer.maxCandidates`).
    var candidates: [StarDetection]
    /// `nil` while no star is selected.
    var trackState: StarTracker.State?
    /// The tracked star (binned coordinates) when locked and seen in this frame.
    var star: StarDetection?
    var binMilliseconds: Double
    var detectMilliseconds: Double
}

/// Detection and tracking on binned frames. Not thread-safe: owned by the analysis queue.
struct StarAnalyzer: Sendable {
    static let maxCandidates = 24

    private(set) var tracker = StarTracker()
    private(set) var isSelecting = false
    private let detector = StarDetector()

    var isLocked: Bool { isSelecting && tracker.state == .locked }

    /// Starts tracking the star nearest to `point` (binned coordinates); `nil` clears the selection.
    mutating func select(near point: Vec2?) {
        if let point {
            tracker.lock(near: point)
            isSelecting = true
        } else {
            tracker.reset()
            isSelecting = false
        }
    }

    mutating func process(_ image: GrayImage8, time: Double, geometry: BinningGeometry,
                          binMilliseconds: Double) -> StarAnalysisResult {
        let started = ProcessInfo.processInfo.systemUptime
        var candidates: [StarDetection]
        var state: StarTracker.State?
        var star: StarDetection?
        if isSelecting {
            _ = tracker.update(image, time: time)
            state = tracker.state
            candidates = tracker.lastDetections
            if tracker.state == .locked, tracker.missCount == 0 { star = tracker.lastDetection }
            if tracker.state == .lost {
                // Keep looking near where the star vanished.
                tracker.lock(near: tracker.position)
            }
        } else {
            candidates = detector.detect(image)
        }
        if candidates.count > Self.maxCandidates { candidates = Array(candidates.prefix(Self.maxCandidates)) }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return StarAnalysisResult(
            frameTime: time, geometry: geometry, candidates: candidates, trackState: state, star: star,
            binMilliseconds: binMilliseconds, detectMilliseconds: elapsed
        )
    }
}
