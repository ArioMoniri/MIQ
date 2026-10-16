import Foundation

/// The metadata panel's configurable rows.
///
/// Case order is the canonical display order and is load-bearing for stored
/// settings: `MIQConfig.parseMetadataOrder` appends every case missing from a
/// saved order in `allCases` order, so new cases go at the end — a user's saved
/// order then decodes unchanged with the new rows appended after it.
public enum MetadataField: String, Sendable, CaseIterable {
    case format
    case dimensions
    case spacing
    case orientation
    case datatype
    case volumes
    case scaling
    /// Live intensity at the crosshair voxel. Unlike every other field this is
    /// not derived from the header at parse time — it is injected by the preview
    /// only while the user is interacting (the crosshair is visible) and its
    /// value updates per cursor move. It therefore never appears in
    /// `asDisplayLines()`; the preview reserves its slot and draws the value.
    case value
    /// Repetition time (NIfTI `pixdim[4]` with `xyzt_units`, MGH tail TR), plus
    /// TE / TI / flip angle where the format carries them (MGH).
    case repetitionTime
    /// NIfTI `intent_code` as a human name ("Label", "t-statistic (dof 25)").
    /// Hidden for `NIFTI_INTENT_NONE`.
    case intent
    /// b-value shell summary from a MIF `dw_scheme` or a `.bval` sidecar.
    case diffusion
    /// Allowlisted BIDS sidecar acquisition parameters (see `SidecarMetadata`).
    case sidecar
    /// Live crosshair position: voxel indices plus world coordinates. Like
    /// `.value`, injected by the preview (see `MIQMetadata.formatVoxelPosition`)
    /// and never part of `asDisplayLines()`.
    case voxelPosition
    /// NIfTI `descrip` (and `intent_name`): free text that scanners and
    /// converters sometimes fill with identifying details. Default OFF.
    case description
    /// MIF `command_history` (last command) / NIfTI header-extension list.
    /// Command lines can embed paths with subject identifiers. Default OFF.
    case provenance

    /// Row label shown in the panel and in Settings.
    public var displayLabel: String {
        switch self {
        case .format:         return "Format"
        case .dimensions:     return "Dimensions"
        case .spacing:        return "Spacing"
        case .orientation:    return "Orientation"
        case .datatype:       return "Datatype"
        case .volumes:        return "Volumes"
        case .scaling:        return "Scaling"
        case .value:          return "Voxel value"
        case .repetitionTime: return "TR"
        case .intent:         return "Intent"
        case .diffusion:      return "Diffusion"
        case .sidecar:        return "BIDS"
        case .voxelPosition:  return "Position"
        case .description:    return "Description"
        case .provenance:     return "Provenance"
        }
    }

    /// True for rows that can carry free text written by a scanner, converter or
    /// user, and so may contain protected health information. These default OFF.
    public var mayContainPHI: Bool {
        switch self {
        case .description, .provenance: return true
        default: return false
        }
    }
}

/// One metadata row. Split, because the preview's two-column panel needs each
/// label's rendered width; `text` is the joined form.
public struct MetadataEntry: Sendable {
    public let field: MetadataField?
    public let label: String
    public let value: String

    public var text: String {
        label.isEmpty ? value : "\(label): \(value)"
    }

    public init(field: MetadataField?, label: String, value: String) {
        self.field = field
        self.label = label
        self.value = value
    }
}

public struct MIQMetadata: Sendable {
    public let dimensions: String
    public let spacing: String
    public let datatype: String
    public let volumes: Int
    public let sclSlope: Float
    public let sclInter: Float
    public let orientation: String?
    /// `.repetitionTime` row text, `nil` when the header carries no TR.
    public let repetitionTime: String?
    /// `.intent` row text, `nil` for no intent.
    public let intent: String?
    /// `.description` row text (descrip + intent_name), `nil` when both are empty.
    public let descriptionText: String?
    /// `.diffusion` row text: the header's diffusion scheme, else the sidecar `.bval`.
    public let diffusion: String?
    /// `.provenance` row text.
    public let provenance: String?
    /// `.sidecar` row text, including any header/sidecar consistency warning.
    public let sidecarSummary: String?

    /// Multiplication sign, not the letter x.
    private static let separator = "\u{00D7}"

