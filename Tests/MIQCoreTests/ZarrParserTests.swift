import Foundation
import Testing
import zlib
@testable import MIQCore

/// Builds tiny Zarr directory stores on disk, in-test, and previews them.
struct ZarrParserTests {
    // MARK: - Fixture helpers

    /// A fresh `<tmp>/<uuid>/<name>` store directory.
    private static func makeStore(_ name: String = "test.ome.zarr") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("miq-zarr-\(UUID().uuidString)")
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeJSON(_ object: Any, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Serialises one full-size chunk. `storedOrder[i]` is the array axis stored
    /// at position `i` (nil = C order); out-of-bounds elements are zero padding.
    private static func chunkBytes(
        shape: [Int], chunk: [Int], grid: [Int], storedOrder: [Int]? = nil,
        element: ([Int]) -> [UInt8], elementSize: Int
    ) -> Data {
        let order = storedOrder ?? Array(shape.indices)
        let storedShape = order.map { chunk[$0] }
        let total = chunk.reduce(1, *)
        var out = Data()
        out.reserveCapacity(total * elementSize)
        var local = [Int](repeating: 0, count: shape.count) // in stored order
        for _ in 0..<total {
            var coords = [Int](repeating: 0, count: shape.count)
            for (i, axis) in order.enumerated() { coords[axis] = grid[axis] * chunk[axis] + local[i] }
            if zip(coords, shape).allSatisfy({ $0 < $1 }) {
                out.append(contentsOf: element(coords))
            } else {
                out.append(contentsOf: [UInt8](repeating: 0, count: elementSize))
            }
            var d = storedShape.count - 1
            while d >= 0 {
                local[d] += 1
                if local[d] < storedShape[d] { break }
                local[d] = 0
                d -= 1
            }
        }
        return out
    }

    private static func allGrids(shape: [Int], chunk: [Int]) -> [[Int]] {
        var grids: [[Int]] = [[]]
        for (n, c) in zip(shape, chunk) {
            let count = (n + c - 1) / c
            grids = grids.flatMap { prefix in (0..<count).map { prefix + [$0] } }
        }
        return grids
    }

    private static func u16(_ v: Int, bigEndian: Bool = false) -> [UInt8] {
        let x = UInt16(v)
        return bigEndian ? [UInt8(x >> 8), UInt8(x & 0xFF)] : [UInt8(x & 0xFF), UInt8(x >> 8)]
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

    private static func value16(_ image: MIQImage, x: Int, y: Int, z: Int) -> Int {
        let index = image.voxelElementIndex(x: x, y: y, z: z, t: 0) * 2
        return Int(image.byte(atPayloadOffset: index)) | Int(image.byte(atPayloadOffset: index + 1)) << 8
    }

    private static func float32(_ image: MIQImage, x: Int, y: Int, z: Int) -> Float {
        let index = image.voxelElementIndex(x: x, y: y, z: z, t: 0) * 4
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(image.byte(atPayloadOffset: index + i)) << (8 * UInt32(i)) }
        return Float(bitPattern: bits)
    }

    private static func ome04Group(_ root: URL, axes: [[String: Any]], datasets: [[String: Any]]) throws {
        try writeJSON(["zarr_format": 2], root.appendingPathComponent(".zgroup"))
        try writeJSON(["multiscales": [["version": "0.4", "axes": axes, "datasets": datasets]]], root.appendingPathComponent(".zattrs"))
    }

    private static var zyxMicrometer: [[String: Any]] { [
        ["name": "z", "type": "space", "unit": "micrometer"],
        ["name": "y", "type": "space", "unit": "micrometer"],
        ["name": "x", "type": "space", "unit": "micrometer"],
    ] }

    private static func scaleTransform(_ scale: [Double]) -> [[String: Any]] {
        [["type": "scale", "scale": scale]]
    }

    /// Writes a v2 array with every chunk present, values from `element`.
    private static func writeV2Array(
        _ dir: URL, shape: [Int], chunks: [Int], dtype: String, order: String = "C",
        compressor: [String: Any]? = nil, separator: String? = nil, fill: Any = 0,
        skip: Set<[Int]> = [], elementSize: Int, element: ([Int]) -> [UInt8],
        encode: (Data) throws -> Data = { $0 }
    ) throws {
        var meta: [String: Any] = [
            "zarr_format": 2, "shape": shape, "chunks": chunks, "dtype": dtype,
            "order": order, "compressor": compressor ?? NSNull(), "filters": NSNull(), "fill_value": fill,
        ]
        if let separator { meta["dimension_separator"] = separator }
        try writeJSON(meta, dir.appendingPathComponent(".zarray"))
        for grid in allGrids(shape: shape, chunk: chunks) where !skip.contains(grid) {
            let stored = order == "F" ? Array(shape.indices.reversed()) : nil
            let raw = chunkBytes(shape: shape, chunk: chunks, grid: grid, storedOrder: stored, element: element, elementSize: elementSize)
            let key = grid.map(String.init).joined(separator: separator ?? ".")
            try write(try encode(raw), dir.appendingPathComponent(key))
        }
    }

    private static func pattern(_ c: [Int]) -> Int { c[c.count - 3] * 100 + c[c.count - 2] * 10 + c[c.count - 1] }

    // MARK: - Tests

    @Test func detectsZarrStoresByDirectorySuffix() {
        for name in ["a.zarr", "a.ome.zarr", "brain.nii.zarr", "B.OME.ZARR"] {
            #expect(MIQFileKind(url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)) == .zarr)
        }
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/tmp/a.zarr/", isDirectory: true)) == .zarr)
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/tmp/a.nii")) == .nii)
        #expect(MIQFileKind.zarr.supportsBoundedNetworkRead)
    }

    @Test func v2UncompressedWithPartialEdgeChunks() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer,
                            datasets: [["path": "0", "coordinateTransformations": Self.scaleTransform([2, 0.5, 0.25])]])
        let shape = [3, 5, 4]
        try Self.writeV2Array(root.appendingPathComponent("0"), shape: shape, chunks: [2, 2, 3], dtype: "<u2",
                              elementSize: 2) { Self.u16(Self.pattern($0)) }

