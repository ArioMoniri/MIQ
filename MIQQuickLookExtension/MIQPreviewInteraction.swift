import AppKit
import MIQCore

// View-feature state for the Quick Look preview: window presets and the W/L
// badge, colour maps, sibling overlays, diffusion DEC colour, and the
// alternate fourth-quadrant views (via `MIQAlternateViewRenderer`). The model
// keeps owning loading and the plain grayscale render; this layer only reads
// `MIQPreviewModel.interactionSnapshot` and, when a feature changes what a
// slice looks like, renders its own "decorated" copy of the three slices off
// the main thread. With every feature off it does no pixel work at all.

/// Facts about the displayed volume that the features branch on. Derived once
/// per interactive-state generation, off the main thread.
struct MIQVolumeTraits: Sendable {
    let isRGB: Bool
    let isLabelVolume: Bool
    let looksLikeCT: Bool
    let suggestedColormap: Colormap
    /// More than one voxel along every spatial axis — something to rotate.
    let allows3D: Bool
    /// The 3-component view when the file is a diffusion vector field.
    let vectorComponents: MIQVolume?

    var colormapOptions: [Colormap] { ColormapCycle.options(suggested: suggestedColormap) }

    var availableViewModes: [PreviewViewMode] {
        PreviewViewMode.available(isRGB: isRGB, allows3D: allows3D)
    }

    /// Scalar intensities that a colour map / window badge applies to.
    var isScalar: Bool { !isRGB && !isLabelVolume }

    static func analyze(_ snapshot: MIQInteractionSnapshot, fileName: String) -> MIQVolumeTraits {
        let volume = snapshot.volume
        let header = volume.image.header
        let isRGB = header.datatype == .rgb24 || header.datatype == .rgba32
        // One representative slice is enough for the CT and sign heuristics.
        var minValue = Float.infinity
        var maxValue = -Float.infinity
        if !isRGB {
            let index = volume.sliceIndex(for: .axial, cursor: volume.centerCursor(), options: snapshot.options)
            if let sample = volume.displaySliceValues(plane: .axial, index: index, volumeIndex: 0, options: snapshot.options) {
                for v in sample.values where v.isFinite {
                    minValue = min(minValue, v)
                    maxValue = max(maxValue, v)
                }
            }
        }
        let hasSample = minValue <= maxValue
        let isFloat = header.datatype == .float32 || header.datatype == .float64
        let suggested = isRGB ? Colormap.grayscale : Colormap.suggested(
            intentCode: volume.niftiIntentCode,
            minValue: hasSample ? minValue : 0,
            maxValue: hasSample ? maxValue : 0,
            isFloatingPoint: isFloat
        )
        return MIQVolumeTraits(
            isRGB: isRGB,
            isLabelVolume: snapshot.segmentationLut != nil,
            looksLikeCT: !isRGB && WindowPreset.looksLikeCT(header: header, sampleMin: hasSample ? minValue : nil),
            suggestedColormap: suggested,
            allows3D: volume.width > 1 && volume.height > 1 && volume.depth > 1,
            vectorComponents: isRGB ? nil : DiffusionColor.vectorComponents(of: volume, fileName: fileName)
        )
    }
}

/// A sibling file offered as an overlay (from `SiblingFiles`).
struct MIQOverlayCandidate: Sendable, Hashable {
    let url: URL
    let fileName: String
    let role: SiblingRole

    /// Discrete maps: resampled nearest-neighbour and drawn as labels.
    var isLabelRole: Bool { role == .segmentation || role == .mask }

    var menuTitle: String {
        switch role {
        case .anatomical: return String(localized: "Underlay: \(fileName)", table: "Preview")
        case .fractionalAnisotropy: return String(localized: "Modulate DEC by: \(fileName)", table: "Preview")
        default: return String(localized: "Overlay: \(fileName)", table: "Preview")
        }
    }
}

/// A sibling volume resampled onto the previewed volume's grid.
struct MIQLoadedOverlay: Sendable {
    let candidate: MIQOverlayCandidate
    let volume: MIQVolume
    /// Label colours: the overlay's own for a segmentation; the *previewed*
    /// volume's for an anatomical underlay (the previewed file is the labels).
    let labelLut: SegmentationLut?
    let window: MIQIntensityWindowBounds?
}

