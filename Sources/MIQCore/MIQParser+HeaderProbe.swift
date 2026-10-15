import Foundation

extension MIQParser {
    /// Prefix read (or, for gzip kinds, decompressed) by `probeHeader`. Every
    /// supported header fits: NIfTI ≤ 540 B, MGH 284 B, and the MIF/NRRD text
    /// headers are a few KB in practice. A text header longer than this fails the
    /// probe, which callers treat as "size unknown".
    static let headerOnlyProbeBytes = 64 * 1024

    /// Parses only the header of `url`, without reading or decompressing the
    /// payload: at most `headerOnlyProbeBytes` of (decompressed) prefix. Lets a
    /// caller estimate the decoded size (`MIQHeader.estimatedPayloadBytes`) and
    /// decline a file before committing to a full gunzip.
    ///
    /// Throws for an unsupported extension, a malformed header, or an I/O error.
    /// The returned header's `voxOffset` is meaningful only for size estimates.
    public func probeHeader(url: URL) throws -> MIQHeader {
        guard let kind = MIQFileKind(url: url) else {
            throw MIQError.unsupportedFileFormat
        }
        // A Zarr store is a directory: its "header" is JSON metadata spread over
        // several files, and the preview read is already capped by
        // `zarrMaxPreviewBytes`, so there is no prefix to probe.
        if kind == .zarr {
            throw MIQError.unsupportedFeature("Header-only probe isn't available for Zarr stores")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let prefix: Data
        if kind.isCompressed {
            prefix = try MIQBinaryReader.gunzip(from: handle, inputChunkBytes: 16 * 1024) { produced in
                produced.count >= Self.headerOnlyProbeBytes
            }
        } else {
            prefix = try handle.read(upToCount: Self.headerOnlyProbeBytes) ?? Data()
        }
        return try parseHeaderOnly(prefix, kind: kind)
    }

    /// Header-only parse of an in-memory (decompressed) prefix. `internal` for tests.
    func parseHeaderOnly(_ prefix: Data, kind: MIQFileKind) throws -> MIQHeader {
        switch kind {
        case .nii, .niiGz:
            return try parseNiftiHeader(from: prefix, compressed: kind.isCompressed)
        case .mgh, .mgz:
            return try parseMghHeader(from: prefix)
        case .mif, .mifGz:
            return try parseMifHeaderOnly(from: prefix)
        case .nrrd:
            return try parseNrrdHeaderOnly(from: prefix)
        case .zarr:
            throw MIQError.unsupportedFeature("Header-only probe isn't available for Zarr stores")
        }
    }
}
