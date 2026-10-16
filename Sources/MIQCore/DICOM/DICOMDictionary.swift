import Foundation

/// A DICOM data element tag `(gggg,eeee)`.
struct DICOMTag: Hashable, Sendable, CustomStringConvertible {
    let group: UInt16
    let element: UInt16

    init(_ group: UInt16, _ element: UInt16) {
        self.group = group
        self.element = element
    }

    var description: String { String(format: "(%04X,%04X)", group, element) }

    // MARK: File meta (group 0002, always explicit VR little endian)

    static let transferSyntaxUID = DICOMTag(0x0002, 0x0010)

    // MARK: Technical, display-safe

    static let modality = DICOMTag(0x0008, 0x0060)
    static let sliceThickness = DICOMTag(0x0018, 0x0050)
    static let kvp = DICOMTag(0x0018, 0x0060)
    static let repetitionTime = DICOMTag(0x0018, 0x0080)
    static let echoTime = DICOMTag(0x0018, 0x0081)
    static let magneticFieldStrength = DICOMTag(0x0018, 0x0087)
    static let spacingBetweenSlices = DICOMTag(0x0018, 0x0088)
    static let convolutionKernel = DICOMTag(0x0018, 0x1210)
    static let imagePositionPatient = DICOMTag(0x0020, 0x0032)
    static let imageOrientationPatient = DICOMTag(0x0020, 0x0037)
    static let samplesPerPixel = DICOMTag(0x0028, 0x0002)
    static let photometricInterpretation = DICOMTag(0x0028, 0x0004)
    static let planarConfiguration = DICOMTag(0x0028, 0x0006)
    static let numberOfFrames = DICOMTag(0x0028, 0x0008)
    static let rows = DICOMTag(0x0028, 0x0010)
    static let columns = DICOMTag(0x0028, 0x0011)
    static let pixelSpacing = DICOMTag(0x0028, 0x0030)
    static let bitsAllocated = DICOMTag(0x0028, 0x0100)
    static let bitsStored = DICOMTag(0x0028, 0x0101)
    static let highBit = DICOMTag(0x0028, 0x0102)
    static let pixelRepresentation = DICOMTag(0x0028, 0x0103)
    static let rescaleIntercept = DICOMTag(0x0028, 0x1052)
    static let rescaleSlope = DICOMTag(0x0028, 0x1053)

    // MARK: Internal-only (grouping; never displayed or logged)

    static let seriesInstanceUID = DICOMTag(0x0020, 0x000E)

    // MARK: Sequences the reader descends into (enhanced multi-frame geometry)

    static let sharedFunctionalGroups = DICOMTag(0x5200, 0x9229)
    static let perFrameFunctionalGroups = DICOMTag(0x5200, 0x9230)
    static let planePositionSequence = DICOMTag(0x0020, 0x9113)
    static let planeOrientationSequence = DICOMTag(0x0020, 0x9116)
    static let pixelMeasuresSequence = DICOMTag(0x0028, 0x9110)
    static let pixelValueTransformationSequence = DICOMTag(0x0028, 0x9145)

    // MARK: Structural

    static let item = DICOMTag(0xFFFE, 0xE000)
    static let itemDelimitation = DICOMTag(0xFFFE, 0xE00D)
    static let sequenceDelimitation = DICOMTag(0xFFFE, 0xE0DD)
    static let pixelData = DICOMTag(0x7FE0, 0x0010)
}

/// How an allowlisted value's bytes are decoded. Equals the tag's dictionary VR, which
/// the decoder uses in both explicit and implicit transfer syntaxes (an allowlisted tag
/// is always encoded with its dictionary VR; a writer emitting `UN` for one simply
/// leaves that field undecodable).
enum DICOMValueKind: Sendable {
    /// `US` — unsigned 16-bit binary.
    case unsignedShort
    /// `DS` — decimal string, backslash-separated multi-value.
    case decimalString
    /// `IS` — integer string.
    case integerString
    /// `CS`/`SH`/`UI` — short ASCII code string.
    case codeString
}

