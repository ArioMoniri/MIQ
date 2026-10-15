import Foundation

/// Fixed width/level windows for CT data in Hounsfield units, plus `auto`
/// (the percentile window every other volume gets).
///
/// Values are the commonly quoted ones from Radiopaedia's "Windowing (CT)"
/// article (https://radiopaedia.org/articles/windowing-ct). They are display
/// conventions, not standards: institutions and individual readers vary them
/// (stroke and subdural windows especially), so treat them as reasonable
/// starting points a user can adjust, never as calibrated settings.
///
/// The presets only make sense when the stored values *are* Hounsfield units;
/// `looksLikeCT(header:sampleMin:)` (modality-aware, else heuristic) is the gate the UI can use to
/// decide whether to offer them.
public enum WindowPreset: String, CaseIterable, Sendable {
    /// Percentile windowing (`RenderingOptions.lowerPercentile/upperPercentile`).
    case auto
    /// W 80 / L 40.
    case brain
    /// W 200 / L 75 (Radiopaedia gives W 130–300 / L 50–100).
    case subdural
    /// W 40 / L 40 (a narrow brain window for early ischaemia; W 8 / L 32 is also used).
    case stroke
    /// W 1800 / L 400.
    case bone
    /// W 1500 / L -600.
    case lung
    /// W 400 / L 40 (Radiopaedia gives W 350–400 / L 20–60).
    case softTissue

    /// Every preset with a fixed window, i.e. all but `auto`, in menu order.
    public static var fixedPresets: [WindowPreset] {
        allCases.filter { $0 != .auto }
    }

    /// Window width (HU), or `nil` for `auto`.
    public var width: Float? {
        switch self {
        case .auto: return nil
        case .brain: return 80
        case .subdural: return 200
        case .stroke: return 40
        case .bone: return 1800
        case .lung: return 1500
        case .softTissue: return 400
        }
    }

    /// Window level / centre (HU), or `nil` for `auto`.
    public var level: Float? {
        switch self {
        case .auto: return nil
        case .brain: return 40
        case .subdural: return 75
        case .stroke: return 40
        case .bone: return 400
        case .lung: return -600
        case .softTissue: return 40
        }
    }

