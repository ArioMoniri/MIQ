import Foundation

/// Pure-Swift decoder for Blosc 1.x chunks (the numcodecs / zarr-python v2
/// default compressor), written from the Blosc 1 format description.
///
/// A chunk is a 16-byte header — version, versionlz, flags, typesize, nbytes,
/// blocksize, cbytes — then either the raw data (`memcpyed` flag) or a table of
/// per-block offsets followed by the blocks. Each block is compressed as one
/// stream or, when split, as `typesize` streams (one per byte of the element),
/// each prefixed by its compressed size. Decompressed blocks are then byte- or
/// bit-unshuffled. Inner codecs: BloscLZ, LZ4/LZ4HC, zlib and Zstandard;
/// Snappy and the delta filter throw a clear unsupported error.
///
/// The header's `nbytes` must equal the caller's expected size, so nothing is
/// allocated from header fields, and every offset is checked against `cbytes`.
enum BloscDecoder {
    private static let headerSize = 16
    private static let doShuffle: UInt8 = 0x01
    private static let memcpyed: UInt8 = 0x02
    private static let doBitShuffle: UInt8 = 0x04
    private static let doDelta: UInt8 = 0x08
    private static let dontSplit: UInt8 = 0x10

    static func corrupt(_ message: String) -> MIQError {
        .malformedFile("Blosc data is corrupt (\(message))")
    }

    /// Decodes a Blosc chunk that must decompress to exactly `expectedBytes`.
    static func decompress(_ input: Data, expectedBytes: Int) throws -> Data {
        guard expectedBytes >= 0 else { throw corrupt("negative size") }
        var output = Data(count: expectedBytes)
        try Data(input).withUnsafeBytes { raw in
            try output.withUnsafeMutableBytes { out in
                try decompress(raw, into: out)
            }
        }
        return output
    }

    private static func u32(_ p: UnsafePointer<UInt8>, _ i: Int) -> Int {
        Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16 | Int(p[i + 3]) << 24
    }

    /// Decodes into `output`, whose size must equal the header's `nbytes`.
    static func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws {
        guard input.count >= headerSize, let src = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw MIQError.truncatedData
        }
        let version = src[0]
        let flags = src[2]
        let typesize = Int(src[3])
        let nbytes = u32(src, 4)
        let blocksize = u32(src, 8)
        let cbytes = u32(src, 12)
        guard (1...4).contains(version) else {
            throw MIQError.unsupportedFeature("Blosc format version \(version) isn't supported")
        }
        guard flags & (doShuffle | doBitShuffle) != (doShuffle | doBitShuffle) else {
            throw MIQError.unsupportedFeature("Blosc2 extended chunk headers aren't supported")
        }
        guard nbytes == output.count else {
            throw MIQError.malformedFile("Blosc chunk declares \(nbytes) bytes, expected \(output.count)")
        }
        guard cbytes >= headerSize, cbytes <= input.count else { throw MIQError.truncatedData }
        guard nbytes > 0, let dst = output.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

        if flags & memcpyed != 0 {
            guard cbytes - headerSize >= nbytes else { throw MIQError.truncatedData }
            dst.update(from: src + headerSize, count: nbytes)
            return
        }
        guard flags & doDelta == 0 else {
            throw MIQError.unsupportedFeature("Blosc delta filter isn't supported")
        }
        guard typesize > 0 else { throw corrupt("typesize 0") }
        guard blocksize > 0 else { throw corrupt("blocksize 0") }
        let compressor = Int(flags >> 5)
        switch compressor {
        case 0, 1, 3, 4: break
        case 2: throw MIQError.unsupportedFeature("Blosc compressor snappy isn't supported")
        default: throw MIQError.unsupportedFeature("Blosc compressor code \(compressor) isn't supported")
        }

