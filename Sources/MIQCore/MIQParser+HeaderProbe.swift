import Foundation

// MARK: - Header-only parsing

extension MIQParser {
    /// Small prefix cap for latency-sensitive callers that only need a size
    /// estimate (the thumbnail extension's decode-budget check and
    /// `MIQColdPreviewGate`). Every binary header fits (NIfTI ≤ 540 B, MGH 284 B),
    /// and MIF/NRRD/MetaImage text headers are a few KB in practice. A text header
    /// longer than this fails the read, which those callers treat as "size unknown".
    public static let headerProbeCap = 64 * 1024

    /// Generous cap for callers that summarise a file (Spotlight, captions, App
    /// Intents, `miq info`). Real headers are a few KB; MRtrix `command_history`
    /// lines can push that higher, so the cap is generous while still bounding a
    /// pathological file. Also bounds the MetaImage text-header scan.
    public static let maxTextHeaderBytes = 4 * 1024 * 1024

    /// Parses only the header of the file at `url`, without reading or
    /// decompressing the voxel payload. Uncompressed kinds read in small chunks
    /// until the header is complete; gzipped kinds stream-inflate only until it is.
    /// Either way at most about `maxBytes` of (decompressed) prefix is produced —
    /// a gzip stream may overshoot by one inflate chunk — and a header longer than
    /// that throws as truncated.
    ///
    /// This is the single header-only reader: the thumbnail extension and the cold
    /// preview gate pass `headerProbeCap`; Spotlight, captions, App Intents and
    /// the CLI use the default `maxTextHeaderBytes` (via `VolumeSummary`).
    ///
    /// - Parameter maxBytes: Prefix cap (clamped to at least 1 byte).
    /// - Throws: `MIQError.unsupportedFileFormat` for an unrecognised extension,
    ///   `MIQError.unsupportedFeature` for Zarr stores and DICOM (no bounded header
    ///   prefix), the format parser's error for a malformed / truncated header, or
    ///   an I/O error. The returned header's `voxOffset` is meaningful only for
    ///   size estimates; a detached header's data file is never opened.
    public func parseHeaderOnly(url: URL, maxBytes: Int = MIQParser.maxTextHeaderBytes) throws -> MIQHeader {
        try parseHeaderOnlyWithPrefix(url: url, maxBytes: maxBytes).header
    }

    /// `parseHeaderOnly(url:maxBytes:)` plus the kind and the prefix it parsed, for
    /// callers that read further fixed-offset fields (NIfTI `xyzt_units` in
    /// `VolumeSummary`).
    func parseHeaderOnlyWithPrefix(url: URL, maxBytes: Int) throws -> (header: MIQHeader, kind: MIQFileKind, prefix: Data) {
        guard let kind = MIQFileKind(url: url) else { throw MIQError.unsupportedFileFormat }
        // Zarr stores are directories (their metadata is JSON spread over several
        // files, and the preview read is already capped by `zarrMaxPreviewBytes`),
        // and DICOM geometry can sit anywhere before Pixel Data; neither has a
        // bounded header prefix to read.
        if kind == .zarr || kind == .dicom {
            throw MIQError.unsupportedFeature("A header-only read isn't available for \(kind.displayName)")
        }
        let prefix = try readHeaderPrefix(url: url, kind: kind, maxBytes: maxBytes)
        return (try parseHeaderOnly(prefix, kind: kind), kind, prefix)
    }

    /// Header-only parse of an in-memory (decompressed) prefix. `internal` for tests.
    func parseHeaderOnly(_ prefix: Data, kind: MIQFileKind) throws -> MIQHeader {
        switch kind {
        case .nii, .niiGz:
            return try parseNiftiHeader(from: prefix, compressed: kind.isCompressed)
        case .mgh, .mgz:
            return try parseMghHeader(from: prefix)
        case .mif, .mifGz, .mih:
            return try parseMifHeaderOnly(from: prefix)
        case .nrrd, .nhdr:
            // A detached header's data file is never opened here.
            return try parseNrrdHeaderOnly(from: prefix)
        case .mha, .mhd:
            return try parseMetaImageHeaderOnly(from: prefix)
        case .zarr, .dicom:
            throw MIQError.unsupportedFeature("A header-only read isn't available for \(kind.displayName)")
        }
    }

    /// Fixed header sizes: NIfTI-2's 540 bytes + 4-byte extension flag covers
    /// NIfTI-1's 348 as well; MGH's header is 284 bytes.
    private static let niftiHeaderPrefixBytes = 544
    private static let mghHeaderPrefixBytes = 284
    /// Read granularity for the header-only path — small, since typical headers
    /// are well under this.
    private static let headerReadChunkBytes = 16 * 1024

    /// Reads (and for gzipped kinds, inflates) just enough of the file to contain
    /// its header, stopping at `maxBytes`. A file shorter than the header yields
    /// what exists; the format parser then reports it as truncated.
    func readHeaderPrefix(url: URL, kind: MIQFileKind, maxBytes: Int) throws -> Data {
        let cap = Swift.max(1, maxBytes)
        let isComplete = Self.headerCompleteness(for: kind)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if kind.isCompressed {
            return try MIQBinaryReader.gunzip(from: handle, inputChunkBytes: Self.headerReadChunkBytes) { produced in
                isComplete(produced) || produced.count >= cap
            }
        }

        var data = Data()
        while !isComplete(data), data.count < cap {
            let want = Swift.min(Self.headerReadChunkBytes, cap - data.count)
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
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
        case .mif, .mifGz, .mih:
            let marker = Data("\nEND".utf8)
            return { $0.range(of: marker) != nil }
        case .nrrd:
            let lf = Data("\n\n".utf8)
            let crlf = Data("\n\r\n".utf8)
            return { $0.range(of: lf) != nil || $0.range(of: crlf) != nil }
        case .nhdr, .mhd:
            // The whole (small) file is header: read to EOF, capped by the caller.
            return { _ in false }
        case .mha:
            // `ElementDataFile` is the last header line; complete once its newline is in.
            let key = Data("ElementDataFile".utf8)
            return { data in
                guard let hit = data.range(of: key) else { return false }
                return data[hit.upperBound...].contains(0x0A)
            }
        case .zarr, .dicom:
            return { _ in true } // rejected in `parseHeaderOnlyWithPrefix` before reading
        }
    }
}
