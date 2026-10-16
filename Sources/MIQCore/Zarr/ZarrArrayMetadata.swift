import Foundation

/// Element type of a Zarr array, normalised to what MIQ can address.
///
/// Zarr v2 spells types as NumPy typestrings (`"<u2"`, `">f4"`, `"|b1"`,
/// `"|S348"`), v3 as names (`"uint16"`, `"float32"`, `"bool"`), with the byte
/// order moved into the `bytes` codec. Decoded chunks are byte-swapped to
/// little-endian before assembly, so `datatype` always describes LE storage.
struct ZarrDataType: Equatable {
    /// `nil` for opaque byte strings (`|S<n>` / `r<bits>`), which are only read
    /// as raw bytes (the NIfTI-Zarr header array) and never as voxels.
    let datatype: MIQDatatype?
    let elementSize: Int
    /// Source byte order. Ignored for one-byte and opaque types.
    let littleEndian: Bool
    /// Label for the metadata panel when it differs from `datatype.label` (`bool`).
    let label: String?

    var needsSwap: Bool { !littleEndian && datatype != nil && elementSize > 1 }

    /// Largest opaque element (`|S<n>`, `|V<n>`, `r<bits>`) accepted. Such
    /// arrays only ever hold a NIfTI-Zarr header (348–540 bytes plus extensions,
    /// itself capped at 1 MiB); a crafted `|S1099511627776` must throw here
    /// rather than make `fillBytes` allocate a terabyte.
    static let maxOpaqueElementSize = 1 << 20

    /// Parses a Zarr v2 NumPy typestring.
    static func v2(_ raw: Any?) throws -> ZarrDataType {
        guard let string = raw as? String, string.count >= 2 else {
            throw MIQError.unsupportedFeature("Zarr structured or missing dtype isn't supported")
        }
        let order = string.first!
        let body = String(string.dropFirst())
        let little: Bool
        switch order {
        case "<", "|": little = true
        case ">": little = false
        default: throw MIQError.unsupportedFeature("Zarr dtype \(string) isn't supported")
        }
        if body.hasPrefix("S") || body.hasPrefix("V"), let n = Int(body.dropFirst()), n > 0 {
            guard n <= maxOpaqueElementSize else {
                throw MIQError.unsupportedFeature("Zarr dtype \(string) is implausibly large")
            }
            return ZarrDataType(datatype: nil, elementSize: n, littleEndian: true, label: nil)
        }
        let mapped: (MIQDatatype, String?)
        switch body {
        case "b1": mapped = (.uint8, "bool")
        case "i1": mapped = (.int8, nil)
        case "u1": mapped = (.uint8, nil)
        case "i2": mapped = (.int16, nil)
        case "u2": mapped = (.uint16, nil)
        case "i4": mapped = (.int32, nil)
        case "u4": mapped = (.uint32, nil)
        case "i8": mapped = (.int64, nil)
        case "u8": mapped = (.uint64, nil)
        case "f4": mapped = (.float32, nil)
        case "f8": mapped = (.float64, nil)
        default: throw MIQError.unsupportedFeature("Zarr dtype \(string) isn't supported yet")
        }
        return ZarrDataType(datatype: mapped.0, elementSize: mapped.0.bytesPerVoxel, littleEndian: little, label: mapped.1)
    }

