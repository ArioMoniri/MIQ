import Foundation
import Testing
@testable import MIQCore

/// Deterministic, structured parser fuzzing across every supported format, plain and
/// gzip'd. Complements `MIQCoreTests.parsersSurviveRandomCorruption` (random byte
/// noise on the in-memory parsers) with *targeted* mutations — truncation at every
/// interesting offset, each header field driven to its extremes, malformed text
/// headers — run through the real entry point, `MIQParser.parse(url:)`, so the
/// gzip / volume-0-budget plumbing is exercised too, and through the slice renderer
/// whenever a mutation still parses.
///
/// The contract under test: for any input, the parser either returns an image that
/// is safe to render or throws an `MIQError`. It never traps (a trap kills the whole
/// test process, so simply finishing the run is the assertion), never hands back a
/// buffer wildly larger than its input could justify, and never returns an image
/// whose declared volume 0 lies outside its own buffer.
///
/// Every mutation is derived from fixed seeds (SplitMix64) and loop indices only, so
/// a failure message's `case` label reproduces exactly, run to run and machine to
/// machine.
struct ParserFuzzTests {
    // MARK: - Targets

    enum Format: String, CaseIterable, Sendable {
        case nifti1, nifti2, mgh, mif, nrrd

        var isText: Bool { self == .mif || self == .nrrd }
    }

    struct Target: Sendable, CustomTestStringConvertible {
        let format: Format
        let gzipped: Bool

        var testDescription: String { "\(format.rawValue)\(gzipped ? ".gz" : "")" }

        /// File extension handed to `MIQFileKind(url:)`. NRRD has no `.nrrd.gz`
        /// kind: its "gzip'd" form is `encoding: gzip` inside a `.nrrd`.
        var fileExtension: String {
            switch (format, gzipped) {
            case (.nifti1, false), (.nifti2, false): return "nii"
            case (.nifti1, true), (.nifti2, true): return "nii.gz"
            case (.mgh, false): return "mgh"
            case (.mgh, true): return "mgz"
            case (.mif, false): return "mif"
            case (.mif, true): return "mif.gz"
            case (.nrrd, _): return "nrrd"
            }
        }

        /// Whether the on-disk bytes are the gzip of the logical file (as opposed
        /// to NRRD, whose gzip lives inside the file after a plain-text header).
        var wrapsWholeFileInGzip: Bool { gzipped && format != .nrrd }
    }

    static let allTargets: [Target] = Format.allCases.flatMap {
        [Target(format: $0, gzipped: false), Target(format: $0, gzipped: true)]
    }
    static let binaryTargets = allTargets.filter { !$0.format.isText }
    static let textTargets = allTargets.filter { $0.format.isText }
    static let gzipTargets = allTargets.filter { $0.gzipped }

    // MARK: - Tests

    /// Every unmutated seed must parse and render, or the mutations below start
    /// from an already-rejected file and probe nothing.
    @Test(arguments: allTargets)
    func seedFileParses(_ target: Target) throws {
        let harness = try FuzzHarness(target: target)
        harness.exercise(onDisk: try FuzzHarness.seedFile(for: target), label: "seed")
        #expect(harness.stats.parsed > 0 && harness.stats.rejected == 0)
        harness.finish("seed", expectBothOutcomes: false)
    }

    /// Every prefix length through the first 64 bytes (where the size / magic /
    /// dims fields live), every 4th across the rest of the header (all binary fields
    /// are 2/4/8-byte aligned), a sweep of the payload, and the lengths that
    /// straddle the declared payload end.
    @Test(arguments: allTargets)
    func truncationAtManyOffsets(_ target: Target) throws {
        let seed = try FuzzHarness.seedFile(for: target)
        let logical = FuzzHarness.logicalBytes(seed, target: target)
        let headerSpan = Swift.min(logical.count, FuzzHarness.headerSpan(for: target, logical: logical) + 8)
        var lengths = Set(0...Swift.min(64, headerSpan))
        lengths.formUnion(stride(from: 64, through: headerSpan, by: 4))
        lengths.formUnion(stride(from: headerSpan, through: logical.count, by: Swift.max(1, (logical.count - headerSpan) / 24)))
        lengths.formUnion([logical.count, logical.count - 1, logical.count - 2, logical.count - 7, logical.count - 8].filter { $0 >= 0 })
        let harness = try FuzzHarness(target: target)
        for length in lengths.sorted() {
            harness.exercise(logical: Data(logical.prefix(length)), label: "truncate@\(length)")
        }
        harness.finish("truncation")
    }

