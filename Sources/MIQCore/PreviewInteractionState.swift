import Foundation

// Pure state machines behind the Quick Look preview's interactive features
// (maximise / view modes / window presets / colour maps / 3D camera /
// accessibility text / window sizing). AppKit-free so the rules are tested on
// the Linux harness; the extension only wires events to them.

// MARK: - Panels and view modes

/// The four quadrants of the 2×2 preview. `auxiliary` is the fourth quadrant:
/// the metadata panel by default, or an alternate view (`PreviewViewMode`).
public enum PreviewPanel: String, CaseIterable, Sendable, Hashable {
    case coronal
    case sagittal
    case axial
    case auxiliary

    /// The slice plane a slice panel shows; `nil` for the auxiliary quadrant.
    public var plane: SlicePlane? {
        switch self {
        case .coronal: return .coronal
        case .sagittal: return .sagittal
        case .axial: return .axial
        case .auxiliary: return nil
        }
    }

    public init(plane: SlicePlane) {
        switch plane {
        case .coronal: self = .coronal
        case .sagittal: self = .sagittal
        case .axial: self = .axial
        }
    }
}

/// What the auxiliary (fourth) quadrant shows. `slices` is the classic layout —
/// three slice panels plus metadata.
public enum PreviewViewMode: String, CaseIterable, Sendable, Hashable {
    case slices
    case mip
    case minip
    case volume3D

    /// Short English title for menus and the quadrant badge.
    public var displayName: String {
        switch self {
        case .slices: return "Slices"
        case .mip: return "MIP"
        case .minip: return "MinIP"
        case .volume3D: return "3D"
        }
    }

    /// The projection this mode renders, if it is a projection mode.
    public var projectionMode: ProjectionMode? {
        switch self {
        case .mip: return .mip
        case .minip: return .minip
        case .slices, .volume3D: return nil
        }
    }

    /// Modes available for a volume. RGB data has no scalar intensities to
    /// project or ray-cast, so it only gets `slices`; `allows3D` lets the
    /// caller drop 3D (e.g. a single-slice image, where there is nothing to
    /// rotate).
    public static func available(isRGB: Bool, allows3D: Bool) -> [PreviewViewMode] {
        guard !isRGB else { return [.slices] }
        return allows3D ? [.slices, .mip, .minip, .volume3D] : [.slices, .mip, .minip]
    }
}

/// What a double-click did, for the caller to act on.
public enum PreviewDoubleClickOutcome: Sendable, Hashable {
    /// The panel was zoomed in: the zoom was reset and the layout is unchanged.
    case resetZoom
    /// The panel now fills the canvas.
    case maximized(PreviewPanel)
    /// The 2×2 layout is back.
    case restored
}

/// Layout state: which panel (if any) is maximised and what the auxiliary
/// quadrant shows.
public struct PreviewLayoutState: Sendable, Hashable {
    public private(set) var maximized: PreviewPanel?
    public private(set) var viewMode: PreviewViewMode = .slices
    /// The alternate mode "M" brings back after returning to metadata.
    public private(set) var lastAlternateMode: PreviewViewMode = .mip

    public init(maximized: PreviewPanel? = nil, viewMode: PreviewViewMode = .slices) {
        self.maximized = maximized
        self.viewMode = viewMode
        if viewMode != .slices { lastAlternateMode = viewMode }
    }

    /// Whether `panel` is on screen.
    public func isVisible(_ panel: PreviewPanel) -> Bool {
        maximized == nil || maximized == panel
    }

    /// The auxiliary quadrant shows an alternate view rather than metadata.
    public var showsAlternateView: Bool { viewMode != .slices }

    /// Double-click rule: a zoomed panel resets its zoom first; otherwise the
    /// panel toggles between maximised and the 2×2 layout. The metadata
    /// quadrant (auxiliary in `slices` mode) is never maximised.
    public mutating func handleDoubleClick(on panel: PreviewPanel, isZoomed: Bool) -> PreviewDoubleClickOutcome? {
        if isZoomed { return .resetZoom }
        return toggleMaximize(panel)
    }

    /// Maximise `panel`, or restore the layout if it is already maximised.
    /// `nil` when the request is ignored (the metadata quadrant).
    @discardableResult
    public mutating func toggleMaximize(_ panel: PreviewPanel) -> PreviewDoubleClickOutcome? {
        if maximized == panel {
            maximized = nil
            return .restored
        }
        if panel == .auxiliary, viewMode == .slices { return nil }
        maximized = panel
        return .maximized(panel)
    }

    /// Back to the 2×2 layout.
    public mutating func restore() {
        maximized = nil
    }

