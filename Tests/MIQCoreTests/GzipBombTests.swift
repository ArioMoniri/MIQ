import Foundation
import Testing
import zlib
@testable import MIQCore

/// Decompression-bomb and lying-trailer behaviour of the gzip paths.
///
/// What is bounded, and by what (see `MIQBinaryReader.initialInflateCapacity` and
/// `MIQParser.niftiVolumeZeroBudget`):
/// - `.nii.gz` cold load: output is capped at `vox_offset + volume-0 bytes`, so a
///   stream that inflates far past its header's declared payload costs only the
///   declared payload. The trailer is never reached, so a lying ISIZE is moot.
/// - `.nii.gz` with `fullyDecompress: true`, `.mgz`, `.mif.gz`, NRRD `encoding: gzip`:
///   the whole stream is inflated — by design, since a sparse mask legitimately
///   reaches bomb-like ratios. The output is bounded by the *real* stream (never by
///   ISIZE), and zlib's length check at stream end rejects a lying ISIZE.
/// - ISIZE only seeds the first allocation, clamped to 1100× the compressed size.
struct GzipBombTests {
    private static func tempURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-bomb-\(UUID().uuidString)\(suffix)")
    }

    private static func write(_ data: Data, suffix: String) throws -> URL {
        let url = tempURL(suffix)
        try data.write(to: url)
        return url
    }

    /// 4×4×4 uint8 NIfTI-1 (352 + 64 bytes) — the "small dims" the header claims.
    private static let smallNii = TestMIQFactory.makeNii(width: 4, height: 4, depth: 4, datatype: .uint8)

    /// Replaces the gzip trailer's ISIZE (last 4 bytes, little-endian).
    private static func withISIZE(_ gz: Data, _ isize: UInt32) -> Data {
        var bytes = [UInt8](gz)
        for k in 0..<4 { bytes[bytes.count - 4 + k] = UInt8(truncatingIfNeeded: isize >> (8 * UInt32(k))) }
        return Data(bytes)
    }

    // MARK: - Stream inflating past the declared payload

    @Test
    func niiGzBombIsCappedToDeclaredPayload() throws {
        // 64 MiB of zeros after a header declaring a 64-byte payload: ~290 KiB compressed.
        let tail = 64 << 20
        let gz = try StreamingGzip.gzip(prefix: Self.smallNii, zeroTail: tail)
        #expect(gz.count < 1 << 20)
        let url = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try MIQParser().parse(url: url)
        // Exactly vox_offset + 4·4·4 — not one byte of the 64 MiB tail.
        #expect(image.storage.count == Self.smallNii.count)
        let volume = MIQVolume(image: image)
        #expect(volume.containsAllVolumes)
        #expect(volume.voxel(x: 3, y: 3, z: 3) == Float(63))
    }

    @Test
    func niiGzBombFullDecompressIsBoundedByRealStreamNotTrailer() throws {
        // Documented unbounded path (4D navigation re-parse): the full stream is
        // inflated, but no more than the stream really holds.
        let tail = 8 << 20
        let gz = try StreamingGzip.gzip(prefix: Self.smallNii, zeroTail: tail)
        let url = try Self.write(Self.withISIZE(gz, 0x10), suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        // Understated ISIZE: zlib's length check rejects it at stream end.
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url, fullyDecompress: true) }

        let honest = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: honest) }
        let image = try MIQParser().parse(url: honest, fullyDecompress: true)
        #expect(image.storage.count == Self.smallNii.count + tail)
    }

    @Test
    func niiGzClaimingHugeDimsOverSmallStreamThrowsTruncated() throws {
        // Header declares 1000³ uint8 (1 GB budget); the stream holds ~1 MiB. The
        // capped inflate must stop at the real stream end (capacity seeded from the
        // 1100× ratio, not the budget) and the parser reject the short payload.
        var header = [UInt8](Self.smallNii.prefix(352))
        for (i, dim) in [Int16(1000), 1000, 1000].enumerated() {
            let u = UInt16(bitPattern: dim)
            header[42 + 2 * i] = UInt8(u & 0xFF)
            header[43 + 2 * i] = UInt8(u >> 8)
        }
        let gz = try StreamingGzip.gzip(prefix: Data(header), zeroTail: 1 << 20)
        let url = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url) }
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url, fullyDecompress: true) }
    }

    @Test
    func mgzBombInflatesOnlyTheRealStream() throws {
        // MGH has no volume-0 cap (`parseMgh` needs every frame), so the whole
        // stream is inflated; trailing bytes past the declared payload are ignored.
        let mgh = TestMIQFactory.makeMgh(width: 4, height: 4, depth: 4, frames: 1, datatype: .uint8)
        let tail = 8 << 20
        let gz = try StreamingGzip.gzip(prefix: mgh, zeroTail: tail)
        let url = try Self.write(gz, suffix: ".mgz")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try MIQParser().parse(url: url)
        #expect(image.storage.count == mgh.count + tail)
        #expect(MIQVolume(image: image).voxel(x: 1, y: 0, z: 0) == 1)
    }

    // MARK: - Lying ISIZE trailer

    @Test(arguments: [UInt32(0), 1, 415, 417, 0x7FFF_FFFF, 0xFFFF_FFFF])
    func smallNiiGzLyingISIZEIsRejected(_ isize: UInt32) throws {
        // The whole stream fits in the 64 KiB header probe, so the probe itself
        // reaches the trailer, zlib's length check fails, and both paths throw.
        let gz = Self.withISIZE(try TestZlib.gzip(Self.smallNii), isize)
        let url = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url) }
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url, fullyDecompress: true) }
    }

    @Test(arguments: [UInt32(0), 1, 0x7FFF_FFFF, 0xFFFF_FFFF])
    func largeNiiGzLyingISIZEColdLoadStopsBeforeTrailer(_ isize: UInt32) throws {
        // Stream longer than the probe and the volume-0 budget: the capped inflate
        // stops at the declared payload without reaching the trailer, so the cold
        // load yields exactly volume 0 whatever ISIZE claims...
        let gz = Self.withISIZE(try StreamingGzip.gzip(prefix: Self.smallNii, zeroTail: 1 << 20), isize)
        let url = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try MIQParser().parse(url: url)
        #expect(image.storage.count == Self.smallNii.count)
        // ...and full decompression reaches the trailer, where zlib rejects the lie.
        #expect(throws: MIQError.self) { _ = try MIQParser().parse(url: url, fullyDecompress: true) }
    }

    @Test(arguments: [UInt32(0), 1, 0x7FFF_FFFF, 0xFFFF_FFFF])
    func compressedKindsRejectLyingISIZE(_ isize: UInt32) throws {
        let cases: [(Data, String)] = [
            (TestMIQFactory.makeMgh(width: 4, height: 4, depth: 4, frames: 1, datatype: .uint8), ".mgz"),
            (TestMIQFactory.makeMif(width: 4, height: 4, depth: 4, datatype: .uint8), ".mif.gz"),
        ]
        for (plain, suffix) in cases {
            let url = try Self.write(Self.withISIZE(try TestZlib.gzip(plain), isize), suffix: suffix)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: MIQError.self, "\(suffix) isize=\(isize)") { _ = try MIQParser().parse(url: url) }
        }
    }

    @Test
    func inflateCapacityIgnoresInflatedISIZE() {
        // A 100-byte stream claiming 4 GiB gets at most 1100× its size up front.
        #expect(MIQBinaryReader.initialInflateCapacity(compressedCount: 100, isize: .max) == 110_000)
        #expect(MIQBinaryReader.initialInflateCapacity(compressedCount: 10, isize: .max) == MIQBinaryReader.inflateCapacityFloor)
        #expect(MIQBinaryReader.initialInflateCapacity(compressedCount: 1 << 20, isize: .max) == (1 << 20) * 1100)
        // A wrapped / zero hint still starts at the floor.
        #expect(MIQBinaryReader.initialInflateCapacity(compressedCount: 1 << 20, isize: 0) == MIQBinaryReader.inflateCapacityFloor)
    }

    // MARK: - 16 MiB output window boundaries

    @Test(arguments: [-1, 0, 1])
    func cappedGunzipIsExactAcrossOutputWindowBoundary(_ delta: Int) throws {
        let window = MIQBinaryReader.inflateOutputWindow
        let gz = try StreamingGzip.gzip(prefix: Data([1, 2, 3]), zeroTail: window + (1 << 20))
        let cap = window + delta
        let out = try MIQBinaryReader.gunzip(gz, maxOutputBytes: cap)
        #expect(out.count == cap)
        #expect(out.prefix(3) == Data([1, 2, 3]))
    }

    @Test
    func niiGzBudgetSpanningTwoOutputWindowsIsExact() throws {
        // Volume 0 = 4096×4097 uint8 = 16 MiB + 4 KiB: the capped inflate needs a
        // second 16 MiB window and must stop exactly at the budget, not at a window edge.
        let width = 4096, height = 4097
        var header = [UInt8](TestMIQFactory.makeNii(width: 1, height: 1, depth: 1, datatype: .uint8).prefix(352))
        for (i, dim) in [Int16(width), Int16(height), 1].enumerated() {
            let u = UInt16(bitPattern: dim)
            header[42 + 2 * i] = UInt8(u & 0xFF)
            header[43 + 2 * i] = UInt8(u >> 8)
        }
        let budget = 352 + width * height
        #expect(budget > MIQBinaryReader.inflateOutputWindow)
        let gz = try StreamingGzip.gzip(prefix: Data(header), zeroTail: width * height + (4 << 20))
        let url = try Self.write(gz, suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try MIQParser().parse(url: url)
        #expect(image.storage.count == budget)
    }
}