    /// Random single- and few-byte flips, ~80% of them inside the header.
    @Test(arguments: allTargets)
    func seededByteFlips(_ target: Target) throws {
        let seed = try FuzzHarness.seedFile(for: target)
        let logical = [UInt8](FuzzHarness.logicalBytes(seed, target: target))
        let headerSpan = Swift.max(1, Swift.min(logical.count, FuzzHarness.headerSpan(for: target, logical: Data(logical))))
        let harness = try FuzzHarness(target: target)
        let iterations = 100
        for i in 0..<iterations {
            var rng = SplitMix64(seed: 0xA076_1D64_78BD_642F &* UInt64(i + 1) &+ UInt64(target.testDescription.utf8.count))
            var bytes = logical
            let flips = i < 40 ? 1 : Int(rng.next() % 6) + 1
            for _ in 0..<flips {
                let span = (rng.next() % 5) == 0 ? bytes.count : headerSpan
                let index = Int(rng.next() % UInt64(span))
                // Single flipped bit for the first sweep, arbitrary byte afterwards.
                bytes[index] = i < 40 ? bytes[index] ^ UInt8(1 << (rng.next() % 8)) : UInt8(truncatingIfNeeded: rng.next())
            }
            harness.exercise(logical: Data(bytes), label: "flip#\(i)")
        }
        harness.finish("flips")
    }

    /// Each binary header field driven to its interesting extremes (0, -1, max,
    /// min, NaN, ±Inf, huge offsets, bogus datatype codes), one at a time, then
    /// seeded pairs of them.
    @Test(arguments: binaryTargets)
    func headerFieldExtremes(_ target: Target) throws {
        let seed = try FuzzHarness.seedFile(for: target)
        let logical = [UInt8](FuzzHarness.logicalBytes(seed, target: target))
        let fields = BinaryField.fields(for: target.format)
        let harness = try FuzzHarness(target: target)

        var singles: [(field: BinaryField, value: [UInt8], name: String)] = []
        for field in fields {
            for (name, value) in field.extremeEncodings() {
                singles.append((field, value, name))
            }
        }
        for entry in singles {
            var bytes = logical
            entry.field.write(entry.value, into: &bytes)
            harness.exercise(logical: Data(bytes), label: "\(entry.field.name)=\(entry.name)")
        }

        var rng = SplitMix64(seed: 0x5851_F42D_4C95_7F2D &+ UInt64(target.format.rawValue.utf8.count))
        for i in 0..<60 {
            var bytes = logical
            let a = singles[Int(rng.next() % UInt64(singles.count))]
            let b = singles[Int(rng.next() % UInt64(singles.count))]
            a.field.write(a.value, into: &bytes)
            b.field.write(b.value, into: &bytes)
            harness.exercise(logical: Data(bytes), label: "pair#\(i) \(a.field.name)=\(a.name),\(b.field.name)=\(b.name)")
        }
        harness.finish("fields")
    }

    /// MIF / NRRD text headers: each key dropped, each value replaced with garbage
    /// (non-numbers, overflowing integers, NaN, empty lists, negative sizes), very
    /// long lines, duplicate keys, missing terminators, stray NUL / invalid UTF-8.
    @Test(arguments: textTargets)
    func malformedTextHeaders(_ target: Target) throws {
        let harness = try FuzzHarness(target: target)
        var count = 0
        for variant in TextHeaderFuzz.variants(for: target) {
            harness.exercise(logical: variant.bytes, label: variant.label)
            count += 1
        }
        #expect(count > 100)
        harness.finish("text")
    }