/// Everything that changes how a slice is coloured, beyond the model's render.
struct MIQSliceDecoration: Sendable {
    let colormap: Colormap
    let overlay: MIQLoadedOverlay?
    let outlineOnly: Bool
    let opacity: Float
    let vectorComponents: MIQVolume?
    let fractionalAnisotropy: MIQVolume?
}

/// Identity of one decorated slice render; a panel re-renders only when its
/// key changes.
struct MIQDecorationKey: Hashable, Sendable {
    let plane: SlicePlane
    let index: Int
    let t: Int
    let window: MIQIntensityWindowBounds?
    let colormap: Colormap
    let overlay: URL?
    let outlineOnly: Bool
    let opacity: Float
    let dec: Bool
    let decFA: Bool
    let generation: Int
}

enum MIQSliceDecorator {
    /// Renders one decorated slice. Runs off the main thread.
    static func render(plane: SlicePlane, snapshot: MIQInteractionSnapshot, decoration: MIQSliceDecoration) -> RGBABitmap? {
        let volume = snapshot.volume
        let options = snapshot.options
        let index = volume.sliceIndex(for: plane, cursor: snapshot.cursor, options: options)
        let t = snapshot.cursor.t

        var base: RGBABitmap?
        var layerSource: (volume: MIQVolume, volumeIndex: Int, style: OverlayStyle)?

        if let components = decoration.vectorComponents {
            base = DiffusionColor.slice(
                components: components, plane: plane, index: index,
                fa: decoration.fractionalAnisotropy,
                maxDimension: snapshot.maxDimension, options: options
            )?.rgbaBitmap()
        } else if let overlay = decoration.overlay, overlay.candidate.role == .anatomical {
            // The previewed file is a segmentation: anatomy underneath, its
            // labels on top.
            let under = overlay.volume.slice(
                plane: plane, index: index, volumeIndex: 0,
                maxDimension: snapshot.maxDimension, options: options,
                windowBounds: overlay.window, lut: nil
            )
            base = under.rgbaBitmap()
            if let lut = overlay.labelLut {
                layerSource = (volume, t, .labels(lut, outlineOnly: decoration.outlineOnly))
            }
        } else {
            let slice = volume.slice(
                plane: plane, index: index, volumeIndex: t,
                maxDimension: snapshot.maxDimension, options: options,
                windowBounds: snapshot.windowBounds, lut: snapshot.segmentationLut
            )
            base = colorize(slice, plane: plane, index: index, snapshot: snapshot, colormap: decoration.colormap)
        }

        if layerSource == nil, let overlay = decoration.overlay,
           overlay.candidate.role != .anatomical, overlay.candidate.role != .fractionalAnisotropy {
            let style: OverlayStyle
            if let lut = overlay.labelLut {
                style = .labels(lut, outlineOnly: decoration.outlineOnly)
            } else {
                let w = overlay.window ?? MIQIntensityWindowBounds(low: 0, high: 1)
                style = .scalar(ScalarColorMapping(colormap: .hot, low: w.low, high: w.high, threshold: w.low))
            }
            layerSource = (overlay.volume, 0, style)
        }

        guard let baseBitmap = base else { return nil }
        guard let source = layerSource,
              let values = source.volume.displaySliceValues(plane: plane, index: index, volumeIndex: source.volumeIndex, options: options),
              let layer = OverlayCompositor.layer(
                values: values.values, width: values.width, height: values.height,
                style: source.style, toWidth: baseBitmap.width, toHeight: baseBitmap.height
              ) else { return baseBitmap }
        return OverlayCompositor.composite(base: baseBitmap, overlay: layer, opacity: decoration.opacity) ?? baseBitmap
    }

