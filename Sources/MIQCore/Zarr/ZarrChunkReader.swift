import Foundation
import zlib

/// Reads and assembles chunks of one Zarr array from a directory store.
///
/// Works at the granularity of the *addressable* chunk: the stored chunk for an
/// unsharded array, the inner chunk for a sharded one (shards are range-read
/// through their index, never loaded whole). Decoded chunks are byte-swapped to
/// little-endian, so the assembled output is always LE.
///
/// Chunk sizes are bounded by `ZarrArrayMetadata.validateChunkSize`, so the
/// element-count products below cannot overflow. Every chunk or shard file is
/// opened only after its path is checked to lie inside `storeRoot` and its
/// symlink target inside the store or the enclosing dataset's git-annex objects
/// (see `ZarrStoreContainment`), so a chunk symlinked to some other file can't
/// be rendered as voxels.
struct ZarrChunkReader {
    let directory: URL
    let metadata: ZarrArrayMetadata
    /// The store the user picked; no file outside it is read.
    let storeRoot: URL

    /// Shape of one addressable chunk (inner chunk when sharded).
    var chunkShape: [Int] { metadata.pipeline.sharding?.innerChunkShape ?? metadata.chunkShape }

    private var chunkPipeline: ZarrCodecPipeline { metadata.pipeline.sharding?.inner ?? metadata.pipeline }

