import Foundation
import Testing
@testable import MIQCore

/// `VolumeSummary` is the header-only description shared by the Spotlight
/// importer, the App Intents and the `miq info` CLI. These tests pin two
/// contracts: it agrees with the full parse for every format, and it never needs
/// the payload (a file whose payload is missing or corrupt still summarises).
struct VolumeSummaryTests {
    private static func write(_ data: Data, suffix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-summary-\(UUID().uuidString)\(suffix)")
        try data.write(to: url)
        return url
    }

    /// Summary built from the full parse's header — the reference the header-only
    /// path must reproduce.
    private static func fullParseSummary(_ url: URL, unit: String?) throws -> VolumeSummary {
        let image = try MIQParser().parse(url: url)
        return VolumeSummary(header: image.header, kind: try #require(MIQFileKind(url: url)), spacingUnit: unit)
    }

    private static func setByte(_ value: UInt8, at offset: Int, in data: Data) -> Data {
        var copy = data
        copy[copy.startIndex + offset] = value
        return copy
    }

    @Test
    func niftiSummaryMatchesFullParse() throws {
        var data = TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .int16, pixdim: [1, 0.5, 0.75, 1.2])
        data = Self.setByte(2, at: 123, in: data) // xyzt_units = mm
        let url = try Self.write(data, suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary == (try Self.fullParseSummary(url, unit: "mm")))
        #expect(summary.format == "NIfTI-1")
        #expect(summary.dimensions == [6, 5, 4])
        #expect(summary.volumes == 1)
        #expect(summary.voxelSpacing == [0.5, 0.75, Double(Float(1.2))])
        #expect(summary.spacingUnit == "mm")
        #expect(summary.datatype == "int16")
    }

    @Test
    func niftiGzSummaryMatchesFullParseIncludingOrientation() throws {
        let raw = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .float32,
            sformCode: 1, srowX: [-1, 0, 0, 0], srowY: [0, 1, 0, 0], srowZ: [0, 0, 1, 0],
            qformCode: 0, quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let url = try Self.write(try TestZlib.gzip(raw), suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary == (try Self.fullParseSummary(url, unit: nil)))
        #expect(summary.format == "Compressed NIfTI-1")
        #expect(summary.orientation == "LAS")
        #expect(summary.orientationSource == "sform")
        #expect(summary.spacingUnit == nil) // xyzt_units 0 = unknown
    }

    @Test
    func nifti2ReadsUnitsFromItsOwnOffset() throws {
        var data = TestMIQFactory.makeNii2(width: 3, height: 3, depth: 3, datatype: .uint8)
        data = Self.setByte(3, at: 500, in: data) // int32 LE xyzt_units = micron
        let url = try Self.write(data, suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary.format == "NIfTI-2")
        #expect(summary.spacingUnit == "\u{00B5}m")
        #expect(summary.dimensions == [3, 3, 3])
    }

