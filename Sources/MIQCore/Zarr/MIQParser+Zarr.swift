import Foundation

/// Which Zarr convention a store follows, from most to least specific.
public enum ZarrFlavor: String, Sendable {
    /// OME-Zarr multiscales plus a binary `nifti` header array (NIfTI-Zarr 1.0).
    case niftiZarr
    /// OME-NGFF multiscales (0.4 on Zarr v2, 0.5 on Zarr v3).
    case omeZarr
    /// A bare Zarr array (or a group without multiscales metadata).
    case plainZarr
}

/// What was read from a Zarr store, beyond the voxels themselves. A preview
/// shows only the lowest-resolution level, so UI can use this to say so.
public struct ZarrStoreSummary: Sendable, Equatable {
    public let flavor: ZarrFlavor
    /// 2 or 3.
    public let zarrFormat: Int
    /// OME-NGFF `version` (`"0.4"`, `"0.5"`), when declared.
    public let omeVersion: String?
    /// Number of pyramid levels (`multiscales[0].datasets`), 1 for a bare array.
    public let levelCount: Int
    /// Index of the level that was read (into `datasets`).
    public let levelIndex: Int
    /// Store-relative path of the level that was read (`""` for a root array).
    public let levelPath: String
    /// Full N-d shape of the level that was read, in array (C) order.
    public let levelShape: [Int]
    /// Full N-d shape of `datasets[0]` (the finest level), when readable.
    public let fullResolutionShape: [Int]?
    /// Axis names in array order (`["t", "c", "z", "y", "x"]`).
    public let axisNames: [String]
}

public struct ZarrParseResult: Sendable {
    public let image: MIQImage
    public let summary: ZarrStoreSummary
}

extension MIQParser {
    /// Upper bound on the assembled preview buffer (one 3-D block of the
    /// lowest-resolution level). A store whose coarsest level is still larger
    /// throws instead of allocating.
    public static let zarrMaxPreviewBytes = 512 * 1024 * 1024