    /// Parses a Zarr v3 `data_type`; the byte order comes from the `bytes` codec.
    static func v3(_ raw: Any?, littleEndian: Bool) throws -> ZarrDataType {
        guard let name = raw as? String else {
            throw MIQError.unsupportedFeature("Zarr extension data_type isn't supported")
        }
        if name.hasPrefix("r"), let bits = Int(name.dropFirst()), bits > 0, bits % 8 == 0 {
            guard bits / 8 <= maxOpaqueElementSize else {
                throw MIQError.unsupportedFeature("Zarr data_type \(name) is implausibly large")
            }
            return ZarrDataType(datatype: nil, elementSize: bits / 8, littleEndian: true, label: nil)
        }
        let mapped: (MIQDatatype, String?)
        switch name {
        case "bool": mapped = (.uint8, "bool")
        case "int8": mapped = (.int8, nil)
        case "uint8": mapped = (.uint8, nil)
        case "int16": mapped = (.int16, nil)
        case "uint16": mapped = (.uint16, nil)
        case "int32": mapped = (.int32, nil)
        case "uint32": mapped = (.uint32, nil)
        case "int64": mapped = (.int64, nil)
        case "uint64": mapped = (.uint64, nil)
        case "float32": mapped = (.float32, nil)
        case "float64": mapped = (.float64, nil)
        default: throw MIQError.unsupportedFeature("Zarr data_type \(name) isn't supported yet")
        }
        return ZarrDataType(datatype: mapped.0, elementSize: mapped.0.bytesPerVoxel, littleEndian: littleEndian, label: mapped.1)
    }

    /// Encodes a JSON `fill_value` as one little-endian element. `null`, absent,
    /// or unrepresentable values encode as zero bytes, which is also what both
    /// specs mean for "no fill value" when reading.
    func fillBytes(_ raw: Any?) -> [UInt8] {
        let zero = [UInt8](repeating: 0, count: elementSize)
        guard let datatype, let raw, !(raw is NSNull) else { return zero }

        // v3 hex bit pattern ("0x7fc00000") — raw IEEE/integer bits, written MSB first.
        if let string = raw as? String, string.hasPrefix("0x"), let bits = UInt64(string.dropFirst(2), radix: 16) {
            return (0..<elementSize).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
        }

        let value: Double
        if let string = raw as? String {
            switch string {
            case "NaN": value = .nan
            case "Infinity": value = .infinity
            case "-Infinity": value = -.infinity
            default: return zero
            }
        } else if let bool = raw as? Bool, !(raw is Int), !(raw is Double) {
            value = bool ? 1 : 0
        } else if datatype == .int64 || datatype == .uint64, let int = ZarrJSON.int(raw) {
            // Keep full 64-bit precision for large integer fills.
            return Self.littleEndianBytes(UInt64(bitPattern: Int64(int)), size: 8)
        } else if let number = ZarrJSON.double(raw) {
            value = number
        } else {
            return zero
        }

        func clampedInt(_ lo: Double, _ hi: Double) -> Int64 {
            guard value.isFinite else { return 0 }
            return Int64(Swift.min(Swift.max(value.rounded(), lo), hi))
        }
        switch datatype {
        case .int8: return Self.littleEndianBytes(UInt64(bitPattern: clampedInt(-128, 127)), size: 1)
        case .uint8: return label == "bool"
            ? [value != 0 && !value.isNaN ? 1 : 0]
            : Self.littleEndianBytes(UInt64(clampedInt(0, 255)), size: 1)
        case .int16: return Self.littleEndianBytes(UInt64(bitPattern: clampedInt(-32768, 32767)), size: 2)
        case .uint16: return Self.littleEndianBytes(UInt64(clampedInt(0, 65535)), size: 2)
        case .int32: return Self.littleEndianBytes(UInt64(bitPattern: clampedInt(-2_147_483_648, 2_147_483_647)), size: 4)
        case .uint32: return Self.littleEndianBytes(UInt64(clampedInt(0, 4_294_967_295)), size: 4)
        case .int64, .uint64: return Self.littleEndianBytes(UInt64(bitPattern: clampedInt(-9.2e18, 9.2e18)), size: 8)
        case .float32: return Self.littleEndianBytes(UInt64(Float(value).bitPattern), size: 4)
        case .float64: return Self.littleEndianBytes(value.bitPattern, size: 8)
        case .rgb24, .rgba32: return zero
        }
    }

    private static func littleEndianBytes(_ bits: UInt64, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
    }
}

