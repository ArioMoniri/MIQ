import Foundation

/// Pure-Swift LZ4 *block* decompressor (the raw block format, no frame),
/// written from the LZ4 block format description. Used inside Blosc chunks and
/// by numcodecs' `lz4` codec, which prefixes the block with its decompressed
/// size as a little-endian `UInt32`.
///
/// Every literal run and match is bounds-checked against both buffers, so a
/// truncated or hostile block throws instead of trapping.
enum LZ4Decoder {
    static func corrupt(_ message: String) -> MIQError {
        .malformedFile("LZ4 data is corrupt (\(message))")
    }

    /// Decodes one LZ4 block into `output`, returning the bytes written. The
    /// block must end with a literal-only sequence, exactly at `input`'s end.
    static func decompressBlock(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws -> Int {
        let inCount = input.count
        let outCount = output.count
        guard inCount > 0, let src = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw corrupt("empty block")
        }
        let dst = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        var ip = 0
        var op = 0
        while true {
            guard ip < inCount else { throw MIQError.truncatedData }
            let token = Int(src[ip])
            ip += 1

            var literalLength = token >> 4
            if literalLength == 15 {
                var byte: Int
                repeat {
                    guard ip < inCount else { throw MIQError.truncatedData }
                    byte = Int(src[ip])
                    ip += 1
                    literalLength += byte
                } while byte == 255
            }
            guard literalLength <= inCount - ip else { throw MIQError.truncatedData }
            guard literalLength <= outCount - op else { throw corrupt("literals overflow the output") }
            if literalLength > 0 {
                (dst! + op).update(from: src + ip, count: literalLength)
                ip += literalLength
                op += literalLength
            }
            if ip == inCount { return op } // Last sequence: literals only.

            guard inCount - ip >= 2 else { throw MIQError.truncatedData }
            let offset = Int(src[ip]) | Int(src[ip + 1]) << 8
            ip += 2
            guard offset > 0, offset <= op else { throw corrupt("match offset out of range") }
            var matchLength = token & 15
            if matchLength == 15 {
                var byte: Int
                repeat {
                    guard ip < inCount else { throw MIQError.truncatedData }
                    byte = Int(src[ip])
                    ip += 1
                    matchLength += byte
                } while byte == 255
            }
            matchLength += 4
            guard matchLength <= outCount - op else { throw corrupt("match overflows the output") }
            copyMatch(dst!, at: op, offset: offset, length: matchLength)
            op += matchLength
        }
    }

    /// numcodecs `LZ4`: a little-endian `UInt32` decompressed size, then one
    /// LZ4 block. The size must equal `expectedBytes`.
    static func decompressNumcodecs(_ input: Data, expectedBytes: Int) throws -> Data {
        guard input.count >= 4 else { throw MIQError.truncatedData }
        let stored = Data(input)
        let declared = Int(stored[0]) | Int(stored[1]) << 8 | Int(stored[2]) << 16 | Int(stored[3]) << 24
        guard declared == expectedBytes else {
            throw MIQError.malformedFile("LZ4 chunk declares \(declared) bytes, expected \(expectedBytes)")
        }
        var output = Data(count: expectedBytes)
        let produced = try stored.withUnsafeBytes { raw in
            try output.withUnsafeMutableBytes { out in
                try decompressBlock(UnsafeRawBufferPointer(rebasing: raw[4...]), into: out)
            }
        }
        guard produced == expectedBytes else { throw corrupt("block decodes to \(produced) bytes, expected \(expectedBytes)") }
        return output
    }

    /// Overlap-aware LZ77 match copy (`offset < length` repeats the pattern).
    @inline(__always)
    static func copyMatch(_ out: UnsafeMutablePointer<UInt8>, at position: Int, offset: Int, length: Int) {
        let dst = out + position
        let src = dst - offset
        if offset >= length {
            dst.update(from: src, count: length)
        } else if offset == 1 {
            dst.update(repeating: src.pointee, count: length)
        } else {
            var copied = 0
            while copied < length {
                let n = Swift.min(offset, length - copied)
                (dst + copied).update(from: src + copied, count: n)
                copied += n
            }
        }
    }
}