        // End-to-end through the generic entry point.
        let image = try MIQParser().parse(url: root)
        #expect(image.header.dimensions == [4, 5, 3, 1])
        #expect(image.header.datatype == .uint16)
        #expect(image.header.formatLabel == "OME-Zarr 0.4")
        #expect(image.header.orientationFrame == nil)
        #expect(abs(image.header.pixdim[1] - 0.00025) < 1e-9)
        #expect(abs(image.header.pixdim[2] - 0.0005) < 1e-9)
        #expect(abs(image.header.pixdim[3] - 0.002) < 1e-9)
        for z in 0..<3 { for y in 0..<5 { for x in 0..<4 {
            #expect(Self.value16(image, x: x, y: y, z: z) == z * 100 + y * 10 + x)
        } } }
    }

    @Test func v2GzipSlashSeparatorBigEndianFortranOrder() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer, datasets: [["path": "s0"]])
        let shape = [2, 3, 5]
        let dir = root.appendingPathComponent("s0")
        try Self.writeV2Array(dir, shape: shape, chunks: [1, 2, 2], dtype: ">i2", order: "F",
                              compressor: ["id": "gzip", "level": 1], separator: "/",
                              elementSize: 2, element: { Self.u16(Self.pattern($0), bigEndian: true) },
                              encode: { try TestZlib.gzip($0) })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1/1/2").path))

        let result = try MIQParser().parseZarr(url: root)
        #expect(result.image.header.dimensions == [5, 3, 2, 1])
        #expect(result.image.header.datatype == .int16)
        #expect(result.image.header.littleEndian)
        for z in 0..<2 { for y in 0..<3 { for x in 0..<5 {
            #expect(Self.value16(result.image, x: x, y: y, z: z) == z * 100 + y * 10 + x)
        } } }
    }

    @Test func v2ZlibCompressor() throws {
        let root = try Self.makeStore("plain.zarr")
        // A bare root array (no OME metadata): trailing dims are spatial.
        try Self.writeV2Array(root, shape: [2, 2, 3], chunks: [2, 2, 3], dtype: "<u2",
                              compressor: ["id": "zlib", "level": 6], elementSize: 2,
                              element: { Self.u16(Self.pattern($0)) }, encode: { Self.zlibCompress($0) })
        let result = try MIQParser().parseZarr(url: root)
        #expect(result.summary.flavor == .plainZarr)
        #expect(result.image.header.formatLabel == "Zarr v2")
        #expect(Self.value16(result.image, x: 2, y: 1, z: 1) == 112)
    }

    @Test func v3BytesGzipPicksFirstTimeAndChannel() throws {
        let root = try Self.makeStore()
        let axes: [[String: Any]] = [
            ["name": "t", "type": "time", "unit": "second"],
            ["name": "c", "type": "channel"],
            ["name": "z", "type": "space", "unit": "millimeter"],
            ["name": "y", "type": "space", "unit": "millimeter"],
            ["name": "x", "type": "space", "unit": "millimeter"],
        ]
        try Self.writeJSON([
            "zarr_format": 3, "node_type": "group",
            "attributes": ["ome": ["version": "0.5", "multiscales": [[
                "axes": axes,
                "datasets": [["path": "0", "coordinateTransformations": Self.scaleTransform([1, 1, 3, 2, 1])]],
            ]]]],
        ], root.appendingPathComponent("zarr.json"))
        let shape = [2, 2, 2, 3, 4]
        let chunks = [1, 1, 2, 2, 2]
        let dir = root.appendingPathComponent("0")
        try Self.writeJSON([
            "zarr_format": 3, "node_type": "array", "shape": shape, "data_type": "uint16",
            "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": chunks]],
            "chunk_key_encoding": ["name": "default", "configuration": ["separator": "/"]],
            "fill_value": 0,
            "codecs": [["name": "bytes", "configuration": ["endian": "big"]], ["name": "gzip", "configuration": ["level": 1]]],
            "dimension_names": ["t", "c", "z", "y", "x"],
        ], dir.appendingPathComponent("zarr.json"))
        for grid in Self.allGrids(shape: shape, chunk: chunks) {
            let raw = Self.chunkBytes(shape: shape, chunk: chunks, grid: grid, element: { c in
                Self.u16(c[0] * 4000 + c[1] * 2000 + Self.pattern(c), bigEndian: true)
            }, elementSize: 2)
            try Self.write(try TestZlib.gzip(raw), dir.appendingPathComponent((["c"] + grid.map(String.init)).joined(separator: "/")))
        }

        let result = try MIQParser().parseZarr(url: root)
        #expect(result.summary.zarrFormat == 3)
        #expect(result.summary.omeVersion == "0.5")
        #expect(result.summary.axisNames == ["t", "c", "z", "y", "x"])
        #expect(result.image.header.formatLabel == "OME-Zarr 0.5")
        #expect(result.image.header.dimensions == [4, 3, 2, 1])
        #expect(result.image.header.pixdim == [1, 1, 2, 3])
        for z in 0..<2 { for y in 0..<3 { for x in 0..<4 {
            #expect(Self.value16(result.image, x: x, y: y, z: z) == z * 100 + y * 10 + x)
        } } }
    }

    @Test func multiscaleReadsOnlyCoarsestLevel() throws {
        let root = try Self.makeStore()
        let mmAxes = Self.zyxMicrometer.map { axis -> [String: Any] in
            var a = axis; a["unit"] = "millimeter"; return a
        }
        try Self.ome04Group(root, axes: mmAxes, datasets: [
            ["path": "0", "coordinateTransformations": Self.scaleTransform([1, 1, 1])],
            ["path": "1", "coordinateTransformations": Self.scaleTransform([2, 2, 2])],
        ])
        // Level 0: metadata only, no chunks — reading it would yield fill zeros.
        try Self.writeJSON([
            "zarr_format": 2, "shape": [4, 4, 4], "chunks": [4, 4, 4], "dtype": "|u1",
            "order": "C", "compressor": NSNull(), "filters": NSNull(), "fill_value": 0,
        ], root.appendingPathComponent("0/.zarray"))
        try Self.writeV2Array(root.appendingPathComponent("1"), shape: [2, 2, 2], chunks: [2, 2, 2], dtype: "|u1",
                              elementSize: 1) { [UInt8(Self.pattern($0) + 1)] }

        let result = try MIQParser().parseZarr(url: root)
        #expect(result.summary.levelCount == 2)
        #expect(result.summary.levelIndex == 1)
        #expect(result.summary.levelPath == "1")
        #expect(result.summary.fullResolutionShape == [4, 4, 4])
        #expect(result.image.header.dimensions == [2, 2, 2, 1])
        #expect(result.image.header.pixdim == [1, 2, 2, 2])
        #expect(result.image.header.formatLabel == "OME-Zarr 0.4 (level 2/2)")
        #expect(result.image.byte(atPayloadOffset: result.image.voxelElementIndex(x: 1, y: 1, z: 1, t: 0)) == 112)
    }

    @Test func missingChunksUseFillValue() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer, datasets: [["path": "0"]])
        try Self.writeV2Array(root.appendingPathComponent("0"), shape: [1, 4, 4], chunks: [1, 2, 2], dtype: "<u2",
                              fill: 7, skip: [[0, 1, 1]], elementSize: 2) { Self.u16(Self.pattern($0)) }
        let image = try MIQParser().parseZarr(url: root).image
        #expect(Self.value16(image, x: 1, y: 1, z: 0) == 11)
        #expect(Self.value16(image, x: 2, y: 2, z: 0) == 7)
        #expect(Self.value16(image, x: 3, y: 3, z: 0) == 7)
        #expect(Self.value16(image, x: 3, y: 1, z: 0) == 13)
    }

    @Test func missingFloatChunkUsesNaNFill() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer, datasets: [["path": "0"]])
        try Self.writeV2Array(root.appendingPathComponent("0"), shape: [1, 2, 4], chunks: [1, 2, 2], dtype: "<f4",
                              fill: "NaN", skip: [[0, 0, 1]], elementSize: 4) { c in
            withUnsafeBytes(of: Float(Self.pattern(c)).bitPattern.littleEndian) { Array($0) }
        }
        let image = try MIQParser().parseZarr(url: root).image
        #expect(Self.float32(image, x: 1, y: 1, z: 0) == 11)
        #expect(Self.float32(image, x: 3, y: 0, z: 0).isNaN)
    }

    @Test func bloscIsAClearUnsupportedError() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer, datasets: [["path": "0"]])
        try Self.writeJSON([
            "zarr_format": 2, "shape": [1, 2, 2], "chunks": [1, 2, 2], "dtype": "<u2", "order": "C",
            "compressor": ["id": "blosc", "cname": "lz4", "clevel": 5, "shuffle": 1], "filters": NSNull(), "fill_value": 0,
        ], root.appendingPathComponent("0/.zarray"))
        do {
            _ = try MIQParser().parse(url: root)
            Issue.record("expected an unsupported-compressor error")
        } catch let error as MIQError {
            #expect(error.errorDescription?.contains("Zarr compressor blosc isn't supported yet") == true)
        }
    }

    @Test func oversizedLevelIsRejected() throws {
        let root = try Self.makeStore()
        try Self.ome04Group(root, axes: Self.zyxMicrometer, datasets: [["path": "0"]])
        try Self.writeV2Array(root.appendingPathComponent("0"), shape: [2, 4, 4], chunks: [2, 4, 4], dtype: "<u2",
                              elementSize: 2) { Self.u16(Self.pattern($0)) }
        #expect(throws: MIQError.self) { try MIQParser().parseZarr(url: root, maxBytes: 63) }
        #expect(try MIQParser().parseZarr(url: root, maxBytes: 64).image.payloadCount == 64)
    }

    @Test func v3ShardingWithTransposeAndEmptyInnerChunk() throws {
        let root = try Self.makeStore()
        try Self.writeJSON([
            "zarr_format": 3, "node_type": "group",
            "attributes": ["ome": ["version": "0.5", "multiscales": [[
                "axes": Self.zyxMicrometer, "datasets": [["path": "0", "coordinateTransformations": Self.scaleTransform([1, 1, 1])]],
            ]]]],
        ], root.appendingPathComponent("zarr.json"))
        let shape = [2, 4, 4]
        let shard = [2, 4, 4]
        let inner = [1, 2, 2]
        let dir = root.appendingPathComponent("0")
        try Self.writeJSON([
            "zarr_format": 3, "node_type": "array", "shape": shape, "data_type": "uint16",
            "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": shard]],
            "chunk_key_encoding": ["name": "default"],
            "fill_value": 9,
            "codecs": [[
                "name": "sharding_indexed",
                "configuration": [
                    "chunk_shape": inner,
                    "codecs": [
                        ["name": "transpose", "configuration": ["order": [2, 1, 0]]],
                        ["name": "bytes", "configuration": ["endian": "little"]],
                        ["name": "gzip", "configuration": ["level": 1]],
                    ],
                    "index_codecs": [["name": "bytes", "configuration": ["endian": "little"]], ["name": "crc32c"]],
                    "index_location": "end",
                ],
            ]],
        ], dir.appendingPathComponent("zarr.json"))

        // Build the shard: inner chunks concatenated, then a (offset, nbytes) index + 4-byte CRC.
        var body = Data()
        var index = Data()
        let empty: [Int] = [1, 1, 0]
        for g in Self.allGrids(shape: shard, chunk: inner) {
            func appendU64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { index.append(contentsOf: $0) } }
            if g == empty {
                appendU64(.max); appendU64(.max)
                continue
            }
            let raw = Self.chunkBytes(shape: shape, chunk: inner, grid: g, storedOrder: [2, 1, 0],
                                      element: { Self.u16(Self.pattern($0)) }, elementSize: 2)
            let compressed = try TestZlib.gzip(raw)
            appendU64(UInt64(body.count)); appendU64(UInt64(compressed.count))
            body.append(compressed)
        }
        index.append(contentsOf: [0, 0, 0, 0]) // CRC-32C: stripped, not verified
        try Self.write(body + index, dir.appendingPathComponent("c/0/0/0"))

        let image = try MIQParser().parseZarr(url: root).image
        #expect(image.header.dimensions == [4, 4, 2, 1])
        for z in 0..<2 { for y in 0..<4 { for x in 0..<4 {
            let expected = (z == 1 && y >= 2 && x < 2) ? 9 : z * 100 + y * 10 + x
            #expect(Self.value16(image, x: x, y: y, z: z) == expected)
        } } }
    }

    /// A NIfTI-1 header (LE, uint8, 4×4×4) whose sform maps i→L, j→S, k→A.
    private static func niftiHeader() -> Data {
        var h = Data(count: 348)
        func put<T: FixedWidthInteger>(_ v: T, _ offset: Int) {
            withUnsafeBytes(of: v.littleEndian) { h.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }
        func putF(_ v: Float, _ offset: Int) { put(v.bitPattern, offset) }
        put(Int32(348), 0)
        for (i, d) in [3, 4, 4, 4, 1, 1, 1, 1].enumerated() { put(Int16(d), 40 + 2 * i) }
        put(Int16(2), 70)  // DT_UINT8
        put(Int16(8), 72)  // bitpix
        for (i, p) in [1, 0.5, 0.5, 0.5, 0, 0, 0, 0].enumerated() { putF(Float(p), 76 + 4 * i) }
        putF(352, 108)
        putF(2, 112)       // scl_slope
        putF(10, 116)      // scl_inter
        put(Int16(0), 252) // qform_code
        put(Int16(1), 254) // sform_code
        for (i, v) in [-0.5, 0, 0, 10].enumerated() { putF(Float(v), 280 + 4 * i) }
        for (i, v) in [0, 0, 0.5, 20].enumerated() { putF(Float(v), 296 + 4 * i) }
        for (i, v) in [0, 0.5, 0, 30].enumerated() { putF(Float(v), 312 + 4 * i) }
        h.replaceSubrange(344..<348, with: Array("n+1\0".utf8))
        return h
    }

    @Test func niftiZarrHeaderProvidesOrientationAndScaling() throws {
        let root = try Self.makeStore("brain.nii.zarr")
        try Self.ome04Group(root, axes: Self.zyxMicrometer.map { axis -> [String: Any] in
            var a = axis; a["unit"] = "millimeter"; return a
        }, datasets: [
            ["path": "0", "coordinateTransformations": Self.scaleTransform([0.5, 0.5, 0.5])],
            ["path": "1", "coordinateTransformations": Self.scaleTransform([1, 1, 1]) + [["type": "translation", "translation": [0.25, 0.25, 0.25]]]],
        ])
        try Self.writeJSON([
            "zarr_format": 2, "shape": [4, 4, 4], "chunks": [4, 4, 4], "dtype": "|u1",
            "order": "C", "compressor": NSNull(), "filters": NSNull(), "fill_value": 0,
        ], root.appendingPathComponent("0/.zarray"))
        try Self.writeV2Array(root.appendingPathComponent("1"), shape: [2, 2, 2], chunks: [2, 2, 2], dtype: "|u1",
                              elementSize: 1) { [UInt8(Self.pattern($0))] }
        try Self.writeV2Array(root.appendingPathComponent("nifti"), shape: [348], chunks: [348], dtype: "|u1",
                              compressor: ["id": "zlib", "level": 1], elementSize: 1,
                              element: { [Self.niftiHeader()[$0[0]]] }, encode: { Self.zlibCompress($0) })

        let result = try MIQParser().parseZarr(url: root)
        let header = result.image.header
        #expect(result.summary.flavor == .niftiZarr)
        #expect(header.formatLabel == "NIfTI-Zarr (level 2/2)")
        #expect(header.dimensions == [2, 2, 2, 1])
        #expect(header.pixdim == [1, 1, 1, 1])
        #expect(header.sformCode == 1)
        #expect(header.sclSlope == 2 && header.sclInter == 10)
        let frame = try #require(header.orientationFrame)
        #expect(frame.source == .sform)
        #expect(frame.axes.map(\.axis) == [.rightLeft, .superiorInferior, .anteriorPosterior])
        #expect(frame.axes.map(\.positive) == [false, true, true])
        // Level-1 voxel (0,0,0) sits half a level-0 voxel in: origin moves by col · 0.5.
        #expect(header.srowX == [-1, 0, 0, 9.75])
        #expect(header.srowY == [0, 0, 1, 20.25])
        #expect(header.srowZ == [0, 1, 0, 30.25])
        #expect(result.image.byte(atPayloadOffset: result.image.voxelElementIndex(x: 1, y: 0, z: 1, t: 0)) == 101)
    }
}