/// A bytes→bytes codec MIQ can undo. Listed in *encode* order; decoding walks
/// the list backwards.
enum ZarrBytesCodec: Equatable {
    /// gzip or zlib — zlib's auto-detecting inflate handles both wrappers.
    case deflate
    /// A 4-byte CRC-32C trailer. Stripped, not verified: a preview tolerates a
    /// flipped bit, and verifying would need a CRC-32C table zlib doesn't ship.
    case crc32c
    /// Zstandard frames (`ZstdDecoder`): zarr-python 3's default codec.
    case zstd
    /// A Blosc 1.x chunk (`BloscDecoder`): zarr-python 2's default compressor.
    case blosc
    /// numcodecs `LZ4`: a `UInt32` size prefix plus one LZ4 block.
    case lz4

    /// The bytes→bytes codec for a numcodecs / Zarr v3 compressor name, or `nil`.
    static func compressor(named name: String) -> ZarrBytesCodec? {
        switch name {
        case "gzip", "zlib": return .deflate
        case "zstd": return .zstd
        case "blosc": return .blosc
        case "lz4": return .lz4
        default: return nil
        }
    }
}

/// Zarr v3 `sharding_indexed`: each stored object (shard) packs a grid of inner
/// chunks plus an index of `(offset, nbytes)` UInt64 pairs, one per inner chunk
/// in C order, with `UInt64.max` for both marking an empty inner chunk.
final class ZarrSharding {
    let innerChunkShape: [Int]
    let inner: ZarrCodecPipeline
    let indexLittleEndian: Bool
    let indexHasChecksum: Bool
    let indexAtEnd: Bool

    // A class only because it nests a `ZarrCodecPipeline` (which refers back to it).
    init(innerChunkShape: [Int], inner: ZarrCodecPipeline, indexLittleEndian: Bool, indexHasChecksum: Bool, indexAtEnd: Bool) {
        self.innerChunkShape = innerChunkShape
        self.inner = inner
        self.indexLittleEndian = indexLittleEndian
        self.indexHasChecksum = indexHasChecksum
        self.indexAtEnd = indexAtEnd
    }
}

/// The decode recipe for one stored chunk.
struct ZarrCodecPipeline {
    /// Transpose applied before serialisation: stored axis `i` is array axis
    /// `order[i]`. `nil` is plain C order. v2 `order: "F"` is the reversed order.
    var transposeOrder: [Int]?
    var littleEndian: Bool = true
    var bytesCodecs: [ZarrBytesCodec] = []
    var sharding: ZarrSharding?

    /// Element strides of a decoded chunk of `shape`, indexed by *array* axis.
    func elementStrides(chunkShape shape: [Int]) -> [Int] {
        let order = transposeOrder ?? Array(shape.indices)
        var strides = [Int](repeating: 0, count: shape.count)
        var running = 1
        for storedAxis in order.indices.reversed() {
            let arrayAxis = order[storedAxis]
            strides[arrayAxis] = running
            running *= shape[arrayAxis]
        }
        return strides
    }

    static func unsupportedCompressor(_ name: String) -> MIQError {
        .unsupportedFeature("Zarr compressor \(name) isn't supported yet")
    }