    @Test
    func mghMgzMifNrrdSummariesMatchFullParse() throws {
        let mgh = TestMIQFactory.makeMgh(width: 5, height: 4, depth: 3, frames: 2, datatype: .float32)
        let cases: [(Data, String, String?)] = [
            (mgh, ".mgh", "mm"),
            (try TestZlib.gzip(mgh), ".mgz", "mm"),
            (TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint16, layout: [1, 0, 2]), ".mif", "mm"),
            (try TestZlib.gzip(TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8)), ".mif.gz", "mm"),
            (TestMIQFactory.makeNrrd(width: 4, height: 3, depth: 2, datatype: .int16, space: "left-posterior-superior"), ".nrrd", nil),
        ]
        for (data, suffix, unit) in cases {
            let url = try Self.write(data, suffix: suffix)
            defer { try? FileManager.default.removeItem(at: url) }
            let summary = try VolumeSummary.read(contentsOf: url)
            #expect(summary == (try Self.fullParseSummary(url, unit: unit)), "\(suffix)")
        }
    }

    @Test
    func mghReportsVolumesAndFormat() throws {
        let url = try Self.write(TestMIQFactory.makeMgh(width: 5, height: 4, depth: 3, frames: 7, datatype: .uint8), suffix: ".mgh")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary.format == "MGH")
        #expect(summary.volumes == 7)
        #expect(summary.datatype == "uint8")
    }

    // MARK: - Header-only guarantee

    @Test
    func niftiWithMissingPayloadStillSummarises() throws {
        // Header claims a 4D 64³×10 float volume, but the file ends right after the header.
        let full = TestMIQFactory.makeNii(width: 64, height: 64, depth: 64, datatype: .float32, volumes: 10)
        let url = try Self.write(Data(full.prefix(352)), suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) { _ = try MIQParser().parse(url: url) }
        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary.dimensions == [64, 64, 64])
        #expect(summary.volumes == 10)
    }

    @Test
    func niftiGzTruncatedMidPayloadStillSummarises() throws {
        // Incompressible payload so the gzip stream is long; cut it well after the
        // header. The full parse cannot inflate it; the header-only read stops early.
        var full = TestMIQFactory.makeNii(width: 32, height: 32, depth: 32, datatype: .uint8)
        var rng = SystemRandomNumberGenerator()
        for i in 352..<full.count { full[i] = UInt8.random(in: 0...255, using: &rng) }
        let gz = try TestZlib.gzip(full)
        let url = try Self.write(Data(gz.prefix(gz.count / 2)), suffix: ".nii.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) { _ = try MIQParser().parse(url: url, fullyDecompress: true) }
        let summary = try VolumeSummary.read(contentsOf: url)
        #expect(summary.dimensions == [32, 32, 32])
    }

    @Test
    func mifAndNrrdHeadersParseWithoutTheirPayloads() throws {
        let mif = TestMIQFactory.makeMif(width: 8, height: 8, depth: 8, datatype: .float32)
        let mifHeaderEnd = try #require(mif.range(of: Data("\nEND".utf8))).upperBound
        let mifURL = try Self.write(Data(mif.prefix(mifHeaderEnd)), suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: mifURL) }
        #expect(try VolumeSummary.read(contentsOf: mifURL).dimensions == [8, 8, 8])

        // gzip-encoded NRRD with a garbage payload: the header still decides the format label.
        let nrrd = Data("NRRD0004\ntype: short\ndimension: 3\nsizes: 4 5 6\nencoding: gzip\nendian: little\n\n".utf8)
            + Data([0x1F, 0x8B, 0xDE, 0xAD])
        let nrrdURL = try Self.write(nrrd, suffix: ".nrrd")
        defer { try? FileManager.default.removeItem(at: nrrdURL) }
        let summary = try VolumeSummary.read(contentsOf: nrrdURL)
        #expect(summary.format == "Compressed NRRD")
        #expect(summary.dimensions == [4, 5, 6])
        #expect(summary.datatype == "int16")
    }

    @Test
    func rejectsUnsupportedAndMalformedFiles() throws {
        #expect(throws: MIQError.self) {
            _ = try VolumeSummary.read(contentsOf: URL(fileURLWithPath: "/tmp/not-a-volume.txt"))
        }
        let url = try Self.write(Data("mrtrix image\ndim: 2,2,2\n".utf8), suffix: ".mif") // no END
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: MIQError.self) { _ = try VolumeSummary.read(contentsOf: url) }
    }

    // MARK: - Output

    @Test
    func jsonIsSortedAndRoundTrips() throws {
        let summary = VolumeSummary(
            format: "NIfTI-1", dimensions: [2, 3, 4], volumes: 1, voxelSpacing: [1, 1, 2],
            spacingUnit: "mm", datatype: "int16", orientation: "RAS", orientationSource: "sform"
        )
        let data = try summary.jsonData(prettyPrinted: false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"datatype":"int16","dimensions":[2,3,4],"format":"NIfTI-1","orientation":"RAS","orientationSource":"sform","spacingUnit":"mm","volumes":1,"voxelSpacing":[1,1,2]}"#)
        #expect(try JSONDecoder().decode(VolumeSummary.self, from: data) == summary)
    }

    @Test
    func summaryTextListsFieldsAndOmitsUnknownOrientation() {
        let summary = VolumeSummary(
            format: "MGH", dimensions: [2, 3, 4], volumes: 5, voxelSpacing: [1, 1, 2],
            spacingUnit: nil, datatype: "float32", orientation: nil, orientationSource: nil
        )
        #expect(summary.summaryText == """
        Format: MGH
        Dimensions: 2 \u{00D7} 3 \u{00D7} 4
        Voxel spacing: 1.00 \u{00D7} 1.00 \u{00D7} 2.00
        Datatype: float32
        Volumes: 5
        """)
    }

    @Test
    func niftiUnitCodesMapPerSpec() {
        #expect(VolumeSummary.niftiSpatialUnit(code: 0) == nil)
        #expect(VolumeSummary.niftiSpatialUnit(code: 1) == "m")
        #expect(VolumeSummary.niftiSpatialUnit(code: 2 | 8) == "mm") // time bits ignored
        #expect(VolumeSummary.niftiSpatialUnit(code: 3) == "\u{00B5}m")
    }
}