/// Streaming gzip writer for large, highly compressible fixtures: `prefix`
/// followed by `zeroTail` zero bytes, deflated in 1 MiB chunks so the test never
/// holds the uncompressed stream in memory.
enum StreamingGzip {
    static func gzip(prefix: Data, zeroTail: Int) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, 16 + MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        var outBuffer = [UInt8](repeating: 0, count: 1 << 16)
        let zeros = [UInt8](repeating: 0, count: 1 << 20)

        func feed(_ chunk: [UInt8], finish: Bool) throws {
            var input = chunk
            try input.withUnsafeMutableBufferPointer { inBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = UInt32(inBuf.count)
                var status: Int32 = Z_OK
                repeat {
                    status = outBuffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = UInt32(outBuf.count)
                        let ret = deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                        output.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.avail_out))
                        return ret
                    }
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw MIQError.decompressionFailed
                    }
                } while stream.avail_in > 0 || (finish && status != Z_STREAM_END)
            }
        }

        try feed([UInt8](prefix), finish: false)
        var remaining = zeroTail
        while remaining > 0 {
            let n = Swift.min(remaining, zeros.count)
            try feed(n == zeros.count ? zeros : Array(zeros.prefix(n)), finish: false)
            remaining -= n
        }
        try feed([], finish: true)
        return output
    }
}
