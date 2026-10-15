import Foundation
import Testing
@testable import MIQCore

/// `MIQColdPreviewGate` (header-only memory gate before the preview's cold
/// parse) and the display text of load failures the preview shows.
struct ColdPreviewGateTests {
    private static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdPreviewGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func tinyMetaImageClaimingHugeVolumeIsRefusedFromHeaderAlone() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge.mha")
        var bytes = Data("""
        ObjectType = Image
        NDims = 3
        DimSize = 4096 4096 4096
        ElementType = MET_DOUBLE
        ElementDataFile = LOCAL

        """.utf8)
        bytes.append(Data(count: 1024))
        try bytes.write(to: url)

        let message = MIQColdPreviewGate.refusalMessage(url: url)
        #expect(message == "Too large to preview in Quick Look (549.8 GB)")
    }

    @Test func normalFileProceeds() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("small.nii")
        try ModalityFixtures.niftiBytes(dims: [3, 4, 4, 4], values: [Float](repeating: 1, count: 64)).write(to: url)
        #expect(MIQColdPreviewGate.refusalMessage(url: url) == nil)
    }

    @Test func completeUncompressedNiftiIsMappedNotCopied() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vol.nii")
        try ModalityFixtures.niftiBytes(dims: [3, 4, 4, 4], values: [Float](repeating: 1, count: 64)).write(to: url)
        // Over a (tiny) budget, but the whole payload is on disk → mmap'd, allowed.
        #expect(MIQColdPreviewGate.refusalMessage(url: url, budgetBytes: 16) == nil)

        // Truncated: the header promises more than the file holds → refused.
        let truncated = dir.appendingPathComponent("short.nii")
        try ModalityFixtures.niftiBytes(dims: [3, 4, 4, 4], values: [Float](repeating: 1, count: 64))
            .prefix(352 + 8).write(to: truncated)
        #expect(MIQColdPreviewGate.refusalMessage(url: truncated, budgetBytes: 16) != nil)
    }

    @Test func unprobeableFilesProceed() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.mha")
        try Data("not a header".utf8).write(to: url)
        #expect(MIQColdPreviewGate.refusalMessage(url: url) == nil)
    }

    /// The preview shows `PreviewStatusText.failureMessage` verbatim: an
    /// unreadable detached data file (the Quick Look sandbox case) must surface
    /// the explanatory text, not a generic "Preview failed: …".
    @Test func unreadableDetachedDataFileShowsSandboxTextNotGenericFailure() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory where the data file should be stands in for a sandbox denial.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("vol.raw"), withIntermediateDirectories: true)
        let header = dir.appendingPathComponent("vol.nhdr")
        try Data("""
        NRRD0004
        type: float
        dimension: 3
        sizes: 2 2 2
        encoding: raw
        endian: little
        data file: vol.raw

        """.utf8).write(to: header)
        // The gate must not pre-empt this with its own message.
        #expect(MIQColdPreviewGate.refusalMessage(url: header) == nil)
        do {
            _ = try MIQParser().parse(url: header)
            Issue.record("expected a read failure")
        } catch {
            let text = PreviewStatusText.failureMessage(for: error)
            #expect(!text.hasPrefix("Preview failed"))
            #expect(text.contains("couldn't be read from Quick Look (sandbox)"))
        }
    }

    // MARK: - Raw single-file kinds are memory-mapped (regression)

    /// MIF header whose `file: . <offset>` points just past itself.
    private static func mifHeader(dims: String, datatype: String = "Float32LE") -> Data {
        var offset = 0
        var header = ""
        while true {
            header = "mrtrix image\ndim: \(dims)\nvox: 2,2,2,3\nlayout: +0,+1,+2,+3\ndatatype: \(datatype)\nfile: . \(offset)\nEND\n"
            if header.utf8.count == offset { break }
            offset = header.utf8.count
        }
        return Data(header.utf8)
    }

    /// Writes `header` and extends the file (sparsely) to `totalBytes`.
    private static func writeSparse(_ header: Data, totalBytes: UInt64, to url: URL) throws {
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: totalBytes)
        try handle.close()
    }

    /// The reported repro: a 4.2 GB float32 4D `dwi.mif` is memory-mapped by the
    /// parser, so the cold gate must not refuse it even though it is over budget.
    @Test func largeCompleteLocalMifIsNotRefused() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dwi.mif")
        let header = Self.mifHeader(dims: "96,96,60,1900")
        let payload = UInt64(96 * 96 * 60 * 1900 * 4)
        #expect(payload > UInt64(MIQColdPreviewGate.budgetBytes))
        try Self.writeSparse(header, totalBytes: UInt64(header.count) + payload, to: url)
        #expect(MIQColdPreviewGate.refusalMessage(url: url) == nil)

        // Truncated: the header promises more than the file holds → refused.
        let short = dir.appendingPathComponent("short.mif")
        try Self.writeSparse(header, totalBytes: payload / 2, to: short)
        #expect(MIQColdPreviewGate.refusalMessage(url: short) != nil)
    }

    /// Every raw single-file kind passes over budget when complete; MIF `bit`
    /// (unpacked in RAM) does not.
    @Test func rawSingleFileKindsAreExemptWhenComplete() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(count: 64 * 4)

        let mif = dir.appendingPathComponent("a.mif")
        try (Self.mifHeader(dims: "4,4,4,1") + payload).write(to: mif)
        #expect(MIQColdPreviewGate.refusalMessage(url: mif, budgetBytes: 16) == nil)

        let bitMif = dir.appendingPathComponent("mask.mif")
        try (Self.mifHeader(dims: "4,4,4,1", datatype: "Bit") + Data(count: 8)).write(to: bitMif)
        #expect(MIQColdPreviewGate.refusalMessage(url: bitMif, budgetBytes: 16) != nil)

        let nrrd = dir.appendingPathComponent("a.nrrd")
        try (Data("NRRD0004\ntype: float\ndimension: 3\nsizes: 4 4 4\nencoding: raw\nendian: little\n\n".utf8) + payload)
            .write(to: nrrd)
        #expect(MIQColdPreviewGate.refusalMessage(url: nrrd, budgetBytes: 16) == nil)

        let mha = dir.appendingPathComponent("a.mha")
        try (Data("ObjectType = Image\nNDims = 3\nDimSize = 4 4 4\nElementType = MET_FLOAT\nElementDataFile = LOCAL\n".utf8) + payload)
            .write(to: mha)
        #expect(MIQColdPreviewGate.refusalMessage(url: mha, budgetBytes: 16) == nil)

        try payload.write(to: dir.appendingPathComponent("vol.raw"))
        let nhdr = dir.appendingPathComponent("a.nhdr")
        try Data("NRRD0004\ntype: float\ndimension: 3\nsizes: 4 4 4\nencoding: raw\nendian: little\ndata file: vol.raw\n".utf8)
            .write(to: nhdr)
        #expect(MIQColdPreviewGate.refusalMessage(url: nhdr, budgetBytes: 16) == nil)

        let mhd = dir.appendingPathComponent("a.mhd")
        try Data("ObjectType = Image\nNDims = 3\nDimSize = 4 4 4\nElementType = MET_FLOAT\nElementDataFile = vol.raw\n".utf8)
            .write(to: mhd)
        #expect(MIQColdPreviewGate.refusalMessage(url: mhd, budgetBytes: 16) == nil)

        let mih = dir.appendingPathComponent("a.mih")
        try Data("mrtrix image\ndim: 4,4,4\nvox: 1,1,1\nlayout: +0,+1,+2\ndatatype: Float32LE\nfile: vol.raw 0\nEND\n".utf8)
            .write(to: mih)
        #expect(MIQColdPreviewGate.refusalMessage(url: mih, budgetBytes: 16) == nil)

        // A detached data file shorter than the header promises gets no pass.
        try Data(count: 16).write(to: dir.appendingPathComponent("short.raw"))
        let shortNhdr = dir.appendingPathComponent("short.nhdr")
        try Data("NRRD0004\ntype: float\ndimension: 3\nsizes: 4 4 4\nencoding: raw\nendian: little\ndata file: short.raw\n".utf8)
            .write(to: shortNhdr)
        #expect(MIQColdPreviewGate.refusalMessage(url: shortNhdr, budgetBytes: 16) != nil)
    }

    /// Kinds that inflate or join files still materialise the payload: gated.
    @Test func inflatingOrJoiningKindsStayGated() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(count: 64 * 4)

        let gzNrrd = dir.appendingPathComponent("gz.nrrd")
        try (Data("NRRD0004\ntype: float\ndimension: 3\nsizes: 4 4 4\nencoding: gzip\nendian: little\n\n".utf8)
            + TestZlib.gzip(payload)).write(to: gzNrrd)
        #expect(MIQColdPreviewGate.refusalMessage(url: gzNrrd, budgetBytes: 16) != nil)

        let zMha = dir.appendingPathComponent("z.mha")
        try (Data("ObjectType = Image\nNDims = 3\nDimSize = 4 4 4\nElementType = MET_FLOAT\nCompressedData = True\nElementDataFile = LOCAL\n".utf8)
            + TestZlib.gzip(payload)).write(to: zMha)
        #expect(MIQColdPreviewGate.refusalMessage(url: zMha, budgetBytes: 16) != nil)

        let mifGz = dir.appendingPathComponent("a.mif.gz")
        try TestZlib.gzip(Self.mifHeader(dims: "4,4,4,1") + payload).write(to: mifGz)
        #expect(MIQColdPreviewGate.refusalMessage(url: mifGz, budgetBytes: 16) != nil)

        for z in 0..<4 { try Data(count: 64).write(to: dir.appendingPathComponent("s\(z).raw")) }
        let multi = dir.appendingPathComponent("multi.nhdr")
        try Data("NRRD0004\ntype: float\ndimension: 3\nsizes: 4 4 4\nencoding: raw\nendian: little\ndata file: s%d.raw 0 3 1\n".utf8)
            .write(to: multi)
        #expect(MIQColdPreviewGate.refusalMessage(url: multi, budgetBytes: 16) != nil)
    }
}