    /// Parses a v3 `codecs` list. `rank` validates a transpose order.
    static func v3(_ raw: Any?, rank: Int, allowSharding: Bool = true) throws -> ZarrCodecPipeline {
        guard let codecs = raw as? [Any] else {
            throw MIQError.malformedFile("Zarr v3 array metadata has no codecs list")
        }
        var pipeline = ZarrCodecPipeline()
        var sawArrayToBytes = false
        for entry in codecs {
            guard let codec = entry as? ZarrJSON.Object, let rawName = codec["name"] as? String else {
                throw MIQError.malformedFile("Zarr v3 codec entry is not an object with a name")
            }
            let name = rawName.hasPrefix("numcodecs.") ? String(rawName.dropFirst("numcodecs.".count)) : rawName
            let config = codec["configuration"] as? ZarrJSON.Object ?? [:]
            switch name {
            case "transpose":
                guard !sawArrayToBytes, pipeline.transposeOrder == nil else {
                    throw MIQError.unsupportedFeature("Zarr codec chain with repeated transpose isn't supported")
                }
                if let order = ZarrJSON.intArray(config["order"]) {
                    guard order.count == rank, Set(order) == Set(0..<rank) else {
                        throw MIQError.malformedFile("Zarr transpose order \(order) doesn't match rank \(rank)")
                    }
                    pipeline.transposeOrder = order
                } else if let order = config["order"] as? String, order == "F" || order == "C" {
                    // Pre-1.0 drafts spelled it as a memory order string.
                    pipeline.transposeOrder = order == "F" ? Array((0..<rank).reversed()) : nil
                } else {
                    throw MIQError.malformedFile("Zarr transpose codec has no usable order")
                }
            case "bytes", "endian":
                sawArrayToBytes = true
                pipeline.littleEndian = (config["endian"] as? String ?? "little") != "big"
            case "sharding_indexed":
                guard allowSharding else {
                    throw MIQError.unsupportedFeature("Zarr nested sharding isn't supported")
                }
                sawArrayToBytes = true
                pipeline.sharding = try parseSharding(config, rank: rank)
            case "gzip", "zlib", "zstd", "blosc", "lz4":
                guard sawArrayToBytes else { throw MIQError.malformedFile("Zarr \(name) codec precedes the bytes codec") }
                pipeline.bytesCodecs.append(ZarrBytesCodec.compressor(named: name)!)
            case "crc32c":
                pipeline.bytesCodecs.append(.crc32c)
            case "bz2", "lzma", "lz4hc", "zfpy", "zfp":
                throw unsupportedCompressor(name)
            default:
                throw MIQError.unsupportedFeature("Zarr codec \(rawName) isn't supported yet")
            }
        }
        if pipeline.sharding != nil, !pipeline.bytesCodecs.isEmpty {
            throw MIQError.unsupportedFeature("Zarr compression applied to whole shards isn't supported yet")
        }
        return pipeline
    }

    private static func parseSharding(_ config: ZarrJSON.Object, rank: Int) throws -> ZarrSharding {
        guard let inner = ZarrJSON.intArray(config["chunk_shape"]), inner.count == rank, inner.allSatisfy({ $0 > 0 }) else {
            throw MIQError.malformedFile("Zarr sharding codec has no valid chunk_shape")
        }
        let innerPipeline = try v3(config["codecs"] ?? [["name": "bytes"]], rank: rank, allowSharding: false)
        var indexLittle = true
        var indexChecksum = false
        for entry in config["index_codecs"] as? [Any] ?? [["name": "bytes"], ["name": "crc32c"]] {
            guard let codec = entry as? ZarrJSON.Object, let name = codec["name"] as? String else { continue }
            let codecConfig = codec["configuration"] as? ZarrJSON.Object ?? [:]
            switch name {
            case "bytes": indexLittle = (codecConfig["endian"] as? String ?? "little") != "big"
            case "crc32c": indexChecksum = true
            default: throw MIQError.unsupportedFeature("Zarr shard index codec \(name) isn't supported yet")
            }
        }
        let location = config["index_location"] as? String ?? "end"
        return ZarrSharding(
            innerChunkShape: inner,
            inner: innerPipeline,
            indexLittleEndian: indexLittle,
            indexHasChecksum: indexChecksum,
            indexAtEnd: location != "start"
        )
    }

    /// Builds the pipeline for a v2 `.zarray` (`order`, `filters`, `compressor`).
    static func v2(order: Any?, filters: Any?, compressor: Any?, rank: Int, dtype: ZarrDataType) throws -> ZarrCodecPipeline {
        var pipeline = ZarrCodecPipeline()
        pipeline.littleEndian = dtype.littleEndian
        if (order as? String) == "F", rank > 1 {
            pipeline.transposeOrder = Array((0..<rank).reversed())
        }
        if let filters = filters as? [Any], let first = filters.first {
            let id = (first as? ZarrJSON.Object)?["id"] as? String ?? "unknown"
            throw MIQError.unsupportedFeature("Zarr filter \(id) isn't supported yet")
        }
        if let compressor = compressor as? ZarrJSON.Object {
            let id = compressor["id"] as? String ?? "unknown"
            guard let codec = ZarrBytesCodec.compressor(named: id) else { throw unsupportedCompressor(id) }
            pipeline.bytesCodecs = [codec]
        }
        return pipeline
    }
}