    /// The slice through `colormap`. The diverging map is centred on zero, so
    /// it maps the raw values symmetrically instead of the windowed bytes.
    static func colorize(
        _ slice: SliceImage,
        plane: SlicePlane,
        index: Int,
        snapshot: MIQInteractionSnapshot,
        colormap: Colormap
    ) -> RGBABitmap? {
        guard snapshot.segmentationLut == nil, colormap != .grayscale, case .grayscale(let gray) = slice else {
            return slice.rgbaBitmap()
        }
        if colormap.isDiverging, let window = snapshot.windowBounds,
           let raw = snapshot.volume.displaySliceValues(plane: plane, index: index, volumeIndex: snapshot.cursor.t, options: snapshot.options) {
            let scaled = OverlayCompositor.resizeNearest(
                raw.values, width: raw.width, height: raw.height, toWidth: gray.width, toHeight: gray.height
            )
            let mapping = ScalarColorMapping.diverging(limit: max(abs(window.low), abs(window.high)))
            if let bitmap = mapping.rgbaBitmap(values: scaled, width: gray.width, height: gray.height) {
                return opaque(bitmap)
            }
        }
        return gray.rgbaBitmap(colormap: colormap)
    }

    /// Non-finite voxels come back transparent from `ScalarColorMapping`; show
    /// them black like the grayscale path does.
    static func opaque(_ bitmap: RGBABitmap) -> RGBABitmap {
        var bytes = [UInt8](bitmap.pixels)
        var i = 3
        while i < bytes.count {
            bytes[i] = 255
            i += 4
        }
        return RGBABitmap(width: bitmap.width, height: bitmap.height, pixels: Data(bytes))
    }
}

@MainActor
final class MIQInteractionController {
    /// Something visible changed (decorated slices landed, badge timeout,
    /// alternate view image, menus' state).
    var onChange: (() -> Void)?

    let alternate = MIQAlternateViewRenderer()

    private weak var model: MIQPreviewModel?
    private(set) var layout = PreviewLayoutState()
    /// The slice plane last interacted with; the projection follows it.
    private(set) var activePlane: SlicePlane = .axial

    private(set) var traits: MIQVolumeTraits?
    private var traitsGeneration: Int?
    private var traitsTask: Task<Void, Never>?
    private var appliedInitialPreset = false
    private var appliedInitialColormap = false
    /// The configured default map when it isn't in the standard cycle
    /// (e.g. "cool"), so "C" can come back to it.
    private var configuredExtraColormap: Colormap?

    /// The preset behind the current manual window, for the badge and menu
    /// check marks; `nil` for auto or a free W/L drag.
    private(set) var activePreset: WindowPreset?
    private(set) var isAdjustingWindow = false
    private var adjustingTask: Task<Void, Never>?
    private static let badgeLingerNanoseconds: UInt64 = 1_500_000_000

    private(set) var colormap: Colormap = .grayscale

    /// `nil` until the (off-main) sibling lookup finished; empty when the
    /// directory can't be listed (the usual Quick Look sandbox case) — the
    /// overlay menu items then simply don't appear.
    private(set) var overlayCandidates: [MIQOverlayCandidate]?
    private var candidatesTask: Task<Void, Never>?
    private(set) var overlay: MIQLoadedOverlay?
    private(set) var loadingOverlay: MIQOverlayCandidate?
    private var overlayTask: Task<Void, Never>?
    private(set) var overlayOutlineOnly = true
    private(set) var overlayOpacity: Float = 0.5
    private static let maxCandidates = 8

    /// DEC colour is on by default whenever the file is a vector field.
    private(set) var decEnabled = true
    private var fractionalAnisotropy: MIQVolume?
    private(set) var fractionalAnisotropyName: String?

    private var decoratedImages: [SlicePlane: NSImage] = [:]
    private var decoratedKeys: [SlicePlane: MIQDecorationKey] = [:]
    private var decorationTask: Task<Void, Never>?

    init() {
        alternate.onChange = { [weak self] in self?.onChange?() }
    }

    // MARK: Model binding

    /// Called on every model change. A new model (new file) resets all state.
    func modelDidChange(_ model: MIQPreviewModel) {
        if model !== self.model {
            reset()
            self.model = model
        }
        guard let snapshot = model.interactionSnapshot else { return }
        if traitsGeneration != snapshot.generation {
            analyzeTraits(snapshot, fileName: model.interactionFileURL.lastPathComponent)
        }
        // A reset back to auto (or a fresh load) clears the preset marker.
        if !model.hasManualWindow { activePreset = nil }
        startDecorationRender()
        refreshAlternate()
    }

