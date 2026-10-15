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
}
