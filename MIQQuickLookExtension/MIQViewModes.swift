import AppKit
import MIQCore

/// Renders the fourth-quadrant alternate views — MIP / MinIP projections and
/// the 3D volume rendering — entirely off the main thread.
///
/// * Projections are one full pass over a timepoint, so each result is cached
///   per (plane, mode, timepoint, colour map, volume generation).
/// * 3D builds its `VolumeRenderGrid` once per (volume generation, timepoint,
///   label-ness), then every camera change cancels the previous frame and
///   renders a quick low-resolution frame followed, after a short idle, by a
///   full-resolution one. The first Metal access (kernel compile + CPU
///   cross-check) therefore also happens off the main thread.
@MainActor
final class MIQAlternateViewRenderer {
    var onChange: (() -> Void)?

    private(set) var image: NSImage?
    /// True while the image on screen is stale or missing and work is running.
    private(set) var isBusy = false
    private(set) var caption = ""
    /// Draw with interpolation: 3D frames are rendered near screen resolution
    /// (and stretched while a low-res drag frame is up); projections are voxel
    /// data and stay nearest-neighbour like the slices.
    private(set) var smoothsImage = false
    /// Shown instead of an image (e.g. nothing to project).
    private(set) var placeholder: String?
    private(set) var camera = VolumeRenderCamera.anterior
    private(set) var renderMode: VolumeRenderMode = .dvr
    private(set) var isLabelVolume = false

    private struct ProjectionKey: Hashable {
        let plane: SlicePlane
        let mode: ProjectionMode
        let t: Int
        let colormap: Colormap
        let generation: Int
    }

    private struct GridKey: Hashable {
        let generation: Int
        let t: Int
        let asLabels: Bool
    }

    private var currentMode: PreviewViewMode = .slices
    private var projectionCache: [ProjectionKey: NSImage] = [:]
    private var projectionOrder: [ProjectionKey] = []
    private static let projectionCacheLimit = 12
    private static let projectionUnavailable = String(localized: "Projection not available for this image", table: "Preview")
    private var projectionTask: Task<Void, Never>?
    private var projectionTaskKey: ProjectionKey?
    /// Projections that came back empty (RGB data): not retried per scroll step.
    private var failedProjections: Set<ProjectionKey> = []

    private var grid: VolumeRenderGrid?
    private var gridKey: GridKey?
    private var gridTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var segmentationLut: SegmentationLut?
    private var pixelSize = CGSize(width: 256, height: 256)
    private var lastRenderedSignature: RenderSignature?

    private struct RenderSignature: Equatable {
        let grid: GridKey
        let camera: VolumeRenderCamera
        let mode: VolumeRenderMode
        let width: Int
        let height: Int
    }

    /// Grid edge for the 3D view. 128³ keeps a CPU frame interactive; Metal
    /// would cope with more, but the preview is a glance, not a workstation.
    private static let gridMaxDimension = 128
    private static let interactiveSide = 160
    private static let maxSide = 512
    private static let refineDelayNanoseconds: UInt64 = 180_000_000

    // MARK: Inputs

    func update(
        mode: PreviewViewMode,
        plane: SlicePlane,
        snapshot: MIQInteractionSnapshot,
        colormap: Colormap,
        isLabelVolume: Bool,
        pixelSize: CGSize
    ) {
        if mode != currentMode {
            currentMode = mode
            image = nil
            lastRenderedSignature = nil
        }
        self.pixelSize = pixelSize
        self.isLabelVolume = isLabelVolume
        self.segmentationLut = snapshot.segmentationLut
        if !VolumeRenderModeCycle.available(isLabelVolume: isLabelVolume).contains(renderMode) {
            renderMode = VolumeRenderModeCycle.available(isLabelVolume: isLabelVolume)[0]
        }
        if let projection = mode.projectionMode {
            cancel3D()
            updateProjection(plane: plane, mode: projection, snapshot: snapshot, colormap: colormap)
        } else if mode == .volume3D {
            cancelProjection()
            update3D(snapshot: snapshot)
        } else {
            suspend()
        }
    }