    /// Next mode in `available` (wrapping). Leaving an alternate mode while the
    /// auxiliary quadrant is maximised restores the layout, so the user isn't
    /// left with a maximised metadata panel.
    public mutating func cycleViewMode(available: [PreviewViewMode]) {
        setViewMode(Self.next(after: viewMode, in: available))
    }

    /// "M": metadata ⇄ the last alternate mode (if available).
    public mutating func toggleMetadata(available: [PreviewViewMode]) {
        if viewMode != .slices {
            setViewMode(.slices)
        } else if available.contains(lastAlternateMode) {
            setViewMode(lastAlternateMode)
        } else if let first = available.first(where: { $0 != .slices }) {
            setViewMode(first)
        }
    }

    public mutating func setViewMode(_ mode: PreviewViewMode) {
        viewMode = mode
        if mode != .slices { lastAlternateMode = mode }
        if mode == .slices, maximized == .auxiliary { maximized = nil }
    }

    static func next<T: Equatable>(after value: T, in list: [T]) -> T {
        guard !list.isEmpty else { return value }
        guard let i = list.firstIndex(of: value) else { return list[0] }
        return list[(i + 1) % list.count]
    }
}

// MARK: - Window presets

/// Keyboard / menu rules for `WindowPreset`.
public enum WindowPresetShortcuts {
    /// Digits 1…6 select `WindowPreset.fixedPresets` in menu order
    /// (Brain, Subdural, Stroke, Bone, Lung, Soft Tissue).
    public static func preset(forDigit digit: Int) -> WindowPreset? {
        let presets = WindowPreset.fixedPresets
        guard digit >= 1, digit <= presets.count else { return nil }
        return presets[digit - 1]
    }

    /// The digit that selects `preset`, or `nil` for `auto`.
    public static func digit(for preset: WindowPreset) -> Int? {
        WindowPreset.fixedPresets.firstIndex(of: preset).map { $0 + 1 }
    }

    /// Cycles auto → brain → … → soft tissue → auto.
    public static func next(after preset: WindowPreset) -> WindowPreset {
        PreviewLayoutState.next(after: preset, in: WindowPreset.allCases)
    }

    /// The preset to apply when a volume first becomes interactive, or `nil`
    /// to keep the percentile (auto) window. Only a volume that looks like CT
    /// gets one, and only when the user enabled auto-detection and chose a
    /// fixed preset (`MIQConfig.ctPresetAutoDetect` + `ctWindowPreset`).
    public static func initialPreset(looksLikeCT: Bool, autoDetect: Bool, configured: WindowPreset) -> WindowPreset? {
        guard looksLikeCT, autoDetect, configured != .auto else { return nil }
        return configured
    }

    /// The text for the on-image window badge: "Brain · W 80 / L 40" for a
    /// preset, "W 80 / L 40" for a manual window.
    public static func badgeText(preset: WindowPreset?, bounds: MIQIntensityWindowBounds) -> String {
        if let preset, preset != .auto {
            return "\(preset.displayName) · \(bounds.widthLevelLabel)"
        }
        return bounds.widthLevelLabel
    }
}

// MARK: - Colour maps

public enum ColormapCycle {
    /// The maps "C" cycles through for scalar images.
    public static let standard: [Colormap] = [.grayscale, .hot, .viridis, .inferno]

    /// `standard`, plus `suggested` when it isn't already in it (the diverging
    /// map for a signed statistic), placed right after grayscale.
    public static func options(suggested: Colormap) -> [Colormap] {
        guard !standard.contains(suggested) else { return standard }
        var list = standard
        list.insert(suggested, at: 1)
        return list
    }

    public static func next(after colormap: Colormap, in options: [Colormap]) -> Colormap {
        PreviewLayoutState.next(after: colormap, in: options)
    }

    /// Short menu title.
    public static func displayName(_ colormap: Colormap) -> String {
        switch colormap {
        case .grayscale: return "Grayscale"
        case .hot: return "Hot"
        case .cool: return "Cool"
        case .winter: return "Winter"
        case .viridis: return "Viridis"
        case .inferno: return "Inferno"
        case .diverging: return "Diverging"
        }
    }
}

// MARK: - 3D

extension VolumeRenderCamera {
    /// Elevation limit (degrees); just shy of the poles, where azimuth degenerates.
    public static let maxElevation: Float = 89
    public static let zoomRange: ClosedRange<Float> = 0.5...6

    /// Drag-to-rotate: horizontal drag spins azimuth, vertical drag tilts
    /// elevation (dragging up looks from above). Azimuth wraps to (-180, 180].
    public func rotated(dragX dx: Double, dragY dy: Double, degreesPerPoint: Float = 0.5) -> VolumeRenderCamera {
        guard dx.isFinite, dy.isFinite else { return self }
        var az = azimuth + Float(dx) * degreesPerPoint
        az = az.truncatingRemainder(dividingBy: 360)
        if az > 180 { az -= 360 }
        if az <= -180 { az += 360 }
        let el = min(Self.maxElevation, max(-Self.maxElevation, elevation + Float(dy) * degreesPerPoint))
        return VolumeRenderCamera(azimuth: az, elevation: el, zoom: zoom)
    }