    /// Previews a Zarr directory store (OME-Zarr 0.4/0.5, NIfTI-Zarr, or a bare
    /// Zarr v2/v3 array) by reading only its lowest-resolution pyramid level.
    ///
    /// Only the spatial block at index 0 of every non-spatial axis (first `t`,
    /// first `c`) is assembled, into a canonical x-fastest little-endian buffer,
    /// so the result behaves like a single-volume NIfTI for the renderer.
    /// Spacing comes from the level's `scale` transform converted to millimetres
    /// via the axis units. OME axes carry no anatomical meaning, so orientation
    /// is unknown unless a NIfTI-Zarr header supplies an sform/qform.
    ///
    /// Supported encodings: v2 `compressor` null/gzip/zlib, `order` C/F, `.`/`/`
    /// separators; v3 `bytes` (either endian), `transpose`, `gzip`, `crc32c`
    /// (stripped, not verified) and `sharding_indexed` (range-read via the shard
    /// index). blosc/zstd/lz4 etc. throw `MIQError.unsupportedFeature`.
    public func parseZarr(url: URL, maxBytes: Int = MIQParser.zarrMaxPreviewBytes) throws -> ZarrParseResult {
        let store = try ZarrStore.locate(url)

        let levels = store.levels
        guard !levels.isEmpty else { throw MIQError.malformedFile("OME-Zarr multiscales has no datasets") }
        let shapes = try levels.map { ZarrArrayMetadata.shape(directory: try store.directory(for: $0.path)) }
        let rank = shapes.compactMap { $0?.count }.first ?? store.axes.count
        let axes = store.axes.count == rank ? store.axes : ZarrAxis.defaults(rank: rank)
        let spatial = try ZarrAxis.spatialIndices(axes)

        // Lowest resolution = fewest spatial voxels; datasets are ordered fine →
        // coarse, so ties go to the later entry.
        var chosen: Int?
        var chosenCount = Int.max
        for (i, shape) in shapes.enumerated() {
            guard let shape, shape.count == rank else { continue }
            let count = spatial.all.reduce(1) { partial, axis in
                partial.multipliedReportingOverflow(by: shape[axis]).overflow ? Int.max : partial * shape[axis]
            }
            if count <= chosenCount {
                chosen = i
                chosenCount = count
            }
        }
        guard let levelIndex = chosen else {
            throw MIQError.malformedFile("no readable Zarr array metadata in any pyramid level")
        }
        let level = levels[levelIndex]
        let arrayDirectory = try store.directory(for: level.path)
        guard let metadata = try ZarrArrayMetadata.read(directory: arrayDirectory) else {
            throw MIQError.malformedFile("Zarr level \(level.path) has no array metadata")
        }
        guard metadata.shape.count == rank else {
            throw MIQError.malformedFile("Zarr level \(level.path) rank doesn't match its axes")
        }
        guard let datatype = metadata.dataType.datatype else {
            throw MIQError.unsupportedFeature("Zarr byte-string arrays can't be previewed")
        }

        // Output geometry: x fastest, then y, then z; all other axes pinned to 0.
        let width = metadata.shape[spatial.x]
        let height = metadata.shape[spatial.y]
        let depth = spatial.z.map { metadata.shape[$0] } ?? 1
        guard width > 0, height > 0, depth > 0 else { throw MIQError.invalidDimensions }
        try validateDimensionExtent([width, height, depth], bytesPerVoxel: datatype.bytesPerVoxel)
        let byteCount = width * height * depth * datatype.bytesPerVoxel
        guard byteCount <= maxBytes else {
            throw MIQError.unsupportedFeature(
                "the lowest-resolution Zarr level is \(byteCount / 1_048_576) MB, over the \(maxBytes / 1_048_576) MB preview limit"
            )
        }
        var extents = [Int](repeating: 1, count: rank)
        var outputStrides = [Int](repeating: 0, count: rank)
        extents[spatial.x] = width
        outputStrides[spatial.x] = 1
        extents[spatial.y] = height
        outputStrides[spatial.y] = width
        if let z = spatial.z {
            extents[z] = depth
            outputStrides[z] = width * height
        }

        var storage = Data(count: byteCount)
        let reader = ZarrChunkReader(directory: arrayDirectory, metadata: metadata, storeRoot: store.storeRoot)
        try storage.withUnsafeMutableBytes { buffer in
            ZarrChunkReader.fill(buffer, with: metadata.fillValue)
            try reader.assemble(extents: extents, outputStrides: outputStrides, into: buffer)
        }
        if !VolumeLocation.isLocal(url) { onNetworkReadFinished?() }

        // Physical geometry of the chosen level, in mm.
        let transform = store.transform(forLevel: levelIndex, rank: rank)
        let unitScale = axes.map { ZarrAxis.millimetresPerUnit($0.unit) }
        func spacing(_ axis: Int?) -> Double { axis.map { transform.scale[$0] * unitScale[$0] } ?? 1 }
        func origin(_ axis: Int?) -> Double { axis.map { transform.translation[$0] * unitScale[$0] } ?? 0 }
        var pixdim: [Float] = [1, Float(spacing(spatial.x)), Float(spacing(spatial.y)), Float(spacing(spatial.z))]
        var srowX: [Float] = [pixdim[1], 0, 0, Float(origin(spatial.x))]
        var srowY: [Float] = [0, pixdim[2], 0, Float(origin(spatial.y))]
        var srowZ: [Float] = [0, 0, pixdim[3], Float(origin(spatial.z))]
        var qformCode = 0
        var sformCode = 0
        var sclSlope: Float = 0
        var sclInter: Float = 0
        var orientationFrame: OrientationFrame?

        let niftiHeader = store.niftiHeaderBytes.flatMap { try? parseNiftiHeader(from: $0) }
        if let nifti = niftiHeader {
            // The header describes datasets[0]; rescale it to the chosen level.
            // NIfTI i/j/k are the zarr x/y/z axes.
            let base = store.transform(forLevel: 0, rank: rank)
            let fullShape = shapes[0]
            let spatialOrder = [spatial.x, spatial.y, spatial.z]
            var ratio: [Float] = [1, 1, 1]
            var shift: [Float] = [0, 0, 0] // level origin in level-0 voxels
            for (c, axisOpt) in spatialOrder.enumerated() {
                guard let axis = axisOpt else { continue }
                let hasScales = levels[0].scale != nil && level.scale != nil
                if hasScales, base.scale[axis] != 0 {
                    ratio[c] = Float(transform.scale[axis] / base.scale[axis])
                    shift[c] = Float((transform.translation[axis] - base.translation[axis]) / base.scale[axis])
                } else if let fullShape, metadata.shape[axis] > 0 {
                    ratio[c] = Float(fullShape[axis]) / Float(metadata.shape[axis])
                }
            }
            pixdim = [nifti.pixdim[safe: 0] ?? 1] + (0..<3).map { (nifti.pixdim[safe: $0 + 1] ?? 1) * ratio[$0] }
            if nifti.sformCode > 0 {
                func rescale(_ row: [Float]) -> [Float] {
                    let r = (0..<4).map { row[safe: $0] ?? 0 }
                    let offset = r[3] + r[0] * shift[0] + r[1] * shift[1] + r[2] * shift[2]
                    return [r[0] * ratio[0], r[1] * ratio[1], r[2] * ratio[2], offset]
                }
                srowX = rescale(nifti.srowX)
                srowY = rescale(nifti.srowY)
                srowZ = rescale(nifti.srowZ)
            }
            qformCode = nifti.qformCode
            sformCode = nifti.sformCode
            sclSlope = nifti.sclSlope
            sclInter = nifti.sclInter
            // Direction only: positive per-axis rescaling never changes it.
            orientationFrame = nifti.orientationFrame
        }

        let flavor: ZarrFlavor = store.niftiHeaderBytes != nil
            ? .niftiZarr
            : (store.hasMultiscales ? .omeZarr : .plainZarr)
        var label: String
        switch flavor {
        case .niftiZarr: label = "NIfTI-Zarr"
        case .omeZarr: label = store.omeVersion.map { "OME-Zarr \($0)" } ?? "OME-Zarr"
        case .plainZarr: label = "Zarr v\(metadata.zarrFormat)"
        }
        if levels.count > 1 { label += " (level \(levelIndex + 1)/\(levels.count))" }

        let header = MIQHeader(
            littleEndian: true,
            dimensions: [width, height, depth, 1],
            pixdim: pixdim,
            datatype: datatype,
            voxOffset: 0,
            sclSlope: sclSlope,
            sclInter: sclInter,
            qformCode: qformCode,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            formatLabel: label,
            datatypeLabel: metadata.dataType.label,
            orientationFrame: orientationFrame
        )
        let summary = ZarrStoreSummary(
            flavor: flavor,
            zarrFormat: metadata.zarrFormat,
            omeVersion: store.omeVersion,
            levelCount: levels.count,
            levelIndex: levelIndex,
            levelPath: level.path,
            levelShape: metadata.shape,
            fullResolutionShape: shapes[0],
            axisNames: axes.map(\.name)
        )
        return ZarrParseResult(image: MIQImage(header: header, storage: storage, payloadOffset: 0), summary: summary)
    }
}