    /// Mutations applied to the *compressed* bytes: truncated streams, flipped
    /// deflate bits, a lying ISIZE trailer, a damaged gzip magic.
    @Test(arguments: gzipTargets)
    func compressedStreamMutations(_ target: Target) throws {
        let seed = try FuzzHarness.seedFile(for: target)
        let onDisk = [UInt8](seed)
        // Where the gzip member starts within the on-disk bytes (NRRD: after the header).
        let gzStart = target.wrapsWholeFileInGzip ? 0 : FuzzHarness.nrrdPayloadStart(seed)
        let harness = try FuzzHarness(target: target)

        var lengths = Set(stride(from: gzStart, through: onDisk.count, by: Swift.max(1, (onDisk.count - gzStart) / 24)))
        lengths.formUnion((0..<12).map { onDisk.count - $0 }.filter { $0 >= gzStart })
        lengths.formUnion((gzStart..<Swift.min(onDisk.count, gzStart + 12)))
        for length in lengths.sorted() {
            harness.exercise(onDisk: Data(onDisk.prefix(length)), label: "gz-truncate@\(length)")
        }

        for i in 0..<48 {
            var rng = SplitMix64(seed: 0xE703_7ED1_A0B4_28DB &* UInt64(i + 1))
            var bytes = onDisk
            for _ in 0..<(Int(rng.next() % 3) + 1) {
                let index = gzStart + Int(rng.next() % UInt64(bytes.count - gzStart))
                bytes[index] ^= UInt8(1 << (rng.next() % 8))
            }
            harness.exercise(onDisk: Data(bytes), label: "gz-flip#\(i)")
        }

        for isize: UInt32 in [0, 1, 0x7FFF_FFFF, 0xFFFF_FFFF] {
            var bytes = onDisk
            let at = bytes.count - 4
            for k in 0..<4 { bytes[at + k] = UInt8(truncatingIfNeeded: isize >> (8 * UInt32(k))) }
            harness.exercise(onDisk: Data(bytes), label: "gz-isize=\(isize)")
        }

        var badMagic = onDisk
        badMagic[gzStart] = 0x00
        harness.exercise(onDisk: Data(badMagic), label: "gz-badmagic")
        harness.finish("gzip")
    }
}

// MARK: - Harness

/// Writes a candidate to a scratch file, parses it through `MIQParser.parse(url:)`
/// (both cold-load and full-decompress paths for `.nii.gz`), and on success checks
/// the image's invariants and renders it every way the preview can.
struct FuzzHarness {
    let target: ParserFuzzTests.Target
    let url: URL
    let stats = Stats()

    /// Outcome counts, so each test can assert its mutations reached both sides
    /// of the parser (a corpus that is rejected wholesale fuzzes nothing).
    final class Stats {
        var parsed = 0
        var rejected = 0
        var total: Int { parsed + rejected }
    }

    /// Upper bound on any parsed buffer: DEFLATE expands at most ~1032:1 and MIF
    /// `bit` unpacks 8:1, so a buffer past this was invented, not decoded.
    static func storageBound(forInputCount count: Int) -> Int {
        Swift.max(count, 1) * 1100 + (1 << 20)
    }

    init(target: ParserFuzzTests.Target) throws {
        self.target = target
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("case.\(target.fileExtension)")
    }