    /// Short English menu title.
    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .brain: return "Brain"
        case .subdural: return "Subdural"
        case .stroke: return "Stroke"
        case .bone: return "Bone"
        case .lung: return "Lung"
        case .softTissue: return "Soft Tissue"
        }
    }

    /// The preset as display bounds (`low = level - width/2`, `high = level + width/2`),
    /// ready to pass as `windowBounds:` to `MIQVolume.slice`. `nil` for `auto`.
    /// Bounds are in *scaled* units — the same values `MIQVolume.voxel` returns —
    /// which is HU for a CT whose slope/intercept were applied as the header says.
    public var bounds: MIQIntensityWindowBounds? {
        guard let width, let level else { return nil }
        return MIQIntensityWindowBounds(widthLevel: width, level: level)
    }

    // MARK: - CT heuristic

    /// Tolerance (HU) around air's -1024 for both the intercept and minimum tests.
    static let airTolerance: Float = 50

    /// Does this volume hold CT Hounsfield units, i.e. should CT presets be offered?
    ///
    /// **When the file states a modality** (`MIQHeader.modality`, currently DICOM's
    /// Modality (0008,0060)), that decides: `CT` -> true, any other code (`MR`, `PT`,
    /// `NM`, ...) -> false. The datatype is not checked then, since a DICOM CT whose
    /// frames disagree on rescale is materialised as float32. `OT` ("other") is not
    /// treated as a statement and falls through to the heuristic below.
    ///
    /// **Otherwise** (NIfTI, MGH, MIF, NRRD, ... none of which records modality) it
    /// is a heuristic: true when the stored datatype is an integer type (CT is
    /// acquired as 12-16-bit integers; float CT is rare and indistinguishable from
    /// other float maps) **and** either
    ///  * the intercept puts stored 0 near air: `scl_inter` within +/-50 of -1024
    ///    with a unit (or unset) slope, the usual DICOM->NIfTI encoding of unsigned
    ///    storage; or
    ///  * the sampled scaled minimum is near air (within +/-50 of -1024 HU), which
    ///    is what an in-air body or head CT stored as signed HU shows.
    ///
    /// Limits of the heuristic (a display hint only, never to be presented as the
    /// modality):
    ///  * a CT whose out-of-field padding is -2048/-3024 has that as its minimum,
    ///    and a tightly cropped scan may contain no air at all; both are missed
    ///    (unless the intercept test fires);
    ///  * any integer map that happens to bottom out near -1024 is a false
    ///    positive.
    ///
    /// - Parameter sampleMin: minimum finite *scaled* value of a representative
    ///   sample (e.g. the pooled center slices), or `nil` if not known.
    public static func looksLikeCT(header: MIQHeader, sampleMin: Float?) -> Bool {
        if let modality = header.modality?.uppercased(), !modality.isEmpty, modality != "OT" {
            return modality == "CT"
        }
        guard isIntegerDatatype(header.datatype) else { return false }
        let slope = header.sclSlope
        let unitSlope = slope == 0 || abs(slope - 1) < 1e-6
        if unitSlope, abs(header.sclInter - (-1024)) <= airTolerance {
            return true
        }
        if let sampleMin, sampleMin.isFinite, abs(sampleMin - (-1024)) <= airTolerance {
            return true
        }
        return false
    }

    private static func isIntegerDatatype(_ datatype: MIQDatatype) -> Bool {
        switch datatype {
        case .uint8, .int8, .int16, .uint16, .int32, .uint32, .int64, .uint64:
            return true
        case .float32, .float64, .rgb24, .rgba32:
            return false
        }
    }
}

extension MIQIntensityWindowBounds {
    /// Bounds from a width/level pair: `[level - width/2, level + width/2]`.
    public init(widthLevel width: Float, level: Float) {
        self.init(low: level - width / 2, high: level + width / 2)
    }

    /// `high - low`.
    public var width: Float { high - low }

    /// Midpoint of the window.
    public var level: Float { (low + high) / 2 }

    /// "W 80 / L 40" — the radiology convention, for any bounds (preset,
    /// percentile, or a manual drag). See `formatWindowValue` for the numbers.
    public var widthLevelLabel: String {
        "W \(Self.formatWindowValue(width)) / L \(Self.formatWindowValue(level))"
    }

    /// Compact, locale-independent number for window labels: whole numbers for
    /// |v| ≥ 100 (HU and most integer data), one decimal for |v| ≥ 1, three
    /// significant digits below that (float maps such as ADC in SI units, where
    /// the whole window is ~1e-9). Trailing zeros are dropped; `-0` prints as `0`;
    /// non-finite prints as "–".
    public static func formatWindowValue(_ value: Float) -> String {
        guard value.isFinite else { return "–" }
        let magnitude = abs(value)
        if magnitude >= 100 || value == value.rounded() {
            let rounded = value.rounded()
            if abs(rounded) < 1e15 {
                let integer = Int64(rounded)
                return integer == 0 ? "0" : String(integer)
            }
            return String(format: "%.3g", Double(value))
        }
        let text: String
        if magnitude >= 1 {
            text = String(format: "%.1f", Double(value))
        } else {
            text = String(format: "%.3g", Double(value))
        }
        return stripTrailingZeros(text)
    }

    private static func stripTrailingZeros(_ text: String) -> String {
        // Only touch a plain decimal mantissa ("12.50" → "12.5", "0.100" → "0.1");
        // exponent forms ("1.5e-09") are left as printed.
        guard text.contains("."), !text.contains("e") else { return text }
        var trimmed = Substring(text)
        while trimmed.hasSuffix("0") { trimmed = trimmed.dropLast() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        return trimmed == "-0" ? "0" : String(trimmed)
    }
}
