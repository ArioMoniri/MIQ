import Foundation

/// Acquisition parameters from a BIDS sidecar beside an image: `<stem>.json`
/// and `<stem>.bval`, where `<stem>` is the image name minus its format suffix
/// (`sub-01_dwi.nii.gz` → `sub-01_dwi`).
///
/// Privacy: only an explicit allowlist of acquisition keys is ever read out of
/// the JSON (`allowedKeys`). Everything else — and BIDS sidecars converted from
/// DICOM can carry `PatientName`, `PatientBirthDate`, `InstitutionName`,
/// `SeriesDescription`, `AcquisitionDateTime`, device serial numbers... — is
/// dropped at parse time and never stored. String values are length-capped and
/// stripped of control characters.
///
/// Robustness: every failure (no sidecar, sandbox denial, oversized file,
/// malformed JSON, wrong value types) is silent — `load` returns `nil` or omits
/// the field. Files over `maxFileBytes` are not read. Only the image's own
/// directory is consulted; BIDS inheritance from parent-level sidecars is not
/// resolved.
public struct SidecarMetadata: Sendable, Equatable {
    /// Seconds.
    public var repetitionTime: Double?
    /// Seconds.
    public var echoTime: Double?
    /// Seconds.
    public var inversionTime: Double?
    /// Degrees.
    public var flipAngle: Double?
    /// Tesla.
    public var magneticFieldStrength: Double?
    /// BIDS axis code: "i", "j", "k", optionally suffixed "-".
    public var phaseEncodingDirection: String?
    /// Millimetres.
    public var sliceThickness: Double?
    public var taskName: String?
    /// "2D" / "3D".
    public var mrAcquisitionType: String?
    /// From `<stem>.bval`: one b-value (s/mm²) per volume.
    public var bValues: [Double]?

    public init() {}

    /// The only JSON keys ever read. Deliberately acquisition physics only —
    /// no descriptive free text (`SeriesDescription`, `ProtocolName`), no site /
    /// device / person / date fields.
    public static let allowedKeys: [String] = [
        "RepetitionTime",
        "EchoTime",
        "InversionTime",
        "FlipAngle",
        "MagneticFieldStrength",
        "PhaseEncodingDirection",
        "SliceThickness",
        "TaskName",
        "MRAcquisitionType",
    ]

    /// Sidecars above this size are ignored (real ones are a few KB; the cap
    /// bounds the cost of a stray large `.json` in the preview path).
    public static let maxFileBytes = 1024 * 1024
    private static let maxStringLength = 64

    /// Recognised image suffixes, longest first so `.nii.gz` wins over `.gz`.
    static let imageSuffixes = [".nii.gz", ".mif.gz", ".mgh.gz", ".nii", ".mgz", ".mgh", ".mif", ".nrrd", ".nhdr"]

    /// The image's name without its format suffix, or `nil` for an unrecognised one.
    public static func stem(of imageURL: URL) -> String? {
        let name = imageURL.lastPathComponent
        let lower = name.lowercased()
        for suffix in imageSuffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// Reads `<stem>.json` and `<stem>.bval` beside `imageURL`. `nil` when
    /// neither yields anything (including when they cannot be read).
    public static func load(forImageAt imageURL: URL) -> SidecarMetadata? {
        guard let stem = stem(of: imageURL) else { return nil }
        let directory = imageURL.deletingLastPathComponent()
        var sidecar = readCapped(directory.appendingPathComponent(stem + ".json"))
            .flatMap(parse(jsonData:)) ?? SidecarMetadata()
        if let bvalData = readCapped(directory.appendingPathComponent(stem + ".bval")) {
            sidecar.bValues = parseBval(String(decoding: bvalData, as: UTF8.self))
        }
        return sidecar == SidecarMetadata() ? nil : sidecar
    }

    /// Reads at most `maxFileBytes`; a larger (or unreadable) file yields `nil`.
    private static func readCapped(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1),
              !data.isEmpty, data.count <= maxFileBytes else { return nil }
        return data
    }