    /// Ends a test: both outcomes must have been reached (a corpus the parser
    /// rejects wholesale, or accepts wholesale, is not probing the boundary), and
    /// the scratch directory is removed. `MIQ_FUZZ_STATS=1` prints the counts.
    func finish(_ test: String, expectBothOutcomes: Bool = true) {
        if expectBothOutcomes {
            #expect(stats.parsed > 0, "\(test) \(target.testDescription): no mutation parsed")
            #expect(stats.rejected > 0, "\(test) \(target.testDescription): no mutation was rejected")
        }
        if ProcessInfo.processInfo.environment["MIQ_FUZZ_STATS"] != nil {
            print("fuzz-stats \(test) \(target.testDescription): \(stats.total) parses (\(stats.parsed) ok, \(stats.rejected) rejected)")
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Mutated logical (uncompressed) bytes; re-gzipped when the target is gzip'd.
    func exercise(logical: Data, label: String) {
        let onDisk: Data
        if target.wrapsWholeFileInGzip {
            // An empty input has no gzip encoding; an empty file still has to fail cleanly.
            onDisk = logical.isEmpty ? Data() : ((try? TestZlib.gzip(logical)) ?? Data())
        } else {
            onDisk = logical
        }
        exercise(onDisk: onDisk, label: label)
    }

    func exercise(onDisk: Data, label: String) {
        do {
            try onDisk.write(to: url, options: .atomic)
        } catch {
            Issue.record("\(target.testDescription) [\(label)]: could not write scratch file: \(error)")
            return
        }
        // `fullyDecompress` only changes anything for `.nii.gz` (it lifts the volume-0 cap).
        let isNiftiGz = target.gzipped && (target.format == .nifti1 || target.format == .nifti2)
        let modes: [Bool] = isNiftiGz ? [false, true] : [false]
        for fullyDecompress in modes {
            do {
                let image = try MIQParser().parse(url: url, fullyDecompress: fullyDecompress)
                stats.parsed += 1
                Self.checkAndRender(image, inputCount: onDisk.count, label: "\(target.testDescription) [\(label)] full=\(fullyDecompress)")
            } catch is MIQError {
                // A domain error is the graceful outcome for a corrupt file.
                stats.rejected += 1
            } catch {
                Issue.record("\(target.testDescription) [\(label)] full=\(fullyDecompress) threw non-MIQError: \(error)")
            }
        }
        // The network-volume path (bounded prefix read + streaming inflate) is gated
        // on `VolumeLocation.isLocal`, so drive it directly for NIfTI.
        if target.format == .nifti1 || target.format == .nifti2 {
            let kind: MIQFileKind = target.gzipped ? .niiGz : .nii
            do {
                if let prefix = try MIQParser().loadBoundedNiftiPrefix(url: url, kind: kind) {
                    let image = try MIQParser().parseNifti(prefix, compressed: target.gzipped)
                    stats.parsed += 1
                    Self.checkAndRender(image, inputCount: onDisk.count, label: "\(target.testDescription) [\(label)] bounded-prefix")
                }
            } catch is MIQError {
                stats.rejected += 1
            } catch {
                Issue.record("\(target.testDescription) [\(label)] bounded-prefix threw non-MIQError: \(error)")
            }
        }
    }

    /// Invariants of any image a parser hands back, then a full render pass.
    static func checkAndRender(_ image: MIQImage, inputCount: Int, label: String) {
        let header = image.header
        #expect(header.dimensions.count >= 4, "\(label): dims \(header.dimensions)")
        #expect(header.dimensions.allSatisfy { $0 >= 1 }, "\(label): dims \(header.dimensions)")
        #expect(image.storage.count <= storageBound(forInputCount: inputCount),
                "\(label): storage \(image.storage.count) B from a \(inputCount) B input")

        // Volume 0 must lie inside the buffer the parser returned. Computed with
        // overflow checks: the point is to catch a header that slipped through.
        let bpv = header.datatype.bytesPerVoxel
        let span: Int?
        if let strides = image.payloadElementStrides, strides.count >= 3 {
            span = lastElementSpan(dims: [header.width, header.height, header.depth], strides: Array(strides.prefix(3)))
        } else {
            span = checkedProduct([header.width, header.height, header.depth])
        }
        guard let elements = span, case let (bytes, false) = elements.multipliedReportingOverflow(by: bpv) else {
            Issue.record("\(label): volume-0 extent overflows Int (dims \(header.dimensions))")
            return
        }
        #expect(bytes <= image.payloadCount, "\(label): volume 0 needs \(bytes) B, payload has \(image.payloadCount) B")
        guard bytes <= image.payloadCount, elements <= 1 << 22 else { return }

        let volume = MIQVolume(image: image)
        _ = MIQMetadata(header: header, orientation: volume.storageOrientationLabel()).asDisplayLines()
        _ = volume.containsAllVolumes
        _ = volume.voxel(x: -1, y: 0, z: 0)
        _ = volume.voxel(x: volume.width - 1, y: volume.height - 1, z: volume.depth - 1, t: volume.volumes - 1)
        let modes: [(ViewOrientation, SegmentationColoring)] = [(.stored, .off), (.neurological, .auto), (.radiological, .random)]
        for (orientation, coloring) in modes {
            do {
                let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: orientation, segmentationColoring: coloring)
                let preview = volume.centerPreview(maxDimension: 64, options: options)
                for (plane, slice) in preview.slices {
                    let channels: Int
                    if case .rgb = slice { channels = 3 } else { channels = 1 }
                    #expect(slice.pixels.count == slice.width * slice.height * channels, "\(label): \(plane) buffer size")
                    _ = volume.displayOrientation(for: plane, options: options)
                }
            }
        }
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98)
        for plane in SlicePlane.allCases {
            _ = volume.slice(plane: plane, index: Int.max, volumeIndex: volume.volumes - 1, maxDimension: 64, options: options)
            _ = volume.slice(plane: plane, index: Int.min, volumeIndex: volume.volumes, maxDimension: 64, options: options)
        }
    }

    private static func checkedProduct(_ values: [Int]) -> Int? {
        var product = 1
        for value in values {
            let (next, overflow) = product.multipliedReportingOverflow(by: value)
            if overflow { return nil }
            product = next
        }
        return product
    }

    /// Element count needed to reach the last voxel of volume 0 through `strides`.
    private static func lastElementSpan(dims: [Int], strides: [Int]) -> Int? {
        var last = 0
        for (dim, stride) in zip(dims, strides) {
            let (term, o1) = (dim - 1).multipliedReportingOverflow(by: Swift.abs(stride))
            let (sum, o2) = last.addingReportingOverflow(term)
            if o1 || o2 { return nil }
            last = sum
        }
        return last + 1
    }

    // MARK: Seeds

    /// A small valid file per target, as it would sit on disk.
    static func seedFile(for target: ParserFuzzTests.Target) throws -> Data {
        let logical: Data
        switch target.format {
        case .nifti1:
            logical = TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .int16, pixdim: [1, 1, 2, 3], volumes: 2)
        case .nifti2:
            logical = TestMIQFactory.makeNii2(width: 6, height: 5, depth: 4, datatype: .float32, pixdim: [1, 1, 2, 3])
        case .mgh:
            logical = TestMIQFactory.makeMghWithDirectionCosines(
                width: 6, height: 5, depth: 4, frames: 2, datatype: .int16,
                xr: -1, xa: 0, xs: 0, yr: 0, ya: 0, ys: -1, zr: 0, za: 1, zs: 0
            )
        case .mif:
            logical = TextHeaderFuzz.mif(TextHeaderFuzz.mifSeedFields)
        case .nrrd:
            return TextHeaderFuzz.nrrd(TextHeaderFuzz.nrrdSeedFields(gzip: target.gzipped), gzip: target.gzipped)
        }
        return target.wrapsWholeFileInGzip ? try TestZlib.gzip(logical) : logical
    }

    /// The bytes mutations operate on: the decompressed file for gzip-wrapped
    /// kinds, the file itself otherwise.
    static func logicalBytes(_ seed: Data, target: ParserFuzzTests.Target) -> Data {
        target.wrapsWholeFileInGzip ? ((try? MIQBinaryReader.gunzip(seed)) ?? seed) : seed
    }

    static func headerSpan(for target: ParserFuzzTests.Target, logical: Data) -> Int {
        switch target.format {
        case .nifti1: return 352
        case .nifti2: return 544
        case .mgh: return 284
        case .mif: return logical.range(of: Data("\nEND\n".utf8))?.upperBound ?? 256
        case .nrrd: return nrrdPayloadStart(logical)
        }
    }

    static func nrrdPayloadStart(_ data: Data) -> Int {
        data.range(of: Data("\n\n".utf8)).map { data.distance(from: data.startIndex, to: $0.upperBound) } ?? 0
    }
}

