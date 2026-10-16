import Foundation
import Testing
@testable import MIQCore

/// Pure-Swift Zstandard / Blosc / LZ4 decoders against reference vectors made
/// by numcodecs and zarr-python (`scripts/dev/make_codec_fixtures.py`), plus
/// hand-built edge cases and truncation/mutation fuzzing.
struct ZarrCodecTests {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // MIQCoreTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/codecs", isDirectory: true)

    struct Manifest: Decodable {
        struct Stream: Decodable {
            let file: String
            let codec: String
            let size: Int
            let sha256: String
        }
        struct Store: Decodable {
            let store: String
            let shape: [Int]
            let sha256: String
            let originMM: [Double]
            let spacingMM: [Double]

            enum CodingKeys: String, CodingKey {
                case store, shape, sha256
                case originMM = "origin_mm"
                case spacingMM = "spacing_mm"
            }
        }
        let streams: [Stream]
        let stores: [Store]
    }

    static func manifest() throws -> Manifest {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    static func decode(_ codec: String, _ data: Data, size: Int) throws -> Data {
        switch codec {
        case "zst": return try ZstdDecoder.decompress(data, capacity: size)
        case "blosc": return try BloscDecoder.decompress(data, expectedBytes: size)
        case "lz4": return try LZ4Decoder.decompressNumcodecs(data, expectedBytes: size)
        default: throw MIQError.unsupportedFeature(codec)
        }
    }

    // MARK: - Reference vectors

    @Test func everyReferenceStreamDecodesToItsHash() throws {
        let manifest = try Self.manifest()
        #expect(manifest.streams.count >= 60)
        for stream in manifest.streams {
            let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(stream.file))
            let decoded = try Self.decode(stream.codec, data, size: stream.size)
            #expect(decoded.count == stream.size, "\(stream.file)")
            #expect(SHA256.hex(Array(decoded)) == stream.sha256, "\(stream.file)")
        }
    }

    @Test func zarrPythonStoresReadEndToEnd() throws {
        let manifest = try Self.manifest()
        #expect(manifest.stores.count == 4)
        for store in manifest.stores {
            let url = Self.fixtureDirectory.appendingPathComponent(store.store, isDirectory: true)
            let image = try MIQParser().parse(url: url)
            #expect(image.header.dimensions == [store.shape[2], store.shape[1], store.shape[0], 1], "\(store.store)")
            #expect(SHA256.hex(Array(image.storage)) == store.sha256, "\(store.store)")

            // OME translation reaches voxelToWorld, without inventing an orientation.
            #expect(image.header.orientationFrame == nil)
            #expect(image.header.srowIsUnorientedAffine)
            let affine = MIQVolume(image: image).voxelToWorld
            let origin = affine.apply(0, 0, 0)
            #expect(abs(origin.x - store.originMM[0]) < 1e-6, "\(store.store)")
            #expect(abs(origin.y - store.originMM[1]) < 1e-6)
            #expect(abs(origin.z - store.originMM[2]) < 1e-6)
            let far = affine.apply(1, 1, 1)
            #expect(abs(far.x - origin.x - store.spacingMM[0]) < 1e-7)
            #expect(abs(far.y - origin.y - store.spacingMM[1]) < 1e-7)
            #expect(abs(far.z - origin.z - store.spacingMM[2]) < 1e-7)
        }
    }

    // MARK: - XXH64

    @Test func xxh64KnownVectors() {
        func hash(_ s: String) -> UInt64 { Array(s.utf8).withUnsafeBytes { XXHash64.hash($0) } }
        #expect(hash("") == 0xEF46_DB37_51D8_E999)
        #expect(hash("abc") == 0x44BC_2CF5_AD77_0999)
    }

    // MARK: - Hand-built Zstandard frames

