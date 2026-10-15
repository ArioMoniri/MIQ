import Foundation

extension CaptionPrompt {
    /// Builds the caption metadata for the file at `url` from its header alone —
    /// the voxel payload is never read or decompressed (see
    /// `MIQParser.parseHeaderOnly(url:maxBytes:)` for the I/O bound). Produces the same
    /// dictionary as `metadata(header:format:orientation:)` fed from a full
    /// parse, so the caption is identical whichever path built it.
    ///
    /// The orientation code is taken from the header's orientation frame, which is
    /// what `MIQVolume.storageOrientationLabel()` reports for the same file.
    ///
    /// - Throws: `MIQError.unsupportedFileFormat` for an unrecognised extension,
    ///   `MIQError.unsupportedFeature` for kinds without a bounded header (Zarr,
    ///   DICOM) — callers fall back to a full parse — or the format parser's error.
    public static func headerOnlyMetadata(url: URL) throws -> [String: String] {
        guard let kind = MIQFileKind(url: url) else { throw MIQError.unsupportedFileFormat }
        let header = try MIQParser().parseHeaderOnly(url: url)
        return metadata(
            header: header,
            format: header.formatLabel ?? kind.displayName,
            orientation: header.orientationFrame.map { $0.axes.map(\.letter).joined() }
        )
    }
}
