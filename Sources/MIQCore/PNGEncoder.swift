import Foundation
import zlib

/// Minimal, dependency-free PNG writer for 8-bit grayscale, RGB and RGBA buffers.
///
/// Exists so MIQCore output can be saved without CoreGraphics/ImageIO — the
/// `miq` command-line tool uses it, and it builds unchanged on Linux. Only the
/// three chunks a decoder needs are emitted (`IHDR`, one `IDAT`, `IEND`); no
/// gamma, colour-profile, text or timestamp chunks, so the file carries nothing
/// beyond the pixels and their dimensions. Every scanline uses filter type 0
/// (None) — simple and deterministic; zlib's deflate does the size work.
public enum PNGEncoder {
    /// Pixel layout of the input buffer, and of the PNG written.
    public enum ColorType: Sendable, Equatable {
        /// One byte per pixel (PNG colour type 0).
        case gray8
        /// Three interleaved bytes per pixel (PNG colour type 2).
        case rgb8
        /// Four interleaved bytes per pixel, straight alpha (PNG colour type 6).
        case rgba8

        public var bytesPerPixel: Int {
            switch self {
            case .gray8: return 1
            case .rgb8: return 3
            case .rgba8: return 4
            }
        }

        /// The colour-type byte stored in `IHDR`.
        public var pngColorType: UInt8 {
            switch self {
            case .gray8: return 0
            case .rgb8: return 2
            case .rgba8: return 6
            }
        }
    }

    public enum EncodingError: Error, Equatable, LocalizedError {
        /// Width or height is zero/negative, or exceeds PNG's 2^31 − 1 limit.
        case invalidDimensions(width: Int, height: Int)
        /// The buffer length is not `width × height × bytesPerPixel`.
        case bufferSizeMismatch(expected: Int, actual: Int)
        /// zlib reported a failure while deflating the image data.
        case compressionFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidDimensions(let w, let h):
                return "Invalid PNG dimensions \(w) × \(h)."
            case .bufferSizeMismatch(let expected, let actual):
                return "Pixel buffer has \(actual) bytes, expected \(expected)."
            case .compressionFailed(let status):
                return "zlib deflate failed (status \(status))."
            }
        }
    }

    /// The fixed 8-byte PNG file signature.
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Encodes `pixels` (row-major, top row first, tightly packed) as a PNG file.
    ///
    /// - Parameter compressionLevel: zlib level 0–9; the default favours size,
    ///   since the images here are at most a few hundred pixels on a side.
    public static func encode(
        pixels: [UInt8],
        width: Int,
        height: Int,
        colorType: ColorType,
        compressionLevel: Int32 = 9
    ) throws -> Data {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else {
            throw EncodingError.invalidDimensions(width: width, height: height)
        }
        let rowBytes = width.multipliedReportingOverflow(by: colorType.bytesPerPixel)
        let total = rowBytes.partialValue.multipliedReportingOverflow(by: height)
        guard !rowBytes.overflow, !total.overflow else {
            throw EncodingError.invalidDimensions(width: width, height: height)
        }
        guard pixels.count == total.partialValue else {
            throw EncodingError.bufferSizeMismatch(expected: total.partialValue, actual: pixels.count)
        }

        // Filtered image data: each scanline is prefixed by its filter-type byte (0 = None).
        let stride = rowBytes.partialValue
        var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
        pixels.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for row in 0..<height {
                    (d + row * (stride + 1) + 1).update(from: s + row * stride, count: stride)
                }
            }
        }

        var ihdr = [UInt8]()
        ihdr.reserveCapacity(13)
        appendBigEndian(UInt32(width), to: &ihdr)
        appendBigEndian(UInt32(height), to: &ihdr)
        ihdr.append(8)                       // bit depth
        ihdr.append(colorType.pngColorType)  // colour type
        ihdr.append(0)                       // compression method: deflate
        ihdr.append(0)                       // filter method: adaptive (per-row type byte)
        ihdr.append(0)                       // interlace: none

        var out = [UInt8]()
        out.append(contentsOf: signature)
        appendChunk(type: "IHDR", data: ihdr, to: &out)
        appendChunk(type: "IDAT", data: try deflateZlib(raw, level: compressionLevel), to: &out)
        appendChunk(type: "IEND", data: [], to: &out)
        return Data(out)
    }

    /// Encodes an RGBA bitmap (alpha preserved).
    public static func encode(_ bitmap: RGBABitmap, compressionLevel: Int32 = 9) throws -> Data {
        try encode(pixels: [UInt8](bitmap.pixels), width: bitmap.width, height: bitmap.height,
                   colorType: .rgba8, compressionLevel: compressionLevel)
    }

    /// Encodes a rendered slice: grayscale slices as 8-bit gray, colour (RGB
    /// datatype or segmentation-coloured) slices as 8-bit RGB.
    public static func encode(_ slice: SliceImage, compressionLevel: Int32 = 9) throws -> Data {
        switch slice {
        case .grayscale(let img):
            return try encode(pixels: img.pixels, width: img.width, height: img.height,
                              colorType: .gray8, compressionLevel: compressionLevel)
        case .rgb(let img):
            return try encode(pixels: img.pixels, width: img.width, height: img.height,
                              colorType: .rgb8, compressionLevel: compressionLevel)
        }
    }

    // MARK: - CRC-32

    /// Lookup table for the reflected CRC-32 polynomial 0xEDB88320 (ISO 3309 / PNG).
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    /// CRC-32 as PNG defines it (over chunk type + chunk data). Pure Swift, so
    /// the checksum does not depend on the zlib build in use; `crc32("IEND")`
    /// is `0xAE426082`.
    public static func crc32<S: Sequence>(_ bytes: S, seed: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var c = seed ^ 0xFFFF_FFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - Internal

    private static func appendBigEndian(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendChunk(type: String, data: [UInt8], to out: inout [UInt8]) {
        let typeBytes = Array(type.utf8)
        appendBigEndian(UInt32(data.count), to: &out)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        let crc = crc32(data, seed: crc32(typeBytes))
        appendBigEndian(crc, to: &out)
    }

    /// One-shot zlib-wrapped deflate (RFC 1950), which is exactly the format the
    /// concatenated `IDAT` payload must use.
    private static func deflateZlib(_ input: [UInt8], level: Int32) throws -> [UInt8] {
        var destLength = compressBound(uLong(input.count))
        var dest = [UInt8](repeating: 0, count: Int(destLength))
        let status = input.withUnsafeBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { dst in
                compress2(dst.baseAddress, &destLength, src.baseAddress, uLong(input.count),
                          max(0, min(9, level)))
            }
        }
        guard status == Z_OK else { throw EncodingError.compressionFailed(status) }
        dest.removeSubrange(Int(destLength)...)
        return dest
    }
}
