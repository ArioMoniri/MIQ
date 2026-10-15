import Foundation
import zlib

/// Decodes single volumes of a 4D NIfTI on demand, for series whose full payload
/// is over the preview's decompression budget
/// (`MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes`). Instead of
/// refusing volumes > 0, the preview asks for the one volume it is about to show.
///
/// NIfTI stores time as the outermost axis with no strides, so volume `t` is the
/// contiguous byte range `vox_offset + t × volumeBytes ..< + volumeBytes` of the
/// (decompressed) file:
/// - **`.nii`** — that range is read straight from the file: memory-mapped for a
///   local file (a zero-copy slice of the mapping, paged in on demand), or a
///   seek plus chunked, cancellable reads otherwise (a network mount can't be
///   mapped).
/// - **`.nii.gz`** — gzip has no random access, so one inflate stream is kept
///   open and run *forward* to the requested range, discarding the bytes before
///   it. Scrubbing forward from `t` to `t + 1` therefore inflates only one more
///   volume; asking for an earlier volume than the stream's position rewinds to
///   the start of the file. Output is produced in `MIQBinaryReader`-sized
///   windows (`inflateOutputWindow` caps each step) with cancellation polled
///   between windows; a cancelled read throws `CancellationError` and leaves the
///   stream wherever it got to, so the next request resumes from there.
///
/// Decoded volumes are kept in a small LRU (`CostBoundedCache`) bounded by
/// `cacheByteLimit` — never below one volume, so the volume on screen is always
/// reusable for the crosshair readout and re-windowing.
///
/// Thread-safe: reads are serialised by a lock (a second scrub request waits for
/// the first, which stops promptly once its task is cancelled).
public final class NiftiVolumeReader: @unchecked Sendable {
    /// The parsed header of the file (dimensions, datatype, scaling, `voxOffset`).
    public let header: MIQHeader
    public let url: URL
    public let isCompressed: Bool
    /// Bytes of one volume (`width × height × depth × bytesPerVoxel`).
    public let volumeBytes: Int
    /// Volumes along the 4th axis.
    public let volumeCount: Int

    /// Default cap on decoded volumes kept for re-use (256 MiB).
    public static let defaultCacheByteLimit = 256 * 1024 * 1024
    /// Most decoded volumes kept regardless of size.
    public static let maxCachedVolumes = 4
    /// Compressed bytes read per `FileHandle` call on the gzip path.
    static let inputChunkBytes = 256 * 1024
    /// Bytes read per call on the uncompressed unmapped path (matches the
    /// parser's network chunk, which bounds how long a cancelled read runs on).
    static let readChunkBytes = 2 * 1024 * 1024

    private let cache: CostBoundedCache<Int, Data>
    private let lock = NSLock()
    private let mapLocalFile: Bool
    /// The uncompressed file's mapping, created on first use.
    private var mapped: Data?
    private var gzip: GzipForwardStream?

    /// - Parameters:
    ///   - header: the file's parsed NIfTI header (e.g. the cold load's).
    ///   - compressed: `.nii.gz` (`true`) or `.nii`.
    ///   - mapLocalFile: memory-map an uncompressed file instead of reading it
    ///     with seeks; pass `false` for a network volume.
    /// - Throws: `MIQError.invalidDimensions` for a header whose volume size or
    ///   extent is not representable.
    public init(
        url: URL,
        header: MIQHeader,
        compressed: Bool,
        mapLocalFile: Bool = true,
        cacheByteLimit: Int = NiftiVolumeReader.defaultCacheByteLimit
    ) throws {
        guard let bytes = header.estimatedVolumeZeroBytes, bytes > 0,
              header.voxOffset >= 0 else {
            throw MIQError.invalidDimensions
        }
        // The last volume's end must be representable.
        let (span, o1) = bytes.multipliedReportingOverflow(by: max(1, header.volumes))
        let (_, o2) = header.voxOffset.addingReportingOverflow(span)
        guard !o1, !o2 else { throw MIQError.invalidDimensions }
        self.url = url
        self.header = header
        self.isCompressed = compressed
        self.volumeBytes = bytes
        self.volumeCount = header.volumes
        self.mapLocalFile = mapLocalFile
        self.cache = CostBoundedCache(
            countLimit: Self.maxCachedVolumes,
            totalCostLimit: max(cacheByteLimit, bytes)
        )
    }

    deinit {
        gzip?.close()
    }

    /// Whether volume `t` is already decoded (no I/O needed).
    public func isCached(_ t: Int) -> Bool {
        cache.value(forKey: t) != nil
    }

    /// The raw (unscaled, file-endian) bytes of volume `t`.
    /// - Throws: `MIQError.invalidDimensions` for `t` out of range,
    ///   `MIQError.truncatedData` when the file ends inside the volume,
    ///   `CancellationError` when the calling task is cancelled.
    public func volumeData(at t: Int) throws -> Data {
        guard t >= 0, t < volumeCount else { throw MIQError.invalidDimensions }
        if let hit = cache.value(forKey: t) { return hit }
        lock.lock()
        defer { lock.unlock() }
        // Another caller may have decoded it while this one waited.
        if let hit = cache.value(forKey: t) { return hit }
        let start = header.voxOffset + t * volumeBytes
        let data = isCompressed
            ? try readCompressed(start: start)
            : try readUncompressed(start: start)
        cache.insert(data, forKey: t, cost: data.count)
        return data
    }

