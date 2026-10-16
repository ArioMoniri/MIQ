import Foundation
import Testing
import zlib
@testable import MIQCore

/// Regression tests for the security-review findings: hostile sizes that used to
/// trap (Zarr chunk geometry, opaque dtypes, printf patterns, header-declared
/// payloads), Zarr path traversal, uncapped gzip, sidecar free text and the
/// log-tag salt. Every case must *throw* (or degrade), never trap, because
/// thumbnails and Spotlight parse files the user never opened.
struct SecurityHardeningTests {
    // MARK: - Fixtures

    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miq-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSON(_ object: Any, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func zlibCompress(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let status = data.withUnsafeBytes { raw in
            compress2(&out, &length, raw.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 6)
        }
        precondition(status == Z_OK)
        return Data(out.prefix(Int(length)))
    }

    /// A 1×2×2 uint8 v2 array with one chunk holding 1, 2, 3, 4.
    private static func writeTinyV2Array(_ dir: URL) throws {
        try writeJSON([
            "zarr_format": 2, "shape": [1, 2, 2], "chunks": [1, 2, 2], "dtype": "|u1", "order": "C",
            "compressor": NSNull(), "filters": NSNull(), "fill_value": 0,
        ], dir.appendingPathComponent(".zarray"))
        try write(Data([1, 2, 3, 4]), dir.appendingPathComponent("0.0.0"))
    }

    private static func omeGroup(_ root: URL, datasetPath: String) throws {
        try writeJSON(["zarr_format": 2], root.appendingPathComponent(".zgroup"))
        try writeJSON(["multiscales": [[
            "version": "0.4",
            "axes": [["name": "z", "type": "space"], ["name": "y", "type": "space"], ["name": "x", "type": "space"]],
            "datasets": [["path": datasetPath]],
        ]]], root.appendingPathComponent(".zattrs"))
    }

    // MARK: - M1: Zarr sizes

    @Test func zarrChunkExtentNearIntMaxThrows() throws {
        let root = try Self.makeDirectory().appendingPathComponent("a.zarr", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.writeJSON([
            "zarr_format": 2, "shape": [1, 2, 2], "chunks": [1, 2, Int.max], "dtype": "|u1", "order": "C",
            "compressor": NSNull(), "filters": NSNull(), "fill_value": 0,
        ], root.appendingPathComponent(".zarray"))
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }
    }

    @Test func zarrChunkOverPreviewBudgetThrows() throws {
        let json: [String: Any] = [
            "zarr_format": 2, "shape": [4096, 4096, 4096], "chunks": [4096, 4096, 4096], "dtype": "<u2",
            "compressor": NSNull(), "filters": NSNull(), "fill_value": 0,
        ]
        #expect(throws: MIQError.self) { try ZarrArrayMetadata.v2(json) }
    }

    @Test func zarrHugeOpaqueDtypesThrow() throws {
        #expect(throws: MIQError.self) { try ZarrDataType.v2("|S1099511627776") }
        #expect(throws: MIQError.self) { try ZarrDataType.v2("|V1099511627776") }
        #expect(throws: MIQError.self) { try ZarrDataType.v3("r8796093022208", littleEndian: true) }
        #expect(try ZarrDataType.v2("|S348").elementSize == 348)
        #expect(try ZarrDataType.v3("r2784", littleEndian: true).elementSize == 348)
    }

    @Test func zarrShardWithTooManyInnerChunksThrows() throws {
        let json: [String: Any] = [
            "zarr_format": 3, "node_type": "array", "shape": [1, 1, 4], "data_type": "uint8",
            "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": [1, 1, 1 << 62]]],
            "codecs": [["name": "sharding_indexed", "configuration": ["chunk_shape": [1, 1, 1]]]],
        ]
        #expect(throws: MIQError.self) { try ZarrArrayMetadata.v3(json) }
    }

    @Test func zarrByteArrayLengthOverflowThrows() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = try ZarrArrayMetadata.v2([
            "zarr_format": 2, "shape": [1 << 62], "chunks": [1], "dtype": "|S4",
            "compressor": NSNull(), "filters": NSNull(), "fill_value": NSNull(),
        ])
        let reader = ZarrChunkReader(directory: dir, metadata: metadata, storeRoot: dir)
        #expect(throws: MIQError.self) { try reader.readAllBytes(maxBytes: 1 << 20) }
    }

    @Test func zarrInflateFeedsZlibInWindows() throws {
        let original = Data((0..<10_000).map { UInt8($0 % 7) })
        let compressed = Self.zlibCompress(original)
        #expect(try ZarrChunkReader.inflate(compressed, expectedBytes: original.count, window: 13) == original)
        // A cap smaller than the stream is a deliberate prefix, as before.
        #expect(try ZarrChunkReader.inflate(compressed, expectedBytes: 100, window: 7) == original.prefix(100))
        #expect(throws: MIQError.self) {
            try ZarrChunkReader.inflate(compressed, expectedBytes: ZarrArrayMetadata.maxChunkBytes + 1)
        }
        #expect(throws: MIQError.self) { try ZarrChunkReader.inflate(compressed.prefix(20), expectedBytes: original.count, window: 5) }
    }

    // MARK: - M2: Zarr path traversal

    @Test func zarrDatasetPathCannotLeaveTheStore() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.writeTinyV2Array(base.appendingPathComponent("other.zarr/0", isDirectory: true))
        let root = base.appendingPathComponent("victim.zarr", isDirectory: true)
        try Self.omeGroup(root, datasetPath: "../other.zarr/0")
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }

        // Sanity: the same array inside the store previews.
        let good = base.appendingPathComponent("good.zarr", isDirectory: true)
        try Self.omeGroup(good, datasetPath: "0")
        try Self.writeTinyV2Array(good.appendingPathComponent("0", isDirectory: true))
        #expect(try MIQParser().parseZarr(url: good).image.payloadCount == 4)

        #expect(!ZarrStore.isSafeRelativePath(FileManager.default.temporaryDirectory.path))   // absolute
        #expect(!ZarrStore.isSafeRelativePath("a/../../b"))
        #expect(!ZarrStore.isSafeRelativePath(".."))
        #expect(ZarrStore.isSafeRelativePath("0"))
        #expect(ZarrStore.isSafeRelativePath("scale0/image"))
    }

    @Test func zarrLevelSymlinkedOutsideTheStoreIsRejected() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.writeTinyV2Array(base.appendingPathComponent("elsewhere", isDirectory: true))
        let root = base.appendingPathComponent("s.zarr", isDirectory: true)
        try Self.omeGroup(root, datasetPath: "0")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("0"), withDestinationURL: base.appendingPathComponent("elsewhere"))
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }
    }

    @Test func zarrChunkSymlinkedOutsideTheStoreIsRejected() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base.appendingPathComponent("secret.bin")
        try Data([9, 9, 9, 9]).write(to: secret)
        let root = base.appendingPathComponent("s.zarr", isDirectory: true)
        try Self.omeGroup(root, datasetPath: "0")
        let array = root.appendingPathComponent("0", isDirectory: true)
        try Self.writeTinyV2Array(array)
        try FileManager.default.removeItem(at: array.appendingPathComponent("0.0.0"))
        try FileManager.default.createSymbolicLink(at: array.appendingPathComponent("0.0.0"), withDestinationURL: secret)
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }
    }

    // MARK: - Zarr in a DataLad / git-annex dataset

    /// `<base>/ds/.git/annex/objects/Xk/Pq/KEY/KEY` holding `bytes`; returns its URL.
    private static func annexObject(in dataset: URL, bytes: [UInt8]) throws -> URL {
        let object = dataset.appendingPathComponent(".git/annex/objects/Xk/Pq/SHA256E-s4--abc/SHA256E-s4--abc")
        try write(Data(bytes), object)
        return object
    }

    /// Replaces the store's only chunk with a relative symlink to `target`
    /// (`target` relative to the chunk's folder, as git-annex writes it).
    private static func linkChunk(of root: URL, to relativeTarget: String) throws {
        let chunk = root.appendingPathComponent("0/0.0.0")
        try FileManager.default.removeItem(at: chunk)
        try FileManager.default.createSymbolicLink(atPath: chunk.path, withDestinationPath: relativeTarget)
    }

    @Test func zarrChunkInEnclosingAnnexObjectStoreIsRead() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let dataset = base.appendingPathComponent("ds", isDirectory: true)
        _ = try Self.annexObject(in: dataset, bytes: [5, 6, 7, 8])
        let root = dataset.appendingPathComponent("sub/s.zarr", isDirectory: true)
        try Self.omeGroup(root, datasetPath: "0")
        try Self.writeTinyV2Array(root.appendingPathComponent("0", isDirectory: true))
        // ds/sub/s.zarr/0/0.0.0 → ../../../.git/annex/objects/…
        try Self.linkChunk(of: root, to: "../../../.git/annex/objects/Xk/Pq/SHA256E-s4--abc/SHA256E-s4--abc")

        let image = try MIQParser().parseZarr(url: root).image
        let bytes = [UInt8](image.storage[(image.storage.startIndex + image.payloadOffset)...].prefix(4))
        #expect(bytes == [5, 6, 7, 8])
    }

    @Test func zarrChunkOutsideStoreButNotInAnAncestorAnnexIsRejected() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        // An annex of a *sibling* dataset is not the store's own dataset.
        _ = try Self.annexObject(in: base.appendingPathComponent("other", isDirectory: true), bytes: [9, 9, 9, 9])
        // A look-alike path without `.git` is not an annex either.
        try Self.write(Data([9, 9, 9, 9]), base.appendingPathComponent("ds/annex/objects/k/k"))
        let root = base.appendingPathComponent("ds/s.zarr", isDirectory: true)
        try Self.omeGroup(root, datasetPath: "0")
        try Self.writeTinyV2Array(root.appendingPathComponent("0", isDirectory: true))

        try Self.linkChunk(of: root, to: "../../../other/.git/annex/objects/Xk/Pq/SHA256E-s4--abc/SHA256E-s4--abc")
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }
        try Self.linkChunk(of: root, to: "../../annex/objects/k/k")
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root) }
    }

    @Test func zarrContainmentChecksTheUnresolvedPathLexically() throws {
        let base = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let dataset = base.appendingPathComponent("ds", isDirectory: true)
        let object = try Self.annexObject(in: dataset, bytes: [1, 2, 3, 4])
        let store = dataset.appendingPathComponent("s.zarr", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // A metadata path climbing out with `..` straight into the annex is still
        // an escape, even though the annex would be allowed as a symlink target.
        let climbed = store.appendingPathComponent("../.git/annex/objects/Xk/Pq/SHA256E-s4--abc/SHA256E-s4--abc")
        #expect(ZarrStoreContainment.resolvedChunkURL(climbed, storeRoot: store) == nil)
        #expect(ZarrStoreContainment.resolvedChunkURL(object, storeRoot: store) == nil)
        #expect(ZarrStoreContainment.resolvedChunkURL(store, storeRoot: store) == nil)
        try Self.write(Data([0]), store.appendingPathComponent("0/0.0.0"))
        #expect(ZarrStoreContainment.resolvedChunkURL(store.appendingPathComponent("0/0.0.0"), storeRoot: store) != nil)
    }

    // MARK: - L1: printf pattern arithmetic

    @Test func detachedPatternArithmeticNeverTraps() throws {
        let parser = MIQParser()
        // Int.min / -1
        #expect(throws: MIQError.self) { try parser.parseDetachedFilePattern("f%d.raw 0 -9223372036854775808 -1") }
        // Int.max / 1 + 1
        #expect(throws: MIQError.self) { try parser.parseDetachedFilePattern("f%d.raw 0 9223372036854775807 1") }
        // The old trailing `index += step` overflowed after the last name.
        let top = try parser.parseDetachedFilePattern("f%d.raw 9223372036854775806 9223372036854775807 1")
        #expect(top?.names == ["f9223372036854775806.raw", "f9223372036854775807.raw"])
        let bottom = try parser.parseDetachedFilePattern("f%d.raw -9223372036854775807 -9223372036854775808 -1")
        #expect(bottom?.names.count == 2)
        #expect(try parser.parseDetachedFilePattern("s%02d.raw 3 9 3")?.names == ["s03.raw", "s06.raw", "s09.raw"])
    }

    // MARK: - L2: gzip capped at the declared payload

    @Test func attachedNrrdGzipStopsAtDeclaredSize() throws {
        let header = "NRRD0004\ntype: uint8\ndimension: 3\nsizes: 2 2 1\nencoding: gzip\n\n"
        let payload = try TestZlib.gzip(Data(repeating: 7, count: 1 << 20))
        let image = try MIQParser().parseNrrd(Data(header.utf8) + payload)
        #expect(image.payloadCount == 4)
    }

    @Test func detachedNrrdGzipStopsAtSkipPlusFile() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try TestZlib.gzip(Data(repeating: 5, count: 1 << 20)).write(to: dir.appendingPathComponent("d.raw.gz"))
        let nhdr = dir.appendingPathComponent("h.nhdr")
        try Data("NRRD0004\ntype: uint8\ndimension: 3\nsizes: 2 2 1\nencoding: gzip\nbyte skip: 3\ndata file: d.raw.gz\n".utf8).write(to: nhdr)
        let image = try MIQParser().parse(url: nhdr)
        #expect(image.storage.count == 7)
        #expect(MIQVolume(image: image).voxel(x: 1, y: 1, z: 0) == 5)
    }

    // MARK: - L3: header-declared payloads are capped before allocation

    @Test func compressedMetaImageWithHugeDimsThrows() throws {
        let header = "ObjectType = Image\nNDims = 3\nDimSize = 1048576 1048576 1048576\nElementType = MET_UCHAR\nCompressedData = True\nElementDataFile = LOCAL\n"
        let data = Data(header.utf8) + Self.zlibCompress(Data(repeating: 0, count: 64))
        #expect(throws: MIQError.self) { try MIQParser().parseMetaImage(data) }
    }

    @Test func multiFileNrrdWithHugeSizesThrowsBeforeAllocating() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nhdr = dir.appendingPathComponent("h.nhdr")
        try Data("NRRD0004\ntype: uint8\ndimension: 3\nsizes: 1073741824 1073741824 2\nencoding: raw\ndata file: s%d.raw 1 2 1\n".utf8).write(to: nhdr)
        do {
            _ = try MIQParser().parse(url: nhdr)
            Issue.record("expected the oversized payload to be rejected")
        } catch let error as MIQError {
            #expect(error.errorDescription?.contains("limit") == true)
        }
    }

    @Test func multiFileMetaImageWithHugeSizesThrowsBeforeAllocating() throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mhd = dir.appendingPathComponent("h.mhd")
        try Data("ObjectType = Image\nNDims = 3\nDimSize = 1073741824 1073741824 2\nElementType = MET_UCHAR\nElementDataFile = s%d.raw 1 2 1\n".utf8).write(to: mhd)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: mhd) }
    }

    // MARK: - L5: sidecar enumerations

    @Test func sidecarDropsFreeTextInEnumeratedFields() throws {
        func parse(_ pe: String, _ acq: String, _ task: String) throws -> SidecarMetadata? {
            let object = ["PhaseEncodingDirection": pe, "MRAcquisitionType": acq, "TaskName": task]
            return SidecarMetadata.parse(jsonData: try JSONSerialization.data(withJSONObject: object))
        }
        let good = try parse("j-", "3D", "rest2")
        #expect(good?.phaseEncodingDirection == "j-")
        #expect(good?.mrAcquisitionType == "3D")
        #expect(good?.taskName == "rest2")
        #expect(try parse("k", "2D", "nback")?.phaseEncodingDirection == "k")

        let bad = try parse("John Doe", "Patient 12345", "rest of Jane Doe")
        #expect(bad?.phaseEncodingDirection == nil)
        #expect(bad?.mrAcquisitionType == nil)
        #expect(bad?.taskName == nil)
        #expect(try parse("i--", "4D", "task_name")?.phaseEncodingDirection == nil)
        #expect(try parse("x", "3d", "tâche")?.taskName == nil)
    }

    // MARK: - L6: salted log tags

    @Test func logTagSaltIsCreatedOnceAndChangesTheTag() throws {
        let suite = "miq.tests.salt.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        let salt = MIQLogRedaction.salt(in: store)
        #expect(salt.count == 32)
        #expect(MIQLogRedaction.salt(in: store) == salt)   // persisted, reused

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("DOE_JOHN_T1.nii.gz").path
        let salted = MIQLogRedaction.fileTag(path: path, salt: salt)
        #expect(salted.count == 8)
        #expect(salted != MIQLogRedaction.fileTag(path: path, salt: ""))
        #expect(salted == MIQLogRedaction.fileTag(path: path, salt: salt))

        // A malformed stored value is replaced.
        store.set("not-hex", forKey: MIQLogRedaction.saltKey)
        #expect(MIQLogRedaction.salt(in: store) != "not-hex")
    }
}
