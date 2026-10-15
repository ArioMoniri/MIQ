import Foundation
import Testing
@testable import MIQCore

/// "Describe file" without a slice image must not decode the volume: the
/// header-only metadata has to match what the full parse produced before.
@Suite struct CaptionHeaderOnlyTests {
    private typealias Field = CaptionPrompt.CaptionField

    private func fullParseMetadata(_ url: URL) throws -> [String: String] {
        let image = try MIQParser().parse(url: url)
        let volume = MIQVolume(image: image)
        return CaptionPrompt.metadata(
            header: image.header,
            format: image.header.formatLabel ?? MIQFileKind(url: url)?.displayName,
            orientation: volume.storageOrientationLabel()
        )
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionHeaderOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test(arguments: ["nii", "mif", "nrrd", "mgh"])
    func headerOnlyMatchesFullParse(ext: String) throws {
        let data: Data
        switch ext {
        case "nii": data = TestMIQFactory.makeNii(width: 12, height: 10, depth: 8, datatype: .int16, pixdim: [1, 1.5, 1.5, 2])
        case "mif": data = TestMIQFactory.makeMif(width: 12, height: 10, depth: 8, datatype: .float32)
        case "nrrd": data = TestMIQFactory.makeNrrd(width: 12, height: 10, depth: 8, datatype: .uint8)
        default: data = TestMIQFactory.makeMgh(width: 12, height: 10, depth: 8, frames: 1, datatype: .float32)
        }
        let url = try write(data, name: "volume.\(ext)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let headerOnly = try CaptionPrompt.headerOnlyMetadata(url: url)
        #expect(headerOnly == (try fullParseMetadata(url)))
        #expect(headerOnly[Field.dimensions.rawValue] != nil)
    }

    /// A truncated payload breaks a full parse but not the header-only path —
    /// proof that the voxels are not read.
    @Test func doesNotReadThePayload() throws {
        let full = TestMIQFactory.makeNii(width: 64, height: 64, depth: 64, datatype: .float32)
        let url = try write(full.prefix(352 + 16), name: "truncated.nii")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: (any Error).self) { _ = try MIQParser().parse(url: url) }
        let metadata = try CaptionPrompt.headerOnlyMetadata(url: url)
        #expect(metadata[Field.dimensions.rawValue]?.contains("64") == true)
    }

    @Test func unsupportedExtensionThrows() {
        #expect(throws: (any Error).self) {
            _ = try CaptionPrompt.headerOnlyMetadata(url: URL(fileURLWithPath: "/nonexistent/file.txt"))
        }
    }
}