        let leftover = nbytes % blocksize
        let blockCount = nbytes / blocksize + (leftover > 0 ? 1 : 0)
        let tableEnd = headerSize + 4 * blockCount
        guard blockCount <= (cbytes - headerSize) / 4 else { throw MIQError.truncatedData }
        let maxBlock = Swift.min(blocksize, nbytes)
        let shuffles = flags & doShuffle != 0 && typesize > 1
        let bitShuffles = flags & doBitShuffle != 0
        var scratch = [UInt8](repeating: 0, count: shuffles || bitShuffles ? maxBlock : 0)

        for block in 0..<blockCount {
            try Task.checkCancellation()
            let isLeftover = block == blockCount - 1 && leftover > 0
            let size = isLeftover ? leftover : blocksize
            let blockOut = dst + block * blocksize
            let start = u32(src, headerSize + 4 * block)
            guard start >= tableEnd, start < cbytes else { throw corrupt("block offset out of range") }

            let unshuffle = shuffles || (bitShuffles && size >= typesize)
            try scratch.withUnsafeMutableBufferPointer { tmp in
                let target = unshuffle ? tmp.baseAddress! : blockOut
                let streams = flags & dontSplit == 0 && !isLeftover ? typesize : 1
                guard size % streams == 0 else { throw corrupt("block doesn't split into \(streams) streams") }
                let streamSize = size / streams
                var p = start
                for stream in 0..<streams {
                    guard cbytes - p >= 4 else { throw MIQError.truncatedData }
                    let compressed = u32(src, p)
                    p += 4
                    guard compressed > 0, compressed <= cbytes - p else { throw corrupt("stream size out of range") }
                    let streamOut = target + stream * streamSize
                    if compressed == streamSize {
                        streamOut.update(from: src + p, count: streamSize)
                    } else {
                        let produced = try decodeStream(
                            compressor: compressor,
                            UnsafeRawBufferPointer(start: src + p, count: compressed),
                            into: UnsafeMutableRawBufferPointer(start: streamOut, count: streamSize)
                        )
                        guard produced == streamSize else {
                            throw corrupt("stream decodes to \(produced) bytes, expected \(streamSize)")
                        }
                    }
                    p += compressed
                }
                guard unshuffle else { return }
                if shuffles {
                    byteUnshuffle(tmp.baseAddress!, into: blockOut, size: size, typesize: typesize)
                } else {
                    bitUnshuffle(tmp.baseAddress!, into: blockOut, size: size, typesize: typesize, version: version)
                }
            }
        }
    }

    private static func decodeStream(compressor: Int, _ input: UnsafeRawBufferPointer,
                                     into output: UnsafeMutableRawBufferPointer) throws -> Int {
        switch compressor {
        case 0:
            return try BloscLZDecoder.decompress(input, into: output)
        case 1:
            return try LZ4Decoder.decompressBlock(input, into: output)
        case 3:
            let inflated = try ZarrChunkReader.inflate(Data(input), expectedBytes: output.count)
            inflated.withUnsafeBytes { output.copyMemory(from: $0) }
            return inflated.count
        default:
            return try ZstdDecoder.decompress(input, into: output)
        }
    }

    /// Inverse of Blosc's byte shuffle: byte `j` of every element was stored
    /// contiguously; trailing `size % typesize` bytes are stored as-is.
    static func byteUnshuffle(_ src: UnsafePointer<UInt8>, into dst: UnsafeMutablePointer<UInt8>, size: Int, typesize: Int) {
        let count = size / typesize
        for j in 0..<typesize {
            let plane = src + j * count
            var out = dst + j
            for i in 0..<count {
                out.pointee = plane[i]
                out += typesize
            }
        }
        let tail = count * typesize
        if tail < size { (dst + tail).update(from: src + tail, count: size - tail) }
    }

    /// Inverse of bitshuffle: bit `k` of byte `j` of every element was stored as
    /// one bit plane (row `j * 8 + k`, LSB-first within each byte). Blosc 1
    /// (format ≤ 2) only bit-shuffles when the element count is a multiple of
    /// 8 and otherwise stores the block as-is; Blosc 2 shuffles the largest
    /// multiple of 8 elements. Remaining bytes are always stored as-is.
    static func bitUnshuffle(_ src: UnsafePointer<UInt8>, into dst: UnsafeMutablePointer<UInt8>,
                             size: Int, typesize: Int, version: UInt8) {
        var elements = size / typesize
        if version <= 2 {
            if elements % 8 != 0 { elements = 0 }
        } else {
            elements -= elements % 8
        }
        let rowBytes = elements / 8
        for group in 0..<rowBytes {
            for j in 0..<typesize {
                var x: UInt64 = 0
                for k in 0..<8 {
                    x |= UInt64(src[(j * 8 + k) * rowBytes + group]) << UInt64(8 * k)
                }
                x = transposeBits8x8(x)
                for m in 0..<8 {
                    dst[(group * 8 + m) * typesize + j] = UInt8(truncatingIfNeeded: x >> UInt64(8 * m))
                }
            }
        }
        let done = elements * typesize
        if done < size { (dst + done).update(from: src + done, count: size - done) }
    }

    /// Transposes an 8×8 bit matrix stored row-per-byte (bit `m` of byte `k`
    /// moves to bit `k` of byte `m`).
    @inline(__always)
    static func transposeBits8x8(_ value: UInt64) -> UInt64 {
        var x = value
        var t = (x ^ (x >> 7)) & 0x00AA_00AA_00AA_00AA
        x = x ^ t ^ (t << 7)
        t = (x ^ (x >> 14)) & 0x0000_CCCC_0000_CCCC
        x = x ^ t ^ (t << 14)
        t = (x ^ (x >> 28)) & 0x0000_0000_F0F0_F0F0
        x = x ^ t ^ (t << 28)
        return x
    }
}