// MARK: - Axes

struct ZarrAxis: Equatable {
    let name: String
    let type: String?
    let unit: String?

    static func defaults(rank: Int) -> [ZarrAxis] {
        let names = ["t", "c", "z", "y", "x"]
        return (0..<rank).map { i in
            let fromEnd = rank - 1 - i
            let name = fromEnd < 3 ? names[4 - fromEnd] : "dim\(i)"
            return ZarrAxis(name: name, type: fromEnd < 3 ? "space" : nil, unit: nil)
        }
    }

    /// OME 0.4+: objects with name/type/unit. 0.3: bare names.
    static func parse(_ raw: Any?) -> [ZarrAxis] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            if let name = entry as? String {
                return ZarrAxis(name: name, type: nil, unit: nil)
            }
            guard let object = entry as? ZarrJSON.Object, let name = object["name"] as? String else { return nil }
            return ZarrAxis(name: name, type: object["type"] as? String, unit: object["unit"] as? String)
        }
    }

    /// Array indices of the x/y/(z) axes. Named axes win; otherwise the last
    /// spatial axes in order are z, y, x (OME requires `…zyx` ordering).
    static func spatialIndices(_ axes: [ZarrAxis]) throws -> (x: Int, y: Int, z: Int?, all: [Int]) {
        var spatial = axes.indices.filter { i in
            let axis = axes[i]
            if let type = axis.type { return type == "space" }
            return ["x", "y", "z"].contains(axis.name.lowercased())
        }
        if spatial.count < 2 {
            // No usable axis metadata: assume the trailing dims are spatial.
            spatial = Array(axes.indices.suffix(3))
        }
        guard spatial.count >= 2 else { throw MIQError.invalidDimensions }
        func named(_ name: String) -> Int? { spatial.first { axes[$0].name.lowercased() == name } }
        let x = named("x") ?? spatial[spatial.count - 1]
        let y = named("y") ?? spatial.last { $0 != x }!
        let z = named("z") ?? spatial.last { $0 != x && $0 != y }
        guard x != y, z != x, z != y else { throw MIQError.malformedFile("Zarr axes don't name distinct x/y/z axes") }
        return (x, y, z, [x, y] + (z.map { [$0] } ?? []))
    }

    /// Millimetres per OME-NGFF (UDUNITS-2) space unit. Unknown or missing units
    /// keep the raw value (factor 1), matching NIfTI's "assume mm" convention.
    static func millimetresPerUnit(_ unit: String?) -> Double {
        switch unit?.lowercased() {
        case "angstrom": return 1e-7
        case "attometer": return 1e-15
        case "femtometer": return 1e-12
        case "picometer": return 1e-9
        case "nanometer", "nm": return 1e-6
        case "micrometer", "micron", "um", "µm": return 1e-3
        case "millimeter", "mm": return 1
        case "centimeter", "cm": return 10
        case "decimeter": return 100
        case "meter", "m": return 1000
        case "hectometer": return 1e5
        case "kilometer": return 1e6
        case "inch": return 25.4
        case "foot": return 304.8
        case "yard": return 914.4
        case "mile": return 1_609_344
        case "parsec": return 3.0857e19
        default: return 1
        }
    }
}