/// PRIVACY BOUNDARY.
///
/// The DICOM reader never turns a data element's bytes into a value unless its tag is
/// listed here: every other element — the whole patient group (0010,xxxx), study and
/// accession identifiers, institution, physicians and operators, dates and times,
/// descriptions, and every UID except the two below — is skipped by its length and
/// never decoded, copied, stored or logged. Adding a tag here is a privacy decision:
/// only purely technical acquisition / pixel-format fields belong in this list.
///
/// Two UIDs are present for internal use only: the transfer syntax (mapped to a
/// standard name, never shown raw) and `SeriesInstanceUID`, which is used solely to
/// group sibling files in `DICOMSeriesAssembler` and is held in a `DICOMRedactedUID`
/// whose descriptions and mirror never reveal it.
enum DICOMAllowlist {
    static let values: [DICOMTag: DICOMValueKind] = [
        .transferSyntaxUID: .codeString,
        .modality: .codeString,
        .sliceThickness: .decimalString,
        .kvp: .decimalString,
        .repetitionTime: .decimalString,
        .echoTime: .decimalString,
        .magneticFieldStrength: .decimalString,
        .spacingBetweenSlices: .decimalString,
        .convolutionKernel: .codeString,
        .imagePositionPatient: .decimalString,
        .imageOrientationPatient: .decimalString,
        .samplesPerPixel: .unsignedShort,
        .photometricInterpretation: .codeString,
        .planarConfiguration: .unsignedShort,
        .numberOfFrames: .integerString,
        .rows: .unsignedShort,
        .columns: .unsignedShort,
        .pixelSpacing: .decimalString,
        .bitsAllocated: .unsignedShort,
        .bitsStored: .unsignedShort,
        .highBit: .unsignedShort,
        .pixelRepresentation: .unsignedShort,
        .rescaleIntercept: .decimalString,
        .rescaleSlope: .decimalString,
        .seriesInstanceUID: .codeString,
    ]

    /// Sequences whose items are parsed (collecting only `values` tags inside them).
    /// Every other sequence is walked only far enough to find its end.
    static let sequences: Set<DICOMTag> = [
        .sharedFunctionalGroups,
        .perFrameFunctionalGroups,
        .planePositionSequence,
        .planeOrientationSequence,
        .pixelMeasuresSequence,
        .pixelValueTransformationSequence,
    ]

    /// Longest allowlisted value the reader records. Every allowlisted VR is short
    /// (≤ 64 bytes per value); the cap only stops a crafted file from pointing a
    /// "Rows" element at megabytes of payload.
    static let maxValueLength = 1024
}

/// Opaque holder for a UID used only for in-process grouping. Its textual and
/// reflected forms are fixed placeholders, so neither `print`, string interpolation,
/// `dump` nor a debugger summary can surface the identifier.
struct DICOMRedactedUID: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    init(_ value: String) { self.value = value }

    var description: String { "<redacted UID>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The two transfer syntaxes MIQ decodes. Everything else is rejected with a
/// user-presentable `MIQError.unsupportedFeature` reason.
enum DICOMTransferSyntax: Sendable, Equatable {
    case implicitVRLittleEndian
    case explicitVRLittleEndian

    var isExplicitVR: Bool { self == .explicitVRLittleEndian }

    var displayName: String {
        switch self {
        case .implicitVRLittleEndian: return "Implicit VR Little Endian"
        case .explicitVRLittleEndian: return "Explicit VR Little Endian"
        }
    }

    /// Maps a transfer syntax UID to a decodable syntax, or throws an error whose
    /// `unsupportedFeature` reason is short enough for the preview's error view
    /// (e.g. "Compressed DICOM (JPEG 2000) isn't supported yet"). The UID itself is
    /// never echoed into the message.
    static func resolve(uid: String) throws -> DICOMTransferSyntax {
        switch uid {
        case "1.2.840.10008.1.2":
            return .implicitVRLittleEndian
        case "1.2.840.10008.1.2.1":
            return .explicitVRLittleEndian
        case "1.2.840.10008.1.2.2":
            throw MIQError.unsupportedFeature("Big-endian DICOM (Explicit VR Big Endian, retired) isn't supported")
        default:
            if let name = compressedName(uid: uid) {
                throw MIQError.unsupportedFeature("Compressed DICOM (\(name)) isn't supported yet")
            }
            throw MIQError.unsupportedFeature("This DICOM transfer syntax isn't supported")
        }
    }

    /// Human-readable family name for an encapsulated / compressed transfer syntax.
    static func compressedName(uid: String) -> String? {
        switch uid {
        case "1.2.840.10008.1.2.1.99": return "Deflate"
        case "1.2.840.10008.1.2.1.98": return "encapsulated uncompressed"
        case "1.2.840.10008.1.2.5": return "RLE"
        case "1.2.840.10008.1.2.4.50", "1.2.840.10008.1.2.4.51": return "JPEG"
        case "1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70": return "JPEG Lossless"
        case "1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81": return "JPEG-LS"
        case "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91",
             "1.2.840.10008.1.2.4.92", "1.2.840.10008.1.2.4.93": return "JPEG 2000"
        case "1.2.840.10008.1.2.4.201", "1.2.840.10008.1.2.4.202",
             "1.2.840.10008.1.2.4.203": return "HTJ2K"
        case "1.2.840.10008.1.2.4.110", "1.2.840.10008.1.2.4.111",
             "1.2.840.10008.1.2.4.112": return "JPEG XL"
        default:
            if uid.hasPrefix("1.2.840.10008.1.2.4.10") { return "MPEG video" }
            if uid.hasPrefix("1.2.840.10008.1.2.4.") { return "JPEG family" }
            return nil
        }
    }
}