    private func reset() {
        traitsTask?.cancel(); traitsTask = nil
        candidatesTask?.cancel(); candidatesTask = nil
        overlayTask?.cancel(); overlayTask = nil
        decorationTask?.cancel(); decorationTask = nil
        adjustingTask?.cancel(); adjustingTask = nil
        traits = nil
        traitsGeneration = nil
        appliedInitialPreset = false
        appliedInitialColormap = false
        configuredExtraColormap = nil
        activePreset = nil
        isAdjustingWindow = false
        colormap = .grayscale
        overlayCandidates = nil
        overlay = nil
        loadingOverlay = nil
        overlayOutlineOnly = true
        overlayOpacity = 0.5
        decEnabled = true
        fractionalAnisotropy = nil
        fractionalAnisotropyName = nil
        decoratedImages = [:]
        decoratedKeys = [:]
        layout = PreviewLayoutState()
        activePlane = .axial
        alternate.reset()
    }

    private func analyzeTraits(_ snapshot: MIQInteractionSnapshot, fileName: String) {
        traitsGeneration = snapshot.generation
        traitsTask?.cancel()
        traitsTask = Task { [weak self] in
            let job = Task.detached(priority: .utility) {
                MIQVolumeTraits.analyze(snapshot, fileName: fileName)
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.traitsTask = nil
            self.traits = result
            self.applyInitialColormapIfNeeded(result)
            if !self.colormapOptions.contains(self.colormap) { self.colormap = .grayscale }
            if !self.availableViewModes.contains(self.layout.viewMode) { self.layout.setViewMode(.slices) }
            self.applyInitialPresetIfNeeded(result)
            self.lookUpOverlayCandidatesIfNeeded()
            self.restartDecorations()
            self.refreshAlternate()
            self.onChange?()
        }
    }

    /// The first colour map for a file: `MIQConfig.defaultColormap`, or with
    /// "Auto" (nil) `Colormap.suggested` (diverging for signed statistics, hot
    /// for positive ones, grayscale otherwise). Scalar data only.
    private func applyInitialColormapIfNeeded(_ traits: MIQVolumeTraits) {
        guard !appliedInitialColormap else { return }
        appliedInitialColormap = true
        guard traits.isScalar else { return }
        let initial = MIQConfig.defaultColormap ?? traits.suggestedColormap
        configuredExtraColormap = traits.colormapOptions.contains(initial) ? nil : initial
        colormap = initial
    }

    /// Maps "C" cycles through for this file.
    var colormapOptions: [Colormap] {
        guard let traits else { return [.grayscale] }
        var options = traits.colormapOptions
        if let extra = configuredExtraColormap, !options.contains(extra) { options.append(extra) }
        return options
    }

    private func applyInitialPresetIfNeeded(_ traits: MIQVolumeTraits) {
        guard !appliedInitialPreset, let model else { return }
        appliedInitialPreset = true
        guard !model.hasManualWindow,
              let preset = WindowPresetShortcuts.initialPreset(
                looksLikeCT: traits.looksLikeCT,
                autoDetect: MIQConfig.ctPresetAutoDetect,
                configured: MIQConfig.ctWindowPreset
              ) else { return }
        applyPreset(preset)
    }

    // MARK: Layout

    func noteActive(plane: SlicePlane) {
        guard plane != activePlane else { return }
        activePlane = plane
        refreshAlternate()
    }

    /// Double-click / menu maximise. Returns the outcome so the view can
    /// reset a zoom when asked to.
    @discardableResult
    func handleDoubleClick(on panel: PreviewPanel, isZoomed: Bool) -> PreviewDoubleClickOutcome? {
        let outcome = layout.handleDoubleClick(on: panel, isZoomed: isZoomed)
        refreshAlternate()
        onChange?()
        return outcome
    }

    func toggleMaximize(_ panel: PreviewPanel) {
        layout.toggleMaximize(panel)
        refreshAlternate()
        onChange?()
    }

    func restoreLayout() {
        guard layout.maximized != nil else { return }
        layout.restore()
        refreshAlternate()
        onChange?()
    }

    /// MIP / MinIP / 3D only when enabled in Settings (`MIQConfig.volumeRenderingEnabled`).
    var availableViewModes: [PreviewViewMode] {
        guard MIQConfig.volumeRenderingEnabled else { return [.slices] }
        return traits?.availableViewModes ?? [.slices]
    }

    func cycleViewMode() {
        layout.cycleViewMode(available: availableViewModes)
        refreshAlternate()
        onChange?()
    }

    func toggleMetadata() {
        layout.toggleMetadata(available: availableViewModes)
        refreshAlternate()
        onChange?()
    }

    func setViewMode(_ mode: PreviewViewMode) {
        guard availableViewModes.contains(mode) else { return }
        layout.setViewMode(mode)
        refreshAlternate()
        onChange?()
    }

    // MARK: Window / level

    /// A right-drag is adjusting the window: the badge shows now and lingers
    /// briefly after the drag; the result is a free window, not a preset.
    func noteWindowAdjusting() {
        activePreset = nil
        isAdjustingWindow = true
        adjustingTask?.cancel()
        adjustingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.badgeLingerNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.isAdjustingWindow = false
            self.onChange?()
        }
    }