    /// Copies the hyper-rectangle `[0, extents[d])` of the array into `output`,
    /// placing element `(i_0 … i_n)` at `sum(i_d · outputStrides[d])` elements.
    /// The output must already hold the fill value; missing chunks are skipped.
    func assemble(extents: [Int], outputStrides: [Int], into output: UnsafeMutableRawBufferPointer) throws {
        let rank = metadata.shape.count
        precondition(extents.count == rank && outputStrides.count == rank)
        let elementSize = metadata.dataType.elementSize
        let chunk = chunkShape
        let localStrides = chunkPipeline.elementStrides(chunkShape: chunk)
        let chunkElements = chunk.reduce(1, *)
        guard extents.allSatisfy({ $0 > 0 }) else { return }

        // `(n - 1) / c + 1` rather than `(n + c - 1) / c`: the latter overflows for
        // a chunk extent near `Int.max` (n > 0 is guaranteed above).
        let gridCounts = (0..<rank).map { (extents[$0] - 1) / chunk[$0] + 1 }
        var shardCache: [String: ShardIndex] = [:]

        try forEachIndex(gridCounts) { grid in
            try Task.checkCancellation()
            guard var bytes = try fetchChunk(grid, shardCache: &shardCache) else { return }
            guard bytes.count == chunkElements * elementSize else {
                throw MIQError.malformedFile("Zarr chunk \(grid) decoded to \(bytes.count) bytes, expected \(chunkElements * elementSize)")
            }
            if metadata.dataType.needsSwap { Self.swapBytes(&bytes, width: elementSize) }

            let origin = (0..<rank).map { grid[$0] * chunk[$0] }
            let counts = (0..<rank).map { Swift.min(chunk[$0], extents[$0] - origin[$0]) }
            let dstBase = (0..<rank).reduce(0) { $0 + origin[$1] * outputStrides[$1] }
            let last = rank - 1
            let runIsContiguous = localStrides[last] == 1 && outputStrides[last] == 1

            bytes.withUnsafeBytes { src in
                // Odometer over every axis except the innermost, which is a run.
                let outer = Array(counts.dropLast())
                forEachIndexNoThrow(outer) { local in
                    var srcIndex = 0
                    var dstIndex = dstBase
                    for d in 0..<local.count {
                        srcIndex += local[d] * localStrides[d]
                        dstIndex += local[d] * outputStrides[d]
                    }
                    let run = counts[last]
                    if runIsContiguous {
                        (output.baseAddress! + dstIndex * elementSize)
                            .copyMemory(from: src.baseAddress! + srcIndex * elementSize, byteCount: run * elementSize)
                    } else {
                        for i in 0..<run {
                            (output.baseAddress! + (dstIndex + i * outputStrides[last]) * elementSize)
                                .copyMemory(from: src.baseAddress! + (srcIndex + i * localStrides[last]) * elementSize, byteCount: elementSize)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Chunk fetch

    private struct ShardIndex {
        /// `(offset, nbytes)` per inner chunk in C order; `nil` = empty.
        let entries: [(offset: UInt64, length: UInt64)?]
        let fileURL: URL
    }

    /// Decoded bytes of the addressable chunk at grid coordinates `grid`, or `nil`
    /// when it isn't stored (→ fill value).
    private func fetchChunk(_ grid: [Int], shardCache: inout [String: ShardIndex]) throws -> Data? {
        let expected = chunkShape.reduce(1, *) * metadata.dataType.elementSize
        guard let sharding = metadata.pipeline.sharding else {
            let url = directory.appendingPathComponent(metadata.chunkKey(grid))
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try requireInsideStore(url)
            return try Self.decode(try Data(contentsOf: url), codecs: metadata.pipeline.bytesCodecs, expectedBytes: expected)
        }

        let perShard = zip(metadata.chunkShape, sharding.innerChunkShape).map { $0 / $1 }
        let shardCoords = zip(grid, perShard).map { $0 / $1 }
        let key = metadata.chunkKey(shardCoords)
        let index: ShardIndex
        if let cached = shardCache[key] {
            index = cached
        } else {
            let url = directory.appendingPathComponent(key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try requireInsideStore(url)
            index = try readShardIndex(url: url, innerCount: perShard.reduce(1, *), sharding: sharding)
            shardCache[key] = index
        }
        var linear = 0
        for d in 0..<grid.count {
            linear = linear * perShard[d] + grid[d] % perShard[d]
        }
        guard let entry = index.entries[linear] else { return nil }

        let handle = try FileHandle(forReadingFrom: index.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        guard let stored = try handle.read(upToCount: Int(entry.length)), stored.count == Int(entry.length) else {
            throw MIQError.truncatedData
        }
        return try Self.decode(stored, codecs: sharding.inner.bytesCodecs, expectedBytes: expected)
    }

    /// Throws unless `url` lies inside `storeRoot` lexically and its symlink
    /// target lies inside the store or the enclosing dataset's git-annex object
    /// store (see `ZarrStoreContainment`).
    private func requireInsideStore(_ url: URL) throws {
        guard ZarrStoreContainment.resolvedChunkURL(url, storeRoot: storeRoot) != nil else {
            throw MIQError.unsupportedFeature("Zarr chunk points outside the store; only files inside the store are read")
        }
    }

    private func readShardIndex(url: URL, innerCount: Int, sharding: ZarrSharding) throws -> ShardIndex {
        let indexBytes = innerCount * 16 + (sharding.indexHasChecksum ? 4 : 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= UInt64(indexBytes) else { throw MIQError.truncatedData }
        let indexOffset = sharding.indexAtEnd ? fileSize - UInt64(indexBytes) : 0
        try handle.seek(toOffset: indexOffset)
        guard let raw = try handle.read(upToCount: indexBytes), raw.count == indexBytes else {
            throw MIQError.truncatedData
        }
        var entries: [(offset: UInt64, length: UInt64)?] = []
        entries.reserveCapacity(innerCount)
        for i in 0..<innerCount {
            let offset = MIQBinaryReader.uint64(raw, i * 16, littleEndian: sharding.indexLittleEndian)
            let length = MIQBinaryReader.uint64(raw, i * 16 + 8, littleEndian: sharding.indexLittleEndian)
            if offset == UInt64.max && length == UInt64.max {
                entries.append(nil)
                continue
            }
            let (end, overflow) = offset.addingReportingOverflow(length)
            guard !overflow, end <= fileSize, length <= UInt64(Int.max) else {
                throw MIQError.malformedFile("Zarr shard index entry \(i) points outside the shard")
            }
            entries.append((offset, length))
        }
        return ShardIndex(entries: entries, fileURL: url)
    }

    /// Reads a whole 1-D array (e.g. the NIfTI-Zarr header) as raw bytes.
    func readAllBytes(maxBytes: Int) throws -> Data {
        guard metadata.shape.count == 1 else {
            throw MIQError.malformedFile("expected a 1-D Zarr array")
        }
        let (byteCount, overflow) = metadata.shape[0].multipliedReportingOverflow(by: metadata.dataType.elementSize)
        guard !overflow, byteCount <= maxBytes else { throw MIQError.malformedFile("Zarr byte array is implausibly large") }
        var output = Data(count: byteCount)
        let fill = metadata.fillValue
        try output.withUnsafeMutableBytes { buffer in
            Self.fill(buffer, with: fill)
            try assemble(extents: metadata.shape, outputStrides: [1], into: buffer)
        }
        return output
    }

    // MARK: - Helpers

    /// Undoes `codecs` (listed in encode order). `expectedBytes` caps inflation so
    /// a hostile chunk can't balloon past its declared size.
    static func decode(_ stored: Data, codecs: [ZarrBytesCodec], expectedBytes: Int) throws -> Data {
        var data = stored
        for codec in codecs.reversed() {
            switch codec {
            case .crc32c:
                guard data.count >= 4 else { throw MIQError.truncatedData }
                data = data.prefix(data.count - 4)
            case .deflate:
                data = try inflate(data, expectedBytes: expectedBytes)
            case .zstd:
                data = try ZstdDecoder.decompress(data, capacity: try decodedCap(expectedBytes))
            case .blosc:
                data = try BloscDecoder.decompress(data, expectedBytes: try decodedCap(expectedBytes))
            case .lz4:
                data = try LZ4Decoder.decompressNumcodecs(data, expectedBytes: try decodedCap(expectedBytes))
            }
        }
        return data
    }

    /// `expectedBytes`, after checking it against `ZarrArrayMetadata.maxChunkBytes`:
    /// the pure-Swift decoders allocate their output up front.
    private static func decodedCap(_ expectedBytes: Int) throws -> Int {
        guard expectedBytes >= 0, expectedBytes <= ZarrArrayMetadata.maxChunkBytes else {
            throw MIQError.unsupportedFeature("Zarr chunk is too large to preview")
        }
        return expectedBytes
    }

    /// Inflates a gzip- or zlib-wrapped stream (zlib header auto-detection),
    /// producing at most `expectedBytes`, which must not exceed
    /// `ZarrArrayMetadata.maxChunkBytes`. Input and output are handed to zlib in
    /// windows of at most `window` bytes (`avail_in`/`avail_out` are UInt32), so
    /// neither side can overflow the conversion. `window` is a parameter only so
    /// tests can exercise the refills without multi-GiB fixtures.
    static func inflate(_ input: Data, expectedBytes: Int, window: Int = Int(UInt32.max)) throws -> Data {
        guard expectedBytes > 0 else { return Data() }
        guard expectedBytes <= ZarrArrayMetadata.maxChunkBytes, window > 0 else {
            throw MIQError.unsupportedFeature("Zarr chunk is too large to preview")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 32 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { inflateEnd(&stream) }
        let window = Swift.min(window, Int(UInt32.max))
        var output = Data(count: expectedBytes)
        let input = Data(input) // contiguous, zero-based
        var produced = 0
        var status: Int32 = Z_OK
        input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                guard let outBase = outRaw.bindMemory(to: Bytef.self).baseAddress else {
                    status = Z_DATA_ERROR
                    return
                }
                let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress
                var fed = 0
                while produced < expectedBytes {
                    if stream.avail_in == 0, fed < inRaw.count, let inBase {
                        let chunk = Swift.min(inRaw.count - fed, window)
                        stream.next_in = UnsafeMutablePointer(mutating: inBase + fed)
                        stream.avail_in = UInt32(chunk)
                        fed += chunk
                    }
                    let outWindow = Swift.min(expectedBytes - produced, window)
                    stream.next_out = outBase + produced
                    stream.avail_out = UInt32(outWindow)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced += outWindow - Int(stream.avail_out)
                    if status == Z_STREAM_END { return }
                    guard status == Z_OK || status == Z_BUF_ERROR else { return }
                    // No progress possible: every input byte consumed, output space left.
                    if stream.avail_in == 0, fed >= inRaw.count, stream.avail_out > 0 { return }
                }
            }
        }
        // A full buffer is success even if the stream has trailing data we didn't need.
        guard status == Z_STREAM_END || produced == expectedBytes else {
            throw MIQError.decompressionFailed
        }
        return output.prefix(produced)
    }

    static func fill(_ buffer: UnsafeMutableRawBufferPointer, with pattern: [UInt8]) {
        guard let base = buffer.baseAddress, !pattern.isEmpty else { return }
        if pattern.allSatisfy({ $0 == 0 }) {
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            return
        }
        let count = buffer.count / pattern.count
        pattern.withUnsafeBytes { p in
            for i in 0..<count {
                (base + i * pattern.count).copyMemory(from: p.baseAddress!, byteCount: pattern.count)
            }
        }
    }

    static func swapBytes(_ data: inout Data, width: Int) {
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + width <= bytes.count {
                var lo = i
                var hi = i + width - 1
                while lo < hi {
                    bytes.swapAt(lo, hi)
                    lo += 1
                    hi -= 1
                }
                i += width
            }
        }
    }
}

/// Calls `body` for every index tuple in `[0, counts[0]) × … × [0, counts[n])`,
/// last axis fastest. A zero-rank shape visits the single empty tuple once.
private func forEachIndex(_ counts: [Int], _ body: ([Int]) throws -> Void) rethrows {
    guard counts.allSatisfy({ $0 > 0 }) else { return }
    var index = [Int](repeating: 0, count: counts.count)
    while true {
        try body(index)
        var d = counts.count - 1
        while d >= 0 {
            index[d] += 1
            if index[d] < counts[d] { break }
            index[d] = 0
            d -= 1
        }
        if d < 0 { return }
    }
}

private func forEachIndexNoThrow(_ counts: [Int], _ body: ([Int]) -> Void) {
    forEachIndex(counts, body)
}
