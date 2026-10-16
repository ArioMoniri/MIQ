import Foundation
import Testing
@testable import MIQCore

/// Header-derived decoded-size estimates, the header-only probe that feeds them,
/// and the decoded-size half of the thumbnail gate.
struct PayloadSizeEstimateTests {
    private static func tempURL(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-size-\(UUID().uuidString)\(suffix)")
    }

    private static func write(_ data: Data, suffix: String) throws -> URL {
        let url = tempURL(suffix: suffix)
        try data.write(to: url)
        return url
    }

    // MARK: - Arithmetic

    @Test func bytesIsDimsProductTimesVoxelSize() {
        #expect(MIQPayloadSizeEstimate.bytes(dimensions: [4, 3, 2, 5], bytesPerVoxel: 4) == 4 * 3 * 2 * 5 * 4)
        // Padding axes (0 or 1) don't change the product.
        #expect(MIQPayloadSizeEstimate.bytes(dimensions: [4, 3, 2, 0], bytesPerVoxel: 2) == 4 * 3 * 2 * 2)
    }

    @Test func bytesOverflowIsNil() {
        #expect(MIQPayloadSizeEstimate.bytes(dimensions: [Int.max, 2], bytesPerVoxel: 1) == nil)
        #expect(MIQPayloadSizeEstimate.bytes(dimensions: [1 << 32, 1 << 32], bytesPerVoxel: 8) == nil)
    }