// MARK: - Store discovery

/// One pyramid level: its path and per-axis coordinate transforms.
struct ZarrLevel {
    let path: String
    let scale: [Double]?
    let translation: [Double]?
}

struct ZarrStore {
    /// Directory of the multiscales group (or the array itself).
    let root: URL
    /// The directory the user picked (`root` or its parent for the
    /// bioformats2raw layout). Nothing outside it is ever read.
    let storeRoot: URL
    let hasMultiscales: Bool
    let omeVersion: String?
    let axes: [ZarrAxis]
    let levels: [ZarrLevel]
    /// Multiscale-level transforms applied after each dataset's.
    let globalScale: [Double]?
    let globalTranslation: [Double]?
    /// Raw bytes of the NIfTI-Zarr `nifti` array, when present.
    let niftiHeaderBytes: Data?

    /// The directory of a level's array. `path` comes from untrusted metadata:
    /// absolute paths and `..` components are rejected outright, and the
    /// symlink-resolved directory must lie inside `storeRoot`, so a dataset path
    /// like `../../other.zarr/0` (or a level symlinked elsewhere) can't make a
    /// preview read another store.
    func directory(for path: String) throws -> URL {
        if path.isEmpty { return root }
        guard Self.isSafeRelativePath(path),
              let resolved = MIQParser.containedResolvedURL(root.appendingPathComponent(path, isDirectory: true), inside: storeRoot) else {
            throw MIQError.unsupportedFeature("Zarr dataset path points outside the store; only arrays inside the store are read")
        }
        return resolved
    }

    /// A relative `/`-separated path with no `..` component, no NUL, not absolute.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Combined scale/translation for a level: `global ∘ dataset`.
    func transform(forLevel index: Int, rank: Int) -> (scale: [Double], translation: [Double]) {
        func fit(_ v: [Double]?, _ fallback: Double) -> [Double] {
            guard let v, v.count == rank else { return [Double](repeating: fallback, count: rank) }
            return v
        }
        let level = levels[safe: index]
        let s = fit(level?.scale, 1)
        let t = fit(level?.translation, 0)
        let gs = fit(globalScale, 1)
        let gt = fit(globalTranslation, 0)
        return ((0..<rank).map { s[$0] * gs[$0] }, (0..<rank).map { t[$0] * gs[$0] + gt[$0] })
    }

    private struct Node {
        let isArray: Bool
        let attributes: ZarrJSON.Object
    }