/// Deterministic SplitMix64 — seedable (unlike `SystemRandomNumberGenerator`), so
/// a fuzz failure reproduces exactly.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Binary header fields

/// One fixed-offset binary header field and the extreme values worth writing to it.
struct BinaryField {
    enum Kind { case int16, int32, int64, float32, float64 }

    let name: String
    let offset: Int
    let kind: Kind
    let bigEndian: Bool

    static func fields(for format: ParserFuzzTests.Format) -> [BinaryField] {
        switch format {
        case .nifti1:
            var fields = (0..<8).map { BinaryField(name: "dim[\($0)]", offset: 40 + 2 * $0, kind: .int16, bigEndian: false) }
            fields += [
                BinaryField(name: "datatype", offset: 70, kind: .int16, bigEndian: false),
                BinaryField(name: "bitpix", offset: 72, kind: .int16, bigEndian: false),
            ]
            fields += (0..<4).map { BinaryField(name: "pixdim[\($0)]", offset: 76 + 4 * $0, kind: .float32, bigEndian: false) }
            fields += [
                BinaryField(name: "vox_offset", offset: 108, kind: .float32, bigEndian: false),
                BinaryField(name: "scl_slope", offset: 112, kind: .float32, bigEndian: false),
                BinaryField(name: "scl_inter", offset: 116, kind: .float32, bigEndian: false),
                BinaryField(name: "qform_code", offset: 252, kind: .int16, bigEndian: false),
                BinaryField(name: "sform_code", offset: 254, kind: .int16, bigEndian: false),
                BinaryField(name: "quatern_b", offset: 256, kind: .float32, bigEndian: false),
                BinaryField(name: "quatern_c", offset: 260, kind: .float32, bigEndian: false),
                BinaryField(name: "quatern_d", offset: 264, kind: .float32, bigEndian: false),
                BinaryField(name: "sizeof_hdr", offset: 0, kind: .int32, bigEndian: false),
            ]
            // The diagonal and one translation of the sform rows.
            fields += [0, 3, 5, 10].map { BinaryField(name: "srow[\($0)]", offset: 280 + 4 * $0, kind: .float32, bigEndian: false) }
            return fields
        case .nifti2:
            var fields = (0..<8).map { BinaryField(name: "dim[\($0)]", offset: 16 + 8 * $0, kind: .int64, bigEndian: false) }
            fields += [
                BinaryField(name: "datatype", offset: 12, kind: .int16, bigEndian: false),
                BinaryField(name: "bitpix", offset: 14, kind: .int16, bigEndian: false),
                BinaryField(name: "vox_offset", offset: 168, kind: .int64, bigEndian: false),
                BinaryField(name: "scl_slope", offset: 176, kind: .float64, bigEndian: false),
                BinaryField(name: "scl_inter", offset: 184, kind: .float64, bigEndian: false),
                BinaryField(name: "qform_code", offset: 344, kind: .int32, bigEndian: false),
                BinaryField(name: "sform_code", offset: 348, kind: .int32, bigEndian: false),
                BinaryField(name: "quatern_b", offset: 352, kind: .float64, bigEndian: false),
                BinaryField(name: "sizeof_hdr", offset: 0, kind: .int32, bigEndian: false),
            ]
            fields += (0..<4).map { BinaryField(name: "pixdim[\($0)]", offset: 104 + 8 * $0, kind: .float64, bigEndian: false) }
            fields += [0, 3, 5, 10].map { BinaryField(name: "srow[\($0)]", offset: 400 + 8 * $0, kind: .float64, bigEndian: false) }
            return fields
        case .mgh:
            var fields = [
                BinaryField(name: "version", offset: 0, kind: .int32, bigEndian: true),
                BinaryField(name: "width", offset: 4, kind: .int32, bigEndian: true),
                BinaryField(name: "height", offset: 8, kind: .int32, bigEndian: true),
                BinaryField(name: "depth", offset: 12, kind: .int32, bigEndian: true),
                BinaryField(name: "frames", offset: 16, kind: .int32, bigEndian: true),
                BinaryField(name: "type", offset: 20, kind: .int32, bigEndian: true),
                BinaryField(name: "goodRAS", offset: 28, kind: .int16, bigEndian: true),
            ]
            fields += (0..<3).map { BinaryField(name: "spacing[\($0)]", offset: 30 + 4 * $0, kind: .float32, bigEndian: true) }
            fields += [0, 1, 4, 8].map { BinaryField(name: "cosine[\($0)]", offset: 42 + 4 * $0, kind: .float32, bigEndian: true) }
            return fields
        case .mif, .nrrd:
            return []
        }
    }

