import Foundation

/// Fast direct volume renderer for the rotatable 3D preview.
///
/// Typical use (off the main actor):
/// ```swift
/// let grid = VolumeRenderGrid(volume: volume, maxDimension: 128, asLabels: lut != nil)
/// let frame = try await VolumeRenderer.render(
///     grid: grid, camera: VolumeRenderCamera(azimuth: 30, elevation: 15),
///     mode: lut != nil ? .labels : .mip, window: windowBounds, width: 256, height: 256)
/// // frame is an opaque RGBA8888 `RGBABitmap`, wrapped exactly like slice bitmaps.
/// ```
/// Keep the grid and re-render it on every camera drag; cancel the previous
/// render task when a new camera arrives (renders check cancellation per row).
///
/// Backends: a portable multi-threaded CPU ray caster (the reference) and, on
/// Apple platforms, a Metal compute kernel that mirrors it. `.automatic`
/// prefers Metal only after it compiled and passed a CPU cross-check; any Metal
/// error falls back to the CPU path, so a GPU problem can't break the preview.
public enum VolumeRenderer {

    /// Output frame size in pixels, for the entry points that take one bundled.
    public struct Size: Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(width: Int = 256, height: Int = 256) {
            self.width = width
            self.height = height
        }
    }

    /// How `render(volume:…)` builds its `VolumeRenderGrid`: which volume of a
    /// 4D series and the grid's longest-axis cap (see `VolumeRenderGrid.init`).
    public struct GridOptions: Sendable, Hashable {
        public var volumeIndex: Int
        public var maxDimension: Int

        public init(volumeIndex: Int = 0, maxDimension: Int = 128) {
            self.volumeIndex = volumeIndex
            self.maxDimension = maxDimension
        }
    }

    /// Renders `grid` as an opaque `width × height` RGBA8 bitmap.
    /// `window` nil → `grid.suggestedWindow` (ignored by `.labels`).
    /// Throws `CancellationError` when the calling task is cancelled.
    public static func render(
        grid: VolumeRenderGrid,
        camera: VolumeRenderCamera = .anterior,
        mode: VolumeRenderMode,
        window: MIQIntensityWindowBounds?,
        width: Int = 256,
        height: Int = 256,
        options: VolumeRenderOptions = VolumeRenderOptions()
    ) async throws -> RGBABitmap {
        try Task.checkCancellation()
        let setup = try VolumeRenderSetup(
            grid: grid, camera: camera, mode: mode, window: window,
            width: width, height: height, options: options
        )
        if let bitmap = try await metalRenderAsync(setup: setup, grid: grid, backend: options.backend) {
            try Task.checkCancellation()
            return bitmap
        }
        return try await renderCPU(setup: setup, grid: grid)
    }

    /// Releases GPU-side caches (the most recent grid's 3D textures and the
    /// reference keeping its storage alive). Call on memory pressure and when a
    /// preview resets; safe from any thread and non-blocking (the release is
    /// queued behind any in-flight GPU frame). A no-op without Metal, or when
    /// the Metal backend was never initialised.
    public static func releaseCachedResources() {
        #if canImport(Metal)
        MetalVolumeRenderer.releaseSharedCachesAsync()
        #endif
    }

    /// Convenience: builds a grid from `volume` and renders it. Building the
    /// grid dominates for large volumes — for interactive rotation build a
    /// `VolumeRenderGrid` once and call `render(grid:…)` instead.
    public static func render(
        volume: MIQVolume,
        gridOptions: GridOptions = GridOptions(),
        camera: VolumeRenderCamera = .anterior,
        mode: VolumeRenderMode,
        window: MIQIntensityWindowBounds?,
        size: Size = Size(),
        options: VolumeRenderOptions = VolumeRenderOptions()
    ) async throws -> RGBABitmap {
        try Task.checkCancellation()
        let grid = VolumeRenderGrid(
            volume: volume, volumeIndex: gridOptions.volumeIndex,
            maxDimension: gridOptions.maxDimension, asLabels: mode == .labels
        )
        return try await render(
            grid: grid, camera: camera, mode: mode, window: window,
            width: size.width, height: size.height, options: options
        )
    }

    /// Blocking variant for non-async callers (e.g. a thumbnail provider).
    /// Parallelised with `DispatchQueue.concurrentPerform`; `isCancelled` is
    /// polled once per output row and a `true` result throws `CancellationError`.
    public static func renderSynchronously(
        grid: VolumeRenderGrid,
        camera: VolumeRenderCamera = .anterior,
        mode: VolumeRenderMode,
        window: MIQIntensityWindowBounds?,
        size: Size = Size(),
        options: VolumeRenderOptions = VolumeRenderOptions(),
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RGBABitmap {
        let setup = try VolumeRenderSetup(
            grid: grid, camera: camera, mode: mode, window: window,
            width: size.width, height: size.height, options: options
        )
        if isCancelled() { throw CancellationError() }
        if let bitmap = try metalRender(setup: setup, grid: grid, backend: options.backend, isCancelled: isCancelled) {
            if isCancelled() { throw CancellationError() }
            return bitmap
        }
        let count = setup.width * setup.height * 4
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { out.deallocate() }
        let shared = SendablePointer(out)
        let bands = bandRanges(height: setup.height)
        let stopped = StopFlag()
        DispatchQueue.concurrentPerform(iterations: bands.count) { b in
            if stopped.isSet { return }
            let ok = CPUVolumeRayCaster.castRows(
                setup: setup, grid: grid, rows: bands[b], out: shared.pointer,
                shouldStop: { stopped.isSet || isCancelled() }
            )
            if !ok { stopped.set() }
        }
        if stopped.isSet || isCancelled() { throw CancellationError() }
        return RGBABitmap(width: setup.width, height: setup.height, pixels: Data(bytes: out, count: count))
    }

    /// `true` when the Metal backend compiled and passed its CPU cross-check.
    public static var isMetalAvailable: Bool {
        #if canImport(Metal)
        return MetalVolumeRenderer.active != nil
        #else
        return false
        #endif
    }

    // MARK: - Internals

    /// CPU path, parallelised with a task group over 8-row bands so child tasks
    /// observe cancellation of the caller.
    static func renderCPU(setup: VolumeRenderSetup, grid: VolumeRenderGrid) async throws -> RGBABitmap {
        let count = setup.width * setup.height * 4
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { out.deallocate() }
        let shared = SendablePointer(out)
        let bands = bandRanges(height: setup.height)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for band in bands {
                group.addTask {
                    try Task.checkCancellation()
                    let ok = CPUVolumeRayCaster.castRows(
                        setup: setup, grid: grid, rows: band, out: shared.pointer,
                        shouldStop: { Task.isCancelled }
                    )
                    if !ok { throw CancellationError() }
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        return RGBABitmap(width: setup.width, height: setup.height, pixels: Data(bytes: out, count: count))
    }

    static func bandRanges(height: Int, rowsPerBand: Int = 8) -> [Range<Int>] {
        stride(from: 0, to: height, by: rowsPerBand).map { $0..<min(height, $0 + rowsPerBand) }
    }

    /// Metal attempt per `backend`; nil means "use the CPU path". Only
    /// cancellation propagates — any GPU error falls back to the CPU.
    private static func metalRender(
        setup: VolumeRenderSetup,
        grid: VolumeRenderGrid,
        backend: VolumeRenderBackend,
        isCancelled: () -> Bool
    ) throws -> RGBABitmap? {
        guard backend != .cpu else { return nil }
        #if canImport(Metal)
        guard let metal = MetalVolumeRenderer.active else { return nil }
        do {
            return try metal.render(setup: setup, grid: grid, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Async Metal attempt: runs on `MetalVolumeRenderer.workQueue` (bridged
    /// with a continuation) so the blocking GPU wait never occupies a
    /// cooperative-pool thread, with task cancellation forwarded as a flag.
    private static func metalRenderAsync(
        setup: VolumeRenderSetup,
        grid: VolumeRenderGrid,
        backend: VolumeRenderBackend
    ) async throws -> RGBABitmap? {
        guard backend != .cpu else { return nil }
        #if canImport(Metal)
        guard MetalVolumeRenderer.active != nil else { return nil }
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RGBABitmap?, Error>) in
                MetalVolumeRenderer.workQueue.async {
                    do {
                        let bitmap = try metalRender(
                            setup: setup, grid: grid, backend: backend, isCancelled: { stop.isSet }
                        )
                        continuation.resume(returning: bitmap)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            stop.set()
        }
        #else
        return nil
        #endif
    }
}

/// Thread-safe one-way flag for the synchronous path's cooperative stop.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}
