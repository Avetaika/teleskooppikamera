import CoreVideo
import Foundation
import TeleskooppiCore

/// Simple 2x2 box binning of the luma plane (plan 3.4): 1920x1440 -> 960x720, 8-bit.
enum LumaBinning {
    /// Frames wider than this are binned 2x; smaller ones (recordings) pass through.
    static func factor(forWidth width: Int) -> Int { width > 1280 ? 2 : 1 }

    /// Bins the luma plane of a bi-planar buffer. Returns `nil` if the buffer has no readable plane.
    static func binned(_ buffer: CVPixelBuffer) -> GrayImage8? {
        guard CVPixelBufferGetPlaneCount(buffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return bin(
            base.assumingMemoryBound(to: UInt8.self), width: width, height: height, stride: stride,
            factor: factor(forWidth: width)
        )
    }

    /// `factor` 1 copies, 2 averages 2x2 blocks with rounding. Odd trailing rows/columns are dropped.
    static func bin(_ source: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, factor: Int) -> GrayImage8 {
        let outWidth = width / factor
        let outHeight = height / factor
        var out = [UInt8](repeating: 0, count: outWidth * outHeight)
        out.withUnsafeMutableBufferPointer { destination in
            for y in 0..<outHeight {
                if factor == 1 {
                    let row = source + y * stride
                    for x in 0..<outWidth { destination[y * outWidth + x] = row[x] }
                } else {
                    let row0 = source + (2 * y) * stride
                    let row1 = row0 + stride
                    for x in 0..<outWidth {
                        let sum = Int(row0[2 * x]) + Int(row0[2 * x + 1]) + Int(row1[2 * x]) + Int(row1[2 * x + 1])
                        destination[y * outWidth + x] = UInt8((sum + 2) >> 2)
                    }
                }
            }
        }
        return GrayImage8(width: outWidth, height: outHeight, pixels: out)
    }

    /// Array convenience for tests.
    static func bin(_ pixels: [UInt8], width: Int, height: Int, stride: Int, factor: Int) -> GrayImage8 {
        pixels.withUnsafeBufferPointer { bin($0.baseAddress!, width: width, height: height, stride: stride, factor: factor) }
    }
}

/// Runs an action at most every `minInterval` seconds; a 10% tolerance lets a 10 Hz limit pass
/// every third frame of a 30 fps stream despite timing jitter.
struct MinIntervalLimiter: Sendable {
    var minInterval: Double
    private var last = -Double.infinity

    init(minInterval: Double) {
        self.minInterval = minInterval
    }

    mutating func allow(_ now: Double) -> Bool {
        if now < last { last = -Double.infinity }  // clock restarted
        guard now - last >= minInterval * 0.9 else { return false }
        last = now
        return true
    }
}