    func extremeEncodings() -> [(String, [UInt8])] {
        switch kind {
        case .int16:
            let values: [Int16] = [0, -1, 1, 2, 4, 7, 8, 16, 128, 2304, 99, Int16.max, Int16.min]
            return values.map { ("\($0)", encode(UInt64(UInt16(bitPattern: $0)), bytes: 2)) }
        case .int32:
            let values: [Int32] = [0, -1, 1, 2, 3, 4, 5, 348, 540, 4096, Int32.max, Int32.min, 0x0100_0000]
            return values.map { ("\($0)", encode(UInt64(UInt32(bitPattern: $0)), bytes: 4)) }
        case .int64:
            let values: [Int64] = [0, -1, 1, 7, 8, 544, 1 << 31, Int64(Int32.max), 1 << 40, 1 << 62, Int64.max, Int64.min]
            return values.map { ("\($0)", encode(UInt64(bitPattern: $0), bytes: 8)) }
        case .float32:
            let values: [Float] = [0, -0.0, -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                                   .leastNonzeroMagnitude, 1e20, 351, 9.3e18, 1e6]
            return values.map { ("\($0)", encode(UInt64($0.bitPattern), bytes: 4)) }
        case .float64:
            let values: [Double] = [0, -1, 1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude, 1e300, 3.5e38, .leastNonzeroMagnitude]
            return values.map { ("\($0)", encode($0.bitPattern, bytes: 8)) }
        }
    }

    private func encode(_ bits: UInt64, bytes count: Int) -> [UInt8] {
        let little = (0..<count).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
        return bigEndian ? little.reversed() : little
    }

