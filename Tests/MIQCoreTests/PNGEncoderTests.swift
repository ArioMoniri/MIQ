import Foundation
import Testing
import zlib
@testable import MIQCore

/// Structural round-trip checks for `PNGEncoder`: the file is decoded here by an
/// independent minimal reader (chunk walk + zlib `uncompress` + filter-0 unpack)
/// and compared byte-for-byte against the input pixels.
struct PNGEncoderTests {
    private struct Chunk {
        let type: String
        let data: [UInt8]
        let storedCRC: UInt32
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16) | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    private static func chunks(of png: Data) throws -> [Chunk] {
        let bytes = [UInt8](png)
        try #require(bytes.count >= 8)
        #expect(Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var result: [Chunk] = []
        var p = 8
        while p < bytes.count {
            try #require(p + 12 <= bytes.count)
            let length = Int(be32(bytes, p))
            try #require(p + 12 + length <= bytes.count)
            let type = String(decoding: bytes[(p + 4)..<(p + 8)], as: UTF8.self)
            let data = Array(bytes[(p + 8)..<(p + 8 + length)])
            result.append(Chunk(type: type, data: data, storedCRC: be32(bytes, p + 8 + length)))
            p += 12 + length
        }
        #expect(p == bytes.count)
        return result
    }

    /// Decodes an encoder-produced PNG back to tightly packed pixels.
    private static func decode(_ png: Data) throws -> (width: Int, height: Int, colorType: UInt8, pixels: [UInt8]) {
        let all = try chunks(of: png)
        try #require(all.first?.type == "IHDR")
        let ihdr = all[0].data
        try #require(ihdr.count == 13)
        let width = Int(be32(ihdr, 0)), height = Int(be32(ihdr, 4))
        #expect(ihdr[8] == 8)                          // bit depth
        #expect(ihdr[10] == 0 && ihdr[11] == 0 && ihdr[12] == 0)
        let channels: Int
        switch ihdr[9] {
        case 0: channels = 1
        case 2: channels = 3
        case 6: channels = 4
        default: Issue.record("unexpected colour type \(ihdr[9])"); channels = 1
        }

        let idat = all.filter { $0.type == "IDAT" }.flatMap(\.data)
        let stride = width * channels
        var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
        var rawLength = uLongf(raw.count)
        let status = idat.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                uncompress(dst.baseAddress, &rawLength, src.baseAddress, uLong(idat.count))
            }
        }
        try #require(status == Z_OK)
        try #require(Int(rawLength) == raw.count)

        var pixels: [UInt8] = []
        pixels.reserveCapacity(stride * height)
        for row in 0..<height {
            #expect(raw[row * (stride + 1)] == 0, "row \(row) must use filter type None")
            pixels.append(contentsOf: raw[(row * (stride + 1) + 1)..<((row + 1) * (stride + 1))])
        }
        return (width, height, ihdr[9], pixels)
    }

    @Test
    func crc32MatchesKnownVectorsAndZlib() {
        // PNG's IEND chunk CRC is a well-known constant.
        #expect(PNGEncoder.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        // Standard CRC-32 check value.
        #expect(PNGEncoder.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(PNGEncoder.crc32([UInt8]()) == 0)

        let sample = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let reference = sample.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) }
        #expect(UInt(PNGEncoder.crc32(sample)) == UInt(reference))
        // Seeded continuation equals one pass over the concatenation.
        #expect(PNGEncoder.crc32(sample[500...], seed: PNGEncoder.crc32(sample[..<500])) == PNGEncoder.crc32(sample))
    }

    @Test
    func grayscaleRoundTripsWithValidChunkStructure() throws {
        let width = 7, height = 5
        let pixels = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 9) }
        let png = try PNGEncoder.encode(pixels: pixels, width: width, height: height, colorType: .gray8)

        let all = try Self.chunks(of: png)
        #expect(all.map(\.type) == ["IHDR", "IDAT", "IEND"])
        for chunk in all {
            #expect(PNGEncoder.crc32(Array(chunk.type.utf8) + chunk.data) == chunk.storedCRC, "\(chunk.type) CRC")
        }
        #expect(all.last?.data.isEmpty == true)

        let decoded = try Self.decode(png)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.colorType == 0)
        #expect(decoded.pixels == pixels)
    }

    @Test
    func rgbAndRgbaRoundTrip() throws {
        let width = 4, height = 3
        let rgb = (0..<(width * height * 3)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let rgbDecoded = try Self.decode(try PNGEncoder.encode(pixels: rgb, width: width, height: height, colorType: .rgb8))
        #expect(rgbDecoded.colorType == 2)
        #expect(rgbDecoded.pixels == rgb)

        let rgba = (0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: 255 &- $0) }
        let bitmap = RGBABitmap(width: width, height: height, pixels: Data(rgba))
        let rgbaDecoded = try Self.decode(try PNGEncoder.encode(bitmap))
        #expect(rgbaDecoded.colorType == 6)
        #expect(rgbaDecoded.width == width && rgbaDecoded.height == height)
        #expect(rgbaDecoded.pixels == rgba)
    }

    @Test
    func sliceImageEncodesGrayAsGrayAndColourAsRGB() throws {
        let gray = SliceImage.grayscale(GrayscaleImage(width: 2, height: 2, pixels: [0, 64, 128, 255]))
        let grayDecoded = try Self.decode(try PNGEncoder.encode(gray))
        #expect(grayDecoded.colorType == 0)
        #expect(grayDecoded.pixels == [0, 64, 128, 255])

        let colour = SliceImage.rgb(RGBImage(width: 1, height: 2, pixels: [1, 2, 3, 4, 5, 6]))
        let colourDecoded = try Self.decode(try PNGEncoder.encode(colour))
        #expect(colourDecoded.colorType == 2)
        #expect(colourDecoded.pixels == [1, 2, 3, 4, 5, 6])
    }

    @Test
    func rejectsMismatchedBuffersAndBadDimensions() {
        #expect(throws: PNGEncoder.EncodingError.bufferSizeMismatch(expected: 6, actual: 5)) {
            try PNGEncoder.encode(pixels: [0, 0, 0, 0, 0], width: 3, height: 2, colorType: .gray8)
        }
        #expect(throws: PNGEncoder.EncodingError.invalidDimensions(width: 0, height: 2)) {
            try PNGEncoder.encode(pixels: [], width: 0, height: 2, colorType: .gray8)
        }
        #expect(throws: PNGEncoder.EncodingError.invalidDimensions(width: Int.max, height: 2)) {
            try PNGEncoder.encode(pixels: [], width: Int.max, height: 2, colorType: .rgba8)
        }
    }

    @Test
    func encodingIsDeterministic() throws {
        let pixels = [UInt8](repeating: 42, count: 64 * 64)
        let a = try PNGEncoder.encode(pixels: pixels, width: 64, height: 64, colorType: .gray8)
        let b = try PNGEncoder.encode(pixels: pixels, width: 64, height: 64, colorType: .gray8)
        #expect(a == b)
        // A flat image must actually compress.
        #expect(a.count < pixels.count / 4)
    }
}
