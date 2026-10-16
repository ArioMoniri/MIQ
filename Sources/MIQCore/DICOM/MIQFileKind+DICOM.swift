import Foundation

extension MIQFileKind {
    /// Content sniff for DICOM files whose name doesn't carry `.dcm`/`.dicom` (common:
    /// PACS exports are often extensionless, e.g. `IM000123`). Reads only the first 132
    /// bytes and requires the Part-10 `DICM` marker at offset 128. `nil` when the file
    /// can't be read or isn't Part-10.
    ///
    /// Quick Look routes by UTI, which macOS derives from the extension, so an
    /// extensionless file normally never reaches the preview extension; this is for
    /// the host app (Open With / drag-and-drop) and for `MIQParser.parse(url:)`'s
    /// fallback when the extension is unknown.
    public static func sniffDICOM(url: URL) -> MIQFileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: DICOMReader.preambleLength + 4) else { return nil }
        return isDICOMPart10(prefix) ? .dicom : nil
    }

    /// `true` when `prefix` (the first ≥ 132 bytes of a file) has the DICOM Part-10
    /// `DICM` marker at offset 128.
    static func isDICOMPart10(_ prefix: Data) -> Bool {
        DICOMReader.hasPart10Marker(prefix)
    }
}