    /// Volume `t` as a single-volume `MIQVolume`: the original header (geometry,
    /// orientation, scaling) over a payload holding only that volume, so it is
    /// addressed as `volumeIndex: 0` (any other index reads the zero backstop).
    public func volume(at t: Int) throws -> MIQVolume {
        let data = try volumeData(at: t)
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }

    /// Drops every decoded volume (memory pressure). The gzip stream's position
    /// is kept.
    public func purgeCache() {
        cache.removeAll()
    }

    // MARK: - Uncompressed

    private func readUncompressed(start: Int) throws -> Data {
        try Task.checkCancellation()
        if mapLocalFile {
            if mapped == nil {
                mapped = try Data(contentsOf: url, options: [.alwaysMapped])
            }
            if let mapped {
                guard mapped.count - start >= volumeBytes, start >= 0 else { throw MIQError.truncatedData }
                let lower = mapped.startIndex + start
                return mapped[lower..<(lower + volumeBytes)]
            }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        var data = Data()
        data.reserveCapacity(volumeBytes)
        while data.count < volumeBytes {
            try Task.checkCancellation()
            let want = min(Self.readChunkBytes, volumeBytes - data.count)
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                throw MIQError.truncatedData
            }
            data.append(chunk)
        }
        return data
    }

    // MARK: - Compressed

    private func readCompressed(start: Int) throws -> Data {
        if let stream = gzip, stream.position > start {
            stream.close()
            gzip = nil
        }
        let stream: GzipForwardStream
        if let existing = gzip {
            stream = existing
        } else {
            stream = try GzipForwardStream(url: url, inputChunkBytes: Self.inputChunkBytes)
            gzip = stream
        }
        do {
            return try stream.read(from: start, count: volumeBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A corrupt or truncated stream: start over next time.
            stream.close()
            gzip = nil
            throw error
        }
    }
}

/// One gzip member inflated strictly forward from a file, tracking how many
/// decompressed bytes it has produced (`position`). Not thread-safe; the owner
/// serialises access.
final class GzipForwardStream {
    private(set) var position = 0
    private let handle: FileHandle
    private let stream: UnsafeMutablePointer<z_stream>
    private let input: UnsafeMutablePointer<UInt8>
    private let inputCapacity: Int
    private var scratch: [UInt8]
    private var ended = false
    private var closed = false

    init(url: URL, inputChunkBytes: Int) throws {
        handle = try FileHandle(forReadingFrom: url)
        inputCapacity = max(1, inputChunkBytes)
        input = .allocate(capacity: inputCapacity)
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        scratch = [UInt8](repeating: 0, count: min(MIQBinaryReader.inflateOutputWindow, 1 << 20))
        guard inflateInit2_(stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            input.deallocate()
            try? handle.close()
            throw MIQError.decompressionFailed
        }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
        input.deallocate()
        try? handle.close()
    }

    /// Inflates forward to `start` (discarding) and returns the `count` bytes
    /// that follow. `start` must be ≥ `position`.
    func read(from start: Int, count: Int) throws -> Data {
        precondition(!closed && start >= position)
        var out = Data(count: count)
        var copied = 0
        let scratchCount = scratch.count
        while copied < count {
            if Task.isCancelled { throw CancellationError() }
            if ended { throw MIQError.truncatedData }
            if stream.pointee.avail_in == 0 {
                guard let chunk = try handle.read(upToCount: inputCapacity), !chunk.isEmpty else {
                    throw MIQError.truncatedData
                }
                chunk.copyBytes(to: input, count: chunk.count)
                stream.pointee.next_in = input
                stream.pointee.avail_in = UInt32(chunk.count)
            }
            // Skip straight to the wanted range, then copy straight into `out`
            // past the scratch buffer once inside it.
            let produced: Int
            let status: Int32
            if position < start {
                let window = min(scratchCount, start - position)
                (status, produced) = scratch.withUnsafeMutableBufferPointer { buf in
                    inflateStep(into: buf.baseAddress!, window: window)
                }
            } else {
                let window = min(MIQBinaryReader.inflateOutputWindow, count - copied)
                (status, produced) = out.withUnsafeMutableBytes { raw in
                    let base = raw.bindMemory(to: UInt8.self).baseAddress! + copied
                    return inflateStep(into: base, window: window)
                }
                copied += produced
            }
            position += produced
            switch status {
            case Z_OK, Z_BUF_ERROR:
                break
            case Z_STREAM_END:
                ended = true
            default:
                throw MIQError.decompressionFailed
            }
        }
        return out
    }

    private func inflateStep(into base: UnsafeMutablePointer<UInt8>, window: Int) -> (Int32, Int) {
        stream.pointee.next_out = base
        stream.pointee.avail_out = UInt32(window)
        let status = inflate(stream, Z_NO_FLUSH)
        return (status, window - Int(stream.pointee.avail_out))
    }
}

extension MIQParser {
    /// A per-volume reader for a 4D canonical NIfTI (`.nii` / `.nii.gz`) whose
    /// header is already parsed, or `nil` for any other kind (MGH/MIF/NRRD/…
    /// have no cheap per-volume read and keep the "too large" message) and for
    /// 3D files. `isLocal` picks memory mapping over seek-and-read for `.nii`.
    public func niftiVolumeReader(url: URL, header: MIQHeader, isLocal: Bool) throws -> NiftiVolumeReader? {
        guard let kind = MIQFileKind(url: url), kind == .nii || kind == .niiGz,
              header.volumes > 1 else { return nil }
        return try NiftiVolumeReader(url: url, header: header, compressed: kind == .niiGz, mapLocalFile: isLocal)
    }
}