    /// The alternate view is hidden: stop work (caches stay).
    func suspend() {
        cancelProjection()
        cancel3D()
        if currentMode != .slices {
            currentMode = .slices
            image = nil
            isBusy = false
        }
    }

    /// New file: drop everything, including the camera.
    func reset() {
        suspend()
        projectionCache = [:]
        projectionOrder = []
        failedProjections = []
        grid = nil
        gridKey = nil
        camera = .anterior
        renderMode = .dvr
        lastRenderedSignature = nil
        placeholder = nil
    }

    // MARK: Projections

    private func updateProjection(plane: SlicePlane, mode: ProjectionMode, snapshot: MIQInteractionSnapshot, colormap: Colormap) {
        let key = ProjectionKey(plane: plane, mode: mode, t: snapshot.cursor.t, colormap: colormap, generation: snapshot.generation)
        caption = PreviewL10n.core("\(mode.displayName) · \(PreviewAccessibility.planeName(plane))")
        smoothsImage = false
        if let cached = projectionCache[key] {
            cancelProjection()
            // Change-gated: this runs on every model change (each scroll step).
            if image !== cached || isBusy { setImage(cached, busy: false) }
            return
        }
        if failedProjections.contains(key) {
            cancelProjection()
            if image != nil || placeholder == nil {
                placeholder = Self.projectionUnavailable
                setImage(nil, busy: false)
            }
            return
        }
        guard projectionTaskKey != key else { return }
        cancelProjection()
        projectionTaskKey = key
        setBusy(true)
        let volume = snapshot.volume
        let options = snapshot.options
        let maxDimension = snapshot.maxDimension
        projectionTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> RGBABitmap? in
                guard let slice = volume.projection(
                    plane: plane, mode: mode, volumeIndex: key.t,
                    maxDimension: maxDimension, options: options, windowBounds: nil
                ), !Task.isCancelled else { return nil }
                if colormap != .grayscale, case .grayscale(let gray) = slice {
                    return gray.rgbaBitmap(colormap: colormap)
                }
                return slice.rgbaBitmap()
            }
            let bitmap = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.projectionTask = nil
            self.projectionTaskKey = nil
            guard let bitmap, let image = MIQImageBridge.makeNSImage(from: bitmap) else {
                self.failedProjections.insert(key)
                self.placeholder = MIQAlternateViewRenderer.projectionUnavailable
                self.setImage(nil, busy: false)
                return
            }
            self.store(image, for: key)
            self.setImage(image, busy: false)
        }
    }

    private func store(_ image: NSImage, for key: ProjectionKey) {
        projectionCache[key] = image
        projectionOrder.removeAll { $0 == key }
        projectionOrder.append(key)
        while projectionOrder.count > Self.projectionCacheLimit {
            projectionCache[projectionOrder.removeFirst()] = nil
        }
    }

    private func cancelProjection() {
        projectionTask?.cancel()
        projectionTask = nil
        projectionTaskKey = nil
    }

    // MARK: 3D

    func rotate(dx: CGFloat, dy: CGFloat) {
        camera = camera.rotated(dragX: Double(dx), dragY: Double(dy))
        scheduleRender()
    }

    func zoom(by factor: CGFloat) {
        camera = camera.zoomed(by: Float(factor))
        scheduleRender()
    }

    func resetCamera() {
        camera = .anterior
        scheduleRender()
    }

    func cycleRenderMode() {
        renderMode = VolumeRenderModeCycle.next(after: renderMode, isLabelVolume: isLabelVolume)
        scheduleRender()
    }

    func setRenderMode(_ mode: VolumeRenderMode) {
        guard VolumeRenderModeCycle.available(isLabelVolume: isLabelVolume).contains(mode) else { return }
        renderMode = mode
        scheduleRender()
    }

    private func update3D(snapshot: MIQInteractionSnapshot) {
        smoothsImage = true
        updateCaption3D()
        let asLabels = isLabelVolume
        let key = GridKey(generation: snapshot.generation, t: snapshot.cursor.t, asLabels: asLabels)
        if key == gridKey {
            if grid != nil { scheduleRender() }
            return
        }
        // New volume / timepoint: rebuild the grid once, off the main thread.
        gridKey = key
        grid = nil
        renderTask?.cancel()
        gridTask?.cancel()
        setBusy(true)
        let volume = snapshot.volume
        let maxDimension = Self.gridMaxDimension
        gridTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) {
                VolumeRenderGrid(volume: volume, volumeIndex: key.t, maxDimension: maxDimension, asLabels: asLabels)
            }
            let built = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled, self.gridKey == key else { return }
            self.gridTask = nil
            self.grid = built
            self.lastRenderedSignature = nil
            self.scheduleRender()
        }
    }

    private func cancel3D() {
        gridTask?.cancel()
        gridTask = nil
        renderTask?.cancel()
        renderTask = nil
        // A grid whose build was cancelled must be rebuilt next time.
        if grid == nil { gridKey = nil }
    }

    private func updateCaption3D() {
        caption = PreviewL10n.core("3D · \(VolumeRenderModeCycle.displayName(renderMode))")
    }

    /// Debounced render: cancels the previous frame, shows a quick low-res
    /// frame, then refines after a short idle period.
    private func scheduleRender() {
        guard currentMode == .volume3D, let grid, let gridKey else { return }
        updateCaption3D()
        let full = Self.renderSize(for: pixelSize, maxSide: Self.maxSide)
        let signature = RenderSignature(grid: gridKey, camera: camera, mode: renderMode, width: full.width, height: full.height)
        guard signature != lastRenderedSignature else { return }
        renderTask?.cancel()
        let quick = Self.renderSize(for: pixelSize, maxSide: Self.interactiveSide)
        let camera = self.camera
        let mode = self.renderMode
        let labelColors = segmentationLut?.volumeLabelColorMap
        if image == nil { setBusy(true) }
        renderTask = Task { [weak self] in
            do {
                let low = try await MIQAlternateViewRenderer.render(
                    grid: grid, camera: camera, mode: mode, labelColors: labelColors, width: quick.width, height: quick.height
                )
                guard let self, !Task.isCancelled else { return }
                if let lowImage = MIQImageBridge.makeNSImage(from: low) { self.setImage(lowImage, busy: false) }
                try await Task.sleep(nanoseconds: MIQAlternateViewRenderer.refineDelayNanoseconds)
                let high = try await MIQAlternateViewRenderer.render(
                    grid: grid, camera: camera, mode: mode, labelColors: labelColors, width: full.width, height: full.height
                )
                guard !Task.isCancelled else { return }
                if let highImage = MIQImageBridge.makeNSImage(from: high) { self.setImage(highImage, busy: false) }
                self.lastRenderedSignature = signature
                self.renderTask = nil
            } catch {
                // Cancelled by a newer camera change, or a render error; the
                // next interaction retries.
            }
        }
    }

    /// The render itself runs on a detached task (never the main thread),
    /// with this task's cancellation forwarded into it.
    nonisolated private static func render(
        grid: VolumeRenderGrid,
        camera: VolumeRenderCamera,
        mode: VolumeRenderMode,
        labelColors: VolumeLabelColorMap?,
        width: Int,
        height: Int
    ) async throws -> RGBABitmap {
        let job = Task.detached(priority: .userInitiated) { () throws -> RGBABitmap in
            var options = VolumeRenderOptions()
            options.labelColor = labelColors
            return try await VolumeRenderer.render(
                grid: grid, camera: camera, mode: mode, window: nil,
                width: width, height: height, options: options
            )
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Output size with the tile's aspect, longest side `maxSide`.
    nonisolated static func renderSize(for pixelSize: CGSize, maxSide: Int) -> (width: Int, height: Int) {
        let w = max(1, pixelSize.width)
        let h = max(1, pixelSize.height)
        let scale = Double(maxSide) / Double(max(w, h))
        let s = min(1, scale)
        return (max(16, Int((Double(w) * s).rounded())), max(16, Int((Double(h) * s).rounded())))
    }

    // MARK: Output

    private func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        if busy { placeholder = nil }
        onChange?()
    }

    private func setImage(_ newImage: NSImage?, busy: Bool) {
        image = newImage
        isBusy = busy
        if newImage != nil { placeholder = nil }
        onChange?()
    }
}
