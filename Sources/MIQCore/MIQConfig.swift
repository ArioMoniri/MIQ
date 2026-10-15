import Foundation
import os.log

public enum MIQConfig {
    private static let configLogger = Logger(subsystem: "miq.core", category: "config")
    /// One-shot guard for the missing-App-Group notice. `appGroupID` is read from
    /// any thread (extension tasks, the app's main actor), so the flag sits behind
    /// a lock rather than in a `nonisolated(unsafe)` static.
    private static let loggedMissingAppGroupID = OnceFlag()

    /// Lock-protected "has this happened yet" flag. `NSLock` (not
    /// `OSAllocatedUnfairLock`, Apple-only, or `Mutex`, macOS 15+) keeps MIQCore
    /// portable at the macOS 14 deployment target. `@unchecked Sendable` is sound:
    /// the only stored state is mutated while holding `lock`.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        /// `true` exactly once: on the first call, from whichever thread wins.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    public static var appGroupID: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MIQAppGroupID") as? String, !value.isEmpty {
            return value
        }
        if loggedMissingAppGroupID.claim() {
            configLogger.notice("MIQAppGroupID missing from Info.plist — falling back to UserDefaults.standard; settings won't propagate between app and extension")
        }
        return ""
    }

    public enum Keys {
        public static let showAxisLabels        = "showAxisLabels"
        public static let windowLowerPercentile = "windowLowerPercentile"
        public static let windowUpperPercentile = "windowUpperPercentile"
        public static let perVolumeIntensityWindow = "perVolumeIntensityWindow"
        public static let imageOrientation      = "imageOrientation"
        public static let axisLabelColor        = "axisLabelColor"
        public static let showMetadataFormat      = "showMetadataFormat"
        public static let showMetadataDimensions  = "showMetadataDimensions"
        public static let showMetadataSpacing     = "showMetadataSpacing"
        public static let showMetadataOrientation = "showMetadataOrientation"
        public static let showMetadataDatatype    = "showMetadataDatatype"
        public static let showMetadataVolumes     = "showMetadataVolumes"
        public static let showMetadataScaling     = "showMetadataScaling"
        public static let showMetadataValue       = "showMetadataValue"
        public static let showMetadataRepetitionTime = "showMetadataRepetitionTime"
        public static let showMetadataIntent         = "showMetadataIntent"
        public static let showMetadataDiffusion      = "showMetadataDiffusion"
        public static let showMetadataSidecar        = "showMetadataSidecar"
        public static let showMetadataVoxelPosition  = "showMetadataVoxelPosition"
        public static let showMetadataDescription    = "showMetadataDescription"
        public static let showMetadataProvenance     = "showMetadataProvenance"
        public static let metadataOrder           = "metadataOrder"
        public static let segmentationColoring           = "segmentationColoring"
        public static let hideDisclaimerInPreview = "hideDisclaimerInPreview"
        public static let deferLargeNetworkPreviews = "deferLargeNetworkPreviews"
        public static let starBannerDismissed     = "starBannerDismissed"
        public static let showThumbnails                 = "showThumbnails"
        public static let showThumbnailsOnNetworkVolumes = "showThumbnailsOnNetworkVolumes"
        public static let thumbnailImageOrientation      = "thumbnailImageOrientation"
        public static let thumbnailSegmentationColoring  = "thumbnailSegmentationColoring"
        public static let thumbnailWindowLowerPercentile = "thumbnailWindowLowerPercentile"
        public static let thumbnailWindowUpperPercentile = "thumbnailWindowUpperPercentile"
        // MARK: Rendering workstream (CT presets, shared 4D window)
        public static let ctWindowPreset          = "ctWindowPreset"
        public static let ctPresetAutoDetect      = "ctPresetAutoDetect"
        // MARK: Preview panel workstream (data summaries)
        public static let qcPanelEnabled          = "qcPanelEnabled"
        public static let temporalSummaryEnabled  = "temporalSummaryEnabled"
        #if DEBUG
        public static let debugShowLayoutBorders  = "debugShowLayoutBorders"
        #endif
    }

    public enum Defaults {
        public static let showAxisLabels        = true
        public static let windowLowerPercentile = 2.0
        public static let windowUpperPercentile = 98.0
        public static let perVolumeIntensityWindow = true
        public static let imageOrientation      = "stored"
        public static let axisLabelColor        = "1.0,0.15,0.1,1.0"
        public static let showMetadataFormat      = true
        public static let showMetadataDimensions  = true
        public static let showMetadataSpacing     = true
        public static let showMetadataOrientation = true
        public static let showMetadataDatatype    = true
        public static let showMetadataVolumes     = true
        public static let showMetadataScaling     = true
        public static let showMetadataValue       = true
        public static let showMetadataRepetitionTime = true
        public static let showMetadataIntent         = true
        public static let showMetadataDiffusion      = true
        public static let showMetadataSidecar        = true
        public static let showMetadataVoxelPosition  = true
        /// Free-text header fields (NIfTI `descrip` / `intent_name`; MIF
        /// `command_history`) can hold identifying details, so they are opt-in.
        public static let showMetadataDescription    = false
        public static let showMetadataProvenance     = false
        /// Every `MetadataField` in `allCases` order. A saved order from before a
        /// field existed decodes to the same list via `parseMetadataOrder`, which
        /// appends missing fields in this same order — so upgrading users keep
        /// their arrangement with the new rows at the end.
        public static let metadataOrder           = "format,dimensions,spacing,orientation,datatype,volumes,scaling,value,repetitionTime,intent,diffusion,sidecar,voxelPosition,description,provenance"
        public static let segmentationColoring           = "auto"
        public static let hideDisclaimerInPreview = false
        public static let deferLargeNetworkPreviews = true
        /// App-only (the Settings window's "star on GitHub" banner); the
        /// extensions never read it.
        public static let starBannerDismissed     = false
        /// Size (MB) above which `deferLargeNetworkPreviews` defers a network
        /// preview. Not user-configurable (no `Keys` entry / UI control).
        public static let networkPreviewThresholdMB = 100.0
        public static let showThumbnails                 = false
        public static let showThumbnailsOnNetworkVolumes = false
        public static let thumbnailImageOrientation      = "stored"
        public static let thumbnailSegmentationColoring  = "auto"
        public static let thumbnailWindowLowerPercentile = 2.0
        public static let thumbnailWindowUpperPercentile = 98.0
        // MARK: Rendering workstream (CT presets, shared 4D window)
        /// `WindowPreset.rawValue` applied to volumes `WindowPreset.looksLikeCT`
        /// accepts; `auto` keeps percentile windowing (today's behaviour).
        public static let ctWindowPreset          = "auto"
        /// Whether the preview runs `WindowPreset.looksLikeCT` at all (gates
        /// offering/applying presets). Off by default: the heuristic is a guess,
        /// and the default display must not change silently.
        public static let ctPresetAutoDetect      = false
        /// The preview's "Data QC" rows (likely sequence, head mask, face,
        /// overall rating). On by default: they describe the pixel data with
        /// fixed wording and never echo header free text, so they add no PHI.
        public static let qcPanelEnabled          = true
        /// The preview's "tSNR (median)" row for 4D series of ≥ 10 volumes.
        /// On by default for the same reason as `qcPanelEnabled`.
        public static let temporalSummaryEnabled  = true
    }

    public struct MIQColor: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
    }

    /// Shared App Group store, resolved once. Cached rather than reconstructed
    /// per access because the extension reads ~10 settings per rendered frame
    /// during interaction (axis labels, overlay colour, metadata order/visibility),
    /// and `UserDefaults(suiteName:)` allocates on every call. The getters still
    /// read values live via `object(forKey:)`, so app-side writes remain visible.
    /// `nonisolated(unsafe)` is sound here: `UserDefaults` is thread-safe by
    /// Apple's contract, so concurrent reads of this immutable reference are safe.
    ///
    /// The empty-`appGroupID` check is load-bearing, not defensive noise:
    /// `UserDefaults(suiteName: "")` returns a **non-nil** store (a nameless
    /// suite), so a bare `?? .standard` never fires and the app and each appex
    /// would silently read three different stores — while `appGroupID` logs that
    /// it fell back to `.standard`. Reachable whenever `MIQAppGroupID` resolves
    /// empty, i.e. `APP_GROUP_ID` is undefined because `LocalSigning.xcconfig`
    /// (gitignored) is missing from a fresh checkout.
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        let identifier = appGroupID
        guard !identifier.isEmpty, let suite = UserDefaults(suiteName: identifier) else {
            return .standard
        }
        return suite
    }()

    public static var showAxisLabels: Bool {
        let d = defaults
        return d.object(forKey: Keys.showAxisLabels) as? Bool ?? Defaults.showAxisLabels
    }

    public static var windowLowerPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.windowLowerPercentile) as? Double ?? Defaults.windowLowerPercentile
    }

    public static var windowUpperPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.windowUpperPercentile) as? Double ?? Defaults.windowUpperPercentile
    }

    /// When `true`, 4D previews re-derive the percentile window from each
    /// volume's own pooled center slices instead of reusing volume 0's window
    /// for the whole timeseries. Deliberately *not* part of `RenderingOptions`:
    /// the cache only holds the volume-0 cold preview, whose window is identical
    /// either way, so this never needs to invalidate the cache. It is a
    /// model-layer choice of *which* bounds to feed `MIQVolume.slice`, consumed
    /// only by the extension's interactive render path.
    public static var perVolumeIntensityWindow: Bool {
        let d = defaults
        return d.object(forKey: Keys.perVolumeIntensityWindow) as? Bool ?? Defaults.perVolumeIntensityWindow
    }

    public static var imageOrientation: ViewOrientation {
        let raw = defaults.string(forKey: Keys.imageOrientation) ?? Defaults.imageOrientation
        return ViewOrientation(rawValue: raw) ?? .stored
    }

    public static var axisLabelColor: MIQColor {
        let raw = defaults.string(forKey: Keys.axisLabelColor) ?? Defaults.axisLabelColor
        return parseColor(raw) ?? parseColor(Defaults.axisLabelColor)!
    }

    /// User-configured display order for metadata fields. Unknown tokens are
    /// dropped; any `MetadataField` not present in the stored value is appended
    /// in canonical order so the result always covers every case.
    public static var metadataOrder: [MetadataField] {
        let raw = defaults.string(forKey: Keys.metadataOrder) ?? Defaults.metadataOrder
        return parseMetadataOrder(raw)
    }

    public static func parseMetadataOrder(_ raw: String) -> [MetadataField] {
        var seen = Set<MetadataField>()
        var ordered: [MetadataField] = []
        for token in raw.split(separator: ",") {
            guard let field = MetadataField(rawValue: String(token)), !seen.contains(field) else { continue }
            ordered.append(field)
            seen.insert(field)
        }
        for field in MetadataField.allCases where !seen.contains(field) {
            ordered.append(field)
        }
        return ordered
    }

    public static var segmentationColoring: SegmentationColoring {
        let raw = defaults.string(forKey: Keys.segmentationColoring) ?? Defaults.segmentationColoring
        return SegmentationColoring(rawValue: raw) ?? .auto
    }

    public static var hideDisclaimerInPreview: Bool {
        let d = defaults
        return d.object(forKey: Keys.hideDisclaimerInPreview) as? Bool ?? Defaults.hideDisclaimerInPreview
    }

    /// When `true` (default), the preview extension defers the heavy full-file
    /// read for non-boundable kinds (`.mgz`/`.mif.gz`/`.nrrd`, and `.mgh`/`.mif`)
    /// on a network volume when the file exceeds `networkPreviewThresholdBytes`,
    /// showing a "load preview" placeholder instead of auto-pulling it. Prevents a
    /// large read from stalling Finder's own I/O on a slow mount. Local disk and
    /// canonical NIfTI (already bounded to volume 0) are unaffected. Read by the
    /// preview extension only.
    public static var deferLargeNetworkPreviews: Bool {
        let d = defaults
        return d.object(forKey: Keys.deferLargeNetworkPreviews) as? Bool ?? Defaults.deferLargeNetworkPreviews
    }

    /// Byte threshold derived from `Defaults.networkPreviewThresholdMB`. Also the
    /// thumbnail extension's size cutoff (`MIQFileKind.declinesThumbnail`).
    public static var networkPreviewThresholdBytes: Int {
        Int(Defaults.networkPreviewThresholdMB * 1024 * 1024)
    }

    // MARK: - Thumbnails (Finder / Quick Look thumbnail extension)
    // Independent of the preview's image-display settings: a user can want, e.g.,
    // stored-orientation previews but radiological thumbnails. Read by the
    // thumbnail extension only.

    public static var showThumbnails: Bool {
        let d = defaults
        return d.object(forKey: Keys.showThumbnails) as? Bool ?? Defaults.showThumbnails
    }

    /// When `false` (default), the thumbnail extension declines files on network
    /// volumes, so browsing a remote share doesn't spawn a parse per file. Local
    /// thumbnails are unaffected. Read by the thumbnail extension only.
    public static var showThumbnailsOnNetworkVolumes: Bool {
        let d = defaults
        return d.object(forKey: Keys.showThumbnailsOnNetworkVolumes) as? Bool ?? Defaults.showThumbnailsOnNetworkVolumes
    }

    public static var thumbnailImageOrientation: ViewOrientation {
        let raw = defaults.string(forKey: Keys.thumbnailImageOrientation) ?? Defaults.thumbnailImageOrientation
        return ViewOrientation(rawValue: raw) ?? .stored
    }

    public static var thumbnailSegmentationColoring: SegmentationColoring {
        let raw = defaults.string(forKey: Keys.thumbnailSegmentationColoring) ?? Defaults.thumbnailSegmentationColoring
        return SegmentationColoring(rawValue: raw) ?? .auto
    }

    public static var thumbnailWindowLowerPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.thumbnailWindowLowerPercentile) as? Double ?? Defaults.thumbnailWindowLowerPercentile
    }

    public static var thumbnailWindowUpperPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.thumbnailWindowUpperPercentile) as? Double ?? Defaults.thumbnailWindowUpperPercentile
    }

    // MARK: - Rendering workstream (CT presets)

    /// Preset applied to CT-looking volumes; unknown stored values read as `.auto`.
    public static var ctWindowPreset: WindowPreset {
        let raw = defaults.string(forKey: Keys.ctWindowPreset) ?? Defaults.ctWindowPreset
        return WindowPreset(rawValue: raw) ?? .auto
    }

    public static var ctPresetAutoDetect: Bool {
        let d = defaults
        return d.object(forKey: Keys.ctPresetAutoDetect) as? Bool ?? Defaults.ctPresetAutoDetect
    }

    // MARK: - Preview panel workstream (data summaries)

    /// Whether the preview runs `QCAnalyzer` after a load and appends its
    /// `displayLines` under a "Data QC" subheading. Read by the preview
    /// extension only, once per load.
    public static var qcPanelEnabled: Bool {
        defaults.object(forKey: Keys.qcPanelEnabled) as? Bool ?? Defaults.qcPanelEnabled
    }

    /// Whether the preview computes `TemporalStats.summary` (median tSNR, spike
    /// frames) for 4D series and shows it under "Data QC". Read by the preview
    /// extension only, once per load.
    public static var temporalSummaryEnabled: Bool {
        defaults.object(forKey: Keys.temporalSummaryEnabled) as? Bool ?? Defaults.temporalSummaryEnabled
    }

    #if DEBUG
    public static var debugShowLayoutBorders: Bool {
        defaults.object(forKey: Keys.debugShowLayoutBorders) as? Bool ?? false
    }
    #endif

    public static func showMetadataField(_ field: MetadataField) -> Bool {
        defaults.object(forKey: metadataVisibilityKey(field)) as? Bool ?? defaultVisibility(field)
    }

    /// The `UserDefaults` key holding `field`'s visibility toggle.
    public static func metadataVisibilityKey(_ field: MetadataField) -> String {
        switch field {
        case .format:         return Keys.showMetadataFormat
        case .dimensions:     return Keys.showMetadataDimensions
        case .spacing:        return Keys.showMetadataSpacing
        case .orientation:    return Keys.showMetadataOrientation
        case .datatype:       return Keys.showMetadataDatatype
        case .volumes:        return Keys.showMetadataVolumes
        case .scaling:        return Keys.showMetadataScaling
        case .value:          return Keys.showMetadataValue
        case .repetitionTime: return Keys.showMetadataRepetitionTime
        case .intent:         return Keys.showMetadataIntent
        case .diffusion:      return Keys.showMetadataDiffusion
        case .sidecar:        return Keys.showMetadataSidecar
        case .voxelPosition:  return Keys.showMetadataVoxelPosition
        case .description:    return Keys.showMetadataDescription
        case .provenance:     return Keys.showMetadataProvenance
        }
    }

    /// `field`'s visibility when the user never toggled it.
    public static func defaultVisibility(_ field: MetadataField) -> Bool {
        switch field {
        case .format:         return Defaults.showMetadataFormat
        case .dimensions:     return Defaults.showMetadataDimensions
        case .spacing:        return Defaults.showMetadataSpacing
        case .orientation:    return Defaults.showMetadataOrientation
        case .datatype:       return Defaults.showMetadataDatatype
        case .volumes:        return Defaults.showMetadataVolumes
        case .scaling:        return Defaults.showMetadataScaling
        case .value:          return Defaults.showMetadataValue
        case .repetitionTime: return Defaults.showMetadataRepetitionTime
        case .intent:         return Defaults.showMetadataIntent
        case .diffusion:      return Defaults.showMetadataDiffusion
        case .sidecar:        return Defaults.showMetadataSidecar
        case .voxelPosition:  return Defaults.showMetadataVoxelPosition
        case .description:    return Defaults.showMetadataDescription
        case .provenance:     return Defaults.showMetadataProvenance
        }
    }

    private static func parseColor(_ str: String) -> MIQColor? {
        let parts = str.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return MIQColor(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }
}