/// Everything needed to locate and decode the chunks of one Zarr array.
struct ZarrArrayMetadata {
    let zarrFormat: Int
    let shape: [Int]
    /// Shape of a stored object: the chunk, or the shard when sharded.
    let chunkShape: [Int]
    let dataType: ZarrDataType
    let fillValue: [UInt8]
    let pipeline: ZarrCodecPipeline
    /// Key separator; `prefix` is `"c"` for v3's default key encoding.
    let separator: String
    let keyPrefix: String?
    /// v3 `dimension_names`, when present.
    let dimensionNames: [String?]?

    /// Stored-object key relative to the array directory for chunk grid coordinates `coords`.
    func chunkKey(_ coords: [Int]) -> String {
        let parts = coords.map(String.init)
        if let keyPrefix {
            return ([keyPrefix] + parts).joined(separator: separator)
        }
        return parts.isEmpty ? "0" : parts.joined(separator: separator)
    }

    /// Reads `.zarray` (v2) or `zarr.json` with `node_type: "array"` (v3) in `directory`.
    /// `nil` when the directory holds no array metadata.
    static func read(directory: URL) throws -> ZarrArrayMetadata? {
        if let json = try ZarrJSON.object(at: directory.appendingPathComponent("zarr.json")) {
            guard (json["node_type"] as? String) == "array" else { return nil }
            return try v3(json)
        }
        if let json = try ZarrJSON.object(at: directory.appendingPathComponent(".zarray")) {
            return try v2(json)
        }
        return nil
    }

    /// Shape only, parsed leniently so pyramid levels can be ranked without
    /// rejecting a level over a codec we would never decode.
    static func shape(directory: URL) -> [Int]? {
        for name in ["zarr.json", ".zarray"] {
            if let json = try? ZarrJSON.object(at: directory.appendingPathComponent(name)),
               let shape = ZarrJSON.intArray(json["shape"]) {
                return shape
            }
        }
        return nil
    }

    static func v2(_ json: ZarrJSON.Object) throws -> ZarrArrayMetadata {
        guard ZarrJSON.int(json["zarr_format"]) == 2 else {
            throw MIQError.unsupportedFormatVersion(Int32(ZarrJSON.int(json["zarr_format"]) ?? 0))
        }
        let (shape, chunks) = try validatedShape(json["shape"], json["chunks"])
        let dtype = try ZarrDataType.v2(json["dtype"])
        let pipeline = try ZarrCodecPipeline.v2(
            order: json["order"], filters: json["filters"], compressor: json["compressor"],
            rank: shape.count, dtype: dtype
        )
        let separator = json["dimension_separator"] as? String ?? "."
        guard separator == "." || separator == "/" else {
            throw MIQError.malformedFile("Zarr dimension_separator \(separator) is invalid")
        }
        try validateChunkSize(chunks: chunks, sharding: nil, elementSize: dtype.elementSize)
        return ZarrArrayMetadata(
            zarrFormat: 2, shape: shape, chunkShape: chunks, dataType: dtype,
            fillValue: dtype.fillBytes(json["fill_value"]), pipeline: pipeline,
            separator: separator, keyPrefix: nil, dimensionNames: nil
        )
    }