    func write(_ value: [UInt8], into bytes: inout [UInt8]) {
        guard offset + value.count <= bytes.count else { return }
        bytes.replaceSubrange(offset..<(offset + value.count), with: value)
    }
}

// MARK: - Text header fuzzing

enum TextHeaderFuzz {
    typealias Field = (key: String, value: String)

    struct Variant {
        let label: String
        let bytes: Data
    }

    static let mifSeedFields: [Field] = [
        ("dim", "5,4,3"),
        ("vox", "1.5,2,2.5"),
        ("layout", "-0,+2,+1"),
        ("datatype", "Int16LE"),
        ("transform", "1,0,0,0"),
        ("transform", "0,1,0,0"),
        ("transform", "0,0,1,0"),
        ("scaling", "0,1"),
        ("file", "."),
    ]

    static func nrrdSeedFields(gzip: Bool) -> [Field] {
        [
            ("type", "short"),
            ("dimension", "3"),
            ("space", "left-posterior-superior"),
            ("sizes", "5 4 3"),
            ("space directions", "(1.5,0,0) (0,2,0) (0,0,2.5)"),
            ("kinds", "domain domain domain"),
            ("endian", "little"),
            ("encoding", gzip ? "gzip" : "raw"),
            ("space origin", "(0,0,0)"),
        ]
    }

    /// 5×4×3 int16 payload, values = element index.
    static let payload: Data = {
        var bytes: [UInt8] = []
        for i in 0..<60 { bytes += [UInt8(i), 0] }
        return Data(bytes)
    }()

    /// MIF with a self-consistent `file: . <offset>` (the offset is fixed-pointed
    /// to the header's own length). A `file` value other than `.` is emitted verbatim.
    static func mif(_ fields: [Field], terminator: String = "\nEND\n", payload: Data = payload) -> Data {
        var offset = 0
        var text = ""
        for _ in 0..<8 {
            let lines = fields.map { field -> String in
                field.key == "file" && field.value == "." ? "file: . \(offset)" : "\(field.key): \(field.value)"
            }
            text = (["mrtrix image"] + lines).joined(separator: "\n") + terminator
            if text.utf8.count == offset { break }
            offset = text.utf8.count
        }
        return Data(text.utf8) + payload
    }

    static func nrrd(_ fields: [Field], gzip: Bool, magic: String = "NRRD0004", separator: String = "\n\n", payload: Data = payload) -> Data {
        let text = ([magic] + fields.map { "\($0.key): \($0.value)" }).joined(separator: "\n") + separator
        let body = gzip ? ((try? TestZlib.gzip(payload)) ?? payload) : payload
        return Data(text.utf8) + body
    }

    static let garbageValues: [String] = [
        "", "abc", "-1", "0", "nan", "-inf", "1e400",
        "9223372036854775807", "-9223372036854775808", "99999999999999999999999",
        ",,,", "1,,2", "(1,2", "none", "1 2 3 4 5 6 7 8 9", "1,1,1,1,1,1,1,1",
        "\u{FFFD}", "+-0", "2147483647,2147483647,2147483647",
        "4294967296 4294967296 4294967296", "(nan,nan,nan) (inf,0,0) (0,0,0)",
    ]