/// BloscLZ decompressor (Blosc's built-in FastLZ derivative). Each instruction
/// starts with a control byte: below 32 it is a literal run of `ctrl + 1`
/// bytes; otherwise the top three bits give the match length (7 = extended by
/// following bytes) and the low five bits plus the next byte the distance, with
/// a 16-bit far distance escape.
enum BloscLZDecoder {
    private static let maxDistance = 8191

    static func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = input.count
        let capacity = output.count
        guard count > 0, let src = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw BloscDecoder.corrupt("empty BloscLZ stream")
        }
        let dst = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        var ip = 0
        var op = 0
        var ctrl = Int(src[0] & 31)
        ip = 1
        while true {
            if ctrl >= 32 {
                var length = (ctrl >> 5) - 1
                let high = (ctrl & 31) << 8
                if length == 6 {
                    var code: Int
                    repeat {
                        guard ip < count else { throw MIQError.truncatedData }
                        code = Int(src[ip])
                        ip += 1
                        length += code
                    } while code == 255
                }
                guard ip < count else { throw MIQError.truncatedData }
                let code = Int(src[ip])
                ip += 1
                length += 3
                var distance = high + code + 1
                if code == 255, high == 31 << 8 {
                    guard count - ip >= 2 else { throw MIQError.truncatedData }
                    distance = (Int(src[ip]) << 8 | Int(src[ip + 1])) + maxDistance + 1
                    ip += 2
                }
                guard distance <= op else { throw BloscDecoder.corrupt("BloscLZ match before the block start") }
                guard length <= capacity - op else { throw BloscDecoder.corrupt("BloscLZ match overflows the block") }
                LZ4Decoder.copyMatch(dst!, at: op, offset: distance, length: length)
                op += length
            } else {
                let length = ctrl + 1
                guard length <= count - ip else { throw MIQError.truncatedData }
                guard length <= capacity - op else { throw BloscDecoder.corrupt("BloscLZ literals overflow the block") }
                (dst! + op).update(from: src + ip, count: length)
                ip += length
                op += length
            }
            if ip >= count { return op }
            ctrl = Int(src[ip])
            ip += 1
        }
    }
}
