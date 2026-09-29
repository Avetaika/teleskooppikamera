import CoreGraphics
import Foundation
import TeleskooppiCore

/// User-adjustable display state: manual rotation and flips (plan 4.4), optical center, zoom,
/// stretch and night mode. Persisted as JSON in `UserDefaults`.
struct DisplaySettings: Codable, Equatable, Sendable {
    /// Manual rotation in degrees, -180...180.
    var rotationDegrees: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Multiplier on the default scale (the image's short side spans the screen width).
    var zoom: Double = 1
    /// Optical center in image pixels; `nil` = center of the image.
    var opticalCenter: Vec2?
    var blackPoint: Double = 0
    var whitePoint: Double = 1
    var gamma: Double = 1
    var redMode = true
    /// In-app screen brightness (0...1); `nil` = leave the system brightness alone.
    var brightness: Double?

    static let rotationRange: ClosedRange<Double> = -180...180
    static let zoomRange: ClosedRange<Double> = 0.5...4

    /// The rotation slider shows "KÄSI" when anything deviates from the identity view.
    var isManual: Bool {
        rotationDegrees != 0 || flipHorizontal || flipVertical
    }

    /// Image-space center of the image in pixel-index coordinates (pixel i has its center at i).
    static func imageCenter(imageSize: CGSize) -> Vec2 {
        Vec2((Double(imageSize.width) - 1) / 2, (Double(imageSize.height) - 1) / 2)
    }

    func resolvedOpticalCenter(imageSize: CGSize) -> Vec2 {
        opticalCenter ?? Self.imageCenter(imageSize: imageSize)
    }

    /// Screen points per image pixel: the image's short side spans the screen width at zoom 1
    /// (the eyepiece circle is about as tall as the 4:3 image, D-14).
    func scale(imageSize: CGSize, viewSize: CGSize) -> Double {
        let shortSide = min(imageSize.width, imageSize.height)
        guard shortSide > 0 else { return 1 }
        return zoom * Double(viewSize.width) / Double(shortSide)
    }

    /// The image -> screen transform, with the optical center recentered on the screen.
    func transform(imageSize: CGSize, viewSize: CGSize) -> DisplayTransform {
        DisplayTransform.manual(
            rotation: AngleMath.radians(rotationDegrees),
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            scale: scale(imageSize: imageSize, viewSize: viewSize),
            opticalCenter: resolvedOpticalCenter(imageSize: imageSize),
            screenCenter: Vec2(Double(viewSize.width) / 2, Double(viewSize.height) / 2)
        )
    }

    /// Long-press: makes the image point under the touch the new optical center.
    mutating func setOpticalCenter(atScreen point: CGPoint, imageSize: CGSize, viewSize: CGSize) {
        let t = transform(imageSize: imageSize, viewSize: viewSize)
        let p = t.screenToImage(Vec2(Double(point.x), Double(point.y)))
        guard p.isFinite else { return }
        // Keep the center inside the image.
        let x = min(max(p.x, 0), Double(imageSize.width) - 1)
        let y = min(max(p.y, 0), Double(imageSize.height) - 1)
        opticalCenter = Vec2(x, y)
    }

    mutating func resetOpticalCenter() {
        opticalCenter = nil
    }

    mutating func setRotation(degrees: Double) {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        rotationDegrees = d
    }

    /// Keeps black < white with a minimum gap and gamma in a sane range.
    mutating func normalizeStretch() {
        blackPoint = min(max(blackPoint, 0), 0.95)
        whitePoint = min(max(whitePoint, blackPoint + 0.02), 1)
        gamma = min(max(gamma, 0.3), 3)
    }

    // MARK: - Persistence

    static let storageKey = "displaySettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> DisplaySettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(DisplaySettings.self, from: data) else {
            return DisplaySettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