    /// Multiplies zoom by `factor`, clamped to `zoomRange`.
    public func zoomed(by factor: Float) -> VolumeRenderCamera {
        guard factor.isFinite, factor > 0 else { return self }
        let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        return VolumeRenderCamera(azimuth: azimuth, elevation: elevation, zoom: z)
    }
}

public enum VolumeRenderModeCycle {
    /// Modes offered in the 3D view: a segmentation renders as labelled
    /// surfaces; scalar data as MIP or DVR.
    public static func available(isLabelVolume: Bool) -> [VolumeRenderMode] {
        isLabelVolume ? [.labels] : [.mip, .dvr]
    }

    public static func next(after mode: VolumeRenderMode, isLabelVolume: Bool) -> VolumeRenderMode {
        PreviewLayoutState.next(after: mode, in: available(isLabelVolume: isLabelVolume))
    }

    public static func displayName(_ mode: VolumeRenderMode) -> String {
        switch mode {
        case .mip: return "MIP"
        case .minIP: return "MinIP"
        case .dvr: return "DVR"
        case .labels: return "Labels"
        }
    }
}

// MARK: - Accessibility

public enum PreviewAccessibility {
    public static func planeName(_ plane: SlicePlane) -> String {
        switch plane {
        case .axial: return "Axial"
        case .coronal: return "Coronal"
        case .sagittal: return "Sagittal"
        }
    }

    /// "Axial slice 45 of 90, window W 80 / L 40". `sliceIndex` is 0-based;
    /// the label is 1-based. `window` nil (RGB, labels) drops the clause.
    public static func sliceLabel(plane: SlicePlane, sliceIndex: Int, sliceCount: Int, window: String?) -> String {
        let count = max(1, sliceCount)
        let index = min(count, max(1, sliceIndex + 1))
        var text = "\(planeName(plane)) slice \(index) of \(count)"
        if let window, !window.isEmpty { text += ", window \(window)" }
        return text
    }

    /// Accessibility value of the 4D scrubber: "Volume 3 of 20".
    public static func volumeValue(index: Int, count: Int) -> String {
        let c = max(1, count)
        return "Volume \(min(c, max(1, index + 1))) of \(c)"
    }
}

// MARK: - Window sizing

/// Preferred Quick Look window size for the 2×2 layout, from the slices'
/// on-screen sizes (already physical-aspect resampled, so their ratios are the
/// field-of-view ratios).
public enum PreviewWindowSizing {
    public static let minWidth: Double = 600
    public static let maxWidth: Double = 1100
    public static let minHeight: Double = 420
    public static let maxHeight: Double = 900
    public static let baseHeight: Double = 640
    public static let fallback = (width: 700.0, height: 600.0)

    /// The layout puts coronal | sagittal on top and axial | metadata below,
    /// with the column split coronal.width : sagittal.width and the row split
    /// coronal.height : axial.height (each ratio clamped to 0.25…4 like the
    /// view's constraints). The window's aspect is the sum of both.
    public static func preferredSize(
        coronalWidth: Double, coronalHeight: Double,
        sagittalWidth: Double, axialHeight: Double
    ) -> (width: Double, height: Double) {
        guard coronalWidth > 0, coronalHeight > 0, sagittalWidth > 0, axialHeight > 0,
              [coronalWidth, coronalHeight, sagittalWidth, axialHeight].allSatisfy(\.isFinite) else {
            return fallback
        }
        // Normalise to the sagittal column / coronal row = 1, applying the clamps.
        let column = min(4, max(0.25, coronalWidth / sagittalWidth))
        let row = min(4, max(0.25, axialHeight / coronalHeight))
        // Widths: column·s + s; heights: c + row·c — in panel units where the
        // sagittal panel width s and coronal height c are related by the
        // coronal image's own aspect (width column·s shows coronal at its aspect).
        let coronalAspect = coronalWidth / coronalHeight
        let s = 1.0
        let c = column * s / coronalAspect
        let totalWidth = column * s + s
        let totalHeight = c + row * c
        let aspect = totalWidth / totalHeight
        guard aspect.isFinite, aspect > 0 else { return fallback }
        let width = min(maxWidth, max(minWidth, baseHeight * aspect))
        let height = min(maxHeight, max(minHeight, width / aspect))
        return (width.rounded(), height.rounded())
    }
}
