import Foundation
import Testing
@testable import TeleskooppiCore

@Suite struct ImagingTests {
    @Test func binningAveragesBlocks() {
        var img = GrayImage8(width: 5, height: 4)
        for y in 0..<4 { for x in 0..<5 { img[x, y] = UInt8(10 * x + y) } }
        let b = img.binned2x()
        #expect(b.width == 2 && b.height == 2)
        // Block (0,0): 0, 10, 1, 11 -> 5.5 -> rounds to 6.
        #expect(b[0, 0] == 6)
        // Block (1,1): x 2..3, y 2..3 -> 22, 32, 23, 33 -> 27.5 -> 28.
        #expect(b[1, 1] == 28)
        let f = img.converted(to: Float.self).binned2x()
        #expect(f[0, 0] == 5.5)
    }

    @Test func strideIsRespected() {
        var img = GrayImage8(width: 3, height: 2, stride: 5, fill: 0)
        img[2, 1] = 9
        #expect(img.pixels.count == 10)
        #expect(img.pixels[7] == 9)
        let c = img.compacted()
        #expect(c.stride == 3 && c[2, 1] == 9)
        #expect(img.doubleValues().count == 6)
        let data = PGM.encode(img)
        let back = try! PGM.decode(data)
        #expect(back == c)
    }

    @Test func robustStatistics() {
        let v: [Double] = [1, 2, 3, 4, 100]
        #expect(Statistics.median(v) == 3)
        #expect(Statistics.mad(v) == 1)
        #expect(Statistics.median([1, 2, 3, 4]) == 2.5)
        #expect(Statistics.percentile([0, 10], 50) == 5)
        #expect(Statistics.percentile(Array(0...100).map(Double.init), 95) == 95)
        #expect(Statistics.median([]) == nil)

        var rng = SplitMix64(seed: 3)
        var img = GrayImageF(width: 200, height: 200)
        for i in 0..<img.pixels.count { img.pixels[i] = Float(50 + 4 * rng.gaussian()) }
        img[10, 10] = 10000  // outlier does not matter
        let s = img.robustStatistics()
        #expect(abs(s.median - 50) < 0.2)
        #expect(abs(s.sigma - 4) < 0.2)
    }

    @Test func pgmRoundTrip() throws {
        var rng = SplitMix64(seed: 9)
        var img = GrayImage8(width: 37, height: 21)
        for i in 0..<img.pixels.count { img.pixels[i] = UInt8(truncatingIfNeeded: rng.next()) }
        let data = PGM.encode(img)
        #expect(data.starts(with: Array("P5\n37 21\n255\n".utf8)))
        let back = try PGM.decode(data)
        #expect(back == img)

        // Header with comments and 16-bit samples.
        var d16 = Data("P5\n# comment\n2 1\n# another\n65535\n".utf8)
        d16.append(contentsOf: [0xFF, 0xFF, 0x80, 0x00])
        let img16 = try PGM.decode(d16)
        #expect(img16[0, 0] == 255 && img16[1, 0] == 128)

        let u16 = GrayImage16(width: 2, height: 1, pixels: [65535, 0])
        #expect(try PGM.decode(PGM.encode(u16)).pixels == [255, 0])

        #expect(throws: PGM.Error.notP5) { try PGM.decode(Data("P2\n1 1\n255\n0".utf8)) }
        #expect(throws: PGM.Error.truncatedData) { try PGM.decode(Data("P5\n4 4\n255\n\u{1}".utf8)) }
    }

    @Test func pgmFileIO() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tk-pgm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = GrayImage8(width: 4, height: 3, fill: 77)
        let url = dir.appendingPathComponent("a.pgm")
        try PGM.write(img, to: url)
        #expect(try PGM.read(from: url) == img)
        let f = GrayImageF(width: 2, height: 1, pixels: [0, 2])
        #expect(try PGM.decode(PGM.encode(f)).pixels == [0, 255])
    }
}
