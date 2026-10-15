import Foundation
#if canImport(Metal)
import Metal
#endif

// Metal compute backend. UNTESTED ON HARDWARE: authored on Linux, where Metal
// cannot be compiled or run. It is deliberately isolated — the kernel is a
// source string compiled at runtime, the backend is only enabled after it
// reproduces the CPU reference on a synthetic volume, and every failure path
// returns nil/throws so `VolumeRenderer` falls back to the CPU caster.
//
// The kernel source and the parameter packing live outside `#if canImport(Metal)`
// so they at least compile (and the packing is unit-tested) on every platform.

enum VolumeRenderMetalShared {
    /// Indices into the flat `float` parameter buffer the kernel reads. A flat
    /// array sidesteps Swift/MSL struct-layout mismatches entirely.
    enum Param: Int, CaseIterable {
        case width, height, nx, ny, nz, sx, sy, sz, hx, hy, hz
        case rx, ry, rz, ux, uy, uz, dx, dy, dz
        case pixelSize, step, mode, windowLow, windowInvWidth, gradientFloor
        case shading, earlyTermination, bgR, bgG, bgB
    }

    static func modeCode(_ mode: VolumeRenderMode) -> Float {
        switch mode {
        case .mip: return 0
        case .minIP: return 1
        case .dvr: return 2
        case .labels: return 3
        }
    }

    /// Packs a setup in `Param` order. Integer fields are exact in Float (≤ 4096).
    static func pack(_ s: VolumeRenderSetup) -> [Float] {
        var p = [Float](repeating: 0, count: Param.allCases.count)
        func set(_ k: Param, _ v: Float) { p[k.rawValue] = v }
        set(.width, Float(s.width)); set(.height, Float(s.height))
        set(.nx, Float(s.nx)); set(.ny, Float(s.ny)); set(.nz, Float(s.nz))
        set(.sx, s.sx); set(.sy, s.sy); set(.sz, s.sz)
        set(.hx, s.hx); set(.hy, s.hy); set(.hz, s.hz)
        set(.rx, s.right.0); set(.ry, s.right.1); set(.rz, s.right.2)
        set(.ux, s.up.0); set(.uy, s.up.1); set(.uz, s.up.2)
        set(.dx, s.dir.0); set(.dy, s.dir.1); set(.dz, s.dir.2)
        set(.pixelSize, s.pixelSize); set(.step, s.stepMM); set(.mode, modeCode(s.mode))
        set(.windowLow, s.windowLow); set(.windowInvWidth, s.windowInvWidth)
        set(.gradientFloor, s.gradientFloor)
        set(.shading, s.shading ? 1 : 0); set(.earlyTermination, s.earlyTermination)
        set(.bgR, s.background.0); set(.bgG, s.background.1); set(.bgB, s.background.2)
        return p
    }

    static let kernelName = "miq_volume_render"

    /// MSL mirror of `CPUVolumeRayCaster` — keep the two in sync line for line.
    /// Parameter indices must match `Param`'s order.
    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    enum {
        P_W, P_H, P_NX, P_NY, P_NZ, P_SX, P_SY, P_SZ, P_HX, P_HY, P_HZ,
        P_RX, P_RY, P_RZ, P_UX, P_UY, P_UZ, P_DX, P_DY, P_DZ,
        P_PIX, P_STEP, P_MODE, P_WLO, P_WINV, P_GFLOOR,
        P_SHADE, P_EARLY, P_BGR, P_BGG, P_BGB
    };

    static inline float tri(texture3d<float, access::read> t, float3 c, int3 n) {
        float3 cc = clamp(c, float3(0.0), float3(n - 1));
        int3 i0 = int3(cc);
        float3 f = cc - float3(i0);
        int3 i1 = min(i0 + 1, n - 1);
        float c000 = t.read(uint3(i0.x, i0.y, i0.z)).r;
        float c100 = t.read(uint3(i1.x, i0.y, i0.z)).r;
        float c010 = t.read(uint3(i0.x, i1.y, i0.z)).r;
        float c110 = t.read(uint3(i1.x, i1.y, i0.z)).r;
        float c001 = t.read(uint3(i0.x, i0.y, i1.z)).r;
        float c101 = t.read(uint3(i1.x, i0.y, i1.z)).r;
        float c011 = t.read(uint3(i0.x, i1.y, i1.z)).r;
        float c111 = t.read(uint3(i1.x, i1.y, i1.z)).r;
        float c00 = c000 + (c100 - c000) * f.x;
        float c10 = c010 + (c110 - c010) * f.x;
        float c01 = c001 + (c101 - c001) * f.x;
        float c11 = c011 + (c111 - c011) * f.x;
        float c0 = c00 + (c10 - c00) * f.y;
        float c1 = c01 + (c11 - c01) * f.y;
        return c0 + (c1 - c0) * f.z;
    }

