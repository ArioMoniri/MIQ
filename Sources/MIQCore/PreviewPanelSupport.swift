import Foundation

// Pure helpers behind the Quick Look preview's metadata panel and slice
// overlays. They live in MIQCore (rather than the AppKit extension) so the
// wording, the gating rules and the coordinate maths are covered by the Linux
// test suite; the extension only wires them to views.

// MARK: - Display-mode badge and forced L/R labels

extension ViewOrientation {
    /// Text of the always-visible display-mode badge on the slice area.
    public var badgeLabel: String {
        switch self {
        case .stored: return "As stored"
        case .neurological: return "Neurological"
        case .radiological: return "Radiological"
        }
    }

    /// Whether the slices must keep their left/right letters even when the user
    /// turned axis labels off. "As stored" puts patient left on whichever side the
    /// file's storage order says, so without the letters the image is ambiguous;
    /// the two reoriented modes fix the convention and the badge names it.
    public var requiresLeftRightLabels: Bool {
        self == .stored
    }

    /// The mode the slices are actually drawn in. A reoriented mode falls back to
    /// `.stored` when the file's orientation is unknown (`OrientationResolver`),
    /// which the preview sees as "?" labels — so the badge must say "As stored".
    public func effective(orientationKnown: Bool) -> ViewOrientation {
        orientationKnown ? self : .stored
    }
}

extension SliceOrientationLabels {
    /// These labels with every edge blanked except the patient left/right ones —
    /// what the canvas draws in "As stored" mode while axis labels are off. An
    /// unknown orientation keeps nothing (its "?" glyphs make no L/R claim).
    public func leftRightOnly() -> SliceOrientationLabels {
        func keep(_ label: String) -> String {
            guard !isUnknown else { return "" }
            let upper = label.uppercased()
            return upper == "L" || upper == "R" ? label : ""
        }
        return SliceOrientationLabels(
            leading: keep(leading),
            trailing: keep(trailing),
            top: keep(top),
            bottom: keep(bottom),
            isUnknown: isUnknown
        )
    }
}

// MARK: - Crosshair position

extension MIQHeader {
    /// Voxel → world rows (`srowX/Y/Z` layout, three rows of four) for the
    /// crosshair position readout, or `nil` when the header carries no complete
    /// affine for the index space the preview's cursor uses.
    ///
    /// Only transforms whose `srow` rows *are* that affine qualify: a NIfTI sform
    /// (and the DICOM / OME-Zarr headers built the same way) and a NRRD anatomical
    /// space. MGH rows hold direction cosines only (no voxel size, no `c_ras`),
    /// MIF stores its transform per image axis before `layout:` permutes them, and
    /// a qform-only NIfTI keeps no rows at all — those show indices alone rather
    /// than a wrong coordinate.
    public var positionAffine: [[Float]]? {
        switch orientationDiagnostics.transformSource {
        case .sform, .nrrdSpace:
            break
        default:
            return nil
        }
        let rows = [srowX, srowY, srowZ]
        guard rows.allSatisfy({ $0.count >= 4 && $0.prefix(4).allSatisfy(\.isFinite) }) else { return nil }
        return rows
    }

    /// Unit suffix for world coordinates: the NIfTI spatial unit when stated,
    /// otherwise millimetres (MGH, MIF, NRRD, DICOM are millimetres by definition).
    public var positionUnitSymbol: String {
        acquisition.spatialUnit?.symbol ?? "mm"
    }
}

extension MIQMetadata {
    /// `.voxelPosition` readout for a preview cursor: "i, j, k  (x, y, z mm)".
    ///
    /// The preview's `MIQVolumeCursor` already addresses *stored* voxels —
    /// `MIQVolume.cursor(for:sliceIndex:normalizedPoint:options:)` maps every
    /// display mode's flips and axis swaps back through the orientation plan — so
    /// its x/y/z are the header's i/j/k and feed the affine directly.
    public static func voxelPositionText(cursor: MIQVolumeCursor, header: MIQHeader) -> String {
        formatVoxelPosition(
            ijk: [cursor.x, cursor.y, cursor.z],
            affine: header.positionAffine,
            unit: header.positionUnitSymbol
        )
    }
}

// MARK: - Panel warnings