    /// - Parameters:
    ///   - sidecar: BIDS sidecar data found beside the image
    ///     (`SidecarMetadata.load(forImageAt:)`), if the caller looked for one.
    ///   - sidecarWarningsInRow: whether the `.sidecar` row also carries the
    ///     header/sidecar consistency warnings. The preview passes `false` and
    ///     shows `MIQMetadata.panelWarnings(header:sidecar:)` as always-visible
    ///     warning lines instead, so a hidden BIDS row cannot hide a mismatch.
    public init(
        header: MIQHeader,
        orientation: String? = nil,
        sidecar: SidecarMetadata? = nil,
        sidecarWarningsInRow: Bool = true
    ) {
        let sep = " \(Self.separator) "
        dimensions = "\(header.width)\(sep)\(header.height)\(sep)\(header.depth)"

        let x = header.pixdim[safe: 1] ?? 1
        let y = header.pixdim[safe: 2] ?? 1
        let z = header.pixdim[safe: 3] ?? 1
        let acquisition = header.acquisition
        // An unknown (or absent) spatial unit keeps the historical "mm": NIfTI's
        // `xyzt_units = 0` is overwhelmingly millimetres in practice, and MGH / MIF
        // are millimetres by definition.
        let unit = acquisition.spatialUnit ?? .unknown
        switch unit {
        case .meter:
            // Metre-scale voxels are tiny numbers; fixed two decimals would print 0.00.
            spacing = String(format: "%.4g\(sep)%.4g\(sep)%.4g m", x, y, z)
        case .micron:
            spacing = String(format: "%.2f\(sep)%.2f\(sep)%.2f \u{00B5}m", x, y, z)
        case .millimeter, .unknown:
            spacing = String(format: "%.2f\(sep)%.2f\(sep)%.2f mm", x, y, z)
        }

        datatype = header.datatypeLabel ?? header.datatype.label
        volumes = header.volumes
        sclSlope = header.sclSlope
        sclInter = header.sclInter
        self.orientation = orientation

        repetitionTime = Self.timingText(acquisition)
        intent = acquisition.intentDisplayName
        descriptionText = Self.descriptionText(acquisition)
        diffusion = (acquisition.bValues ?? sidecar?.bValues).flatMap(Self.diffusionShellSummary)
        provenance = Self.provenanceText(acquisition)
        sidecarSummary = sidecar.flatMap { sidecar in
            let summary = sidecar.summary()
            let warnings = sidecarWarningsInRow ? sidecar.consistencyWarnings(against: header) : []
            let parts = (summary.map { [$0] } ?? []) + warnings
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        }
    }

    public func asDisplayLines() -> [MetadataEntry] {
        var entries: [MetadataEntry] = [
            MetadataEntry(field: .dimensions, label: "Dimensions", value: dimensions),
            MetadataEntry(field: .spacing, label: "Spacing", value: spacing),
        ]
        if let orientation {
            entries.append(MetadataEntry(field: .orientation, label: "Orientation", value: orientation))
        }
        entries.append(MetadataEntry(field: .datatype, label: "Datatype", value: datatype))
        entries.append(MetadataEntry(field: .volumes, label: "Volumes", value: "\(volumes)"))
        if let scaling {
            entries.append(MetadataEntry(field: .scaling, label: "Scaling", value: scaling))
        }
        // Optional rows: present only when the file (or sidecar) supplies them.
        // Visibility (including the PHI-prone rows' default-off) is the panel's
        // decision, via `MIQConfig.showMetadataField`.
        let optional: [(MetadataField, String?)] = [
            (.repetitionTime, repetitionTime),
            (.intent, intent),
            (.diffusion, diffusion),
            (.sidecar, sidecarSummary),
            (.description, descriptionText),
            (.provenance, provenance),
        ]
        for (field, value) in optional {
            if let value {
                entries.append(MetadataEntry(field: field, label: field.displayLabel, value: value))
            }
        }
        return entries
    }