    static func variants(for target: ParserFuzzTests.Target) -> [Variant] {
        let isMif = target.format == .mif
        let gzip = target.gzipped
        let seed = isMif ? mifSeedFields : nrrdSeedFields(gzip: gzip)
        func build(_ fields: [Field]) -> Data { isMif ? mif(fields) : nrrd(fields, gzip: gzip) }

        var out: [Variant] = [Variant(label: "seed", bytes: build(seed))]

        // Each key dropped.
        for index in seed.indices {
            var fields = seed
            fields.remove(at: index)
            out.append(Variant(label: "drop \(seed[index].key)#\(index)", bytes: build(fields)))
        }
        // Each value replaced by each garbage value.
        for index in seed.indices {
            for garbage in garbageValues {
                var fields = seed
                fields[index].value = garbage
                out.append(Variant(label: "\(seed[index].key)#\(index)=\(garbage.debugDescription)", bytes: build(fields)))
            }
        }
        // Structurally interesting rewrites.
        let specific: [(String, String)] = isMif
            ? [("dim", "5,4,3,2"), ("dim", "5,4"), ("dim", "5,4,3,1,1"), ("layout", "+0,+0,+0"), ("layout", "+0,+1,+5"),
               ("layout", "-0,-1,-2"), ("layout", "+3,+4,+5"), ("datatype", "Bit"), ("datatype", "Float64BE"),
               ("datatype", "CFloat32"), ("file", ". 9223372036854775807"), ("file", ". -5"), ("file", ". 1"),
               ("file", "other.dat"), ("file", ". 99999999999999999999"), ("vox", "nan,nan,nan"), ("scaling", "nan,nan"),
               ("transform", "nan,nan,nan,nan")]
            : [("sizes", "5 4 3 1"), ("sizes", "5 4"), ("sizes", "5 4 3 1 1"), ("sizes", "60 1 1"), ("sizes", "1 1 60"),
               ("dimension", "9"), ("space directions", "none (1,0,0) (0,1,0)"), ("space directions", "(1,0,0) (1,0,0) (1,0,0)"),
               ("space directions", "(0,0,0) (0,0,0) (0,0,0)"), ("space directions", "(1,0) (0,1) (0,0)"),
               ("space directions", "none none none"), ("encoding", "bzip2"), ("encoding", "ascii"), ("encoding", "hex"),
               ("encoding", gzip ? "raw" : "gzip"), ("type", "block"), ("type", "double"), ("endian", "big"),
               ("data file", "other.raw"), ("space", "scanner-xyz"), ("space origin", "(nan,inf,-inf)"), ("spacings", "nan 0 -1")]
        for (key, value) in specific {
            var fields = seed
            if let index = fields.firstIndex(where: { $0.key == key }) {
                fields[index].value = value
            } else {
                fields.append((key, value))
            }
            out.append(Variant(label: "set \(key)=\(value)", bytes: build(fields)))
        }
        // Duplicate keys (last wins in both parsers) — duplicated with garbage.
        for index in seed.indices {
            var fields = seed
            fields.insert((seed[index].key, "garbage"), at: index + 1)
            out.append(Variant(label: "dup \(seed[index].key)", bytes: build(fields)))
        }
        // Very long lines: as a value, as a key, as a comment.
        let long = String(repeating: "9", count: 200_000)
        for (label, field) in [("long-value", ("dim", long)), ("long-key", (long, "1")), ("long-list", ("vox", Array(repeating: "1", count: 50_000).joined(separator: ",")))] {
            var fields = seed
            if let index = fields.firstIndex(where: { $0.key == field.0 }) {
                fields[index].value = field.1
            } else {
                fields.append(field)
            }
            out.append(Variant(label: label, bytes: build(fields)))
        }
        out.append(Variant(label: "long-comment", bytes: build([("# " + long, "x")] + seed)))
        // Terminators, magic, encoding of the text itself.
        if isMif {
            out.append(Variant(label: "no END", bytes: mif(seed, terminator: "\n")))
            out.append(Variant(label: "END no newline", bytes: mif(seed, terminator: "\nEND")))
            out.append(Variant(label: "CRLF END", bytes: mif(seed, terminator: "\r\nEND\r\n")))
            out.append(Variant(label: "no payload", bytes: mif(seed, payload: Data())))
            out.append(Variant(label: "bad magic", bytes: Data("mrtrix imagex\n".utf8) + mif(seed).dropFirst(13)))
        } else {
            out.append(Variant(label: "no blank line", bytes: nrrd(seed, gzip: gzip, separator: "\n")))
            out.append(Variant(label: "CRLF blank line", bytes: nrrd(seed, gzip: gzip, separator: "\r\n\r\n")))
            out.append(Variant(label: "bad magic", bytes: nrrd(seed, gzip: gzip, magic: "NRRX0004")))
            out.append(Variant(label: "no payload", bytes: nrrd(seed, gzip: gzip, payload: Data())))
            out.append(Variant(label: "nhdr-like", bytes: nrrd(seed + [("data file", "LIST")], gzip: gzip)))
        }
        let base = [UInt8](build(seed))
        let headerEnd = isMif ? (Data(base).range(of: Data("\nEND".utf8))?.lowerBound ?? 16) : FuzzHarness.nrrdPayloadStart(Data(base))
        for (label, byte) in [("NUL", UInt8(0x00)), ("invalid-utf8", UInt8(0xFF)), ("CR", UInt8(0x0D)), ("colon", UInt8(0x3A))] {
            for position in stride(from: 1, to: headerEnd, by: Swift.max(1, headerEnd / 6)) {
                var bytes = base
                bytes.insert(byte, at: position)
                out.append(Variant(label: "\(label)@\(position)", bytes: Data(bytes)))
            }
        }
        return out
    }
}
