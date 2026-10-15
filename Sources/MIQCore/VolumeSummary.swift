import Foundation

/// A compact, header-only description of a volume file: format, spatial
/// dimensions, voxel spacing (+ unit), datatype, volume count and storage
/// orientation code.
///
/// Built **only** from header parsing — the voxel payload is never read, and for
/// gzipped kinds only as much of the stream is inflated as the header needs. That
/// makes it cheap enough for per-file callers that must stay fast and bounded:
/// the Spotlight importer (`MIQSpotlightImporter`), the App Intents in the app
/// target, and the `miq info` CLI. All three should share this type so the
/// numbers they report never drift apart.
///
/// Deliberately carries no free-text header fields (NIfTI `descrip`/`aux_file`,
/// MIF comments, NRRD `content`): those can hold patient identifiers, and every
/// consumer of this struct (Spotlight's index in particular) persists or shares
/// what it is given.
public struct VolumeSummary: Sendable, Hashable, Codable {
    /// Display name of the on-disk format, e.g. "Compressed NIfTI-1", "NIfTI-2",
    /// "MGH", "Compressed NRRD". Same wording as the preview's Format row.
    public let format: String
    /// Spatial dimensions in storage order: `[x, y, z]` (a 2D image has `z == 1`).
    public let dimensions: [Int]
    /// Number of volumes (the 4th axis); `1` for a 3D file.
    public let volumes: Int
    /// Voxel spacing per spatial axis, `[x, y, z]`, as magnitudes of the header
    /// values. A non-finite header value is reported as `0` (JSON cannot carry NaN).
    public let voxelSpacing: [Double]
    /// Spatial unit of `voxelSpacing` ("mm", "m", "µm"), or `nil` when the header
    /// does not say. NIfTI reads `xyzt_units`; MGH and MIF are millimetres by
    /// specification; NRRD is reported as unknown.
    public let spacingUnit: String?
    /// Datatype label as the preview shows it ("int16", "float32", MIF "bit", …).
    public let datatype: String
    /// Three-letter storage orientation code (e.g. "RAS", "LPS"), or `nil` when the
    /// header carries no usable orientation.
    public let orientation: String?
    /// Which header field `orientation` came from ("sform", "qform", "mifLayout",
    /// "mghDirectionCosines", "nrrdSpaceDirections"), or `nil` with `orientation`.
    public let orientationSource: String?

    public init(
        format: String,
        dimensions: [Int],
        volumes: Int,
        voxelSpacing: [Double],
        spacingUnit: String?,
        datatype: String,
        orientation: String?,
        orientationSource: String?
    ) {
        self.format = format
        self.dimensions = dimensions
        self.volumes = volumes
        self.voxelSpacing = voxelSpacing
        self.spacingUnit = spacingUnit
        self.datatype = datatype
        self.orientation = orientation
        self.orientationSource = orientationSource
    }

    /// Summarises an already-parsed header. `spacingUnit` is passed in because
    /// `MIQHeader` does not carry it; `read(contentsOf:)` derives it per format.
    public init(header: MIQHeader, kind: MIQFileKind, spacingUnit: String?) {
        let spacing: [Double] = (1...3).map { idx in
            let value = Double(header.pixdim[safe: idx] ?? 1)
            return value.isFinite ? abs(value) : 0
        }
        self.init(
            format: header.formatLabel ?? kind.displayName,
            dimensions: [header.width, header.height, header.depth],
            volumes: header.volumes,
            voxelSpacing: spacing,
            spacingUnit: spacingUnit,
            datatype: header.datatypeLabel ?? header.datatype.label,
            orientation: header.orientationFrame.map { $0.axes.map(\.letter).joined() },
            orientationSource: header.orientationFrame?.source.rawValue
        )
    }

    /// Reads just the header of the file at `url` and summarises it. Never reads
    /// the voxel payload: uncompressed kinds read a small prefix, gzipped kinds
    /// stream-inflate only until the header is complete. Text headers (MIF, NRRD)
    /// are capped at `MIQParser.maxTextHeaderBytes`.
    ///
    /// - Throws: `MIQError.unsupportedFileFormat` for an unrecognised extension,
    ///   or the format parser's error for a malformed / truncated header.
    public static func read(contentsOf url: URL) throws -> VolumeSummary {
        guard let kind = MIQFileKind(url: url) else { throw MIQError.unsupportedFileFormat }
        let parser = MIQParser()
        let prefix = try parser.readHeaderPrefix(url: url, kind: kind)
        let header = try parser.parseHeaderOnly(prefix: prefix, kind: kind)
        return VolumeSummary(header: header, kind: kind, spacingUnit: spacingUnit(kind: kind, header: header, prefix: prefix))
    }

    // MARK: - Output

    /// Pretty-printed (or compact) JSON with sorted keys, so the output is stable
    /// for diffing and scripting. `nil` optionals are omitted.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `"256 × 256 × 128"` — multiplication sign, matching the preview's Dimensions row.
    public var dimensionsText: String {
        dimensions.map(String.init).joined(separator: " \u{00D7} ")
    }