    private var scaling: String? {
        let slope = Double(sclSlope)
        let intercept = Double(sclInter)
        let epsilon = 1e-6

        // `scl_slope == 0` means "do not apply scaling" in the current voxel path,
        // so hide the row rather than showing a misleading x 0.000 + ... expression.
        guard abs(slope) > epsilon else { return nil }
        guard !(abs(slope - 1) <= epsilon && abs(intercept) <= epsilon) else { return nil }

        // A zero intercept contributes nothing — "x 2 + 0" is just noise, so the
        // term is dropped and the row reads "x 2". Only the identity case above
        // hides the row entirely.
        guard abs(intercept) > epsilon else {
            return String(format: "\(Self.separator) %.6g", slope)
        }

        let sign = intercept < 0 ? "-" : "+"
        return String(format: "\(Self.separator) %.6g %@ %.6g", slope, sign, abs(intercept))
    }

    // MARK: - Acquisition formatting

    /// "2.3 s", or "2.3 s (TE 2.98 ms, TI 900 ms, flip 9°)" when the format also
    /// carries the other sequence timings. `nil` without a TR; TE/TI/flip alone
    /// (rare) are still shown, under a "—" TR.
    static func timingText(_ acquisition: MIQAcquisitionInfo) -> String? {
        var extras: [String] = []
        if let te = acquisition.echoTime { extras.append("TE \(formatMilliseconds(te))") }
        if let ti = acquisition.inversionTime { extras.append("TI \(formatMilliseconds(ti))") }
        if let flip = acquisition.flipAngle { extras.append("flip \(formatNumber(flip))\u{00B0}") }
        guard acquisition.repetitionTime != nil || !extras.isEmpty else { return nil }
        let tr = acquisition.repetitionTime.map(formatSeconds) ?? "\u{2014}"
        return extras.isEmpty ? tr : "\(tr) (\(extras.joined(separator: ", ")))"
    }

    /// Seconds for ≥ 1 s ("2.3 s"), milliseconds below ("800 ms").
    static func formatSeconds(_ seconds: Double) -> String {
        if abs(seconds) < 1 { return formatMilliseconds(seconds) }
        return "\(formatNumber(seconds)) s"
    }

    static func formatMilliseconds(_ seconds: Double) -> String {
        "\(formatNumber(seconds * 1000)) ms"
    }

