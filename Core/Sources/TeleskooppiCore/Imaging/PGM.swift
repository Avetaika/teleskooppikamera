import Foundation

/// Binary PGM (P5) reading and writing, for debugging and CLI output.
public enum PGM {
    public enum Error: Swift.Error, Equatable {
        case notP5
        case malformedHeader
        case unsupportedMaxValue(Int)
        case truncatedData
    }

    /// Encodes an 8-bit image as P5 (maxval 255).
    public static func encode(_ image: GrayImage8) -> Data {
        var data = Data("P5\n\(image.width) \(image.height)\n255\n".utf8)
        data.reserveCapacity(data.count + image.pixelCount)
        if image.stride == image.width {
            data.append(contentsOf: image.pixels[0..<image.pixelCount])
        } else {
            for y in 0..<image.height {
                let row = y * image.stride
                data.append(contentsOf: image.pixels[row..<(row + image.width)])
            }
        }
        return data
    }

    /// Encodes a 16-bit image as P5 (maxval 65535, big-endian samples).
    public static func encode(_ image: GrayImage16) -> Data {
        var data = Data("P5\n\(image.width) \(image.height)\n65535\n".utf8)
        data.reserveCapacity(data.count + 2 * image.pixelCount)
        for y in 0..<image.height {
            let row = y * image.stride
            for x in 0..<image.width {
                let v = image.pixels[row + x]
                data.append(UInt8(v >> 8))
                data.append(UInt8(v & 0xFF))
            }
        }
        return data
    }

    /// Encodes a float image linearly mapped from `[black, white]` to 0...255.
    /// Defaults to the image min/max.
    public static func encode(_ image: GrayImageF, black: Double? = nil, white: Double? = nil) -> Data {
        var lo = Double.infinity, hi = -Double.infinity
        if black == nil || white == nil {
            image.forEachPixel { _, _, v in
                lo = min(lo, Double(v))
                hi = max(hi, Double(v))
            }
        }
        let b = black ?? (lo.isFinite ? lo : 0)
        let w = white ?? (hi.isFinite ? hi : 1)
        let scale = w > b ? 255 / (w - b) : 1
        return encode(image.converted(to: UInt8.self, scale: scale, offset: -b * scale))
    }

    public static func write(_ image: GrayImage8, to url: URL) throws {
        try encode(image).write(to: url)
    }

    /// Decodes P5 data. 16-bit files are scaled down to 8 bits.
    public static func decode(_ data: Data) throws -> GrayImage8 {
        let bytes = [UInt8](data)
        var pos = 0

        func skipWhitespaceAndComments() {
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "#") {
                    while pos < bytes.count && bytes[pos] != UInt8(ascii: "\n") { pos += 1 }
                } else if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    pos += 1
                } else {
                    return
                }
            }
        }

        func readInt() throws -> Int {
            skipWhitespaceAndComments()
            var value = 0
            var digits = 0
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 {
                value = value * 10 + Int(bytes[pos] - 0x30)
                digits += 1
                pos += 1
                if digits > 9 { throw Error.malformedHeader }
            }
            guard digits > 0 else { throw Error.malformedHeader }
            return value
        }

        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "P"), bytes[1] == UInt8(ascii: "5") else {
            throw Error.notP5
        }
        pos = 2
        let w = try readInt()
        let h = try readInt()
        let maxVal = try readInt()
        // Exactly one whitespace byte separates the header from the raster.
        guard pos < bytes.count else { throw Error.truncatedData }
        pos += 1
        guard maxVal > 0 && maxVal <= 65535 else { throw Error.unsupportedMaxValue(maxVal) }
        let bytesPerSample = maxVal < 256 ? 1 : 2
        let needed = w * h * bytesPerSample
        guard bytes.count - pos >= needed else { throw Error.truncatedData }
        var img = GrayImage8(width: w, height: h)
        if bytesPerSample == 1 {
            let scale = 255.0 / Double(maxVal)
            for i in 0..<(w * h) {
                let v = bytes[pos + i]
                img.pixels[i] = maxVal == 255 ? v : UInt8(clampingDouble: Double(v) * scale)
            }
        } else {
            let scale = 255.0 / Double(maxVal)
            for i in 0..<(w * h) {
                let v = (UInt16(bytes[pos + 2 * i]) << 8) | UInt16(bytes[pos + 2 * i + 1])
                img.pixels[i] = UInt8(clampingDouble: Double(v) * scale)
            }
        }
        return img
    }

    public static func read(from url: URL) throws -> GrayImage8 {
        try decode(Data(contentsOf: url))
    }
}
