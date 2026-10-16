import Foundation

/// Display-safe technical summary of a DICOM file, built exclusively from the tags in
/// `DICOMAllowlist` (no patient, study, institution, operator, date/time, description
/// or UID fields — those are never decoded in the first place).
///
/// Shown by the preview alongside the standard `MIQMetadata` rows; see
/// `displayEntries`. Every string field is sanitised to short printable ASCII.
public struct DICOMTechnicalInfo: Sendable, Equatable {
    /// Standard name of the transfer syntax, e.g. "Explicit VR Little Endian".
    public let transferSyntaxName: String
    /// Modality code (CT, MR, PT, …).
    public let modality: String?
    public let rows: Int
    public let columns: Int
    /// Frames in the file (or slices, for an assembled series).
    public let numberOfFrames: Int
    public let samplesPerPixel: Int
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let photometricInterpretation: String
    /// `[row spacing, column spacing]` in mm, as stored (DICOM order).
    public let pixelSpacing: [Double]?
    public let sliceThickness: Double?
    public let spacingBetweenSlices: Double?
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    /// Tesla.
    public let magneticFieldStrength: Double?
    /// Milliseconds.
    public let repetitionTime: Double?
    /// Milliseconds.
    public let echoTime: Double?
    public let kvp: Double?
    public let convolutionKernel: String?
    /// Human-readable caveats about how the geometry was derived (unknown
    /// orientation, assumed spacing, …). Empty when everything came from the file.
    public let geometryNotes: [String]

    // Built only by the DICOM parser inside MIQCore, through the synthesized
    // (internal) memberwise initializer; consumers read the fields.

    /// Rows for the metadata panel (all with `field == nil`), in display order. Only
    /// fields present in the file are listed; dimensions, spacing, datatype and
    /// scaling are already covered by `MIQMetadata` and are not repeated.
    public var displayEntries: [MetadataEntry] {
        var entries: [MetadataEntry] = []
        func add(_ label: String, _ value: String?) {
            if let value { entries.append(MetadataEntry(field: nil, label: label, value: value)) }
        }
        add("Modality", modality)
        add("Transfer Syntax", transferSyntaxName)
        add("Photometric", photometricInterpretation)
        add("Bits", bitsStored == bitsAllocated ? "\(bitsAllocated)" : "\(bitsStored) of \(bitsAllocated)")
        if numberOfFrames > 1 { add("Frames", "\(numberOfFrames)") }
        add("Slice Thickness", sliceThickness.map { Self.format($0) + " mm" })
        add("Slice Spacing", spacingBetweenSlices.map { Self.format($0) + " mm" })
        add("Field Strength", magneticFieldStrength.map { Self.format($0) + " T" })
        add("TR", repetitionTime.map { Self.format($0) + " ms" })
        add("TE", echoTime.map { Self.format($0) + " ms" })
        add("kVp", kvp.map { Self.format($0) })
        add("Kernel", convolutionKernel)
        for note in geometryNotes { add("Note", note) }
        return entries
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    /// Restricts an allowlisted code-string value to a short run of printable ASCII.
    static func sanitizedCode(_ value: String?, maxLength: Int = 16) -> String? {
        guard let value else { return nil }
        let filtered = value.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
        let text = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(maxLength))
    }
}