    /// Up to four significant digits, no trailing zeros ("2", "2.98", "1250").
    static func formatNumber(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    private static func descriptionText(_ acquisition: MIQAcquisitionInfo) -> String? {
        let parts = [acquisition.descrip, acquisition.intentName.map { "intent \u{201C}\($0)\u{201D}" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func provenanceText(_ acquisition: MIQAcquisitionInfo) -> String? {
        var parts: [String] = []
        if let command = acquisition.lastCommand { parts.append(command) }
        if !acquisition.extensions.isEmpty {
            let list = acquisition.extensions
                .map { "\($0.codeName) (\(formatByteCount($0.size)))" }
                .joined(separator: ", ")
            parts.append("extensions: \(list)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func formatByteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// b-value shell summary, e.g. "b=0×7, 1000×32, 2000×64": each b rounded to
    /// the nearest 50 s/mm² (scanners report nominal shells with a few units of
    /// jitter, e.g. 995 / 1005), shells ascending. `nil` for an empty or
    /// non-finite list.
    public static func diffusionShellSummary(_ bValues: [Double]) -> String? {
        var counts: [Int: Int] = [:]
        for b in bValues {
            guard b.isFinite, abs(b) < 1e7 else { return nil }
            let shell = Int((b / 50).rounded()) * 50
            counts[shell, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let shells = counts.keys.sorted().map { "\($0)\(separator)\(counts[$0]!)" }
        return "b=" + shells.joined(separator: ", ")
    }

    /// Crosshair readout: "i, j, k" voxel indices, followed by the world position
    /// "(x, y, z mm)" when an affine is supplied.
    ///
    /// - Parameters:
    ///   - ijk: voxel indices, in the index space the affine's columns refer to
    ///     (for NIfTI/MGH the stored axis order; the caller maps a display cursor
    ///     back to it).
    ///   - affine: the voxel→world matrix's three rows of four (`srowX/Y/Z`
    ///     layout). `nil`, fewer than 3 rows, a row shorter than 4, or a
    ///     non-finite result prints the indices alone.
    ///   - unit: world-coordinate unit suffix.
    public static func formatVoxelPosition(ijk: [Int], affine: [[Float]]?, unit: String = "mm") -> String {
        let indices = ijk.prefix(3).map(String.init).joined(separator: ", ")
        guard let affine, affine.count >= 3, ijk.count >= 3,
              affine.prefix(3).allSatisfy({ $0.count >= 4 }) else {
            return indices
        }
        let v = ijk.prefix(3).map(Double.init)
        let world = affine.prefix(3).map { row -> Double in
            Double(row[0]) * v[0] + Double(row[1]) * v[1] + Double(row[2]) * v[2] + Double(row[3])
        }
        guard world.allSatisfy(\.isFinite) else { return indices }
        // Normalise -0.0 so a coordinate at the origin doesn't read "-0.0".
        let coordinates = world.map { String(format: "%.1f", $0 == 0 ? 0 : $0) }
            .map { $0 == "-0.0" ? "0.0" : $0 }
            .joined(separator: ", ")
        return "\(indices)  (\(coordinates) \(unit))"
    }
}

// MARK: - Acquisition & provenance data

/// NIfTI `xyzt_units` spatial code (bits 0-2).
public enum MIQSpatialUnit: Int, Sendable {
    case unknown = 0
    case meter = 1
    case millimeter = 2
    case micron = 3

    public var symbol: String? {
        switch self {
        case .unknown: return nil
        case .meter: return "m"
        case .millimeter: return "mm"
        case .micron: return "\u{00B5}m"
        }
    }
}

/// NIfTI `xyzt_units` temporal code (bits 3-5).
public enum MIQTemporalUnit: Int, Sendable {
    case unknown = 0
    case second = 8
    case millisecond = 16
    case microsecond = 24
    case hertz = 32
    case ppm = 40
    case radiansPerSecond = 48

    /// Units per second, for the time units (a divisor, so 2500 ms is exactly
    /// 2.5 s); `nil` for unknown and the spectral units (Hz / ppm / rad/s),
    /// whose `pixdim[4]` is not a repetition time.
    public var unitsPerSecond: Double? {
        switch self {
        case .second: return 1
        case .millisecond: return 1e3
        case .microsecond: return 1e6
        case .unknown, .hertz, .ppm, .radiansPerSecond: return nil
        }
    }
}

/// One NIfTI header extension: its `ecode` and total `esize` (including the
/// 8-byte esize/ecode prefix). Content is not retained.
public struct MIQHeaderExtension: Sendable, Equatable {
    public let ecode: Int
    public let size: Int

    public init(ecode: Int, size: Int) {
        self.ecode = ecode
        self.size = size
    }

    /// Registered ecode name (nifti1.h / the NIfTI ecode registry), else "ecode N".
    public var codeName: String {
        switch ecode {
        case 0: return "unknown"
        case 2: return "DICOM"
        case 4: return "AFNI"
        case 6: return "comment"
        case 8: return "XCEDE"
        case 10: return "JIM dim info"
        case 12: return "workflow"
        case 14: return "FreeSurfer"
        case 16: return "Python pickle"
        case 18: return "MIND ident"
        case 20: return "b-value"
        case 22: return "spherical direction"
        case 24: return "DT component"
        case 26: return "SHC degree/order"
        case 28: return "VoxBo"
        case 30: return "Caret"
        case 32: return "CIFTI"
        case 34: return "variable frame timing"
        case 38: return "Eval"
        case 40: return "MATLAB"
        case 42: return "Quantiphyse"
        case 44: return "MRS"
        default: return "ecode \(ecode)"
        }
    }
}

/// Display-only acquisition and provenance fields, attached to `MIQHeader` as
/// `acquisition`. Every member is optional / empty by default; each format
/// parser fills what it has:
///
/// - NIfTI-1/2: spatial/temporal unit (`xyzt_units`), repetitionTime
///   (`pixdim[4]`; 4D with a time unit only), intent code/params/name,
///   `descrip`, the extension list, embeddedLabels (label-table XML extension).
/// - MGH: repetitionTime, flipAngle, echoTime, inversionTime (optional tail).
/// - MIF: bValues (`dw_scheme`), lastCommand (`command_history`).
public struct MIQAcquisitionInfo: Sendable {
    /// `nil` when the format has no unit field (MGH, MIF, NRRD — millimetres).
    public var spatialUnit: MIQSpatialUnit?
    public var temporalUnit: MIQTemporalUnit?
    /// Seconds.
    public var repetitionTime: Double?
    /// Seconds.
    public var echoTime: Double?
    /// Seconds.
    public var inversionTime: Double?
    /// Degrees.
    public var flipAngle: Double?
    /// NIfTI `intent_code`; 0 is `NIFTI_INTENT_NONE`.
    public var intentCode: Int = 0
    /// NIfTI `intent_p1...p3`.
    public var intentParameters: [Double] = []
    /// NIfTI `intent_name`, trimmed; free text.
    public var intentName: String?
    /// NIfTI `descrip`, NUL-terminated and trimmed; free text (PHI risk).
    public var descrip: String?
    public var extensions: [MIQHeaderExtension] = []
    /// Label names (and optional colours) embedded in the file, e.g. the Caret /
    /// GIFTI-style `<LabelTable>` XML TotalSegmentator writes as a NIfTI extension.
    public var embeddedLabels: [Int: SegmentationLabel] = [:]
    /// Per-volume b-values (s/mm²) from a diffusion scheme.
    public var bValues: [Double]?
    /// The last `command_history` entry (MIF); free text.
    public var lastCommand: String?

    public init() {}

    /// Human-readable intent, `nil` for `NIFTI_INTENT_NONE`. Statistical intents
    /// carry their degrees-of-freedom parameters, e.g. "t-statistic (dof 25)".
    public var intentDisplayName: String? {
        guard intentCode != 0 else { return nil }
        let name = Self.intentName(for: intentCode) ?? "intent \(intentCode)"
        let p = intentParameters
        func param(_ i: Int) -> String? {
            guard let v = p[safe: i], v.isFinite, v != 0 else { return nil }
            return MIQMetadata.formatNumber(v)
        }
        switch intentCode {
        case 2, 3, 6, 19: // correl, ttest, chisq, chi: p1 = dof
            if let dof = param(0) { return "\(name) (dof \(dof))" }
        case 4: // ftest: p1 = numerator dof, p2 = denominator dof
            if let d1 = param(0), let d2 = param(1) { return "\(name) (dof \(d1), \(d2))" }
        default:
            break
        }
        return name
    }

    /// Names for the codes defined in nifti1.h.
    public static func intentName(for code: Int) -> String? {
        intentNames[code]
    }

    private static let intentNames: [Int: String] = [
        0: "none",
        2: "Correlation",
        3: "t-statistic",
        4: "F-statistic",
        5: "z-score",
        6: "Chi-squared",
        7: "Beta distribution",
        8: "Binomial distribution",
        9: "Gamma distribution",
        10: "Poisson distribution",
        11: "Normal distribution",
        12: "Noncentral F-statistic",
        13: "Noncentral chi-squared",
        14: "Logistic distribution",
        15: "Laplace distribution",
        16: "Uniform distribution",
        17: "Noncentral t-statistic",
        18: "Weibull distribution",
        19: "Chi distribution",
        20: "Inverse Gaussian",
        21: "Extreme value",
        22: "p-value",
        23: "ln(p-value)",
        24: "log10(p-value)",
        1001: "Estimate",
        1002: "Label",
        1003: "NeuroNames label",
        1004: "General matrix",
        1005: "Symmetric matrix",
        1006: "Displacement vector",
        1007: "Vector",
        1008: "Point set",
        1009: "Triangle",
        1010: "Quaternion",
        1011: "Dimensionless",
        2001: "Time series",
        2002: "Node index",
        2003: "RGB vector",
        2004: "RGBA vector",
        2005: "Shape",
    ]

    /// Fixed-width header text field → display string: stops at the first NUL,
    /// replaces control characters with spaces, trims, and yields `nil` when
    /// nothing printable remains. Decoded as UTF-8 with replacement, so stray
    /// Latin-1 bytes cannot fail the parse.
    static func headerText(_ bytes: some Collection<UInt8>) -> String? {
        let terminated = bytes.prefix { $0 != 0 }
        let raw = String(decoding: Array(terminated), as: UTF8.self)
        let cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control ? " " : Character(scalar)
        })
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