    func applyPreset(_ preset: WindowPreset) {
        guard let model else { return }
        if let bounds = preset.bounds {
            activePreset = preset
            model.setManualWindow(bounds)
        } else {
            activePreset = nil
            model.setManualWindow(nil)
        }
        onChange?()
    }

    /// Digit shortcuts select presets only on data that looks like CT —
    /// Hounsfield windows are meaningless elsewhere (the menu still offers them).
    var presetShortcutsEnabled: Bool { traits?.looksLikeCT == true }

    /// "W 80 / L 40" (or "Brain · W 80 / L 40") while adjusting and whenever
    /// the window isn't auto; `nil` otherwise and for RGB / labels / DEC.
    var windowBadgeText: String? {
        guard let model, let traits, traits.isScalar, decVolume == nil,
              isAdjustingWindow || model.hasManualWindow,
              let bounds = model.displayedWindowBounds else { return nil }
        return PreviewL10n.core(
            WindowPresetShortcuts.badgeText(preset: model.hasManualWindow ? activePreset : nil, bounds: bounds)
        )
    }

    /// The window clause for accessibility labels (always, when there is one).
    var windowAccessibilityText: String? {
        guard let model, traits?.isScalar != false, let bounds = model.displayedWindowBounds else { return nil }
        return bounds.widthLevelLabel
    }

    // MARK: Colour maps / DEC

    var colormapAvailable: Bool { traits?.isScalar == true && decVolume == nil }

    func cycleColormap() {
        guard colormapAvailable else { return }
        setColormap(ColormapCycle.next(after: colormap, in: colormapOptions))
    }

    func setColormap(_ map: Colormap) {
        guard colormapAvailable, map != colormap else { return }
        colormap = map
        restartDecorations()
        refreshAlternate()
        onChange?()
    }

    var decAvailable: Bool { traits?.vectorComponents != nil }
    private var decVolume: MIQVolume? { decEnabled ? traits?.vectorComponents : nil }

    func toggleDEC() {
        guard decAvailable else { return }
        decEnabled.toggle()
        restartDecorations()
        onChange?()
    }

    // MARK: Overlays

    private func lookUpOverlayCandidatesIfNeeded() {
        guard overlayCandidates == nil, candidatesTask == nil, let model else { return }
        // Off in Settings: no directory listing at all.
        guard MIQConfig.overlayAutoDiscovery else {
            overlayCandidates = []
            return
        }
        let url = model.interactionFileURL
        let limit = Self.maxCandidates
        candidatesTask = Task { [weak self] in
            // Listing can block on a network mount, and fails silently in the
            // Quick Look sandbox (then the feature just isn't offered).
            let job = Task.detached(priority: .utility) { () -> [MIQOverlayCandidate] in
                MIQInteractionController.overlayCandidates(near: url, limit: limit)
            }
            let found = await job.value
            guard let self, !Task.isCancelled else { return }
            self.candidatesTask = nil
            self.overlayCandidates = found
            self.onChange?()
        }
    }

