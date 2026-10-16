import AppKit
import Foundation
import OSLog
import MIQCore

@MainActor
final class MIQPreviewModel {
    private let logger = MIQLogger.make(category: "model")

    private struct RawPreviewData: Sendable {
        /// 8-bit grey for grayscale slices, RGBA for colour / LUT output.
        let slices: [SlicePlane: PreviewSliceBitmap]
        let orientations: [SlicePlane: SliceOrientationLabels]
        let metadataEntries: [MetadataEntry]
        /// Always-visible panel warnings (orientation caution, sidecar mismatch).
        let panelWarnings: [String]
        /// Format-specific rows drawn after the configurable ones (DICOM).
        let extraEntries: [MetadataEntry]
        let interactiveState: InteractivePreviewState
    }

    private struct InteractivePreviewState: Sendable {
        let volume: MIQVolume
        let options: RenderingOptions
        let maxDimension: Int
        let windowBounds: MIQIntensityWindowBounds?
        let segmentationLut: SegmentationLut?
        let centerCursor: MIQVolumeCursor

        /// The same state over another backing volume — a streamed single
        /// volume, rendered as its volume 0 with this state's window and LUT.
        func replacingVolume(_ volume: MIQVolume) -> InteractivePreviewState {
            InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: windowBounds,
                segmentationLut: segmentationLut,
                centerCursor: centerCursor
            )
        }
    }

    /// The cold-preview memory gate refused the file (header-only probe, run
    /// inside the read lane); carries the display message.
    private struct ColdPreviewRefusal: Error, Sendable {
        let message: String
    }

    enum State {
        case idle
        case loading
        case ready
        case failed(String)
        /// A large file on a network volume whose full read was deferred behind a
        /// placeholder (see `MIQConfig.deferLargeNetworkPreviews`). Carries the
        /// display name and on-disk size for the placeholder. `forceFullRead`
        /// (the "Load preview" button) bypasses the gate and parses normally.
        case deferred(name: String, sizeBytes: Int)
        /// A well-formed scalar volume with no finite voxel in volume 0.
        /// Not `.failed` — nothing went wrong, there is just nothing to render, and
        /// the resulting black grid is otherwise indistinguishable from a bug.
        case noFiniteVoxels

        /// For the unified log, which records `.public` values in plain text:
        /// `.deferred`'s name and `.failed`'s message (Cocoa I/O errors quote the
        /// file name) can carry patient identifiers, so neither is included.
        var logDescription: String {
            switch self {
            case .idle: return "idle"
            case .loading: return "loading"
            case .ready: return "ready"
            case .failed: return "failed"
            case .deferred(_, let sizeBytes): return "deferred(\(sizeBytes / (1024 * 1024))MB)"
            case .noFiniteVoxels: return "noFiniteVoxels"
            }
        }
    }

    /// Lifecycle of the lazy full-decompression for 4D `.nii.gz`. Every other
    /// kind is `.notNeeded` (uncompressed `.nii` is mmap'd; `.mgz`/`.mif.gz`
    /// already decompress in full; 3D `.nii.gz`'s volume-0 budget is the whole
    /// payload). `.pending` files re-parse fully the first time the user steps
    /// past volume 0; until `.expanded`, volumes > 0 render the zero backstop.
    /// `.failed` keeps volumes > 0 on the backstop *without* retrying on every
    /// step (no storm), but is reset to `.pending` at the next scroll-gesture
    /// start so a transient failure isn't permanent for the session.
    /// Over `MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes` the
    /// payload is never expanded in full. A canonical NIfTI (`.nii`/`.nii.gz`)
    /// goes `.streaming` instead: each volume > 0 is decoded on demand by
    /// `volumeStream` while scrubbing. Every other kind goes `.tooLarge`, which
    /// is final for the model: volume 0 stays on screen and volumes > 0 keep
    /// the zero backstop.
    private enum ExpansionState: Equatable {
        case notNeeded
        case pending
        case expanding
        case expanded
        case failed
        case streaming
        case tooLarge(bytes: Int)
    }

    var state: State = .idle
    var coronal: NSImage?
    var sagittal: NSImage?
    var axial: NSImage?
    var coronalOrientation = SliceOrientationLabels.placeholderCoronal
    var sagittalOrientation = SliceOrientationLabels.placeholderSagittal
    var axialOrientation = SliceOrientationLabels.placeholderAxial
    var metadataEntries: [MetadataEntry] = []
    /// Caution lines the panel shows whatever the field toggles say.
    private(set) var panelWarnings: [String] = [] { didSet { panelRevision &+= 1 } }
    /// DICOM technical rows (cached with the bundle).
    private var extraEntries: [MetadataEntry] = [] { didSet { panelRevision &+= 1 } }
    /// "Data QC" rows from `QCAnalyzer`, once the background pass lands.
    private var qcEntries: [MetadataEntry] = [] { didSet { panelRevision &+= 1 } }
    /// The temporal (tSNR / spike) row, once its background pass lands.
    private var temporalEntry: MetadataEntry? { didSet { panelRevision &+= 1 } }
    /// Bumped whenever `panelWarnings` or `panelAppendix` change, so the view's
    /// rebuild gate compares one integer instead of the row arrays.
    private(set) var panelRevision = 0
    /// Whether a deferred placeholder is for a dataless cloud file (iCloud "not
    /// downloaded") rather than a file on a network volume.
    private(set) var deferredIsDataless = false
    var onChange: (() -> Void)?
    private(set) var hasInteracted = false

    private let url: URL
    private let fileKind: MIQFileKind?
    private let maxDimension = 512
    private var renderingOptions: RenderingOptions?
    private var interactiveState: InteractivePreviewState? {
        didSet {
            renderGate.advance()
            snapshotGeneration &+= 1
            // A streamed source belongs to the state it was opened for.
            volumeStream = nil
            streamedVolume = nil
            streamedVolumeLoading = false
            streamedVolumeFailed = false
        }
    }
    /// Advanced on every `interactiveState` swap (fresh parse, cache-hit prep, 4D
    /// expansion). A render takes a ticket at start and asks the gate on
    /// completion (`RenderGenerationGate.decision`): a cancelled render is
    /// dropped, and one whose state was swapped meanwhile shows its pixels but
    /// must not remember the auto window it derived from a buffer that is no
    /// longer current (e.g. the volume-0-capped one).
    private var renderGate = RenderGenerationGate()
    private var interactiveStateGeneration: Int { renderGate.current }
    /// Set on a cache hit for a file the large-network gate would defer: the
    /// cached frame is shown, but the full read waits for the first interaction.
    private var interactivePreparationDeferred = false
    /// Volume count from a cache hit's bundle, until the interactive state lands.
    private var cachedVolumeCount: Int?
    private var expansionState: ExpansionState = .notNeeded
    private var expansionTask: Task<Void, Never>?
    /// The cold parse `load()` is awaiting. Owned by the model (not only by the
    /// controller's load task) so `deinit` can cancel it.
    private var coldLoadTask: Task<RawPreviewData, Error>?
    /// Whether this file is on a network volume, from `load()`'s probe. Its reads
    /// then go through `NetworkReadLane`.
    private var readsOverNetwork = false
    /// The last load's read was dropped because no preview wanted the file any
    /// more (`NetworkReadLane.Superseded`) — so this preview was off screen. The
    /// model is `.idle`; the controller reloads if it comes back into view.
    private(set) var loadSuperseded = false
    private var currentCursor: MIQVolumeCursor?
    private var displayedCursor: MIQVolumeCursor?
    private var windowAdjustment: MIQIntensityWindowBounds?
    /// `MIQConfig.perVolumeIntensityWindow` captured at `load()`. Settings can
    /// only change while no preview is open, so it is fixed for an interaction.
    private var perVolumeWindow = false
    /// `MIQConfig.windowFromHeadMask` captured at `load()` (it is part of the
    /// cache key, so it must not change between the key and the parse).
    private var windowFromHeadMask = false
    /// Per-volume source while `expansionState == .streaming`: a 4D NIfTI over
    /// the decompression budget, decoded one volume at a time as the user
    /// scrubs (`NiftiVolumeReader`). Cleared whenever the interactive state is
    /// replaced.
    private var volumeStream: NiftiVolumeReader?
    /// The streamed volume the slices currently show (`t` > 0), for the
    /// crosshair value readout.
    private var streamedVolume: (t: Int, volume: MIQVolume)? {
        didSet { snapshotGeneration &+= 1 }
    }
    /// `MIQInteractionSnapshot.generation`: bumped on every interactive-state
    /// swap *and* every streamed volume change, since for a streamed series
    /// the snapshot's volume is the displayed timepoint (addressed as t = 0),
    /// so view-feature caches keyed on (generation, t) must not collide.
    private var snapshotGeneration = 0
    /// A streamed volume read is in flight (the Volumes line says
    /// "decompressing…").
    private var streamedVolumeLoading = false
    /// The last streamed read failed; cleared at the next scroll gesture.
    private var streamedVolumeFailed = false
    /// The auto (non-manual) window the most recent render actually applied. In
    /// per-volume mode this is the displayed volume's own window, so a W/L drag
    /// starts from what's on screen instead of snapping back to volume 0.
    private var lastAppliedAutoBounds: MIQIntensityWindowBounds?
    /// Per-timepoint auto window, memoized so revisiting a volume in per-volume
    /// mode doesn't re-decode its 3 center slices each time (`fixedCenterWindow`
    /// is the dominant per-step cost while scrubbing a 4D series). Keyed by `t`;
    /// only populated/consulted when `perVolumeWindow` is on and no manual W/L
    /// override is active. Cleared whenever the backing volume changes (fresh
    /// parse, cache-hit interactive prep, 4D expansion swap) since the bounds
    /// depend on the volume's pixels.
    private var perVolumeWindowCache: [Int: MIQIntensityWindowBounds] = [:]
    private var pendingForceRender = false
    private var interactionPreparationTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pendingRenderCursor: MIQVolumeCursor?
    /// The background QC / temporal passes. Cancelled with the rest of the
    /// in-flight work; `summaryGeneration` (bumped per `load()`) keeps a stale
    /// pass from landing after a reload.
    private var qcTask: Task<Void, Never>?
    private var temporalTask: Task<Void, Never>?
    private var summaryGeneration = 0
    private var qcStarted = false
    private var temporalStarted = false
    /// One window for the whole 4D series when `perVolumeWindow` is off
    /// (`MIQVolume.sharedVolumeWindow`), computed off-main on the first volume
    /// step and again once a capped buffer has been expanded. `nil` until then,
    /// which keeps volume 0's window.
    private var sharedWindow: MIQIntensityWindowBounds?
    private var sharedWindowTask: Task<Void, Never>?
    /// `interactiveStateGeneration` `sharedWindow` was computed for.
    private var sharedWindowGeneration: Int?

    init(url: URL) {
        self.url = url
        self.fileKind = MIQFileKind(url: url)
    }

    /// Reached only because no task below holds `self` across its `await`: each
    /// binds `self` strongly only *after* the detached work returns. A task that
    /// did `guard let self` up front would keep this model alive until its work
    /// finished, so this cancellation could never run while there was anything to
    /// cancel.
    deinit {
        coldLoadTask?.cancel()
        interactionPreparationTask?.cancel()
        renderTask?.cancel()
        expansionTask?.cancel()
        qcTask?.cancel()
        temporalTask?.cancel()
        sharedWindowTask?.cancel()
    }

    /// Stops every in-flight background task: interactive-state prep, the 4D
    /// expansion re-parse, and the render queue — for a model being discarded.
    /// Used by `load()` to reset, and by the controller if it ever replaces its
    /// model. `runCancelableDetached` forwards the cancellation into the chunked
    /// network reads.
    func cancelInFlightWork() {
        coldLoadTask?.cancel()
        coldLoadTask = nil
        interactionPreparationTask?.cancel()
        interactionPreparationTask = nil
        renderTask?.cancel()
        renderTask = nil
        pendingRenderCursor = nil
        expansionTask?.cancel()
        expansionTask = nil
        qcTask?.cancel()
        qcTask = nil
        temporalTask?.cancel()
        temporalTask = nil
        sharedWindowTask?.cancel()
        sharedWindowTask = nil
    }

    /// A 4D buffer that was loaded with the volume-0 cap (any `.nii.gz`, or a
    /// `.nii`/`.nii.gz` on a network volume via the bounded-prefix read) hides
    /// volumes > 0 until expanded. Detected from the actual payload rather than the
    /// file kind, so the bounded uncompressed `.nii` case isn't missed.
    private static func needsExpansion(volume: MIQVolume) -> Bool {
        volume.volumes > 1 && !volume.containsAllVolumes
    }

    /// - Parameters:
    ///   - forceFullRead: when `true` (the placeholder's "Load preview" button),
    ///     bypass the large-network-preview gate and parse normally. The default
    ///     cold load respects the gate.
    ///   - navigating: from `NetworkReadLane.requestStarted`, which the controller
    ///     calls before this: the user is moving through files, so a network read
    ///     waits briefly before starting.
    func load(forceFullRead: Bool = false, navigating: Bool = false) async {
        state = .loading
        onChange?()
        let fileURL = self.url
        let kind = self.fileKind
        // The gate's on/off flag is a cheap UserDefaults read, fine on the
        // MainActor; the actual locality + size probe (which can block on a hung
        // mount) runs inside the detached task below.
        let applyNetworkGate = !forceFullRead && MIQConfig.deferLargeNetworkPreviews
        let options = RenderingOptions(
            lowerPercentile: MIQConfig.windowLowerPercentile,
            upperPercentile: MIQConfig.windowUpperPercentile,
            orientation: MIQConfig.imageOrientation,
            segmentationColoring: MIQConfig.segmentationColoring
        )
        let maxDimension = self.maxDimension
        // Read before the cache short-circuit so the interactive path honours it
        // on a cache hit too (the setting only affects volumes > 0, never the
        // cached volume-0 cold preview — see MIQConfig.perVolumeIntensityWindow).
        perVolumeWindow = MIQConfig.perVolumeIntensityWindow
        // Changes the cold preview's pixels, so it is also in the cache key.
        let headMaskWindow = MIQConfig.windowFromHeadMask
        windowFromHeadMask = headMaskWindow
        // File names carry patient identifiers: log a stable tag, never the name.
        logger.notice("load() started: file=\(MIQLogRedaction.fileTag(fileURL), privacy: .public)")
        logger.notice("MIQConfig percentiles: lower=\(options.lowerPercentile, privacy: .public), upper=\(options.upperPercentile, privacy: .public), orientation=\(options.orientation.rawValue, privacy: .public), showAxisLabels=\(MIQConfig.showAxisLabels, privacy: .public)")

        // The controller creates one model per URL, and a second load() only comes
        // from the deferred placeholder, so there is never state worth keeping.
        cancelInFlightWork()
        loadSuperseded = false
        interactivePreparationDeferred = false
        renderingOptions = options
        interactiveState = nil
        cachedVolumeCount = nil
        expansionState = .notNeeded
        perVolumeWindowCache = [:]
        currentCursor = nil
        displayedCursor = nil
        hasInteracted = false
        windowAdjustment = nil
        pendingForceRender = false
        pendingRenderCursor = nil
        summaryGeneration &+= 1
        qcStarted = false
        temporalStarted = false
        qcEntries = []
        temporalEntry = nil
        sharedWindow = nil
        sharedWindowGeneration = nil
        deferredIsDataless = false

        do {
            // The cache key stats the file (mtime) and the gate probes locality and
            // size; either can block on a hung network mount, so both run off the
            // MainActor. Only the String key and the size come back — cached
            // bundles hold NSImages, so the lookup itself stays on the MainActor.
            //
            // A dataless cloud placeholder (iCloud Drive "Optimize Mac Storage",
            // other File Providers) is routed like a network file: reading it
            // downloads it, so its reads go through `NetworkReadLane` and a large
            // one is deferred behind the "Load preview" placeholder.
            let probe = try await Self.runCancelableDetached { () -> (cacheKey: String, isLocal: Bool, isDataless: Bool, deferralSizeBytes: Int?) in
                let cacheKey = MIQPreviewCache.makeKey(fileURL: fileURL, maxDimension: maxDimension, options: options, windowFromHeadMask: headMaskWindow)
                let isDataless = VolumeLocation.isDataless(fileURL)
                let isLocal = VolumeLocation.isLocal(fileURL) && !isDataless
                let deferralSizeBytes: Int?
                if !applyNetworkGate || isLocal {
                    deferralSizeBytes = nil
                } else if isDataless {
                    deferralSizeBytes = Self.datalessDeferralSizeBytes(fileURL: fileURL)
                } else {
                    deferralSizeBytes = Self.networkDeferralSizeBytes(fileURL: fileURL, kind: kind)
                }
                return (cacheKey, isLocal, isDataless, deferralSizeBytes)
            }
            try Task.checkCancellation()
            readsOverNetwork = !probe.isLocal

            if let cached = MIQPreviewCache.bundle(for: probe.cacheKey) {
                apply(bundle: cached)
                state = .ready
                onChange?()
                if probe.deferralSizeBytes != nil {
                    // The gate would have deferred this file: show the cached frame
                    // but don't pull the whole file until the user interacts.
                    interactivePreparationDeferred = true
                    logger.notice("load() cache hit — interactive state deferred to first interaction (large network file)")
                } else {
                    // On a share this re-read goes through the lane like a cold
                    // load: it waits `dwell` while the user navigates and is
                    // stopped as soon as they move on, so revisiting cached files
                    // doesn't compete with Finder — but it is ready (or under way)
                    // by the time the user interacts.
                    logger.notice("load() cache hit — applying cached center preview, preparing interactive state")
                    prepareInteractiveState(fileURL: fileURL, options: options, navigating: navigating, claimsNewest: false)
                }
                return
            }

            if let sizeBytes = probe.deferralSizeBytes {
                deferredIsDataless = probe.isDataless
                state = .deferred(name: fileURL.lastPathComponent, sizeBytes: sizeBytes)
                logger.notice("load() deferred large network preview: \(sizeBytes / (1024 * 1024), privacy: .public)MB")
                onChange?()
                return
            }

            // The header-only memory gate (≤ 64 KB read: a tiny file whose header
            // claims a multi-GB payload must not make the cold parse allocate it)
            // runs first *inside* the read closure, so on a network volume or for
            // a dataless cloud file its probe waits in `NetworkReadLane` with the
            // rest of the read — dwell while navigating, newest file first —
            // instead of issuing an immediate read (or iCloud download) per file
            // the user arrows past. It throws `ColdPreviewRefusal`, caught below.
            let overNetwork = readsOverNetwork
            let coldLoad = Task {
                try await Self.sharedColdLoad(key: probe.cacheKey) {
                    try await MIQPreviewModel.readColdPreview(
                        overNetwork: overNetwork, fileURL: fileURL, navigating: navigating,
                        options: options, maxDimension: maxDimension, windowFromHeadMask: headMaskWindow
                    )
                }
            }
            coldLoadTask = coldLoad
            // An unstructured task doesn't inherit cancellation, so forward the
            // controller's (a dismissed preview) explicitly.
            let raw = try await withTaskCancellationHandler {
                try await coldLoad.value
            } onCancel: {
                coldLoad.cancel()
            }
            coldLoadTask = nil
            // Applied either way — metadata and orientation are valid even with
            // nothing to window.
            apply(raw: raw)
            if Self.hasNoFiniteVoxels(raw) {
                // Not cached: the cache short-circuit at the top of load() would
                // return `.ready` next time and drop the explanation.
                state = .noFiniteVoxels
                logger.notice("load() finished: volume has no finite voxel values")
            } else {
                MIQPreviewCache.insert(makeBundle(from: raw), for: probe.cacheKey)
                state = .ready
                logger.notice("load() finished successfully")
            }
            onChange?()
        } catch let refusal as ColdPreviewRefusal {
            coldLoadTask = nil
            state = .failed(refusal.message)
            logger.notice("load() declined: header exceeds the cold-preview memory budget")
            onChange?()
        } catch is NetworkReadLane.Superseded {
            state = .idle
            loadSuperseded = true
            logger.notice("load() dropped: no preview wants this file any more")
        } catch is CancellationError {
            // Preview dismissed/replaced mid-parse (e.g. a large file abandoned on
            // a slow network mount). The load task is being torn down — leave state
            // untouched and don't surface a failure.
            logger.notice("load() canceled before completion")
        } catch {
            // Cocoa I/O errors quote the file name: keep the text out of the public log.
            logger.error("load() failed: \(error.localizedDescription, privacy: .private)")
            // `unsupportedFeature` reasons are written for display (e.g. which
            // DICOM compression is missing) and shown verbatim.
            state = .failed(PreviewStatusText.failureMessage(for: error))
            onChange?()
        }
    }

    /// The interactive state for an input event, or `nil` while it isn't ready
    /// (the event is dropped). If the large-network gate deferred preparation on
    /// a cache hit, this first interaction is what starts it.
    private func interactiveStateForInteraction() -> InteractivePreviewState? {
        if let interactiveState { return interactiveState }
        if interactivePreparationDeferred, let renderingOptions {
            interactivePreparationDeferred = false
            logger.notice("first interaction — preparing deferred interactive state")
            prepareInteractiveState(fileURL: url, options: renderingOptions)
        }
        return nil
    }

    func scrollGestureBegan() {
        _ = interactiveStateForInteraction()
        // The in-flight render may have been a forced full render (after W/L or
        // the 4D expansion swap) whose `pendingForceRender` was already consumed.
        // Cancelled, it never repaints, so the diff against `displayedCursor`
        // would skip planes that are stale — re-arm the force so the next render
        // repaints all three.
        if let renderTask {
            renderTask.cancel()
            pendingForceRender = true
        }
        renderTask = nil
        pendingRenderCursor = nil
        // A new gesture earns one more expansion attempt after a prior failure.
        if expansionState == .failed { expansionState = .pending }
        // ...and one more streamed read; a cancelled one is no longer loading.
        streamedVolumeFailed = false
        streamedVolumeLoading = false
    }

    func stepSlice(plane: SlicePlane, deltaSteps: Int) {
        guard deltaSteps != 0, let interactiveState = interactiveStateForInteraction() else { return }
        hasInteracted = true
        let cursor = currentCursor ?? interactiveState.centerCursor
        let geometry = interactiveState.volume.sliceGeometry(for: plane, options: interactiveState.options)
        let dimensions = [interactiveState.volume.width, interactiveState.volume.height, interactiveState.volume.depth]
        let currentIndex = cursor.coordinate(forAxis: geometry.sliceAxis)
        let nextIndex = max(0, min(dimensions[geometry.sliceAxis] - 1, currentIndex + deltaSteps))
        guard nextIndex != currentIndex else { return }

        var coordinates = [cursor.x, cursor.y, cursor.z]
        coordinates[geometry.sliceAxis] = nextIndex
        let updated = MIQVolumeCursor(x: coordinates[0], y: coordinates[1], z: coordinates[2], t: cursor.t)
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    /// Step along the 4th (volume/time) axis, leaving x/y/z untouched. No-op for
    /// 3D files. Reuses the same throttled render path as `stepSlice`. For a
    /// volume-0-capped `.nii.gz`, timepoints > 0 render the zero backstop until
    /// the lazy-expand (kicked off here on first 4D intent) swaps in the fully
    /// decompressed volume.
    func stepVolume(deltaSteps: Int) {
        guard deltaSteps != 0, let interactiveState = interactiveStateForInteraction() else { return }
        let volumes = interactiveState.volume.volumes
        guard volumes > 1 else { return }
        let cursor = currentCursor ?? interactiveState.centerCursor
        applyVolume(cursor.t + deltaSteps, interactiveState: interactiveState)
    }

    /// Absolute timepoint seek (the metadata scrubber). Same path as
    /// `stepVolume`; clamps into range and is a no-op for 3D files.
    func setVolume(to index: Int) {
        guard let interactiveState = interactiveStateForInteraction(), interactiveState.volume.volumes > 1 else { return }
        applyVolume(index, interactiveState: interactiveState)
    }

    /// Total number of volumes along the 4th axis (1 for 3D).
    var volumeCount: Int { interactiveState?.volume.volumes ?? cachedVolumeCount ?? 1 }

    /// Current timepoint the preview is showing.
    var currentVolumeIndex: Int { currentCursor?.t ?? 0 }

    private func applyVolume(_ requestedT: Int, interactiveState: InteractivePreviewState) {
        let cursor = currentCursor ?? interactiveState.centerCursor
        let nextT = max(0, min(interactiveState.volume.volumes - 1, requestedT))
        guard nextT != cursor.t else { return }
        hasInteracted = true

        let updated = MIQVolumeCursor(x: cursor.x, y: cursor.y, z: cursor.z, t: nextT)
        guard updated != currentCursor else { return }

        currentCursor = updated
        triggerExpansionIfNeeded()
        ensureSharedWindowIfNeeded()
        onChange?()
        scheduleRender(for: updated)
    }

    /// What the Volumes line says about the lazy 4D expansion: nothing, a
    /// "decompressing" affordance while it runs, or that it failed — without the
    /// last, volumes > 0 render the zero backstop with no explanation.
    enum VolumeExpansionStatus: Equatable {
        case idle
        case expanding
        case failed
        /// The full payload is over the preview's decompression budget; carries
        /// the short user-facing message (e.g. "Too large for 4D in Quick Look
        /// (4.3 GB)").
        case tooLarge(message: String)
    }

    var volumeExpansionStatus: VolumeExpansionStatus {
        switch expansionState {
        case .expanding: return .expanding
        case .failed: return .failed
        case .tooLarge(let bytes): return .tooLarge(message: MIQPayloadSizeEstimate.tooLargeFor4DMessage(bytes: bytes))
        // Per-volume decoding keeps the scrubber; "decompressing…" while the
        // volume about to be shown is read.
        case .streaming:
            if streamedVolumeFailed { return .failed }
            return streamedVolumeLoading ? .expanding : .idle
        case .notNeeded, .pending, .expanded: return .idle
        }
    }

    /// Kick the one-time full decompression for a 4D `.nii.gz`. Idempotent:
    /// guarded by `expansionState`, and the model is `@MainActor` so the
    /// `.pending` → `.expanding` transition can't race a second caller.
    private func triggerExpansionIfNeeded() {
        guard expansionState == .pending, let interactiveState else { return }
        // Refuse before decompressing: a multi-GB series would get the extension
        // killed mid-gunzip (Apple publishes no Quick Look memory limit, so the
        // budget is a conservative named constant). Volume 0 stays on screen and
        // the Volumes line says why the rest is unavailable; the caller's
        // `onChange` repaints it.
        let header = interactiveState.volume.image.header
        if header.exceedsFullDecompressionBudget() {
            // NIfTI keeps time outermost with no strides, so a single volume is
            // a byte range of the (decompressed) file: decode just the volume
            // being shown. Opening the reader does no I/O.
            if interactiveState.volume.image.payloadElementStrides == nil,
               let reader = try? MIQParser().niftiVolumeReader(url: url, header: header, isLocal: !readsOverNetwork) {
                volumeStream = reader
                expansionState = .streaming
                logger.notice("4D over the Quick Look budget — decoding single volumes on demand")
                // Shared mode needs ≤ 8 sampled volumes; where that would pull
                // the whole compressed series over the network, fall back to
                // per-volume windows — and the window-mode row says so.
                if !perVolumeWindow,
                   !PreviewDataSummaries.streamedSharedWindowAllowed(compressed: reader.isCompressed, readsOverNetwork: readsOverNetwork) {
                    perVolumeWindow = true
                    logger.notice("streamed 4D on a network volume: per-volume windows instead of a shared window")
                }
                // The caller (`applyVolume`) runs `ensureSharedWindowIfNeeded`.
                startDataSummariesIfNeeded()
                return
            }
            let bytes = header.estimatedPayloadBytes ?? Int.max
            expansionState = .tooLarge(bytes: bytes)
            logger.notice("4D expansion skipped: full payload \(bytes / (1024 * 1024), privacy: .public)MB exceeds the Quick Look budget")
            return
        }
        expansionState = .expanding
        let fileURL = self.url
        let options = interactiveState.options
        let maxDimension = interactiveState.maxDimension
        let windowBounds = interactiveState.windowBounds
        let segmentationLut = interactiveState.segmentationLut
        let overNetwork = readsOverNetwork

        // `self` stays weak across the await (see deinit) and the statics are named
        // by type, not `Self`, so nothing in the closure retains the model.
        expansionTask = Task { [weak self] in
            do {
                let expanded = try await MIQPreviewModel.runRead(overNetwork: overNetwork, url: fileURL, navigating: false, claimsNewest: true, label: "expand") { parser in
                    try MIQPreviewModel.loadExpandedInteractiveState(
                        parser: parser,
                        fileURL: fileURL,
                        options: options,
                        maxDimension: maxDimension,
                        windowBounds: windowBounds,
                        segmentationLut: segmentationLut
                    )
                }
                guard let self, !Task.isCancelled else { return }
                self.expansionTask = nil
                self.interactiveState = expanded
                self.lastAppliedAutoBounds = expanded.segmentationLut == nil ? expanded.windowBounds : nil
                // t>0 windows memoized against the capped buffer (zero backstop)
                // are stale now that the real volumes are present.
                self.perVolumeWindowCache = [:]
                self.expansionState = .expanded
                self.logger.notice("4D expansion complete — full decompression swapped in")
                // Every volume is present now: the shared window can sample the
                // whole series, and the temporal summary can run.
                self.ensureSharedWindowIfNeeded()
                self.startDataSummariesIfNeeded()
                // The cursor is unchanged but the underlying volume is not, so
                // force every plane to re-render against the real data.
                self.scheduleFullRender()
                self.onChange?()
            } catch is NetworkReadLane.Superseded {
                // Another file took the link; the next 4D step retries.
                guard let self, !Task.isCancelled else { return }
                self.expansionTask = nil
                self.expansionState = .pending
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.expansionTask = nil
                // `.failed` (not `.notNeeded`): no retry on every subsequent
                // step within this gesture (no storm), but `scrollGestureBegan`
                // resets it to `.pending` so the *next* gesture retries — a
                // transient failure (I/O, security scope) isn't permanent.
                // Volumes > 0 keep the zero backstop; volume 0 stays correct.
                self.expansionState = .failed
                self.logger.error("4D expansion failed: \(error.localizedDescription, privacy: .private)")
                // Repaint so the Volumes line drops "decompressing…" and says so.
                self.onChange?()
            }
        }
    }

    func updateCursor(plane: SlicePlane, normalizedPoint: MIQNormalizedPoint) {
        guard let interactiveState = interactiveStateForInteraction() else { return }
        hasInteracted = true
        let cursor = currentCursor ?? interactiveState.centerCursor
        let sliceIndex = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
        let updated = interactiveState.volume.cursor(
            for: plane,
            sliceIndex: sliceIndex,
            normalizedPoint: normalizedPoint,
            options: interactiveState.options,
            t: cursor.t
        )
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    func adjustWindow(deltaX: CGFloat, deltaY: CGFloat) {
        guard let interactiveState = interactiveStateForInteraction() else { return }
        // Drag starts from the window currently on screen: in per-volume mode
        // that's the displayed volume's own window (lastAppliedAutoBounds), not
        // volume 0's. `nil` only when there is no window at all (RGB-only).
        guard let initialBounds = lastAppliedAutoBounds ?? interactiveState.windowBounds else { return }

        let current = windowAdjustment ?? initialBounds
        // Relative, not absolute: data with tiny values (~1e-9) must stay
        // adjustable. A zero-width window (only left for a constant volume, since
        // `MIQVolume` widens a mask's window over the whole volume) scales the drag
        // by the value's own magnitude instead, or 1 for an all-zero volume.
        let span = initialBounds.high - initialBounds.low
        let magnitude = abs(initialBounds.low)
        let fallbackRange: Float = magnitude > 0 ? magnitude : 1
        let initialRange = span > 0 ? span : fallbackRange
        let sensitivity = initialRange * 0.005
        let minWidth = initialRange * 0.01

        let level = (current.high + current.low) / 2 + Float(deltaY) * sensitivity
        let width = max(minWidth, (current.high - current.low) + Float(deltaX) * sensitivity)
        windowAdjustment = MIQIntensityWindowBounds(low: level - width / 2, high: level + width / 2)
        onChange?()
        scheduleFullRender()
    }

    func crosshairPoint(for plane: SlicePlane) -> MIQNormalizedPoint? {
        guard hasInteracted, let interactiveState, let currentCursor else { return nil }
        return interactiveState.volume.normalizedPoint(for: plane, cursor: currentCursor, options: interactiveState.options)
    }

    /// Whether the live voxel-value line should occupy a slot in the metadata
    /// panel. Tracks crosshair visibility exactly (`crosshairPoint` is gated the
    /// same way): absent on the cold/first-frame preview, present once the user
    /// has interacted. Used by the view to insert/remove the value line — a
    /// one-time structural change, not a per-frame one.
    var showsVoxelValue: Bool {
        guard hasInteracted, let interactiveState else { return false }
        let dt = interactiveState.volume.image.header.datatype
        return dt != .rgb24 && dt != .rgba32
    }

    /// Formatted image intensity at the current crosshair voxel, for the live
    /// readout. Only meaningful while `showsVoxelValue`. Returns "—" when the
    /// value is unavailable — notably timepoints > 0 of a 4D `.nii.gz` whose
    /// full decompression hasn't landed yet (those read the zero backstop, which
    /// must not be shown as a real 0).
    var crosshairVoxelText: String? {
        guard showsVoxelValue, let interactiveState, let cursor = currentCursor else { return nil }
        if cursor.t > 0, !interactiveState.volume.containsAllVolumes {
            // A streamed volume on screen holds the real values (as its volume 0).
            guard let streamed = streamedVolume, streamed.t == cursor.t else { return "—" }
            let value = streamed.volume.voxel(x: cursor.x, y: cursor.y, z: cursor.z, t: 0)
            return MetadataPanelText.formatVoxelValue(value, lut: interactiveState.segmentationLut)
        }
        let value = interactiveState.volume.voxel(x: cursor.x, y: cursor.y, z: cursor.z, t: cursor.t)
        // A label map names the value ("17 Left-Hippocampus").
        return MetadataPanelText.formatVoxelValue(value, lut: interactiveState.segmentationLut)
    }

    /// Whether the live crosshair-position line occupies a panel slot. Same gate
    /// as the crosshair itself; unlike the value it applies to RGB data too.
    var showsVoxelPosition: Bool {
        hasInteracted && interactiveState != nil
    }

    /// "i, j, k  (x, y, z mm)" for the crosshair voxel. The cursor addresses
    /// stored voxels in every display mode (see
    /// `MIQMetadata.voxelPositionText(cursor:header:)`), so it maps through the
    /// header's affine directly.
    var crosshairPositionText: String? {
        guard showsVoxelPosition, let interactiveState, let cursor = currentCursor else { return nil }
        return MIQMetadata.voxelPositionText(cursor: cursor, header: interactiveState.volume.image.header)
    }

    /// Rows drawn after the configurable fields: DICOM technical rows, then the
    /// "Data QC" section (QC rows and the temporal summary).
    var panelAppendix: [MetadataPanelText.Section] {
        var sections: [MetadataPanelText.Section] = []
        if !extraEntries.isEmpty {
            sections.append(MetadataPanelText.Section(title: nil, entries: extraEntries))
        }
        let summaryRows = qcEntries + (temporalEntry.map { [$0] } ?? [])
        if !summaryRows.isEmpty {
            sections.append(MetadataPanelText.Section(title: PreviewDataSummaries.sectionTitle, entries: summaryRows))
        }
        return sections
    }

    /// The 4D window-mode indicator ("per volume" / "shared") for the row after
    /// Volumes; `nil` for 3D, RGB and label maps (no intensity window).
    var volumeWindowModeText: String? {
        guard volumeCount > 1, let interactiveState else { return nil }
        guard interactiveState.segmentationLut == nil, interactiveState.windowBounds != nil else { return nil }
        return PreviewDataSummaries.windowModeText(perVolume: perVolumeWindow)
    }

    /// The display mode the slices are drawn in, for the badge: the configured
    /// one, or "As stored" when the orientation is unknown (the resolver falls
    /// back to stored order then).
    var displayMode: ViewOrientation {
        let configured = renderingOptions?.orientation ?? MIQConfig.imageOrientation
        let known = !(axialOrientation.isUnknown || coronalOrientation.isUnknown || sagittalOrientation.isUnknown)
        return configured.effective(orientationKnown: known)
    }

    /// Whole numbers (integer datatypes, identity-scaled data) render as plain
    /// integers; anything fractional (float data, or scl-scaled integers) uses a
    /// compact significant-digit form. Datatype-agnostic on purpose: the scaled
    /// value alone determines the most natural presentation.
    ///
    /// Non-finite voxels print literally rather than as "—". NaN is real data here
    /// (parametric and statistical maps spell "not computed" with it) and windowing
    /// draws it at the window minimum, indistinguishable from background — so this
    /// readout is the only place it shows, and "—" means "no value available".
    private func apply(bundle: MIQPreviewBundle) {
        coronal = bundle.slices[.coronal]
        sagittal = bundle.slices[.sagittal]
        axial = bundle.slices[.axial]
        coronalOrientation = bundle.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = bundle.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = bundle.orientations[.axial] ?? .placeholderAxial
        metadataEntries = bundle.metadataEntries
        panelWarnings = bundle.panelWarnings
        extraEntries = bundle.extraEntries
        cachedVolumeCount = bundle.volumeCount
    }

    private func apply(raw: RawPreviewData) {
        interactiveState = raw.interactiveState
        lastAppliedAutoBounds = raw.interactiveState.segmentationLut == nil ? raw.interactiveState.windowBounds : nil
        // Fresh parse installs a new volume — drop any per-timepoint windows
        // memoized against the previous one.
        perVolumeWindowCache = [:]
        expansionState = Self.needsExpansion(volume: raw.interactiveState.volume) ? .pending : .notNeeded
        currentCursor = raw.interactiveState.centerCursor
        displayedCursor = raw.interactiveState.centerCursor
        metadataEntries = raw.metadataEntries
        panelWarnings = raw.panelWarnings
        extraEntries = raw.extraEntries
        coronalOrientation = raw.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = raw.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = raw.orientations[.axial] ?? .placeholderAxial
        apply(bitmaps: raw.slices)
        startDataSummariesIfNeeded()
    }

    /// MainActor side of the render handoff: the bitmaps arrive pre-expanded
    /// from the detached task, so this only wraps them in CGImage/NSImage —
    /// no per-pixel work on the main thread.
    private func apply(bitmaps: [SlicePlane: PreviewSliceBitmap]) {
        if let bitmap = bitmaps[.coronal], let coronalImage = MIQImageBridge.makeNSImage(from: bitmap) {
            coronal = coronalImage
        }
        if let bitmap = bitmaps[.sagittal], let sagittalImage = MIQImageBridge.makeNSImage(from: bitmap) {
            sagittal = sagittalImage
        }
        if let bitmap = bitmaps[.axial], let axialImage = MIQImageBridge.makeNSImage(from: bitmap) {
            axial = axialImage
        }
    }

    /// No window and no LUT to replace it ⇒ not one finite voxel in volume 0 (the
    /// window falls back to the whole volume when the center slices have none —
    /// see `MIQVolume.pooledBounds`). The RGB exclusion is load-bearing, not defensive: RGB planes
    /// contribute nothing to the pooled window by design, so every RGB volume
    /// reaches here with no bounds and would otherwise be declared empty.
    private static func hasNoFiniteVoxels(_ raw: RawPreviewData) -> Bool {
        let datatype = raw.interactiveState.volume.image.header.datatype
        guard datatype != .rgb24, datatype != .rgba32 else { return false }
        return raw.interactiveState.windowBounds == nil && raw.interactiveState.segmentationLut == nil
    }

    private func makeBundle(from raw: RawPreviewData) -> MIQPreviewBundle {
        var nsSlices: [SlicePlane: NSImage] = [:]
        var cachedBitmaps: [PreviewSliceBitmap] = []
        for plane in SlicePlane.allCases {
            if let bitmap = raw.slices[plane], let image = MIQImageBridge.makeNSImage(from: bitmap) {
                nsSlices[plane] = image
                cachedBitmaps.append(bitmap)
            }
        }
        return MIQPreviewBundle(
            slices: nsSlices,
            orientations: raw.orientations,
            metadataEntries: raw.metadataEntries,
            panelWarnings: raw.panelWarnings,
            extraEntries: raw.extraEntries,
            volumeCount: raw.interactiveState.volume.volumes,
            // The images share these buffers (zero-copy providers), so their
            // byte counts are the images' resident pixel memory.
            costBytes: PreviewCachePolicy.bundleCost(cachedBitmaps)
        )
    }

    /// - Parameters:
    ///   - navigating: see `load(navigating:)`; only for the cache-hit path.
    ///   - claimsNewest: `true` when an interaction asked for it (the user is on
    ///     this file); `false` right after a cache hit, where it is part of that
    ///     file's request, already registered.
    private func prepareInteractiveState(
        fileURL: URL,
        options: RenderingOptions,
        navigating: Bool = false,
        claimsNewest: Bool = true
    ) {
        let maxDimension = self.maxDimension
        let overNetwork = readsOverNetwork
        let headMaskWindow = windowFromHeadMask
        interactionPreparationTask?.cancel()
        // Weak across the await; see deinit.
        interactionPreparationTask = Task { [weak self] in
            do {
                let interactiveState = try await MIQPreviewModel.runRead(overNetwork: overNetwork, url: fileURL, navigating: navigating, claimsNewest: claimsNewest, label: "prepare") { parser in
                    try MIQPreviewModel.loadInteractiveState(parser: parser, fileURL: fileURL, options: options, maxDimension: maxDimension, windowFromHeadMask: headMaskWindow)
                }
                guard let self, !Task.isCancelled else { return }
                self.interactionPreparationTask = nil
                self.interactiveState = interactiveState
                self.lastAppliedAutoBounds = interactiveState.segmentationLut == nil ? interactiveState.windowBounds : nil
                self.perVolumeWindowCache = [:]
                self.expansionState = Self.needsExpansion(volume: interactiveState.volume) ? .pending : .notNeeded
                self.currentCursor = interactiveState.centerCursor
                self.displayedCursor = interactiveState.centerCursor
                self.startDataSummariesIfNeeded()
                self.onChange?()
            } catch {
                // A cancelled task may already have been replaced; don't clear
                // its successor.
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.interactionPreparationTask = nil
                if error is NetworkReadLane.Superseded {
                    // Another file took the link; the next interaction retries.
                    self.interactivePreparationDeferred = true
                    return
                }
                self.logger.error("interactive state preparation failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func scheduleRender(for cursor: MIQVolumeCursor) {
        guard interactiveState != nil else { return }
        pendingRenderCursor = cursor
        guard renderTask == nil else { return }
        startNextRenderIfNeeded()
    }

    private func scheduleFullRender() {
        guard let interactiveState else { return }
        pendingRenderCursor = currentCursor ?? interactiveState.centerCursor
        pendingForceRender = true
        guard renderTask == nil else { return }
        startNextRenderIfNeeded()
    }

    private func startNextRenderIfNeeded() {
        guard let interactiveState, let cursor = pendingRenderCursor else {
            renderTask = nil
            return
        }

        pendingRenderCursor = nil
        let forceAll = pendingForceRender
        pendingForceRender = false
        let displayedCursor = self.displayedCursor ?? cursor
        let planesToRender = forceAll
            ? SlicePlane.allCases
            : Self.planesNeedingRender(from: displayedCursor, to: cursor, interactiveState: interactiveState)
        guard !planesToRender.isEmpty else {
            self.displayedCursor = cursor
            renderTask = nil
            startNextRenderIfNeeded()
            return
        }

        // A manual W/L adjustment is sticky across all volumes (it overrides
        // per-volume auto entirely). Otherwise the auto window is resolved per
        // volume off the MainActor inside the detached task below.
        let manualBounds = windowAdjustment
        let perVolume = perVolumeWindow
        let shared = perVolume ? nil : sharedWindow
        // Memoized per-volume window: when we've already derived this timepoint's
        // auto window, hand it to the task so it skips the 3-center-slice decode.
        let cachedAutoBounds = (manualBounds == nil && perVolume) ? perVolumeWindowCache[cursor.t] : nil
        let generation = renderGate.ticket()
        // Over the decompression budget, volumes > 0 come from the per-volume
        // reader: decode that one volume first, then render it as volume 0.
        let stream = (expansionState == .streaming && cursor.t > 0) ? volumeStream : nil
        let fileURL = self.url
        let overNetwork = readsOverNetwork
        if let stream, !stream.isCached(cursor.t) {
            streamedVolumeLoading = true
            onChange?()
        }

        // Weak across the await; see deinit.
        renderTask = Task { [weak self] in
            var renderState = interactiveState
            var renderCursor = cursor
            var streamed: MIQVolume?
            if let stream {
                do {
                    let volume = try await MIQPreviewModel.readStreamedVolume(stream, t: cursor.t, fileURL: fileURL, overNetwork: overNetwork)
                    streamed = volume
                    renderState = interactiveState.replacingVolume(volume)
                    renderCursor = MIQVolumeCursor(x: cursor.x, y: cursor.y, z: cursor.z, t: 0)
                } catch {
                    // Cancelled: whoever cancelled already reset the queue.
                    guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                    self.streamedVolumeLoading = false
                    if !(error is NetworkReadLane.Superseded) {
                        // Volumes > 0 keep their last image; the next gesture retries.
                        self.streamedVolumeFailed = true
                        self.logger.error("streamed volume read failed: \(error.localizedDescription, privacy: .private)")
                    }
                    self.onChange?()
                    self.renderTask = nil
                    self.startNextRenderIfNeeded()
                    return
                }
            }
            let renderInput = renderState
            let planeCursor = renderCursor
            // A detached task doesn't inherit cancellation: forward this task's
            // (scroll-gesture restart, `cancelInFlightWork`) so a superseded render
            // stops between planes instead of decoding all three for nothing.
            let render = Task.detached(priority: .userInitiated) {
                MIQPreviewModel.renderBitmaps(
                    cursor: planeCursor,
                    planes: planesToRender,
                    interactiveState: renderInput,
                    manual: manualBounds,
                    perVolume: perVolume,
                    shared: shared,
                    cached: cachedAutoBounds
                )
            }
            let rendered = await withTaskCancellationHandler {
                await render.value
            } onCancel: {
                render.cancel()
            }
            guard let self else { return }
            let decision = self.renderGate.decision(for: generation, cancelled: Task.isCancelled || rendered == nil)
            guard decision != .discard, let result = rendered else { return }
            self.apply(bitmaps: result.bitmaps)
            // Renders run one at a time, so none is reading a volume now.
            self.streamedVolumeLoading = false
            if stream != nil {
                self.streamedVolumeFailed = false
                // Only while the stream is still this state's (not after a swap).
                // Re-rendering the same timepoint (slice scrolling) keeps the
                // entry, so the snapshot generation — and the view features'
                // caches keyed on it — only change with the timepoint.
                if decision == .apply, let streamed, self.streamedVolume?.t != cursor.t {
                    self.streamedVolume = (cursor.t, streamed)
                }
            } else if cursor.t == 0, self.streamedVolume != nil {
                self.streamedVolume = nil
            }
            // Remember the auto window so a subsequent W/L drag starts from it,
            // and memoize it per timepoint for per-volume mode — unless the state
            // was swapped mid-render (4D expansion), which makes it stale.
            if manualBounds == nil, decision == .apply {
                self.lastAppliedAutoBounds = result.bounds
                if perVolume, let bounds = result.bounds {
                    self.perVolumeWindowCache[cursor.t] = bounds
                }
            }
            self.displayedCursor = cursor
            self.onChange?()
            self.renderTask = nil
            self.startNextRenderIfNeeded()
        }
    }

    // MARK: - Background data summaries

    /// Starts the "Data QC" passes the current interactive state allows: QC
    /// once per load (volume 0 suffices, so a capped buffer is fine), the
    /// temporal summary once every volume is in memory (after the 4D expansion
    /// for a capped `.nii.gz`). Each runs detached at utility priority, is
    /// cancelled with the model's other work, and lands only if no reload
    /// happened meanwhile (`summaryGeneration`).
    private func startDataSummariesIfNeeded() {
        guard let interactiveState else { return }
        let volume = interactiveState.volume
        let header = volume.image.header
        let generation = summaryGeneration
        let fileName = url.lastPathComponent

        if !qcStarted, MIQConfig.qcPanelEnabled, PreviewDataSummaries.shouldRunQC(header: header) {
            qcStarted = true
            let options = QCOptions(
                intentCode: header.acquisition.intentCode == 0 ? nil : header.acquisition.intentCode,
                descrip: header.acquisition.descrip
            )
            qcTask = Task { [weak self] in
                let lines: [MetadataEntry]
                do {
                    lines = try await MIQPreviewModel.runCancelableDetached(priority: .utility) {
                        try QCAnalyzer.analyze(volume: volume, fileName: fileName, options: options).displayLines
                    }
                } catch {
                    guard !(error is CancellationError) else { return }
                    MIQLogger.make(category: "model").error("QC pass failed: \(error.localizedDescription, privacy: .private)")
                    return
                }
                guard let self, !Task.isCancelled, generation == self.summaryGeneration else { return }
                self.qcTask = nil
                self.qcEntries = lines
                self.onChange?()
            }
        }

        // A streamed series (over the decompression budget) gets the summary
        // from one forward pass through its own reader — local files only; on
        // a network volume the row is left out rather than pulling the series.
        if !temporalStarted, MIQConfig.temporalSummaryEnabled, expansionState == .streaming, let stream = volumeStream,
           PreviewDataSummaries.shouldRunStreamedTemporalSummary(
               header: header,
               isLabelMap: interactiveState.segmentationLut != nil,
               readsOverNetwork: readsOverNetwork
           ) {
            temporalStarted = true
            let fileURL = url
            temporalTask = Task { [weak self] in
                let summary = try? await MIQPreviewModel.runCancelableDetached(priority: .utility) { () -> TemporalSummary? in
                    try MIQPreviewModel.streamedTemporalSummary(stream: stream, header: header, fileURL: fileURL)
                }
                guard let self, !Task.isCancelled, generation == self.summaryGeneration else { return }
                self.temporalTask = nil
                // `try?` flattens: `nil` on cancellation, a read error or an
                // empty foreground — the row is then simply absent.
                guard let entry = summary.flatMap(PreviewDataSummaries.temporalEntry) else { return }
                self.temporalEntry = entry
                self.onChange?()
            }
        }

        if !temporalStarted, MIQConfig.temporalSummaryEnabled,
           PreviewDataSummaries.shouldRunTemporalSummary(volume: volume, isLabelMap: interactiveState.segmentationLut != nil) {
            temporalStarted = true
            temporalTask = Task { [weak self] in
                // `nil` on cancellation as well as on an empty foreground.
                let summary = try? await MIQPreviewModel.runCancelableDetached(priority: .utility) {
                    TemporalStats.summary(for: volume)
                }
                guard let self, !Task.isCancelled, generation == self.summaryGeneration else { return }
                self.temporalTask = nil
                guard let entry = summary.flatMap(PreviewDataSummaries.temporalEntry) else { return }
                self.temporalEntry = entry
                self.onChange?()
            }
        }
    }

    /// Computes the shared 4D window (`perVolumeWindow` off) for the current
    /// interactive state, off the MainActor, then repaints with it unless the
    /// user has taken manual W/L control. Idempotent per interactive state;
    /// waits for a capped buffer's expansion, since sampling it would only see
    /// volume 0.
    ///
    /// A streamed series (`.streaming`) samples its volumes through a sibling
    /// `NiftiVolumeReader` (one volume resident at a time) instead; on a
    /// network volume that read goes through `NetworkReadLane`. Where that
    /// would pull a whole compressed series over the network,
    /// `triggerExpansionIfNeeded` has already switched to per-volume windows.
    private func ensureSharedWindowIfNeeded() {
        let stream = expansionState == .streaming ? volumeStream : nil
        guard !perVolumeWindow, let interactiveState,
              interactiveState.volume.volumes > 1,
              interactiveState.volume.containsAllVolumes || stream != nil,
              interactiveState.segmentationLut == nil,
              interactiveState.windowBounds != nil,
              sharedWindowTask == nil,
              sharedWindowGeneration != interactiveStateGeneration else { return }
        let generation = interactiveStateGeneration
        let volume = interactiveState.volume
        let options = interactiveState.options
        let fileURL = url
        let overNetwork = readsOverNetwork
        sharedWindowTask = Task { [weak self] in
            let bounds: MIQIntensityWindowBounds?
            if let stream {
                let pass: @Sendable () throws -> MIQIntensityWindowBounds? = {
                    try MIQPreviewModel.streamedSharedWindow(
                        stream: stream, volumeCount: volume.volumes, options: options, fileURL: fileURL
                    )
                }
                if overNetwork {
                    bounds = try? await NetworkReadLane.shared.run("shared-window", url: fileURL, navigating: false, claimsNewest: true) { readFinished in
                        defer { readFinished() }
                        return try pass()
                    }
                } else {
                    bounds = try? await MIQPreviewModel.runCancelableDetached(priority: .userInitiated, pass)
                }
            } else {
                bounds = try? await MIQPreviewModel.runCancelableDetached(priority: .userInitiated) {
                    volume.sharedVolumeWindow(options: options)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.sharedWindowTask = nil
            guard generation == self.interactiveStateGeneration else {
                // Swapped mid-computation (4D expansion): sample the new buffer.
                self.ensureSharedWindowIfNeeded()
                return
            }
            self.sharedWindowGeneration = generation
            guard let bounds else { return }
            self.sharedWindow = bounds
            if self.windowAdjustment == nil { self.scheduleFullRender() }
        }
    }

    /// One cold parse in flight, shared by every preview that asks for the same
    /// cache key while it runs.
    @MainActor
    private final class SharedColdLoad {
        var task: Task<RawPreviewData, Error>!
        /// Previews still waiting. Only decremented on cancellation; a load that
        /// completes simply leaves the registry.
        var waiters = 0
    }

    private static var sharedColdLoads: [String: SharedColdLoad] = [:]

    /// Runs the cold parse for `key` once, however many previews ask for it while
    /// it runs. The Finder preview pane and the Space panel each create a
    /// controller for the same file; when the parse outlasts the gap between their
    /// requests (a network file, or a large `.mgz`/`.mif.gz`) both used to parse
    /// it — twice the bytes over the link, and twice the CPU and memory locally.
    /// A fast local load finishes first and the second preview hits the cache, so
    /// this changes nothing there.
    ///
    /// The shared task belongs to no single preview, so one leaving doesn't stop
    /// it for the others: a cancelled waiter just drops out, and only the last one
    /// out cancels the parse (which `runRead` forwards into the chunked network
    /// reads). A cancelled waiter still waits for the shared result
    /// before its `load()` returns; its caller has already been torn down.
    private static func sharedColdLoad(
        key: String,
        work: @escaping @MainActor () async throws -> RawPreviewData
    ) async throws -> RawPreviewData {
        let shared: SharedColdLoad
        if let existing = sharedColdLoads[key] {
            shared = existing
        } else {
            shared = SharedColdLoad()
            shared.task = Task { @MainActor in
                defer {
                    if MIQPreviewModel.sharedColdLoads[key] === shared {
                        MIQPreviewModel.sharedColdLoads[key] = nil
                    }
                }
                return try await work()
            }
            sharedColdLoads[key] = shared
        }
        shared.waiters += 1
        return try await withTaskCancellationHandler {
            try await shared.task.value
        } onCancel: {
            Task { @MainActor in
                shared.waiters -= 1
                guard shared.waiters == 0 else { return }
                // Unregister first so a new request starts a fresh parse instead
                // of joining the cancelled one.
                if MIQPreviewModel.sharedColdLoads[key] === shared {
                    MIQPreviewModel.sharedColdLoads[key] = nil
                }
                shared.task.cancel()
            }
        }
    }

    /// Runs a parse that reads `fileURL`'s data. On a network volume it goes through
    /// `NetworkReadLane` — one read at a time, the newest request first — and
    /// throws `NetworkReadLane.Superseded` if no preview wants the file any more;
    /// a local file is memory-mapped and runs straight away. `claimsNewest` is for
    /// work an interaction starts (4D expansion, cache-hit prep): it makes this
    /// file the newest request.
    private static func runRead<T: Sendable>(
        overNetwork: Bool,
        url: URL,
        navigating: Bool,
        claimsNewest: Bool,
        label: String,
        _ work: @Sendable @escaping (MIQParser) throws -> T
    ) async throws -> T {
        guard overNetwork else {
            return try await runCancelableDetached { try work(MIQParser()) }
        }
        return try await NetworkReadLane.shared.run(label, url: url, navigating: navigating, claimsNewest: claimsNewest) { readFinished in
            try work(MIQParser(onNetworkReadFinished: readFinished))
        }
    }

    /// The cold preview read for `load()`: `loadPreviewData` through `runRead`.
    private static func readColdPreview(
        overNetwork: Bool,
        fileURL: URL,
        navigating: Bool,
        options: RenderingOptions,
        maxDimension: Int,
        windowFromHeadMask: Bool
    ) async throws -> RawPreviewData {
        try await runRead(overNetwork: overNetwork, url: fileURL, navigating: navigating, claimsNewest: false, label: "load") { parser in
            try MIQPreviewModel.loadPreviewData(parser: parser, fileURL: fileURL, options: options, maxDimension: maxDimension, windowFromHeadMask: windowFromHeadMask)
        }
    }

    /// Temporal summary of a streamed series, from one forward pass through a
    /// sibling reader of `stream`. Blocking: call it from a detached task.
    private nonisolated static func streamedTemporalSummary(
        stream: NiftiVolumeReader,
        header: MIQHeader,
        fileURL: URL
    ) throws -> TemporalSummary? {
        try withSecurityScopedAccess(to: fileURL) {
            let pass = try stream.makeSiblingReader()
            return try TemporalStats.summary(
                volumeCount: header.volumes,
                width: header.width,
                height: header.height,
                depth: header.depth
            ) { t in try pass.volume(at: t) }
        }
    }

    /// Shared intensity window of a streamed series, sampling volumes through a
    /// sibling reader of `stream`. Blocking: call it off the MainActor.
    private nonisolated static func streamedSharedWindow(
        stream: NiftiVolumeReader,
        volumeCount: Int,
        options: RenderingOptions,
        fileURL: URL
    ) throws -> MIQIntensityWindowBounds? {
        try withSecurityScopedAccess(to: fileURL) {
            let sampler = try stream.makeSiblingReader()
            return try MIQVolume.sharedVolumeWindow(volumeCount: volumeCount, options: options) { t in
                try sampler.volume(at: t)
            }
        }
    }

    /// Runs `work` off the MainActor on a detached task but propagates *this*
    /// task's cancellation into it. A bare `Task.detached(...).value` would keep
    /// running after the awaiting task is cancelled (detached tasks don't inherit
    /// cancellation), so a dismissed/replaced preview couldn't stop an in-flight
    /// parse — notably the full network read for non-boundable kinds (`.mif.gz`).
    private static func runCancelableDetached<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: priority, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// On a network volume, the on-disk size (bytes) at which a non-boundable
    /// kind's cold preview should be deferred behind a placeholder rather than
    /// pulling the whole file (which would stall Finder's I/O on a slow mount).
    /// `nil` ⇒ load normally (canonical NIfTI, or under threshold). The caller
    /// has already established that the file is on a network volume. Runs inside
    /// the detached task: the size stat can block on a hung mount.
    private nonisolated static func networkDeferralSizeBytes(fileURL: URL, kind: MIQFileKind?) -> Int? {
        guard let kind, !kind.supportsBoundedNetworkRead else { return nil }
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > MIQConfig.networkPreviewThresholdBytes else { return nil }
        return size
    }

    /// Deferral size for a dataless cloud placeholder: any kind over the network
    /// threshold. Unlike a network mount, canonical NIfTI gets no exemption — the
    /// File Provider materializes the whole file on first read, so the bounded
    /// volume-0 prefix read saves nothing. Runs inside the detached probe task.
    private nonisolated static func datalessDeferralSizeBytes(fileURL: URL) -> Int? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > MIQConfig.networkPreviewThresholdBytes else { return nil }
        return size
    }

    private nonisolated static func loadPreviewData(
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowFromHeadMask: Bool
    ) throws -> RawPreviewData {
        try withSecurityScopedAccess(to: fileURL) {
            // Header-only memory gate; see `load()` for why it runs here, in the
            // read lane. Unprobeable kinds (DICOM, Zarr) proceed unchanged.
            if let refusal = MIQColdPreviewGate.refusalMessage(url: fileURL) {
                throw ColdPreviewRefusal(message: refusal)
            }
            try Task.checkCancellation()
            // DICOM: the same image `parse(url:)` returns, plus its technical
            // rows. Everything else keeps `parse(url:)` (format dispatch,
            // bounded network reads).
            let image: MIQImage
            var extraEntries: [MetadataEntry] = []
            if MIQFileKind(url: fileURL) == .dicom {
                let parsed = try parser.parseDICOM(url: fileURL)
                image = parsed.image
                extraEntries = parsed.info.displayEntries
            } else {
                image = try parser.parse(url: fileURL)
            }
            let volume = MIQVolume(image: image)
            MIQLogger.make(category: "model").notice("cold parse: \(volume.containsAllVolumes ? "full payload" : "volume-0 capped", privacy: .public), volumes=\(volume.volumes, privacy: .public), payload=\(image.payloadCount / 1024, privacy: .public)KB")
            // Single decode of the center slices: the pooled buffer that derives the
            // window is the same buffer finalized into the first-frame images. The
            // previous makeInteractiveState + renderSlices(centerCursor) path decoded
            // them twice (once for the window, once for the render).
            let headMask = try headMaskForWindow(volume: volume, enabled: windowFromHeadMask)
            let preview = volume.centerPreview(volumeIndex: 0, maxDimension: maxDimension, options: options, headMask: headMask)
            let interactiveState = InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: preview.windowBounds,
                segmentationLut: preview.segmentationLut,
                centerCursor: volume.centerCursor()
            )
            // Build the bitmaps here, inside the detached task (8-bit grey for
            // grayscale slices, RGBA for colour / LUT output) — the MainActor
            // then only wraps the buffers in CGImage/NSImage.
            let slices = preview.slices.compactMapValues { $0.previewBitmap() }

            var orientations: [SlicePlane: SliceOrientationLabels] = [:]
            for plane in SlicePlane.allCases {
                orientations[plane] = volume.displayOrientation(for: plane, options: options)
            }

            // BIDS `<stem>.json` / `.bval` beside the image. `nil` when absent or
            // when the sandbox refuses the sibling read — silently, by design.
            let sidecar = SidecarMetadata.load(forImageAt: fileURL)
            if sidecar != nil {
                MIQLogger.make(category: "model").notice("sidecar found: file=\(MIQLogRedaction.fileTag(fileURL), privacy: .public)")
            }
            var metadata = MIQMetadata(
                header: image.header,
                orientation: image.header.orientationDiagnostics.displaySummary,
                sidecar: sidecar,
                sidecarWarningsInRow: false
            ).asDisplayLines()
            metadata.insert(metadataFormatEntry(for: fileURL, header: image.header), at: 0)
            let warnings = MIQMetadata.panelWarnings(header: image.header, sidecar: sidecar)
            #if DEBUG
            if let built = buildDateEntry() { metadata.append(built) }
            #endif

            return RawPreviewData(
                slices: slices,
                orientations: orientations,
                metadataEntries: metadata,
                panelWarnings: warnings,
                extraEntries: extraEntries,
                interactiveState: interactiveState
            )
        }
    }

    private nonisolated static func loadInteractiveState(
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowFromHeadMask: Bool
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try parser.parse(url: fileURL)
            let volume = MIQVolume(image: image)
            let headMask = try headMaskForWindow(volume: volume, enabled: windowFromHeadMask)
            return makeInteractiveState(volume: volume, options: options, maxDimension: maxDimension, headMask: headMask)
        }
    }

    /// The `QCHeadMask` the auto window is restricted to when
    /// `MIQConfig.windowFromHeadMask` is on, computed once per loaded volume
    /// inside the detached load (never on the MainActor). `nil` when the
    /// setting is off or the volume isn't an anatomical scalar 3D image
    /// (`MIQVolume.windowingHeadMask()`), which keeps the ordinary window.
    /// Rethrows only `CancellationError`.
    private nonisolated static func headMaskForWindow(volume: MIQVolume, enabled: Bool) throws -> QCHeadMask? {
        guard enabled, volume.isHeadMaskWindowCandidate else { return nil }
        return try volume.windowingHeadMask()
    }

    private nonisolated static func makeInteractiveState(
        volume: MIQVolume,
        options: RenderingOptions,
        maxDimension: Int,
        headMask: QCHeadMask? = nil
    ) -> InteractivePreviewState {
        // Single decode of the 3 center slices yields both the LUT and the
        // window, instead of `buildSegmentationLut` + `fixedCenterWindow` each
        // decoding them. Shaves time-to-first-scroll on the cache-hit path.
        let center = volume.centerInteractiveState(options: options, headMask: headMask)
        return InteractivePreviewState(
            volume: volume,
            options: options,
            maxDimension: maxDimension,
            windowBounds: center.windowBounds,
            segmentationLut: center.segmentationLut,
            centerCursor: volume.centerCursor()
        )
    }

    /// Fully decompressed re-parse for 4D navigation. Reuses the volume-0
    /// `windowBounds` and `segmentationLut` from the capped state so rendering
    /// stays constant across the timeseries.
    private nonisolated static func loadExpandedInteractiveState(
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowBounds: MIQIntensityWindowBounds?,
        segmentationLut: SegmentationLut?
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try parser.parse(url: fileURL, fullyDecompress: true)
            let volume = MIQVolume(image: image)
            return InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: windowBounds,
                segmentationLut: segmentationLut,
                centerCursor: volume.centerCursor()
            )
        }
    }

    /// The window the render should use for `cursor`. A manual adjustment wins
    /// for every volume (sticky). Otherwise, in per-volume mode, re-derive the
    /// window from this volume's own pooled center slices (same mechanic as the
    /// cold preview, just for `cursor.t`); a single-volume file or a missing
    /// window falls back to the volume-0 bounds. Called only inside the detached
    /// render task — `fixedCenterWindow` decodes 3 center slices.
    private nonisolated static func renderBitmaps(
        cursor: MIQVolumeCursor,
        planes: [SlicePlane],
        interactiveState: InteractivePreviewState,
        manual: MIQIntensityWindowBounds?,
        perVolume: Bool,
        shared: MIQIntensityWindowBounds?,
        cached: MIQIntensityWindowBounds?
    ) -> (bounds: MIQIntensityWindowBounds?, bitmaps: [SlicePlane: PreviewSliceBitmap])? {
        let bounds = resolveWindowBounds(cursor: cursor, interactiveState: interactiveState, manual: manual, perVolume: perVolume, shared: shared, cached: cached)
        guard let slices = renderSlices(for: cursor, planes: planes, interactiveState: interactiveState, windowBounds: bounds) else {
            return nil
        }
        // Bitmap building stays off the MainActor with the rest of the pixel
        // work (8-bit grey for grayscale slices, RGBA for colour / LUT output);
        // only CGImage/NSImage wrapping happens in apply.
        var bitmaps: [SlicePlane: PreviewSliceBitmap] = [:]
        for (plane, slice) in slices {
            guard !Task.isCancelled else { return nil }
            if let bitmap = slice.previewBitmap() { bitmaps[plane] = bitmap }
        }
        return (bounds, bitmaps)
    }

    /// Volume `t` of a 4D NIfTI over the decompression budget, decoded by
    /// `reader` off the MainActor (cancellable: the gzip path polls between
    /// output windows). On a network volume an uncached read goes through
    /// `NetworkReadLane` like every other read of the file; a cached one, or a
    /// local file (memory-mapped `.nii` / local `.nii.gz`), runs straight away.
    private static func readStreamedVolume(
        _ reader: NiftiVolumeReader,
        t: Int,
        fileURL: URL,
        overNetwork: Bool
    ) async throws -> MIQVolume {
        if !overNetwork || reader.isCached(t) {
            return try await runCancelableDetached {
                try withSecurityScopedAccess(to: fileURL) { try reader.volume(at: t) }
            }
        }
        return try await NetworkReadLane.shared.run("volume", url: fileURL, navigating: false, claimsNewest: true) { readFinished in
            defer { readFinished() }
            return try withSecurityScopedAccess(to: fileURL) { try reader.volume(at: t) }
        }
    }

    private nonisolated static func resolveWindowBounds(
        cursor: MIQVolumeCursor,
        interactiveState: InteractivePreviewState,
        manual: MIQIntensityWindowBounds?,
        perVolume: Bool,
        shared: MIQIntensityWindowBounds?,
        cached: MIQIntensityWindowBounds?
    ) -> MIQIntensityWindowBounds? {
        if let manual { return manual }
        guard interactiveState.volume.volumes > 1 else {
            return interactiveState.windowBounds
        }
        // Shared mode: one window over sampled volumes once it is computed;
        // volume 0's until then (and for a LUT-rendered label map, which has
        // no window to share).
        guard perVolume else {
            guard interactiveState.windowBounds != nil else { return nil }
            return shared ?? interactiveState.windowBounds
        }
        // Before 4D expansion, volumes > 0 read the zero backstop; a window
        // derived from zeros is degenerate, so keep volume 0's.
        if cursor.t > 0, !interactiveState.volume.containsAllVolumes {
            return interactiveState.windowBounds
        }
        // A memoized window for this timepoint skips the 3-center-slice decode.
        if let cached { return cached }
        return interactiveState.volume.fixedCenterWindow(volumeIndex: cursor.t, options: interactiveState.options)
            ?? interactiveState.windowBounds
    }

    private nonisolated static func renderSlices(
        for cursor: MIQVolumeCursor,
        planes: [SlicePlane],
        interactiveState: InteractivePreviewState,
        windowBounds: MIQIntensityWindowBounds?
    ) -> [SlicePlane: SliceImage]? {
        var slices: [SlicePlane: SliceImage] = [:]
        for plane in planes {
            // `nil` once the render is superseded: the caller discards it anyway.
            guard !Task.isCancelled else { return nil }
            let index = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
            slices[plane] = interactiveState.volume.slice(
                plane: plane,
                index: index,
                volumeIndex: cursor.t,
                maxDimension: interactiveState.maxDimension,
                options: interactiveState.options,
                windowBounds: windowBounds,
                lut: interactiveState.segmentationLut
            )
        }
        return slices
    }

    private nonisolated static func planesNeedingRender(
        from oldCursor: MIQVolumeCursor,
        to newCursor: MIQVolumeCursor,
        interactiveState: InteractivePreviewState
    ) -> [SlicePlane] {
        // A timepoint change reuses the same x/y/z, so the per-plane slice indices
        // are unchanged — but every plane samples a different volume and must
        // re-render. The spatial diff below would otherwise return nothing.
        if oldCursor.t != newCursor.t {
            return SlicePlane.allCases
        }
        return SlicePlane.allCases.filter { plane in
            let oldIndex = interactiveState.volume.sliceIndex(for: plane, cursor: oldCursor, options: interactiveState.options)
            let newIndex = interactiveState.volume.sliceIndex(for: plane, cursor: newCursor, options: interactiveState.options)
            return oldIndex != newIndex
        }
    }

    private nonisolated static func withSecurityScopedAccess<T>(to fileURL: URL, operation: () throws -> T) throws -> T {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private nonisolated static func metadataFormatEntry(for url: URL, header: MIQHeader) -> MetadataEntry {
        let displayName = header.formatLabel ?? MIQFileKind(url: url)?.displayName ?? "Unknown"
        return MetadataEntry(field: .format, label: "Format", value: displayName)
    }

    #if DEBUG
    private nonisolated static func buildDateEntry() -> MetadataEntry? {
        guard let formatted = BuildDate.formatted(for: Bundle.main.executableURL) else { return nil }
        return MetadataEntry(field: nil, label: "DEBUG BUILD", value: formatted)
    }
    #endif
}

// MARK: - Interaction (ui-interaction)
//
// Read-only accessors and two small window entry points for the view-feature
// layer (MIQPreviewInteraction.swift and friends). Kept in this file only
// because they read the model's private interactive state; nothing here takes
// part in the load path.

/// Everything the view features (colour maps, overlays, projections, 3D) need
/// from the interactive state, as one Sendable value they can hand to detached
/// work.
struct MIQInteractionSnapshot: Sendable {
    let volume: MIQVolume
    let options: RenderingOptions
    let maxDimension: Int
    /// The window on screen: the manual/preset one if set, else the auto
    /// window the last render applied. `nil` for RGB / constant data.
    let windowBounds: MIQIntensityWindowBounds?
    let segmentationLut: SegmentationLut?
    /// Addresses `volume`: for a streamed series (4D over the decompression
    /// budget) `volume` holds only the displayed timepoint, so `cursor.t` is 0
    /// while the slices show a later volume — always read `volume` at `cursor.t`.
    let cursor: MIQVolumeCursor
    /// Changes whenever the backing volume is swapped (fresh parse, cache-hit
    /// preparation, 4D expansion, and each streamed volume that lands);
    /// derived caches key on it.
    let generation: Int
}

extension MIQPreviewModel {
    /// `nil` until the interactive state is ready (cold load done or cache-hit
    /// preparation finished).
    ///
    /// For a streamed series the snapshot follows the volume *on screen*: the
    /// decoded single volume (addressed as `t = 0`) once its render has landed,
    /// volume 0 of the capped buffer while that is displayed — never the
    /// capped buffer's zero backstop for a later timepoint. While a newly
    /// requested volume is still decoding, the snapshot keeps describing the
    /// one displayed. `nil` in the one state with no decoded data for what is
    /// shown (a later volume whose stream was just reset), so features wait
    /// for the next render instead of drawing zeros.
    var interactionSnapshot: MIQInteractionSnapshot? {
        guard let interactiveState else { return nil }
        let cursor = currentCursor ?? interactiveState.centerCursor
        var volume = interactiveState.volume
        var snapshotCursor = cursor
        if expansionState == .streaming {
            let shownT = displayedCursor?.t ?? 0
            if shownT > 0 {
                guard let streamed = streamedVolume, streamed.t == shownT else { return nil }
                volume = streamed.volume
            }
            snapshotCursor = MIQVolumeCursor(x: cursor.x, y: cursor.y, z: cursor.z, t: 0)
        }
        return MIQInteractionSnapshot(
            volume: volume,
            options: interactiveState.options,
            maxDimension: interactiveState.maxDimension,
            windowBounds: displayedWindowBounds,
            segmentationLut: interactiveState.segmentationLut,
            cursor: snapshotCursor,
            generation: snapshotGeneration
        )
    }

    /// The previewed file (for sibling-overlay discovery; never logged).
    var interactionFileURL: URL { url }

    /// The window currently applied to the slices (manual wins over auto).
    var displayedWindowBounds: MIQIntensityWindowBounds? {
        windowAdjustment ?? lastAppliedAutoBounds ?? interactiveState?.windowBounds
    }

    /// True while a manual drag or a preset overrides the auto window.
    var hasManualWindow: Bool { windowAdjustment != nil }

    /// Sets (or with `nil`, clears back to auto) the manual window — the
    /// preset entry point. Same render path as a W/L drag.
    func setManualWindow(_ bounds: MIQIntensityWindowBounds?) {
        guard interactiveStateForInteraction() != nil else { return }
        guard bounds != windowAdjustment else { return }
        windowAdjustment = bounds
        onChange?()
        scheduleFullRender()
    }

    /// Starts deferred interactive preparation, like any other first input.
    func beginInteraction() {
        _ = interactiveStateForInteraction()
    }

    /// 0-based slice index shown in `plane` and the plane's slice count, for
    /// accessibility text. `nil` until the interactive state is ready.
    func displayedSlice(for plane: SlicePlane) -> (index: Int, count: Int)? {
        guard let interactiveState else { return nil }
        let volume = interactiveState.volume
        let cursor = currentCursor ?? interactiveState.centerCursor
        let geometry = volume.sliceGeometry(for: plane, options: interactiveState.options)
        let dims = [volume.width, volume.height, volume.depth]
        return (cursor.coordinate(forAxis: geometry.sliceAxis), dims[geometry.sliceAxis])
    }
}