    static inline float nearestv(texture3d<float, access::read> t, float3 c, int3 n) {
        float3 cc = clamp(c, float3(0.0), float3(n - 1));
        int3 i = int3(cc + 0.5);
        return t.read(uint3(i.x, i.y, i.z)).r;
    }

    static inline float2 shade(texture3d<float, access::read> t, float3 c, int3 n,
                               float3 sp, float3 dir, float floorv) {
        float gx = (tri(t, c + float3(1, 0, 0), n) - tri(t, c - float3(1, 0, 0), n)) / (2.0 * sp.x);
        float gy = (tri(t, c + float3(0, 1, 0), n) - tri(t, c - float3(0, 1, 0), n)) / (2.0 * sp.y);
        float gz = (tri(t, c + float3(0, 0, 1), n) - tri(t, c - float3(0, 0, 1), n)) / (2.0 * sp.z);
        float mag = sqrt(gx * gx + gy * gy + gz * gz);
        if (mag < floorv) { return float2(1.0, 0.0); }
        float ndotl = fabs(gx * dir.x + gy * dir.y + gz * dir.z) / mag;
        return float2(0.3 + 0.7 * ndotl, pow(ndotl, 24.0) * 0.25);
    }

    kernel void miq_volume_render(
        texture3d<float, access::read> vol [[texture(0)]],
        texture3d<float, access::read> occ [[texture(1)]],
        device const float *P [[buffer(0)]],
        device const float4 *tf [[buffer(1)]],
        device const float4 *pal [[buffer(2)]],
        device uchar4 *outp [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int W = int(P[P_W]);
        int H = int(P[P_H]);
        if (int(gid.x) >= W || int(gid.y) >= H) { return; }
        int3 n = int3(int(P[P_NX]), int(P[P_NY]), int(P[P_NZ]));
        float3 sp = float3(P[P_SX], P[P_SY], P[P_SZ]);
        float3 h = float3(P[P_HX], P[P_HY], P[P_HZ]);
        float3 r = float3(P[P_RX], P[P_RY], P[P_RZ]);
        float3 u = float3(P[P_UX], P[P_UY], P[P_UZ]);
        float3 d = float3(P[P_DX], P[P_DY], P[P_DZ]);
        float3 bg = float3(P[P_BGR], P[P_BGG], P[P_BGB]);
        float stepmm = P[P_STEP];
        int mode = int(P[P_MODE]);
        float wlo = P[P_WLO];
        float winv = P[P_WINV];
        bool shading = P[P_SHADE] > 0.5;
        float early = P[P_EARLY];

        float pu = (float(gid.x) + 0.5 - float(W) * 0.5) * P[P_PIX];
        float pv = (float(H) * 0.5 - float(gid.y) - 0.5) * P[P_PIX];
        float3 o = pu * r + pv * u;

        float3 color = bg;
        float tNear = -3.402823466e+38;
        float tFar = 3.402823466e+38;
        bool hit = true;
        for (int a = 0; a < 3; a++) {
            if (fabs(d[a]) < 1e-8) {
                if (o[a] < -h[a] || o[a] > h[a]) { hit = false; }
                continue;
            }
            float inv = 1.0 / d[a];
            float t0 = (-h[a] - o[a]) * inv;
            float t1 = (h[a] - o[a]) * inv;
            if (t0 > t1) { float tmp = t0; t0 = t1; t1 = tmp; }
            tNear = max(tNear, t0);
            tFar = min(tFar, t1);
        }
        if (hit && tNear < tFar) {
            float3 c0 = (o + h) / sp - 0.5;
            float3 dv = d / sp;
            int count = max(1, int((tFar - tNear) / stepmm));
            float tStart = tNear + 0.5 * stepmm;
            if (mode == 0 || mode == 1) {
                bool isMax = mode == 0;
                float best = isMax ? -3.402823466e+38 : 3.402823466e+38;
                for (int i = 0; i < count; i++) {
                    float t = tStart + float(i) * stepmm;
                    float v = tri(vol, c0 + t * dv, n);
                    best = isMax ? max(best, v) : min(best, v);
                }
                int idx = int(clamp((best - wlo) * winv, 0.0, 1.0) * 255.0 + 0.5);
                color = tf[idx].rgb;
            } else {
                bool labels = mode == 3;
                float3 acc = float3(0.0);
                float ca = 0.0;
                for (int i = 0; i < count; i++) {
                    float t = tStart + float(i) * stepmm;
                    float3 c = c0 + t * dv;
                    float4 s;
                    if (labels) {
                        int li = int(nearestv(vol, c, n));
                        if (li == 0) { continue; }
                        s = pal[li];
                        if (s.a <= 0.0) { continue; }
                    } else {
                        float v = tri(vol, c, n);
                        int idx = int(clamp((v - wlo) * winv, 0.0, 1.0) * 255.0 + 0.5);
                        s = tf[idx];
                        if (s.a <= 0.0005) { continue; }
                    }
                    float3 rgb = s.rgb;
                    if (shading) {
                        float2 f = labels ? shade(occ, c, n, sp, d, 1e-3)
                                          : shade(vol, c, n, sp, d, P[P_GFLOOR]);
                        rgb = min(float3(1.0), rgb * f.x + f.y);
                    }
                    float w = (1.0 - ca) * s.a;
                    acc += w * rgb;
                    ca += w;
                    if (ca >= early) { break; }
                }
                color = acc + (1.0 - ca) * bg;
            }
        }
        uchar4 px = uchar4(uchar(clamp(color.r, 0.0, 1.0) * 255.0 + 0.5),
                           uchar(clamp(color.g, 0.0, 1.0) * 255.0 + 0.5),
                           uchar(clamp(color.b, 0.0, 1.0) * 255.0 + 0.5),
                           uchar(255));
        outp[gid.y * uint(W) + gid.x] = px;
    }
    """
}

/// Process-lifetime circuit breaker for the GPU backend. Portable (no Metal
/// types) so its policy is unit-tested on every platform.
///
/// After `failureLimit` consecutive GPU failures — or one device-removed
/// failure — Metal stays off until the process exits; every later frame goes
/// straight to the CPU caster instead of re-trying a broken GPU per drag step.
final class MetalFailureGate: @unchecked Sendable {
    static let defaultFailureLimit = 2

    private let lock = NSLock()
    private let failureLimit: Int
    private var consecutiveFailures = 0
    private var disabled = false

    init(failureLimit: Int = MetalFailureGate.defaultFailureLimit) {
        self.failureLimit = max(1, failureLimit)
    }

    var isDisabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return disabled
    }

    func recordSuccess() {
        lock.lock(); consecutiveFailures = 0; lock.unlock()
    }

    /// `permanent` (device removed / lost) disables immediately.
    func recordFailure(permanent: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        if permanent || consecutiveFailures >= failureLimit { disabled = true }
    }
}

#if canImport(Metal)

enum MetalVolumeRenderError: Error {
    case resourceCreationFailed
    case gridTooLarge
    case commandFailed
    /// The GPU went away (eGPU unplugged, driver reset): disables Metal.
    case deviceRemoved
}

/// Runtime-compiled Metal implementation of the ray caster. Serialised with a
/// lock (one frame in flight); the 3D textures are cached for the most recent
/// grid so camera drags only re-upload the small parameter buffer.
final class MetalVolumeRenderer: @unchecked Sendable {
    /// nil when there is no device, the kernel fails to compile, or the
    /// self-check against the CPU reference fails.
    static let shared: MetalVolumeRenderer? = {
        didInitializeShared.set()
        guard let renderer = MetalVolumeRenderer() else { return nil }
        return renderer.passesSelfCheck() ? renderer : nil
    }()

    /// `shared`, unless the failure gate has switched Metal off for good.
    static var active: MetalVolumeRenderer? {
        guard let shared, !shared.failureGate.isDisabled else { return nil }
        return shared
    }

    /// Dedicated serial queue for async callers: the blocking
    /// `waitUntilCompleted` (and any wait on `lock`) happens here, never on a
    /// Swift-concurrency pool thread.
    static let workQueue = DispatchQueue(label: "MIQ.MetalVolumeRenderer", qos: .userInitiated)

    let failureGate = MetalFailureGate()

    /// Set once `shared` has been (or is being) created, so a cache release
    /// never triggers the kernel compile + self-check just to find nothing.
    private static let didInitializeShared = StopFlag()

    /// Releases `shared`'s caches without blocking the caller (the lock may be
    /// held across a GPU wait): queued behind any in-flight frame on
    /// `workQueue`. A no-op when Metal was never touched.
    static func releaseSharedCachesAsync() {
        guard didInitializeShared.isSet else { return }
        workQueue.async { shared?.releaseCaches() }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let lock = NSLock()
    private var cachedStorage: VolumeRenderGrid.Storage?
    private var cachedVolume: MTLTexture?
    private var cachedOccupancy: MTLTexture?

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let compileOptions = MTLCompileOptions()
            // Precise math so the GPU tracks the CPU reference closely.
            compileOptions.fastMathEnabled = false
            let library = try device.makeLibrary(source: VolumeRenderMetalShared.kernelSource, options: compileOptions)
            guard let function = library.makeFunction(name: VolumeRenderMetalShared.kernelName) else { return nil }
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// Renders one frame. `isCancelled` is polled before waiting for the lock,
    /// once it is held and after the GPU finishes, so a superseded frame
    /// doesn't queue a full GPU pass behind the lock. Throws
    /// `CancellationError` when cancelled; GPU failures feed `failureGate`.
    func render(
        setup: VolumeRenderSetup,
        grid: VolumeRenderGrid,
        isCancelled: () -> Bool = { false }
    ) throws -> RGBABitmap {
        if isCancelled() { throw CancellationError() }
        lock.lock()
        defer { lock.unlock() }
        if isCancelled() { throw CancellationError() }
        do {
            let bitmap = try encodeAndWait(setup: setup, grid: grid)
            failureGate.recordSuccess()
            if isCancelled() { throw CancellationError() }
            return bitmap
        } catch MetalVolumeRenderError.gridTooLarge {
            // A size limit, not a GPU fault.
            throw MetalVolumeRenderError.gridTooLarge
        } catch let error as MetalVolumeRenderError {
            failureGate.recordFailure(permanent: error == .deviceRemoved)
            // Free the cached textures of a device that misbehaved.
            dropCachesLocked()
            throw error
        }
    }

    /// Drops the cached grid storage reference and its 3D textures (memory
    /// pressure, preview reset). The next frame re-uploads.
    func releaseCaches() {
        lock.lock(); defer { lock.unlock() }
        dropCachesLocked()
    }

    /// Caller holds `lock`.
    private func dropCachesLocked() {
        cachedStorage = nil
        cachedVolume = nil
        cachedOccupancy = nil
    }

    /// Caller holds `lock`.
    private func encodeAndWait(setup: VolumeRenderSetup, grid: VolumeRenderGrid) throws -> RGBABitmap {
        let (volumeTex, occupancyTex) = try textures(for: grid)
        let params = VolumeRenderMetalShared.pack(setup)
        let palette = setup.palette.isEmpty ? [Float](repeating: 0, count: 4) : setup.palette
        let outLength = setup.width * setup.height * 4
        guard let paramBuffer = makeBuffer(params),
              let tfBuffer = makeBuffer(setup.transfer),
              let palBuffer = makeBuffer(palette),
              let outBuffer = device.makeBuffer(length: outLength, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalVolumeRenderError.resourceCreationFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTex, index: 0)
        encoder.setTexture(occupancyTex ?? volumeTex, index: 1)
        encoder.setBuffer(paramBuffer, offset: 0, index: 0)
        encoder.setBuffer(tfBuffer, offset: 0, index: 1)
        encoder.setBuffer(palBuffer, offset: 0, index: 2)
        encoder.setBuffer(outBuffer, offset: 0, index: 3)
        let tw = max(1, pipeline.threadExecutionWidth)
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        let groups = MTLSize(
            width: (setup.width + tw - 1) / tw,
            height: (setup.height + th - 1) / th,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            if let error = commandBuffer.error as NSError?,
               error.domain == MTLCommandBufferError.errorDomain,
               error.code == MTLCommandBufferError.Code.deviceRemoved.rawValue {
                throw MetalVolumeRenderError.deviceRemoved
            }
            throw MetalVolumeRenderError.commandFailed
        }
        let pixels = Data(bytes: outBuffer.contents(), count: outLength)
        return RGBABitmap(width: setup.width, height: setup.height, pixels: pixels)
    }

    private func makeBuffer(_ values: [Float]) -> MTLBuffer? {
        values.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLBuffer? in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    /// Caller holds `lock`.
    private func textures(for grid: VolumeRenderGrid) throws -> (MTLTexture, MTLTexture?) {
        if let cached = cachedStorage, cached === grid.storage, let vol = cachedVolume {
            return (vol, cachedOccupancy)
        }
        let (nx, ny, nz) = grid.dimensions
        guard nx <= 2048, ny <= 2048, nz <= 2048 else { throw MetalVolumeRenderError.gridTooLarge }
        guard let vol = makeTexture(grid.storage.values, nx, ny, nz) else {
            throw MetalVolumeRenderError.resourceCreationFailed
        }
        var occ: MTLTexture? = nil
        if let occupancy = grid.storage.occupancy {
            guard let t = makeTexture(occupancy, nx, ny, nz) else { throw MetalVolumeRenderError.resourceCreationFailed }
            occ = t
        }
        cachedStorage = grid.storage
        cachedVolume = vol
        cachedOccupancy = occ
        return (vol, occ)
    }

    private func makeTexture(_ values: [Float], _ nx: Int, _ ny: Int, _ nz: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .r32Float
        desc.width = nx
        desc.height = ny
        desc.depth = nz
        desc.mipmapLevelCount = 1
        desc.usage = .shaderRead
        // Default storage mode (managed on Intel Macs, shared on Apple silicon);
        // `replace(region:)` uploads correctly for both.
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, nx, ny, nz),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: nx * MemoryLayout<Float>.size,
                bytesPerImage: nx * ny * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    /// Renders a small synthetic scene in every mode on both backends and
    /// requires near-agreement. Guards against a kernel that compiles but is
    /// wrong (the one failure mode the CPU fallback can't otherwise catch).
    private func passesSelfCheck() -> Bool {
        let n = 24
        var values = [Float](repeating: 0, count: n * n * n)
        var labels = [Float](repeating: 0, count: n * n * n)
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let dx = Float(x) - 10, dy = Float(y) - 12, dz = Float(z) - 13
                    let r = (dx * dx + dy * dy + dz * dz).squareRoot()
                    let i = (z * n + y) * n + x
                    values[i] = max(0, 100 - r * 10) + Float(x)
                    labels[i] = r < 6 ? 1 : (x > 16 && y > 16 ? 2 : 0)
                }
            }
        }
        let spacing: (x: Float, y: Float, z: Float) = (1, 1.2, 0.9)
        let grid = VolumeRenderGrid(values: values, dimensions: (n, n, n), spacing: spacing, orientationKnown: true)
        let labelGrid = VolumeRenderGrid(
            values: labels, dimensions: (n, n, n), spacing: spacing, orientationKnown: true, labels: [0, 3, 7]
        )
        let camera = VolumeRenderCamera(azimuth: 33, elevation: 21, zoom: 1.1)
        let window = MIQIntensityWindowBounds(low: 10, high: 110)
        for mode in VolumeRenderMode.allCases {
            let g = mode == .labels ? labelGrid : grid
            guard let setup = try? VolumeRenderSetup(
                grid: g, camera: camera, mode: mode, window: window,
                width: 48, height: 40, options: VolumeRenderOptions()
            ) else { return false }
            guard let gpu = try? render(setup: setup, grid: g) else { return false }
            let count = setup.width * setup.height * 4
            var cpu = [UInt8](repeating: 0, count: count)
            let ok = cpu.withUnsafeMutableBufferPointer { buf in
                CPUVolumeRayCaster.castRows(
                    setup: setup, grid: g, rows: 0..<setup.height, out: buf.baseAddress!, shouldStop: { false }
                )
            }
            guard ok, gpu.pixels.count == count else { return false }
            var totalDiff = 0
            var bad = 0
            for (i, a) in gpu.pixels.enumerated() {
                let diff = abs(Int(a) - Int(cpu[i]))
                totalDiff += diff
                if diff > 12 { bad += 1 }
            }
            // Mean |Δ| ≤ 1 level and < 1% of channels off by more than 12.
            if totalDiff > count || bad * 100 > count { return false }
        }
        // The self-check rendered through the texture cache; drop it.
        releaseCaches()
        return true
    }
}

#endif