    func loadOverlay(_ candidate: MIQOverlayCandidate) {
        guard let snapshot = model?.interactionSnapshot else { return }
        overlayTask?.cancel()
        loadingOverlay = candidate
        onChange?()
        let primary = snapshot.volume
        let primaryLut = snapshot.segmentationLut
        let options = snapshot.options
        overlayTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) {
                MIQInteractionController.loadOverlayVolume(candidate, primary: primary, primaryLut: primaryLut, options: options)
            }
            let loaded = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.overlayTask = nil
            self.loadingOverlay = nil
            if let loaded {
                if candidate.role == .fractionalAnisotropy {
                    self.fractionalAnisotropy = loaded.volume
                    self.fractionalAnisotropyName = candidate.fileName
                } else {
                    self.overlay = loaded
                }
            } else {
                // Unreadable sibling (sandbox, format): nothing to show.
                NSSound.beep()
            }
            self.restartDecorations()
            self.onChange?()
        }
    }

    func removeOverlay() {
        overlayTask?.cancel()
        overlayTask = nil
        loadingOverlay = nil
        overlay = nil
        fractionalAnisotropy = nil
        fractionalAnisotropyName = nil
        restartDecorations()
        onChange?()
    }

    var hasOverlay: Bool { overlay != nil }

    /// "O": label outlines ⇄ filled labels.
    func toggleOverlayOutline() {
        guard overlay?.labelLut != nil else { return }
        overlayOutlineOnly.toggle()
        restartDecorations()
        onChange?()
    }

    func setOverlayOpacity(_ value: Float) {
        let clamped = min(1, max(0.05, value))
        guard abs(clamped - overlayOpacity) > 0.0001 else { return }
        overlayOpacity = clamped
        restartDecorations()
        onChange?()
    }

    func stepOverlayOpacity(_ steps: Int) {
        setOverlayOpacity(overlayOpacity + Float(steps) * 0.05)
    }

    /// Up to `limit` overlay files next to `url` (segmentation directories are
    /// left out). Lists the directory, so call it off the MainActor.
    private nonisolated static func overlayCandidates(near url: URL, limit: Int) -> [MIQOverlayCandidate] {
        SiblingFiles.candidateURLs(for: url).compactMap { pair -> MIQOverlayCandidate? in
            guard pair.candidate.role != .segmentationDirectory else { return nil }
            return MIQOverlayCandidate(url: pair.url, fileName: pair.candidate.fileName, role: pair.candidate.role)
        }.prefix(limit).map { $0 }
    }

    nonisolated static func loadOverlayVolume(
        _ candidate: MIQOverlayCandidate,
        primary: MIQVolume,
        primaryLut: SegmentationLut?,
        options: RenderingOptions
    ) -> MIQLoadedOverlay? {
        guard let image = try? MIQParser().parse(url: candidate.url) else { return nil }
        let source = MIQVolume(image: image)
        guard !Task.isCancelled,
              let resampled = OverlayResampler.resampledVolume(
                source,
                ontoGridOf: primary,
                interpolation: candidate.isLabelRole ? .nearest : .trilinear,
                isCancelled: { Task.isCancelled }
              ) else { return nil }
        switch candidate.role {
        case .anatomical:
            return MIQLoadedOverlay(
                candidate: candidate,
                volume: resampled,
                labelLut: primaryLut ?? primary.overlayLabelLut(orientation: options.orientation),
                window: resampled.fixedCenterWindow(options: options)
            )
        case .segmentation, .mask:
            return MIQLoadedOverlay(
                candidate: candidate,
                volume: resampled,
                labelLut: source.overlayLabelLut(orientation: options.orientation),
                window: nil
            )
        case .probabilisticSegmentation, .fractionalAnisotropy, .segmentationDirectory:
            return MIQLoadedOverlay(
                candidate: candidate,
                volume: resampled,
                labelLut: nil,
                window: resampled.fixedCenterWindow(options: options)
            )
        }
    }

    // MARK: Decorated slices

    /// The decorated image for `plane`, or `nil` to show the model's own.
    func decoratedImage(for plane: SlicePlane) -> NSImage? {
        decorationActive ? decoratedImages[plane] : nil
    }

    private var decorationActive: Bool {
        guard let traits else { return false }
        if decVolume != nil || overlay != nil { return true }
        return traits.isScalar && colormap != .grayscale
    }

    private func currentDecoration() -> MIQSliceDecoration {
        MIQSliceDecoration(
            colormap: colormapAvailable ? colormap : .grayscale,
            overlay: overlay,
            outlineOnly: overlayOutlineOnly,
            opacity: overlayOpacity,
            vectorComponents: decVolume,
            fractionalAnisotropy: decVolume == nil ? nil : fractionalAnisotropy
        )
    }

    private func key(for plane: SlicePlane, snapshot: MIQInteractionSnapshot, decoration: MIQSliceDecoration) -> MIQDecorationKey {
        MIQDecorationKey(
            plane: plane,
            index: snapshot.volume.sliceIndex(for: plane, cursor: snapshot.cursor, options: snapshot.options),
            // DEC slices ignore the timepoint and the window.
            t: decoration.vectorComponents == nil ? snapshot.cursor.t : 0,
            window: decoration.vectorComponents == nil ? snapshot.windowBounds : nil,
            colormap: decoration.colormap,
            overlay: decoration.overlay?.candidate.url,
            outlineOnly: decoration.outlineOnly,
            opacity: decoration.opacity,
            dec: decoration.vectorComponents != nil,
            decFA: decoration.fractionalAnisotropy != nil,
            generation: snapshot.generation
        )
    }

    /// A setting changed: drop the in-flight render (its keys are stale) and
    /// start over. Old decorated images stay up until the new ones land.
    private func restartDecorations() {
        decorationTask?.cancel()
        decorationTask = nil
        if !decorationActive {
            decoratedImages = [:]
            decoratedKeys = [:]
        }
        startDecorationRender()
    }

    /// One render at a time; on completion it re-checks the latest state, so a
    /// fast scroll coalesces into "render whatever is current" like the
    /// model's own render queue.
    private func startDecorationRender() {
        guard decorationTask == nil, decorationActive,
              let snapshot = model?.interactionSnapshot else { return }
        let decoration = currentDecoration()
        let wanted = SlicePlane.allCases
            .map { (plane: $0, key: key(for: $0, snapshot: snapshot, decoration: decoration)) }
            .filter { decoratedKeys[$0.plane] != $0.key }
        guard !wanted.isEmpty else { return }

        decorationTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> [(SlicePlane, MIQDecorationKey, RGBABitmap)] in
                var out: [(SlicePlane, MIQDecorationKey, RGBABitmap)] = []
                for item in wanted {
                    if Task.isCancelled { break }
                    if let bitmap = MIQSliceDecorator.render(plane: item.plane, snapshot: snapshot, decoration: decoration) {
                        out.append((item.plane, item.key, bitmap))
                    }
                }
                return out
            }
            let results = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.decorationTask = nil
            for (plane, key, bitmap) in results {
                if let image = MIQImageBridge.makeNSImage(from: bitmap) {
                    self.decoratedImages[plane] = image
                    self.decoratedKeys[plane] = key
                }
            }
            self.onChange?()
            self.startDecorationRender()
        }
    }

    // MARK: Alternate view

    /// Pixel size of the alternate tile, pushed by the view on layout.
    var alternatePixelSize = CGSize(width: 256, height: 256) {
        didSet { if alternatePixelSize != oldValue { refreshAlternate() } }
    }

    private func refreshAlternate() {
        // Hidden behind a maximised slice panel: no work until it's back.
        guard layout.showsAlternateView, layout.isVisible(.auxiliary),
              let snapshot = model?.interactionSnapshot, let traits else {
            alternate.suspend()
            return
        }
        alternate.update(
            mode: layout.viewMode,
            plane: activePlane,
            snapshot: snapshot,
            colormap: colormapAvailable ? colormap : .grayscale,
            isLabelVolume: traits.isLabelVolume,
            pixelSize: alternatePixelSize
        )
    }
}
