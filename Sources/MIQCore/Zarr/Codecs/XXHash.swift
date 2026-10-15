import Foundation

/// XXH64 (seed 0 by default), written from the xxHash specification. Used to
/// verify the optional content checksum of a Zstandard frame, which stores the
/// low 32 bits of XXH64 over the frame's decompressed content.
enum XXHash64 {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always)
    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always)
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* prime2, 31) &* prime1
    }

    @inline(__always)
    private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ round(0, value)) &* prime1 &+ prime4
    }

    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let length = bytes.count
        guard let base = bytes.baseAddress, length > 0 else { return finalize(seed &+ prime5) }
        func load64(_ i: Int) -> UInt64 { UInt64(littleEndian: base.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
        func load32(_ i: Int) -> UInt64 { UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: i, as: UInt32.self))) }

        var i = 0
        var h: UInt64
        if length >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            while i + 32 <= length {
                v1 = round(v1, load64(i))
                v2 = round(v2, load64(i + 8))
                v3 = round(v3, load64(i + 16))
                v4 = round(v4, load64(i + 24))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1)
            h = merge(h, v2)
            h = merge(h, v3)
            h = merge(h, v4)
        } else {
            h = seed &+ prime5
        }
        h &+= UInt64(length)
        while i + 8 <= length {
            h ^= round(0, load64(i))
            h = rotl(h, 27) &* prime1 &+ prime4
            i += 8
        }
        if i + 4 <= length {
            h ^= load32(i) &* prime1
            h = rotl(h, 23) &* prime2 &+ prime3
            i += 4
        }
        while i < length {
            h ^= UInt64(base.load(fromByteOffset: i, as: UInt8.self)) &* prime5
            h = rotl(h, 11) &* prime1
            i += 1
        }
        return finalize(h)
    }

    private static func finalize(_ value: UInt64) -> UInt64 {
        var h = value
        h ^= h >> 33
        h &*= prime2
        h ^= h >> 29
        h &*= prime3
        h ^= h >> 32
        return h
    }
}
