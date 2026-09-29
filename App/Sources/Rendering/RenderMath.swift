import CoreGraphics
import Foundation
import TeleskooppiCore

/// Everything the renderer needs to draw one frame, apart from the frame itself.
struct RenderParams: Equatable, Sendable {
    /// Image -> screen transform as 12 floats in Metal's `float3x3` layout (D-10).
    var matrix: [Float]
    /// Size of the view in points; the screen coordinates in `matrix` are in this space.
    var viewSize: SIMD2<Float>
    var blackPoint: Float
    var whitePoint: Float
    var gamma: Float
    /// Night mode: the picture is drawn in red only.
    var redMode: Bool
    /// Show chroma instead of luma only.
    var colorMode: Bool

    static let identityMatrix: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]

    static let initial = RenderParams(
        matrix: identityMatrix, viewSize: SIMD2(1, 1), blackPoint: 0, whitePoint: 1, gamma: 1,
        redMode: true, colorMode: false
    )
}

/// CPU mirror of the shader math, used by tests and for hit testing.
enum RenderMath {
    /// Builds the render parameters from the shared display transform (D-10).
    static func params(
        transform: DisplayTransform, viewSize: CGSize, blackPoint: Double, whitePoint: Double,
        gamma: Double, redMode: Bool, colorMode: Bool = false
    ) -> RenderParams {
        RenderParams(
            matrix: transform.metalFloat3x3,
            viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
            blackPoint: Float(blackPoint),
            whitePoint: Float(whitePoint),
            gamma: Float(gamma),
            redMode: redMode,
            colorMode: colorMode
        )
    }

    /// Screen position (points) of an image point: the vertex shader's `m * float3(p, 1)`.
    static func screenPosition(imagePoint p: SIMD2<Float>, matrix m: [Float]) -> SIMD2<Float> {
        // Columns are padded to four floats: column 0 = m[0...2], column 1 = m[4...6], column 2 = m[8...10].
        SIMD2(
            m[0] * p.x + m[4] * p.y + m[8],
            m[1] * p.x + m[5] * p.y + m[9]
        )
    }

    /// Clip-space position (-1...1, y up) of an image point: the vertex shader output.
    static func clipPosition(imagePoint p: SIMD2<Float>, matrix m: [Float], viewSize: SIMD2<Float>) -> SIMD2<Float> {
        let q = screenPosition(imagePoint: p, matrix: m)
        return SIMD2(q.x / viewSize.x * 2 - 1, 1 - q.y / viewSize.y * 2)
    }

    /// Black/white point and gamma stretch of the fragment shader for one channel.
    static func stretch(_ value: Float, black: Float, white: Float, gamma: Float) -> Float {
        let range = max(white - black, 1e-4)
        let normalized = min(max((value - black) / range, 0), 1)
        return powf(normalized, 1 / max(gamma, 0.05))
    }
}