    static func v3(_ json: ZarrJSON.Object) throws -> ZarrArrayMetadata {
        guard ZarrJSON.int(json["zarr_format"]) == 3 else {
            throw MIQError.unsupportedFormatVersion(Int32(ZarrJSON.int(json["zarr_format"]) ?? 0))
        }
        let grid = json["chunk_grid"] as? ZarrJSON.Object
        guard (grid?["name"] as? String ?? "regular") == "regular" else {
            throw MIQError.unsupportedFeature("Zarr chunk grid \(grid?["name"] ?? "") isn't supported yet")
        }
        let gridConfig = grid?["configuration"] as? ZarrJSON.Object
        let (shape, chunks) = try validatedShape(json["shape"], gridConfig?["chunk_shape"])
        let pipeline = try ZarrCodecPipeline.v3(json["codecs"], rank: shape.count)
        let dtype = try ZarrDataType.v3(json["data_type"], littleEndian: pipeline.sharding?.inner.littleEndian ?? pipeline.littleEndian)

        let encoding = json["chunk_key_encoding"] as? ZarrJSON.Object
        let encodingName = encoding?["name"] as? String ?? "default"
        let encodingConfig = encoding?["configuration"] as? ZarrJSON.Object
        let separator: String
        let prefix: String?
        switch encodingName {
        case "default":
            separator = encodingConfig?["separator"] as? String ?? "/"
            prefix = "c"
        case "v2":
            separator = encodingConfig?["separator"] as? String ?? "."
            prefix = nil
        default:
            throw MIQError.unsupportedFeature("Zarr chunk key encoding \(encodingName) isn't supported yet")
        }
        guard separator == "." || separator == "/" else {
            throw MIQError.malformedFile("Zarr chunk key separator \(separator) is invalid")
        }
        if let sharding = pipeline.sharding {
            for (outer, inner) in zip(chunks, sharding.innerChunkShape) where outer % inner != 0 {
                throw MIQError.malformedFile("Zarr shard shape \(chunks) isn't a multiple of inner chunk shape \(sharding.innerChunkShape)")
            }
        }
        try validateChunkSize(chunks: chunks, sharding: pipeline.sharding, elementSize: dtype.elementSize)
        let names = (json["dimension_names"] as? [Any])?.map { $0 as? String }
        return ZarrArrayMetadata(
            zarrFormat: 3, shape: shape, chunkShape: chunks, dataType: dtype,
            fillValue: dtype.fillBytes(json["fill_value"]), pipeline: pipeline,
            separator: separator, keyPrefix: prefix, dimensionNames: names
        )
    }

    /// Upper bound on one decoded addressable chunk (the inner chunk when
    /// sharded), and on a shard index. A chunk is decoded whole, so a larger one
    /// could not fit the preview budget anyway.
    static let maxChunkBytes = MIQParser.zarrMaxPreviewBytes

    /// Rejects chunk geometry whose byte size overflows `Int` or exceeds
    /// `maxChunkBytes`, so `ZarrChunkReader` can multiply chunk extents, element
    /// sizes and shard-index entry counts without overflow checks. Thumbnails
    /// browse Zarr folders automatically, so a hostile `chunks: [9223372036854775807]`
    /// must throw here instead of trapping later.
    static func validateChunkSize(chunks: [Int], sharding: ZarrSharding?, elementSize: Int) throws {
        func checkedBytes(_ extents: [Int], unit: Int) -> Int? {
            var product = unit
            for extent in extents {
                let (next, overflow) = product.multipliedReportingOverflow(by: extent)
                guard !overflow else { return nil }
                product = next
            }
            return product
        }
        let addressable = sharding?.innerChunkShape ?? chunks
        guard let chunkBytes = checkedBytes(addressable, unit: elementSize), chunkBytes <= maxChunkBytes else {
            throw MIQError.unsupportedFeature("Zarr chunk shape \(addressable) is too large to preview")
        }
        if let sharding {
            // 16 bytes (offset + nbytes) per inner chunk in the shard index.
            let perShard = zip(chunks, sharding.innerChunkShape).map { $0 / $1 }
            guard let indexBytes = checkedBytes(perShard, unit: 16), indexBytes <= maxChunkBytes else {
                throw MIQError.unsupportedFeature("Zarr shard shape \(chunks) holds too many inner chunks to preview")
            }
        }
    }

    private static func validatedShape(_ rawShape: Any?, _ rawChunks: Any?) throws -> ([Int], [Int]) {
        guard let shape = ZarrJSON.intArray(rawShape), !shape.isEmpty, shape.allSatisfy({ $0 >= 0 }) else {
            throw MIQError.malformedFile("Zarr array has no valid shape")
        }
        guard let chunks = ZarrJSON.intArray(rawChunks), chunks.count == shape.count, chunks.allSatisfy({ $0 > 0 }) else {
            throw MIQError.malformedFile("Zarr array chunk shape doesn't match its shape")
        }
        return (shape, chunks)
    }
}