    /// Parses sidecar JSON, keeping only `allowedKeys`. `nil` for malformed JSON
    /// or a non-object top level.
    public static func parse(jsonData: Data) -> SidecarMetadata? {
        guard jsonData.count <= maxFileBytes,
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dictionary = object as? [String: Any] else { return nil }
        var sidecar = SidecarMetadata()
        sidecar.repetitionTime = number(dictionary["RepetitionTime"])
        sidecar.echoTime = number(dictionary["EchoTime"])
        sidecar.inversionTime = number(dictionary["InversionTime"])
        sidecar.flipAngle = number(dictionary["FlipAngle"])
        sidecar.magneticFieldStrength = number(dictionary["MagneticFieldStrength"])
        sidecar.sliceThickness = number(dictionary["SliceThickness"])
        sidecar.phaseEncodingDirection = string(dictionary["PhaseEncodingDirection"])
        sidecar.taskName = string(dictionary["TaskName"])
        sidecar.mrAcquisitionType = string(dictionary["MRAcquisitionType"])
        return sidecar
    }

    /// A finite, non-negative JSON number. Booleans are rejected: Darwin's
    /// `JSONSerialization` hands them back as `NSNumber` (objCType "c"), where a
    /// plain `is Bool` test would also match the numbers 0 and 1.
    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let double: Double?
        if let n = value as? NSNumber {
            guard String(cString: n.objCType) != "c" else { return nil }
            double = n.doubleValue
        } else if let n = value as? Double {
            double = n
        } else if let n = value as? Int {
            double = Double(n)
        } else {
            double = nil
        }
        guard let double, double.isFinite, double >= 0 else { return nil }
        return double
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let cleaned = String(raw.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxStringLength))
    }

    /// Parses FSL-style `.bval` text: whitespace-separated numbers on one line
    /// (or, from some tools, one per line). `nil` if any token is not a finite
    /// number, or there are none.
    public static func parseBval(_ text: String) -> [Double]? {
        var values: [Double] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let value = Double(token), value.isFinite else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    /// One-line summary of the allowlisted parameters, e.g.
    /// "TR 2 s · TE 30 ms · FA 90° · 3 T · PE j- · task rest". `nil` when the
    /// sidecar holds none (b-values are summarised by the `.diffusion` row).
    public func summary() -> String? {
        var parts: [String] = []
        if let tr = repetitionTime { parts.append("TR \(MIQMetadata.formatSeconds(tr))") }
        if let te = echoTime { parts.append("TE \(MIQMetadata.formatMilliseconds(te))") }
        if let ti = inversionTime { parts.append("TI \(MIQMetadata.formatMilliseconds(ti))") }
        if let fa = flipAngle { parts.append("FA \(MIQMetadata.formatNumber(fa))\u{00B0}") }
        if let field = magneticFieldStrength { parts.append("\(MIQMetadata.formatNumber(field)) T") }
        if let type = mrAcquisitionType { parts.append(type) }
        if let pe = phaseEncodingDirection { parts.append("PE \(pe)") }
        if let thickness = sliceThickness { parts.append("slice \(MIQMetadata.formatNumber(thickness)) mm") }
        if let task = taskName { parts.append("task \(task)") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Relative tolerance for header/sidecar agreement.
    static let consistencyTolerance = 0.01

    /// Disagreements between the sidecar and the image header, as display
    /// strings. Currently: TR (sidecar `RepetitionTime` vs NIfTI `pixdim[4]` /
    /// MGH TR) differing by more than 1 %, and a `.bval` whose count differs from
    /// the image's volume count.
    public func consistencyWarnings(against header: MIQHeader) -> [String] {
        var warnings: [String] = []
        if let sidecarTR = repetitionTime, sidecarTR > 0,
           let headerTR = header.acquisition.repetitionTime, headerTR > 0,
           abs(sidecarTR - headerTR) / sidecarTR > Self.consistencyTolerance {
            warnings.append(
                "\u{26A0} TR mismatch: sidecar \(MIQMetadata.formatSeconds(sidecarTR)), header \(MIQMetadata.formatSeconds(headerTR))"
            )
        }
        if let bValues, bValues.count != header.volumes {
            warnings.append("\u{26A0} .bval has \(bValues.count) entries for \(header.volumes) volumes")
        }
        return warnings
    }
}