    /// Single-segment frame (1-byte content size) wrapping `blocks`.
    static func frame(contentSize: UInt8, descriptorExtra: UInt8 = 0, dictionary: [UInt8] = [], _ blocks: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20 | descriptorExtra]
        bytes += dictionary
        bytes.append(contentSize)
        return Data(bytes + blocks)
    }

    static func blockHeader(last: Bool, type: Int, size: Int) -> [UInt8] {
        let h = (last ? 1 : 0) | type << 1 | size << 3
        return [UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF), UInt8(h >> 16)]
    }

    @Test func rleLiteralsWithoutSequences() throws {
        // Compressed block: RLE literals (20 × "A"), zero sequences.
        let block = Self.blockHeader(last: true, type: 2, size: 3) + [UInt8(20 << 3 | 1), 0x41, 0x00]
        let decoded = try ZstdDecoder.decompress(Self.frame(contentSize: 20, block), capacity: 64)
        #expect(decoded == Data(repeating: 0x41, count: 20))
    }

    @Test func rawAndRLEBlocksAcrossFrames() throws {
        let raw = Self.frame(contentSize: 3, Self.blockHeader(last: true, type: 0, size: 3) + [1, 2, 3])
        let rle = Self.frame(contentSize: 4, Self.blockHeader(last: true, type: 1, size: 4) + [9])
        let skippable = Data([0x5F, 0x2A, 0x4D, 0x18, 2, 0, 0, 0, 0xAA, 0xBB])
        let decoded = try ZstdDecoder.decompress(raw + skippable + rle, capacity: 7)
        #expect(Array(decoded) == [1, 2, 3, 9, 9, 9, 9])
    }

    @Test func dictionaryFramesAreRejectedClearly() {
        let data = Self.frame(contentSize: 1, descriptorExtra: 0x01, dictionary: [7],
                              Self.blockHeader(last: true, type: 0, size: 1) + [0])
        do {
            _ = try ZstdDecoder.decompress(data, capacity: 1)
            Issue.record("expected a dictionary error")
        } catch {
            #expect((error as? MIQError)?.errorDescription?.contains("dictionary") == true)
        }
        // Dictionary ID 0 means "no dictionary".
        let none = Self.frame(contentSize: 1, descriptorExtra: 0x01, dictionary: [0],
                              Self.blockHeader(last: true, type: 0, size: 1) + [5])
        #expect((try? ZstdDecoder.decompress(none, capacity: 1)) == Data([5]))
    }

    @Test func structuralErrorsThrow() {
        let ok = Self.blockHeader(last: true, type: 0, size: 2) + [1, 2]
        // Reserved descriptor bit, reserved block type, content-size mismatch, overflow.
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(Self.frame(contentSize: 2, descriptorExtra: 0x08, ok), capacity: 2) }
        #expect(throws: MIQError.self) {
            try ZstdDecoder.decompress(Self.frame(contentSize: 2, Self.blockHeader(last: true, type: 3, size: 2) + [1, 2]), capacity: 2)
        }
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(Self.frame(contentSize: 3, ok), capacity: 3) }
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(Self.frame(contentSize: 2, ok), capacity: 1) }
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(Data([1, 2, 3, 4, 5]), capacity: 8) }
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(Data(), capacity: 8) }
    }

    @Test func checksumIsVerified() throws {
        let manifest = try Self.manifest()
        let entry = try #require(manifest.streams.first { $0.file == "text_checksum_l3.zst" })
        var data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(entry.file))
        data[data.count - 1] ^= 0x01
        #expect(throws: MIQError.self) { try ZstdDecoder.decompress(data, capacity: entry.size) }
        let unchecked = try ZstdDecoder.decompress(data, capacity: entry.size, verifyChecksum: false)
        #expect(SHA256.hex(Array(unchecked)) == entry.sha256)
    }

    @Test func outputLargerThanCapacityThrows() throws {
        let manifest = try Self.manifest()
        for name in ["text_l3.zst", "repeated_l3.zst", "blosc_lz4_s1_t2.blosc", "numcodecs_lz4.lz4"] {
            let entry = try #require(manifest.streams.first { $0.file == name })
            let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(name))
            #expect(throws: MIQError.self) { try Self.decode(entry.codec, data, size: entry.size - 1) }
        }
    }

    // MARK: - Blosc edge cases

    @Test func bloscSnappyAndDeltaAreClearUnsupportedErrors() {
        func header(flags: UInt8) -> Data {
            var h: [UInt8] = [2, 1, flags, 2]
            for v in [UInt32(64), 64, 40] { withUnsafeBytes(of: v.littleEndian) { h += $0 } }
            return Data(h + [UInt8](repeating: 0, count: 24))
        }
        for (flags, text) in [(UInt8(2 << 5 | 1), "snappy"), (UInt8(1 << 5 | 0x08), "delta")] {
            do {
                _ = try BloscDecoder.decompress(header(flags: flags), expectedBytes: 64)
                Issue.record("expected \(text) to be unsupported")
            } catch {
                #expect((error as? MIQError)?.errorDescription?.contains(text) == true)
            }
        }
        // nbytes must match the expected chunk size; nothing is allocated from it.
        #expect(throws: MIQError.self) { try BloscDecoder.decompress(header(flags: 1 << 5), expectedBytes: 65) }
    }

    @Test func bitUnshuffleInvertsAReferenceShuffle() {
        // Forward bitshuffle by definition, for 16 elements of 3 bytes.
        let typesize = 3
        let count = 16
        let input = (0..<(count * typesize)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        var shuffled = [UInt8](repeating: 0, count: input.count)
        let rowBytes = count / 8
        for i in 0..<count {
            for j in 0..<typesize {
                for k in 0..<8 where input[i * typesize + j] >> k & 1 == 1 {
                    shuffled[(j * 8 + k) * rowBytes + i / 8] |= 1 << (i % 8)
                }
            }
        }
        var output = [UInt8](repeating: 0, count: input.count)
        shuffled.withUnsafeBufferPointer { s in
            output.withUnsafeMutableBufferPointer { o in
                BloscDecoder.bitUnshuffle(s.baseAddress!, into: o.baseAddress!, size: input.count, typesize: typesize, version: 2)
            }
        }
        #expect(output == input)
    }

    // MARK: - Fuzz

    /// Deterministic xorshift so failures reproduce.
    struct XorShift {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @Test func truncatedAndMutatedInputsThrowWithoutTrapping() throws {
        let manifest = try Self.manifest()
        let names = ["text_l1.zst", "skewed_l3.zst", "image_l19.zst", "repeated_l3.zst", "text_checksum_l3.zst",
                     "blosc_blosclz_s1_t4.blosc", "blosc_lz4_s2_t8.blosc", "blosc_zstd_s1_t2.blosc",
                     "blosc_zlib_s0_t1.blosc", "numcodecs_lz4.lz4"]
        var rng = XorShift(state: 0x9E37_79B9_7F4A_7C15)
        for name in names {
            let entry = try #require(manifest.streams.first { $0.file == name })
            let original = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(name))
            // Truncation: always an error (each fixture is one frame / chunk).
            for _ in 0..<40 {
                let cut = Int(rng.next() % UInt64(original.count))
                #expect(throws: (any Error).self, "\(name) cut at \(cut)") {
                    try Self.decode(entry.codec, original.prefix(cut), size: entry.size)
                }
            }
            // Mutation: anything but a trap; a successful decode must keep its size.
            for _ in 0..<150 {
                var mutated = original
                for _ in 0..<(1 + Int(rng.next() % 4)) {
                    let at = Int(rng.next() % UInt64(mutated.count))
                    mutated[at] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
                }
                if let decoded = try? Self.decode(entry.codec, mutated, size: entry.size), entry.codec != "zst" {
                    #expect(decoded.count == entry.size)
                }
            }
            // Random garbage of the same length.
            for _ in 0..<20 {
                let junk = Data((0..<original.count).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
                _ = try? Self.decode(entry.codec, junk, size: entry.size)
            }
        }
    }

    // MARK: - Zarr wiring

    @Test func codecNamesMapToDecoders() throws {
        let dtype = try ZarrDataType.v2("<u2")
        for id in ["blosc", "zstd", "lz4", "gzip", "zlib"] {
            let pipeline = try ZarrCodecPipeline.v2(order: "C", filters: nil, compressor: ["id": id], rank: 3, dtype: dtype)
            #expect(pipeline.bytesCodecs.count == 1)
        }
        for name in ["zstd", "blosc", "numcodecs.zstd", "numcodecs.blosc"] {
            let pipeline = try ZarrCodecPipeline.v3([["name": "bytes"], ["name": name]], rank: 3)
            #expect(pipeline.bytesCodecs.count == 1)
        }
        #expect(throws: MIQError.self) {
            try ZarrCodecPipeline.v2(order: "C", filters: nil, compressor: ["id": "bz2"], rank: 3, dtype: dtype)
        }
        #expect(throws: MIQError.self) { try ZarrCodecPipeline.v3([["name": "zstd"], ["name": "bytes"]], rank: 3) }
    }

    @Test func decodedSizeMustMatchTheChunk() throws {
        let manifest = try Self.manifest()
        let entry = try #require(manifest.streams.first { $0.file == "image_l3.zst" })
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(entry.file))
        // A larger expected chunk is never padded: the short result is caught by
        // `assemble`'s size check.
        #expect(try ZarrChunkReader.decode(data, codecs: [.zstd], expectedBytes: entry.size + 2).count == entry.size)
        #expect(try ZarrChunkReader.decode(data, codecs: [.zstd], expectedBytes: entry.size).count == entry.size)
        #expect(throws: MIQError.self) {
            try ZarrChunkReader.decode(data, codecs: [.zstd], expectedBytes: ZarrArrayMetadata.maxChunkBytes + 1)
        }
    }
}