extension MIQMetadata {
    /// Strips any leading warning sign (and the whitespace after it) so every
    /// warning gets the panel's own prefix exactly once, and folds line breaks:
    /// the panel's row mapping relies on one row per line.
    public static func normalizedWarning(_ text: String) -> String {
        var trimmed = Substring(text)
        while let first = trimmed.unicodeScalars.first,
              first == "\u{26A0}" || first == "\u{FE0F}" || first == "\u{FE0E}" || first == " " {
            trimmed = Substring(trimmed.unicodeScalars.dropFirst())
        }
        return trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Warnings the panel always shows, independent of the row toggles: the
    /// orientation caution (qform/sform conflict, no transform) followed by any
    /// BIDS sidecar/header disagreement. Normalised, de-duplicated, in order.
    public static func panelWarnings(header: MIQHeader, sidecar: SidecarMetadata?) -> [String] {
        var raw: [String] = []
        if let warning = header.orientationDiagnostics.warning { raw.append(warning) }
        if let sidecar { raw.append(contentsOf: sidecar.consistencyWarnings(against: header)) }
        var seen = Set<String>()
        return raw.map(normalizedWarning).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Background summaries (QC, temporal)

public enum PreviewDataSummaries {
    /// Fewest volumes for which the preview computes a temporal (tSNR / spike)
    /// summary: shorter series are rarely fMRI and give a meaningless median.
    public static let minimumTemporalVolumes = 10

    /// Largest per-volume voxel count the temporal summary accepts. Its maps hold
    /// two `Double`s and three `Float`s per voxel (~28 B), so this caps the
    /// working set near 115 MB — far beyond any fMRI grid, below a 4D T1 stack.
    public static let maximumTemporalVoxelsPerVolume = 4 * 1024 * 1024

    private static func isScalar(_ header: MIQHeader) -> Bool {
        header.datatype != .rgb24 && header.datatype != .rgba32
    }

    /// Whether the preview runs `QCAnalyzer` for this header: scalar data only,
    /// and not for a 4D series over the Quick Look decompression budget (whose
    /// full read the preview already refuses).
    public static func shouldRunQC(header: MIQHeader) -> Bool {
        guard isScalar(header) else { return false }
        if header.volumes > 1, header.exceedsFullDecompressionBudget() { return false }
        return true
    }

    /// Whether the preview runs `TemporalStats.summary` for this volume: a scalar,
    /// non-label series of at least `minimumTemporalVolumes` with every volume
    /// present in memory (a volume-0-capped buffer waits for the 4D expansion),
    /// within the decompression budget and the per-volume voxel cap.
    public static func shouldRunTemporalSummary(volume: MIQVolume, isLabelMap: Bool) -> Bool {
        let header = volume.image.header
        guard isScalar(header), !isLabelMap else { return false }
        guard volume.volumes >= minimumTemporalVolumes, volume.containsAllVolumes else { return false }
        guard !header.exceedsFullDecompressionBudget() else { return false }
        let (spatial, overflow) = volume.width.multipliedReportingOverflow(by: volume.height)
        let (voxels, overflow2) = spatial.multipliedReportingOverflow(by: volume.depth)
        return !overflow && !overflow2 && voxels > 0 && voxels <= maximumTemporalVoxelsPerVolume
    }

    /// Row for a temporal summary: label "tSNR (median)", value
    /// "52 · 1 spike frame". `nil` when no median could be computed.
    public static func temporalEntry(_ summary: TemporalSummary) -> MetadataEntry? {
        guard let median = summary.medianTSNR, median.isFinite else { return nil }
        let tsnr = median >= 10 ? String(Int(median.rounded())) : String(format: "%.1f", Double(median))
        let spikes: String
        switch summary.spikeCount {
        case 0: spikes = "no spike frames"
        case 1: spikes = "1 spike frame"
        default: spikes = "\(summary.spikeCount) spike frames"
        }
        return MetadataEntry(field: nil, label: "tSNR (median)", value: "\(tsnr) \u{00B7} \(spikes)")
    }

    /// Subheading above the QC / temporal rows.
    public static let sectionTitle = "Data QC"

    /// Label and value of the 4D window-mode indicator shown beside Volumes.
    public static let windowModeLabel = "Window"
    public static func windowModeText(perVolume: Bool) -> String {
        perVolume ? "per volume" : "shared"
    }
}

// MARK: - Status texts

public enum PreviewStatusText {
    /// The failure line for a load error. `MIQError.unsupportedFeature` carries
    /// a reason written for display ("Compressed DICOM (JPEG 2000) isn't
    /// supported yet"), shown verbatim; anything else is prefixed.
    public static func failureMessage(for error: Error) -> String {
        if case MIQError.unsupportedFeature(let reason) = error {
            return reason
        }
        return "Preview failed: \(error.localizedDescription)"
    }

    /// Message of the deferred-preview placeholder. A dataless cloud file (iCloud
    /// Drive "Optimize Mac Storage", other File Providers) is not on a network
    /// volume — reading it downloads it — so it gets its own wording.
    public static func deferredMessage(name: String, sizeText: String, isDataless: Bool) -> String {
        if isDataless {
            return "\(name) is \(sizeText) in iCloud (not downloaded).\nLoading it now downloads the whole file, which could make Finder unresponsive."
        }
        return "\(name) is \(sizeText) on a network volume.\nLoading it now could make Finder unresponsive while it transfers."
    }
}