    /// `"1.00 × 1.00 × 1.20 mm"` (unit omitted when unknown).
    public var voxelSpacingText: String {
        let values = voxelSpacing.map { String(format: "%.2f", $0) }.joined(separator: " \u{00D7} ")
        return spacingUnit.map { "\(values) \($0)" } ?? values
    }

    /// Multi-line, human-readable `Label: value` summary for dialogs and CLIs.
    public var summaryText: String {
        var lines = [
            "Format: \(format)",
            "Dimensions: \(dimensionsText)",
            "Voxel spacing: \(voxelSpacingText)",
            "Datatype: \(datatype)",
            "Volumes: \(volumes)",
        ]
        if let orientation { lines.append("Orientation: \(orientation)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Units

    /// NIfTI `xyzt_units` spatial code → unit label. Codes per the NIfTI-1 spec:
    /// 1 = metre, 2 = millimetre, 3 = micron; 0 (unknown) and anything else → `nil`.
    static func niftiSpatialUnit(code: Int) -> String? {
        switch code & 0x07 {
        case 1: return "m"
        case 2: return "mm"
        case 3: return "\u{00B5}m"
        default: return nil
        }
    }

    private static func spacingUnit(kind: MIQFileKind, header: MIQHeader, prefix: Data) -> String? {
        switch kind {
        case .nii, .niiGz:
            // xyzt_units: NIfTI-1 `char` at byte 123; NIfTI-2 `int32` at byte 500.
            let isNifti2 = prefix.count >= 504
                && MIQBinaryReader.int32(prefix, 0, littleEndian: header.littleEndian) == 540
            if isNifti2 {
                return niftiSpatialUnit(code: Int(MIQBinaryReader.int32(prefix, 500, littleEndian: header.littleEndian)))
            }
            guard prefix.count > 123 else { return nil }
            return niftiSpatialUnit(code: Int(prefix[prefix.startIndex + 123]))
        case .mgh, .mgz, .mif, .mifGz:
            return "mm"
        case .nrrd, .zarr, .dicom:
            return nil
        }
    }
}

// MARK: - Header-only parsing

extension MIQParser {
    /// Upper bound on a text header (MIF / NRRD) read by the header-only path. Real
    /// headers are a few KB; MRtrix `command_history` lines can push that higher,
    /// so the cap is generous while still bounding a pathological file.
    public static let maxTextHeaderBytes = 4 * 1024 * 1024

    /// Parses only the header of the file at `url`, without reading the payload.
    /// See `VolumeSummary.read(contentsOf:)` for the I/O guarantees.
    public func parseHeaderOnly(url: URL) throws -> MIQHeader {
        guard let kind = MIQFileKind(url: url) else { throw MIQError.unsupportedFileFormat }
        // Zarr stores are directories and DICOM geometry can sit anywhere before
        // Pixel Data; neither has a bounded header prefix to read.
        if kind == .zarr || kind == .dicom {
            throw MIQError.unsupportedFeature("A header-only summary isn't available for \(kind.displayName)")
        }
        return try parseHeaderOnly(prefix: readHeaderPrefix(url: url, kind: kind), kind: kind)
    }

    func parseHeaderOnly(prefix: Data, kind: MIQFileKind) throws -> MIQHeader {
        try parseHeaderOnly(prefix, kind: kind)
    }

    /// Fixed header sizes: NIfTI-2's 540 bytes + 4-byte extension flag covers
    /// NIfTI-1's 348 as well; MGH's header is 284 bytes.
    private static let niftiHeaderPrefixBytes = 544
    private static let mghHeaderPrefixBytes = 284
    /// Read granularity for the header-only path — small, since typical headers
    /// are well under this.
    private static let headerReadChunkBytes = 16 * 1024

    /// Reads (and for gzipped kinds, inflates) just enough of the file to contain
    /// its header. A file shorter than the header yields what exists; the format
    /// parser then reports it as truncated.
    func readHeaderPrefix(url: URL, kind: MIQFileKind) throws -> Data {
        let isComplete = Self.headerCompleteness(for: kind)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if kind.isCompressed {
            return try MIQBinaryReader.gunzip(from: handle, inputChunkBytes: Self.headerReadChunkBytes) { produced in
                isComplete(produced) || produced.count >= Self.maxTextHeaderBytes
            }
        }

        var data = Data()
        while !isComplete(data), data.count < Self.maxTextHeaderBytes {
            guard let chunk = try handle.read(upToCount: Self.headerReadChunkBytes), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    /// Predicate deciding when a prefix holds the whole header for `kind`.
    private static func headerCompleteness(for kind: MIQFileKind) -> (Data) -> Bool {
        switch kind {
        case .nii, .niiGz:
            return { $0.count >= niftiHeaderPrefixBytes }
        case .mgh, .mgz:
            return { $0.count >= mghHeaderPrefixBytes }
        case .mif, .mifGz:
            let marker = Data("\nEND".utf8)
            return { $0.range(of: marker) != nil }
        case .nrrd:
            let lf = Data("\n\n".utf8)
            let crlf = Data("\n\r\n".utf8)
            return { $0.range(of: lf) != nil || $0.range(of: crlf) != nil }
        case .zarr, .dicom:
            return { _ in true } // rejected in `parseHeaderOnly(url:)` before reading
        }
    }
}