    @Test func headerEstimatesFullAndVolumeZero() throws {
        let data = TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .float32, volumes: 6)
        let header = try MIQParser().parseNiftiHeader(from: data)
        #expect(header.estimatedPayloadBytes == 4 * 3 * 2 * 6 * 4)
        #expect(header.estimatedVolumeZeroBytes == 4 * 3 * 2 * 4)
        #expect(MIQFileKind.niiGz.estimatedThumbnailDecodeBytes(header: header) == 4 * 3 * 2 * 4)
        #expect(MIQFileKind.mgz.estimatedThumbnailDecodeBytes(header: header) == 4 * 3 * 2 * 6 * 4)
    }

    @Test func fullDecompressionBudget() throws {
        let data = TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .float32, volumes: 6)
        let header = try MIQParser().parseNiftiHeader(from: data)
        let bytes = 4 * 3 * 2 * 6 * 4
        #expect(!header.exceedsFullDecompressionBudget(bytes))
        #expect(header.exceedsFullDecompressionBudget(bytes - 1))
        #expect(!header.exceedsFullDecompressionBudget())
        #expect(MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes == 1_610_612_736)
    }

    @Test func tooLargeMessageFormatsDecimalGigabytes() {
        #expect(MIQPayloadSizeEstimate.gigabytesText(2_400_000_000) == "2.4 GB")
        #expect(MIQPayloadSizeEstimate.tooLargeFor4DMessage(bytes: 4_300_000_000) == "Too large for 4D in Quick Look (4.3 GB)")
    }

    // MARK: - Header-only probe

    @Test func probeReadsEveryFormatsHeader() throws {
        let cases: [(Data, String, Int)] = [
            (TestMIQFactory.makeNii(width: 5, height: 4, depth: 3, datatype: .int16, volumes: 2), ".nii", 5 * 4 * 3 * 2 * 2),
            (try TestZlib.gzip(TestMIQFactory.makeNii(width: 5, height: 4, depth: 3, datatype: .int16, volumes: 2)), ".nii.gz", 5 * 4 * 3 * 2 * 2),
            (TestMIQFactory.makeMgh(width: 5, height: 4, depth: 3, frames: 2, datatype: .float32), ".mgh", 5 * 4 * 3 * 2 * 4),
            (try TestZlib.gzip(TestMIQFactory.makeMgh(width: 5, height: 4, depth: 3, frames: 2, datatype: .float32)), ".mgz", 5 * 4 * 3 * 2 * 4),
            (TestMIQFactory.makeMif(width: 5, height: 4, depth: 3, datatype: .uint16), ".mif", 5 * 4 * 3 * 2),
            (try TestZlib.gzip(TestMIQFactory.makeMif(width: 5, height: 4, depth: 3, datatype: .uint16)), ".mif.gz", 5 * 4 * 3 * 2),
            (TestMIQFactory.makeNrrd(width: 5, height: 4, depth: 3, datatype: .float32), ".nrrd", 5 * 4 * 3 * 4),
        ]
        for (data, suffix, expected) in cases {
            let url = try Self.write(data, suffix: suffix)
            defer { try? FileManager.default.removeItem(at: url) }
            let header = try MIQParser().parseHeaderOnly(url: url, maxBytes: MIQParser.headerProbeCap)
            #expect(header.width == 5, "\(suffix)")
            #expect(header.estimatedPayloadBytes == expected, "\(suffix)")
        }
    }

    /// The probe must not need the payload: a header whose payload is absent (a
    /// truncated download, or simply a file we refuse to inflate) still probes.
    @Test func probeIgnoresMissingPayload() throws {
        let headerOnly = TestMIQFactory.makeMghHeaderOnly(width: 2048, height: 2048, depth: 512, frames: 4, datatype: .float32)
        let url = try Self.write(try TestZlib.gzip(headerOnly), suffix: ".mgz")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try MIQParser().parseHeaderOnly(url: url, maxBytes: MIQParser.headerProbeCap)
        #expect(header.estimatedPayloadBytes == 2048 * 2048 * 512 * 4 * 4)
        // Full parse rejects it; the probe is header-only by design.
        #expect(throws: (any Error).self) { try MIQParser().parse(url: url) }
    }

    @Test func probeRejectsUnsupportedAndMissingFiles() {
        #expect(throws: (any Error).self) { try MIQParser().parseHeaderOnly(url: Self.tempURL(suffix: ".txt"), maxBytes: MIQParser.headerProbeCap) }
        #expect(throws: (any Error).self) { try MIQParser().parseHeaderOnly(url: Self.tempURL(suffix: ".nii"), maxBytes: MIQParser.headerProbeCap) }
    }

    /// One reader, two caps: a text header longer than the small probe cap fails
    /// the probe ("size unknown") but parses with the default (summary) cap, for
    /// plain and gzipped files alike.
    @Test func headerOnlyReadHonoursByteCap() throws {
        let comments = String(repeating: "# padding comment line for a long header\n", count: 2_500) // ~100 KB
        let text = "NRRD0004\ntype: float\ndimension: 3\nsizes: 4 3 2\n\(comments)encoding: raw\ndata file: absent.raw\n"
        #expect(text.utf8.count > MIQParser.headerProbeCap)
        let nhdr = try Self.write(Data(text.utf8), suffix: ".nhdr")
        defer { try? FileManager.default.removeItem(at: nhdr) }
        #expect(throws: (any Error).self) { try MIQParser().parseHeaderOnly(url: nhdr, maxBytes: MIQParser.headerProbeCap) }
        #expect(try MIQParser().parseHeaderOnly(url: nhdr).dimensions.prefix(3) == [4, 3, 2])
        #expect(try VolumeSummary.read(contentsOf: nhdr).dimensions == [4, 3, 2])

        // Uncompressed reads stop exactly at the cap.
        let prefix = try MIQParser().readHeaderPrefix(url: nhdr, kind: .nhdr, maxBytes: 1_000)
        #expect(prefix.count == 1_000)

        let mif = TestMIQFactory.makeMif(width: 5, height: 4, depth: 3, datatype: .uint16)
        var mifText = String(decoding: mif, as: UTF8.self)
        // Splice a long comment block in after the magic line.
        if let firstNewline = mifText.firstIndex(of: "\n") {
            mifText.insert(contentsOf: "\n" + String(repeating: "comments: padding padding padding padding\n", count: 2_500).dropLast(), at: firstNewline)
        }
        let mifGz = try Self.write(try TestZlib.gzip(Data(mifText.utf8)), suffix: ".mif.gz")
        defer { try? FileManager.default.removeItem(at: mifGz) }
        #expect(throws: (any Error).self) { try MIQParser().parseHeaderOnly(url: mifGz, maxBytes: MIQParser.headerProbeCap) }
        #expect(try MIQParser().parseHeaderOnly(url: mifGz).width == 5)
    }

    @Test func headerOnlyReadRejectsDICOM() {
        #expect(throws: MIQError.self) { try MIQParser().parseHeaderOnly(url: Self.tempURL(suffix: ".dcm")) }
    }

    // MARK: - Redaction

    @Test func fileTagIsStableEightHexAndHidesName() {
        let dir = FileManager.default.temporaryDirectory
        let johnPath = dir.appendingPathComponent("DOE_JOHN_T1.nii.gz").path
        let janePath = dir.appendingPathComponent("DOE_JANE_T1.nii.gz").path
        let tag = MIQLogRedaction.fileTag(path: johnPath)
        #expect(tag.count == 8)
        #expect(tag.allSatisfy { $0.isHexDigit })
        #expect(tag == MIQLogRedaction.fileTag(path: johnPath))
        #expect(tag != MIQLogRedaction.fileTag(path: janePath))
        #expect(!tag.contains("DOE"))
        // FNV-1a 32-bit reference vectors.
        #expect(MIQLogRedaction.fileTag(path: "") == "811c9dc5")
        #expect(MIQLogRedaction.fileTag(path: "a") == "e40c292c")
        // A `..`-laden URL tags the same as its standardized path (dir/../dir/a.nii == dir/a.nii).
        let dotted = dir.appendingPathComponent("..").appendingPathComponent(dir.lastPathComponent).appendingPathComponent("a.nii")
        #expect(MIQLogRedaction.fileTag(dotted) == MIQLogRedaction.fileTag(path: dir.appendingPathComponent("a.nii").standardizedFileURL.path))
    }

    // MARK: - Locality probes

    @Test func volumeLocationProbesDontCrash() throws {
        let url = try Self.write(Data([1, 2, 3]), suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }
        // A plain temp file is never a cloud placeholder.
        #expect(!VolumeLocation.isDataless(url))
        _ = VolumeLocation.isLocal(url)
        // A missing file is not dataless (failed probe keeps the normal path).
        #expect(!VolumeLocation.isDataless(Self.tempURL(suffix: ".nii")))
        #expect(VolumeLocation.dataLessFlag == 0x4000_0000)
    }
}
