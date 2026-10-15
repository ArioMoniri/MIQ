import Foundation
import Testing
import zlib
@testable import MIQCore

/// Detached-header formats (NRRD `.nhdr`, MRtrix `.mih`, MetaImage `.mhd`) and the
/// attached MetaImage `.mha`: payload resolution next to the header, path-traversal
/// rejection, read errors, byte order, compression and LPS→RAS orientation.
struct DetachedHeaderTests {

    // MARK: - Fixtures

    /// A fresh directory per test; removed by the caller's `defer`.
    private static func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-detached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 4×3×2 uint8 ramp 0…23 (x fastest).
    private static let ramp = Data((0..<24).map { UInt8($0) })

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// zlib-wrapped deflate (what MetaIO writes for `CompressedData = True`).
    private static func zlibCompress(_ data: Data) throws -> Data {
        var destLength = compressBound(uLong(data.count))
        var out = Data(count: Int(destLength))
        let status = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
                compress2(
                    dst.bindMemory(to: Bytef.self).baseAddress, &destLength,
                    src.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_SPEED
                )
            }
        }
        guard status == Z_OK else { throw MIQError.decompressionFailed }
        out.count = Int(destLength)
        return out
    }

    private static func axisCodes(_ image: MIQImage) -> String? {
        image.header.orientationFrame.map { $0.axes.map(\.letter).joined() }
    }

    private static func expectRamp(_ image: MIQImage) {
        let volume = MIQVolume(image: image)
        #expect(volume.width == 4 && volume.height == 3 && volume.depth == 2)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 0)
        #expect(volume.voxel(x: 3, y: 0, z: 0) == 3)
        #expect(volume.voxel(x: 0, y: 1, z: 0) == 4)
        #expect(volume.voxel(x: 3, y: 2, z: 1) == 23)
    }

    private static let nhdrGeometry = """
        NRRD0004
        type: uint8
        dimension: 3
        sizes: 4 3 2
        space: left-posterior-superior
        space directions: (1,0,0) (0,1,0) (0,0,1)
        """

    // MARK: - File kinds

    @Test func recognisesNewKinds() {
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.nhdr")) == .nhdr)
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.MIH")) == .mih)
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.mha")) == .mha)
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.mhd")) == .mhd)
        #expect(MIQFileKind.nhdr.isDetachedHeader && MIQFileKind.mih.isDetachedHeader && MIQFileKind.mhd.isDetachedHeader)
        #expect(!MIQFileKind.mha.isDetachedHeader && !MIQFileKind.nrrd.isDetachedHeader)
        #expect(MIQFileKind.mha.payloadEncodingDecidedByHeader && !MIQFileKind.mih.payloadEncodingDecidedByHeader)
    }

    // MARK: - NRRD .nhdr

    @Test func nhdrWithRawDataFile() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.ramp.write(to: dir.appendingPathComponent("vol.raw"))
        let header = dir.appendingPathComponent("vol.nhdr")
        // No trailing blank line: a detached header may end at EOF.
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: vol.raw\n", to: header)

        let image = try MIQParser().parse(url: header)
        Self.expectRamp(image)
        #expect(image.header.formatLabel == "NRRD (detached)")
        #expect(Self.axisCodes(image) == "LPS")
    }

    @Test func nhdrDatafileSpellingAndByteSkip() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try (Data(repeating: 0xEE, count: 7) + Self.ramp).write(to: dir.appendingPathComponent("vol.raw"))
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\nbyte skip: 7\ndatafile: vol.raw\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))

        // byte skip -1: payload is the file's last bytes.
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\nbyte skip: -1\ndata file: vol.raw\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))
    }

    @Test func nhdrWithGzipDataFileInSubdirectory() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try TestZlib.gzip(Self.ramp).write(to: sub.appendingPathComponent("vol.raw.gz"))
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: gzip\ndata file: ./data/vol.raw.gz\n", to: header)

        let image = try MIQParser().parse(url: header)
        Self.expectRamp(image)
        #expect(image.header.formatLabel == "Compressed NRRD (detached)")
    }

    @Test func nhdrPrintfMultiFile() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two 4×3 slices, slice001.raw and slice002.raw.
        try Self.ramp.prefix(12).write(to: dir.appendingPathComponent("slice001.raw"))
        try Self.ramp.suffix(12).write(to: dir.appendingPathComponent("slice002.raw"))
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: slice%03d.raw 1 2 1 2\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))

        // Same files via LIST (subdim defaults to dimension - 1).
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: LIST\nslice001.raw\nslice002.raw\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))

        // Wrong file count for the sizes.
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: slice%03d.raw 1 1 1\n", to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
    }

    @Test func printfFormatterIsRestricted() throws {
        let parser = MIQParser()
        #expect(try parser.formatDetachedFileName("s%03d.raw", index: 7) == "s007.raw")
        #expect(try parser.formatDetachedFileName("s%d_100%%.raw", index: 12) == "s12_100%.raw")
        #expect(throws: MIQError.self) { try parser.formatDetachedFileName("s%s.raw", index: 1) }
        #expect(throws: MIQError.self) { try parser.formatDetachedFileName("s%d%d.raw", index: 1) }
        #expect(throws: MIQError.self) { try parser.parseDetachedFilePattern("s%d.raw 0 2147483647 1") }
    }

    @Test(arguments: ["../outside.raw", "sub/../../outside.raw", "/etc/passwd"])
    func nhdrRejectsPathTraversal(dataFile: String) throws {
        let parent = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Self.ramp.write(to: parent.appendingPathComponent("outside.raw"))
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: \(dataFile)\n", to: header)

        do {
            _ = try MIQParser().parse(url: header)
            Issue.record("expected traversal rejection for \(dataFile)")
        } catch MIQError.unsupportedFeature(let reason) {
            #expect(reason.contains("outside the header's folder"))
            #expect(!reason.contains("/"), "error must name only the file, not a path: \(reason)")
        }
    }

    @Test func absolutePathInsideHeaderFolderIsAllowed() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("vol.raw")
        try Self.ramp.write(to: raw)
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: \(raw.path)\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))
    }

    @Test func symlinkEscapingHeaderFolderIsRejected() throws {
        let parent = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.ramp.write(to: parent.appendingPathComponent("outside.raw"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.raw"),
            withDestinationURL: parent.appendingPathComponent("outside.raw")
        )
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: link.raw\n", to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
    }

    @Test func missingDataFileIsAClearError() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: sub/missing.raw\n", to: header)
        do {
            _ = try MIQParser().parse(url: header)
            Issue.record("expected a missing-file error")
        } catch MIQError.malformedFile(let reason) {
            #expect(reason.contains("'missing.raw'"))
            #expect(reason.contains("not found"))
        }
    }

    @Test func unreadableDataFileReportsSandboxMessage() throws {
        // A directory where the data file should be: exists, but can't be read as
        // a file — stands in for the Quick Look sandbox denying access.
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("vol.raw"), withIntermediateDirectories: true)
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: vol.raw\n", to: header)
        do {
            _ = try MIQParser().parse(url: header)
            Issue.record("expected a read failure")
        } catch MIQError.unsupportedFeature(let reason) {
            #expect(reason == "Detached data file 'vol.raw' couldn't be read from Quick Look (sandbox). Open the file in MIQ.app or use the attached-header variant")
        }
    }

    @Test func truncatedDataFileIsRejected() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.ramp.prefix(20).write(to: dir.appendingPathComponent("vol.raw"))
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: raw\ndata file: vol.raw\n", to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
    }

    @Test func attachedNrrdWithoutSeparatorStillRejected() throws {
        let parser = MIQParser()
        #expect(throws: MIQError.self) { try parser.parseNrrd(Data((Self.nhdrGeometry + "\nencoding: raw\n").utf8)) }
        // Detached header without a header URL can't resolve its file.
        #expect(throws: MIQError.self) { try parser.parseNrrd(Data((Self.nhdrGeometry + "\ndata file: x.raw\n").utf8)) }
    }

    @Test func nhdrHeaderOnlyProbeNeverOpensDataFile() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = dir.appendingPathComponent("vol.nhdr")
        try Self.write(Self.nhdrGeometry + "\nencoding: gzip\ndata file: absent.raw.gz\n", to: header)
        let probed = try MIQParser().parseHeaderOnly(url: header, maxBytes: MIQParser.headerProbeCap)
        #expect(probed.dimensions == [4, 3, 2, 1])
        let summary = try VolumeSummary.read(contentsOf: header)
        #expect(summary.format == "Compressed NRRD (detached)")
        #expect(summary.orientation == "LPS")
    }

    // MARK: - MRtrix .mih

    @Test func mihWithDataFileAndOffset() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // int16 little-endian ramp at offset 16 of the .dat.
        var payload = Data(repeating: 0xAB, count: 16)
        for v in 0..<24 { payload.append(contentsOf: [UInt8(v), 0]) }
        try payload.write(to: dir.appendingPathComponent("vol.dat"))
        let header = dir.appendingPathComponent("vol.mih")
        try Self.write("""
            mrtrix image
            dim: 4,3,2
            vox: 1,1,1
            layout: +0,+1,+2
            datatype: Int16LE
            file: vol.dat 16
            END

            """, to: header)

        let image = try MIQParser().parse(url: header)
        Self.expectRamp(image)
        #expect(Self.axisCodes(image) == "RAS")
        #expect(try VolumeSummary.read(contentsOf: header).dimensions == [4, 3, 2])

        // A `.mif` must stay single-file.
        let mif = dir.appendingPathComponent("vol.mif")
        try FileManager.default.copyItem(at: header, to: mif)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: mif) }
    }

    @Test func mihRejectsTraversal() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = dir.appendingPathComponent("vol.mih")
        try Self.write("mrtrix image\ndim: 4,3,2\nvox: 1,1,1\nlayout: +0,+1,+2\ndatatype: UInt8\nfile: ../vol.dat 0\nEND\n", to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
    }

    // MARK: - MetaImage

    private static func metaHeader(_ extra: String, dataFile: String) -> String {
        """
        ObjectType = Image
        NDims = 3
        BinaryData = True
        DimSize = 4 3 2
        ElementSpacing = 1.5 1.5 2
        ElementType = MET_UCHAR
        \(extra)
        ElementDataFile = \(dataFile)

        """
    }

    @Test func mhaAttachedRaw() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vol.mha")
        let text = Self.metaHeader("TransformMatrix = 1 0 0 0 1 0 0 0 1\nOffset = 10 20 30\nAnatomicalOrientation = RAI", dataFile: "LOCAL")
        try (Data(text.utf8) + Self.ramp).write(to: url)

        let image = try MIQParser().parse(url: url)
        Self.expectRamp(image)
        #expect(image.header.formatLabel == "MetaImage")
        #expect(image.header.pixdim[1] == 1.5 && image.header.pixdim[3] == 2)
        // Identity in LPS: x points Left, y Posterior, z Superior.
        #expect(Self.axisCodes(image) == "LPS")
        #expect(image.header.orientationFrame?.source == .metaImageTransform)
        #expect(image.header.orientationDiagnostics.transformSource == .metaImage)
        // Origin converted LPS → RAS.
        #expect(image.header.srowX[3] == -10 && image.header.srowY[3] == -20 && image.header.srowZ[3] == 30)
        #expect(image.header.srowX[0] == -1.5)
    }

    @Test func mhaAttachedZlibCompressed() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vol.mha")
        let compressed = try Self.zlibCompress(Self.ramp)
        let text = Self.metaHeader("CompressedData = True\nCompressedDataSize = \(compressed.count)", dataFile: "LOCAL")
        try (Data(text.utf8) + compressed).write(to: url)

        let image = try MIQParser().parse(url: url)
        Self.expectRamp(image)
        #expect(image.header.formatLabel == "Compressed MetaImage")
        // No transform: orientation is unknown, not assumed.
        #expect(image.header.orientationFrame == nil)
        #expect(image.header.orientationDiagnostics.transformSource == .none)

        // Truncated stream.
        try (Data(Self.metaHeader("CompressedData = True", dataFile: "LOCAL").utf8) + compressed.prefix(compressed.count / 2)).write(to: url)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: url) }
    }

    @Test func mhdWithRawFileAndMSBByteOrder() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var payload = Data(repeating: 0, count: 8) // HeaderSize = 8
        for v in 0..<24 { payload.append(contentsOf: [0, UInt8(v)]) } // big-endian int16
        try payload.write(to: dir.appendingPathComponent("vol.raw"))
        let header = dir.appendingPathComponent("vol.mhd")
        try Self.write("""
            ObjectType = Image
            NDims = 3
            DimSize = 4 3 2
            ElementSpacing = 1 1 1
            ElementType = MET_SHORT
            ElementByteOrderMSB = True
            HeaderSize = 8
            TransformMatrix = -1 0 0 0 -1 0 0 0 1
            Offset = 0 0 0
            ElementDataFile = vol.raw

            """, to: header)

        let image = try MIQParser().parse(url: header)
        #expect(image.header.littleEndian == false)
        #expect(image.header.formatLabel == "MetaImage (detached)")
        Self.expectRamp(image)
        // LPS directions (-1,0,0),(0,-1,0),(0,0,1) are RAS-aligned.
        #expect(Self.axisCodes(image) == "RAS")

        let summary = try VolumeSummary.read(contentsOf: header)
        #expect(summary.datatype == "int16")
        #expect(summary.orientation == "RAS")
    }

    @Test func mhdObliqueLPSTransformMapsToRAS() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.ramp.write(to: dir.appendingPathComponent("vol.raw"))
        let header = dir.appendingPathComponent("vol.mhd")
        // Axis 0 points Posterior, axis 1 points Left, axis 2 Inferior (LPS rows).
        try Self.write(Self.metaHeader("TransformMatrix = 0 1 0 1 0 0 0 0 -1", dataFile: "vol.raw"), to: header)
        let image = try MIQParser().parse(url: header)
        #expect(Self.axisCodes(image) == "PLI")
    }

    @Test func mhdDetachedZlibAndListForms() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.zlibCompress(Self.ramp).write(to: dir.appendingPathComponent("vol.zraw"))
        let header = dir.appendingPathComponent("vol.mhd")
        try Self.write(Self.metaHeader("CompressedData = True", dataFile: "vol.zraw"), to: header)
        let image = try MIQParser().parse(url: header)
        Self.expectRamp(image)
        #expect(image.header.formatLabel == "Compressed MetaImage (detached)")

        try Self.ramp.prefix(12).write(to: dir.appendingPathComponent("s0.raw"))
        try Self.ramp.suffix(12).write(to: dir.appendingPathComponent("s1.raw"))
        try Self.write(Self.metaHeader("", dataFile: "LIST 2D") + "s0.raw\ns1.raw\n", to: header)
        Self.expectRamp(try MIQParser().parse(url: header))
        try Self.write(Self.metaHeader("", dataFile: "s%d.raw 0 1 1"), to: header)
        Self.expectRamp(try MIQParser().parse(url: header))
    }

    @Test func mhdRejectsTraversalAndMissingFile() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = dir.appendingPathComponent("vol.mhd")
        try Self.write(Self.metaHeader("", dataFile: "../../vol.raw"), to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
        try Self.write(Self.metaHeader("", dataFile: "nothere.raw"), to: header)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: header) }
    }

    @Test func metaImageChannelsAndTypes() throws {
        let parser = MIQParser()
        let rgbText = Self.metaHeader("ElementNumberOfChannels = 3", dataFile: "LOCAL")
        let rgb = try parser.parseMetaImage(Data(rgbText.utf8) + Data(count: 72))
        #expect(rgb.header.datatype == .rgb24)

        let twoChannels = Self.metaHeader("ElementNumberOfChannels = 2", dataFile: "LOCAL")
        #expect(throws: MIQError.self) { try parser.parseMetaImage(Data(twoChannels.utf8) + Data(count: 48)) }

        let floats = Self.metaHeader("", dataFile: "LOCAL").replacingOccurrences(of: "MET_UCHAR", with: "MET_FLOAT")
        #expect(try parser.parseMetaImage(Data(floats.utf8) + Data(count: 96)).header.datatype == .float32)

        let unknown = Self.metaHeader("", dataFile: "LOCAL").replacingOccurrences(of: "MET_UCHAR", with: "MET_STRING")
        #expect(throws: MIQError.self) { try parser.parseMetaImage(Data(unknown.utf8) + Data(count: 24)) }

        // Detached without a header URL.
        #expect(throws: MIQError.self) { try parser.parseMetaImage(Data(Self.metaHeader("", dataFile: "x.raw").utf8)) }
        // 2D image becomes a single slice.
        let twoD = "NDims = 2\nDimSize = 4 3\nElementType = MET_UCHAR\nElementDataFile = LOCAL\n"
        #expect(try parser.parseMetaImage(Data(twoD.utf8) + Data(count: 12)).header.dimensions == [4, 3, 1, 1])
    }
}