    private static func node(at directory: URL) throws -> Node? {
        if let json = try ZarrJSON.object(at: directory.appendingPathComponent("zarr.json")) {
            return Node(isArray: (json["node_type"] as? String) == "array",
                        attributes: json["attributes"] as? ZarrJSON.Object ?? [:])
        }
        let attrs = try ZarrJSON.object(at: directory.appendingPathComponent(".zattrs")) ?? [:]
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".zarray").path) {
            return Node(isArray: true, attributes: attrs)
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".zgroup").path) || !attrs.isEmpty {
            return Node(isArray: false, attributes: attrs)
        }
        return nil
    }

    /// `(multiscales[0], version)` from 0.5 (`attributes.ome`) or 0.4 (`.zattrs`).
    private static func multiscales(_ attributes: ZarrJSON.Object) -> (ZarrJSON.Object, String?)? {
        if let ome = attributes["ome"] as? ZarrJSON.Object,
           let first = (ome["multiscales"] as? [Any])?.first as? ZarrJSON.Object {
            return (first, ome["version"] as? String ?? first["version"] as? String)
        }
        if let first = (attributes["multiscales"] as? [Any])?.first as? ZarrJSON.Object {
            return (first, first["version"] as? String)
        }
        return nil
    }

    private static func transforms(_ raw: Any?) -> (scale: [Double]?, translation: [Double]?) {
        var scale: [Double]?
        var translation: [Double]?
        for entry in raw as? [Any] ?? [] {
            guard let object = entry as? ZarrJSON.Object else { continue }
            switch object["type"] as? String {
            case "scale": scale = ZarrJSON.doubleArray(object["scale"])
            case "translation": translation = ZarrJSON.doubleArray(object["translation"])
            default: continue
            }
        }
        return (scale, translation)
    }

    static func locate(_ url: URL) throws -> ZarrStore {
        guard var root = try node(at: url).map({ ($0, url) }) else {
            throw MIQError.malformedFile("not a Zarr store (no zarr.json, .zgroup or .zarray)")
        }
        if root.0.isArray {
            let shape = ZarrArrayMetadata.shape(directory: url) ?? []
            let names = (try? ZarrJSON.object(at: url.appendingPathComponent("zarr.json")))?.flatMap {
                ($0["dimension_names"] as? [Any])?.compactMap { $0 as? String }
            }
            let axes = names.map { $0.map { ZarrAxis(name: $0, type: nil, unit: nil) } } ?? ZarrAxis.defaults(rank: shape.count)
            return ZarrStore(root: url, storeRoot: url, hasMultiscales: false, omeVersion: nil, axes: axes,
                             levels: [ZarrLevel(path: "", scale: nil, translation: nil)],
                             globalScale: nil, globalTranslation: nil, niftiHeaderBytes: nil)
        }
        var found = multiscales(root.0.attributes)
        if found == nil {
            // bioformats2raw layout: the image lives in the "0" subgroup.
            let child = url.appendingPathComponent("0", isDirectory: true)
            if MIQParser.containedResolvedURL(child, inside: url) != nil,
               let node = try node(at: child), !node.isArray, let nested = multiscales(node.attributes) {
                root = (node, child)
                found = nested
            }
        }
        guard let (multiscale, version) = found else {
            throw MIQError.malformedFile("Zarr group has no OME multiscales metadata")
        }
        let levels: [ZarrLevel] = (multiscale["datasets"] as? [Any] ?? []).compactMap { entry in
            guard let object = entry as? ZarrJSON.Object, let path = object["path"] as? String else { return nil }
            let t = transforms(object["coordinateTransformations"])
            return ZarrLevel(path: path, scale: t.scale, translation: t.translation)
        }
        let global = transforms(multiscale["coordinateTransformations"])
        return ZarrStore(
            root: root.1,
            storeRoot: url,
            hasMultiscales: true,
            omeVersion: version,
            axes: ZarrAxis.parse(multiscale["axes"]),
            levels: levels,
            globalScale: global.scale,
            globalTranslation: global.translation,
            niftiHeaderBytes: try niftiHeader(in: root.1, storeRoot: url)
        )
    }

    /// The NIfTI-Zarr `nifti` array: raw header bytes (`u1`/`uint8` or one `S<n>`
    /// element). Capped at 1 MiB — a header plus extensions, never a payload.
    private static func niftiHeader(in root: URL, storeRoot: URL) throws -> Data? {
        let directory = root.appendingPathComponent("nifti", isDirectory: true)
        guard MIQParser.containedResolvedURL(directory, inside: storeRoot) != nil,
              let metadata = try? ZarrArrayMetadata.read(directory: directory) else { return nil }
        let bytes = try ZarrChunkReader(directory: directory, metadata: metadata, storeRoot: storeRoot)
            .readAllBytes(maxBytes: 1 << 20)
        return bytes.count >= 348 ? bytes : nil
    }
}
