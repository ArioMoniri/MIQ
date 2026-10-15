import Foundation

/// Everything a backend needs to render one frame, resolved once from the
/// public inputs: camera basis in RAS world space, ray stepping, the 256-entry
/// transfer table and the label palette (both with step-corrected opacity).
/// Shared verbatim by the CPU caster and the Metal kernel so the two stay in
/// lock-step — the kernel reads these exact numbers from a constant buffer.
struct VolumeRenderSetup: Sendable {
    static let transferTableSize = 256

    let width: Int
    let height: Int
    let nx: Int, ny: Int, nz: Int
    let sx: Float, sy: Float, sz: Float
    /// Half physical extent of the volume box (mm), box centred on the origin.
    let hx: Float, hy: Float, hz: Float
    /// Camera basis: screen right, screen up, view direction (eye → scene).
    let right: (Float, Float, Float)
    let up: (Float, Float, Float)
    let dir: (Float, Float, Float)
    /// Millimetres per output pixel.
    let pixelSize: Float
    /// Ray step in millimetres.
    let stepMM: Float
    let mode: VolumeRenderMode
    let windowLow: Float
    let windowInvWidth: Float
    /// Gradient magnitude (per mm) below which a DVR sample is left unshaded.
    let gradientFloor: Float
    let shading: Bool
    let earlyTermination: Float
    /// MinIP only: skip samples touching the grid's flat background
    /// (`VolumeRenderGrid.minIPBackgroundFloor`, via the occupancy field).
    let minIPMasked: Bool
    /// RGBA floats, `transferTableSize` entries; alpha is per-step corrected.
    let transfer: [Float]
    /// RGBA floats per label index (index 0 = background, alpha 0).
    let palette: [Float]
    let background: (Float, Float, Float)

    init(
        grid: VolumeRenderGrid,
        camera: VolumeRenderCamera,
        mode: VolumeRenderMode,
        window: MIQIntensityWindowBounds?,
        width: Int,
        height: Int,
        options: VolumeRenderOptions
    ) throws {
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw VolumeRenderError.invalidOutputSize
        }
        guard grid.voxelCount > 0 else { throw VolumeRenderError.emptyVolume }
        if mode == .labels && !grid.isLabelGrid { throw VolumeRenderError.notALabelGrid }

        self.width = width
        self.height = height
        (nx, ny, nz) = grid.dimensions
        (sx, sy, sz) = grid.spacing
        hx = Float(nx) * sx / 2
        hy = Float(ny) * sy / 2
        hz = Float(nz) * sz / 2

        let az = camera.azimuth.isFinite ? camera.azimuth * .pi / 180 : 0
        let elDeg = camera.elevation.isFinite ? min(max(camera.elevation, -89.9), 89.9) : 0
        let el = elDeg * .pi / 180
        let ca = cos(az), sa = sin(az), ce = cos(el), se = sin(el)
        // Eye direction (centre → camera); see VolumeRenderCamera for the convention.
        let e = (sa * ce, ca * ce, se)
        let r = (-ca, sa, Float(0))
        // up = e × r  (so right × up = e, a right-handed screen frame facing the eye)
        let u = (e.1 * r.2 - e.2 * r.1, e.2 * r.0 - e.0 * r.2, e.0 * r.1 - e.1 * r.0)
        right = r
        up = u
        dir = (-e.0, -e.1, -e.2)

        let diag = (4 * (hx * hx + hy * hy + hz * hz)).squareRoot()
        let zoom = camera.zoom.isFinite && camera.zoom > 0 ? camera.zoom : 1
        pixelSize = diag / (zoom * Float(min(width, height)))

        let spacingRatio = options.sampleSpacing.isFinite ? min(max(options.sampleSpacing, 0.05), 8) : 1
        stepMM = spacingRatio * min(sx, sy, sz)
        self.mode = mode
        shading = options.shading
        earlyTermination = min(max(options.earlyTerminationAlpha, 0.01), 1)
        minIPMasked = mode == .minIP && grid.minIPBackgroundFloor != nil && grid.storage.occupancy != nil

        let win = window ?? grid.suggestedWindow
            ?? MIQIntensityWindowBounds(low: grid.valueRange.min, high: grid.valueRange.max)
        var lo = win.low.isFinite ? win.low : 0
        var hi = win.high.isFinite ? win.high : 1
        if hi < lo { swap(&lo, &hi) }
        let w = max(hi - lo, Float.leastNormalMagnitude * 1e6)
        windowLow = lo
        windowInvWidth = 1 / w
        gradientFloor = w * 1e-3 / max(min(sx, sy, sz), 1e-6)

        // Transfer table: colormap RGB + opacity ramp t^gamma * scale, corrected
        // for the step: alpha' = 1 - (1 - alpha)^(step / reference voxel).
        let n = Self.transferTableSize
        var tf = [Float](repeating: 0, count: n * 4)
        let gamma = options.opacityGamma.isFinite && options.opacityGamma > 0 ? options.opacityGamma : 1
        let scale = min(max(options.opacityScale.isFinite ? options.opacityScale : 0.12, 0), 1)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let (cr, cg, cb) = options.colormap.rgb(t)
            let alpha = min(1, scale * pow(t, gamma))
            tf[i * 4] = cr
            tf[i * 4 + 1] = cg
            tf[i * 4 + 2] = cb
            tf[i * 4 + 3] = Self.correctedAlpha(alpha, spacingRatio)
        }
        transfer = tf

        var pal = [Float]()
        if let labels = grid.labels {
            let colorMap = options.labelColor ?? SegmentationLut.random(labels: Set(labels.dropFirst())).volumeLabelColorMap
            let labelOpacity = min(max(options.labelOpacity.isFinite ? options.labelOpacity : 0.85, 0), 1)
            pal = [Float](repeating: 0, count: labels.count * 4)
            for (idx, label) in labels.enumerated() where idx > 0 {
                let c = colorMap(label)
                pal[idx * 4] = Float(c.r) / 255
                pal[idx * 4 + 1] = Float(c.g) / 255
                pal[idx * 4 + 2] = Float(c.b) / 255
                pal[idx * 4 + 3] = Self.correctedAlpha(labelOpacity * Float(c.a) / 255, spacingRatio)
            }
        }
        palette = pal
        let bg = options.background
        background = (Float(bg.r) / 255, Float(bg.g) / 255, Float(bg.b) / 255)
    }

    static func correctedAlpha(_ alpha: Float, _ ratio: Float) -> Float {
        if alpha >= 1 { return 1 }
        if alpha <= 0 { return 0 }
        return ratio == 1 ? alpha : 1 - pow(1 - alpha, ratio)
    }
}

/// Read-only trilinear sampler over a RAS grid buffer (x fastest). Coordinates
/// are continuous voxel indices (voxel centres at integers), clamped to the edge.
struct VoxelSampler {
    let p: UnsafePointer<Float>
    let nx: Int, ny: Int, nz: Int
    let maxX: Float, maxY: Float, maxZ: Float
    let plane: Int

    init(_ p: UnsafePointer<Float>, _ nx: Int, _ ny: Int, _ nz: Int) {
        self.p = p
        self.nx = nx; self.ny = ny; self.nz = nz
        maxX = Float(nx - 1); maxY = Float(ny - 1); maxZ = Float(nz - 1)
        plane = nx * ny
    }

    @inline(__always)
    func trilinear(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let xc = min(max(x, 0), maxX)
        let yc = min(max(y, 0), maxY)
        let zc = min(max(z, 0), maxZ)
        let x0 = Int(xc), y0 = Int(yc), z0 = Int(zc)
        let fx = xc - Float(x0), fy = yc - Float(y0), fz = zc - Float(z0)
        let dx = x0 < nx - 1 ? 1 : 0
        let dy = y0 < ny - 1 ? nx : 0
        let dz = z0 < nz - 1 ? plane : 0
        let b = z0 * plane + y0 * nx + x0
        let c000 = p[b], c100 = p[b + dx]
        let c010 = p[b + dy], c110 = p[b + dy + dx]
        let c001 = p[b + dz], c101 = p[b + dz + dx]
        let c011 = p[b + dz + dy], c111 = p[b + dz + dy + dx]
        let c00 = c000 + (c100 - c000) * fx
        let c10 = c010 + (c110 - c010) * fx
        let c01 = c001 + (c101 - c001) * fx
        let c11 = c011 + (c111 - c011) * fx
        let c0 = c00 + (c10 - c00) * fy
        let c1 = c01 + (c11 - c01) * fy
        return c0 + (c1 - c0) * fz
    }

    @inline(__always)
    func nearest(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let xi = Int(min(max(x, 0), maxX) + 0.5)
        let yi = Int(min(max(y, 0), maxY) + 0.5)
        let zi = Int(min(max(z, 0), maxZ) + 0.5)
        return p[zi * plane + yi * nx + xi]
    }
}

/// Portable reference ray caster. Each pixel is independent and computed with
/// a fixed sample sequence — DVR/label rays start at a per-pixel offset that is a
/// pure hash of the pixel coordinates (`rayStartJitter`), never RNG state — so
/// output is bit-identical regardless of thread count or scheduling.
enum CPUVolumeRayCaster {

    /// Ray-start offset in [0, 1) steps for pixel (`px`, `py`).
    ///
    /// With every ray starting the same fraction of a step past the box entry,
    /// DVR/label samples line up on concentric shells around the camera and the
    /// opacity steps between them show as "wood-grain" rings. Offsetting each
    /// ray's first sample by a decorrelated fraction turns that structured
    /// aliasing into fine, unstructured noise. The hash (a 32-bit integer mixer
    /// over the pixel coordinates) is integer-only and its result is exactly
    /// representable as a Float, so the Metal kernel's copy of the formula yields
    /// bit-identical offsets. MIP/MinIP keep the fixed half-step start: their
    /// extremum doesn't band, and they stay pixel-exact against references.
    @inline(__always)
    static func rayStartJitter(_ px: Int, _ py: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: px) &* 1973 &+ UInt32(truncatingIfNeeded: py) &* 9277 &+ 26699
        h ^= h >> 16
        h = h &* 0x7feb_352d
        h ^= h >> 15
        h = h &* 0x846c_a68b
        h ^= h >> 16
        return Float(h >> 8) * (1 / 16_777_216)
    }

    /// Renders rows `rows` into `out` (RGBA8, full-frame pointer). Returns
    /// `false` if `shouldStop` fired (checked once per row).
    static func castRows(
        setup s: VolumeRenderSetup,
        grid: VolumeRenderGrid,
        rows: Range<Int>,
        out: UnsafeMutablePointer<UInt8>,
        shouldStop: () -> Bool
    ) -> Bool {
        grid.storage.values.withUnsafeBufferPointer { vbuf in
            let field = VoxelSampler(vbuf.baseAddress!, s.nx, s.ny, s.nz)
            return s.transfer.withUnsafeBufferPointer { tf in
                s.palette.withUnsafeBufferPointer { pal in
                    let occ = grid.storage.occupancy ?? []
                    return occ.withUnsafeBufferPointer { obuf in
                        let occField = obuf.baseAddress.map { VoxelSampler($0, s.nx, s.ny, s.nz) }
                        for py in rows {
                            if shouldStop() { return false }
                            for px in 0..<s.width {
                                let rgb = castPixel(s, px, py, field, occField, tf.baseAddress!, pal.baseAddress)
                                let o = (py * s.width + px) * 4
                                out[o] = toByte(rgb.0)
                                out[o + 1] = toByte(rgb.1)
                                out[o + 2] = toByte(rgb.2)
                                out[o + 3] = 255
                            }
                        }
                        return true
                    }
                }
            }
        }
    }

    @inline(__always)
    static func toByte(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 1) * 255 + 0.5)
    }

    /// Ray/box slab intersection; returns the parametric [tNear, tFar] or nil.
    @inline(__always)
    static func intersect(
        _ o: (Float, Float, Float), _ d: (Float, Float, Float), _ h: (Float, Float, Float)
    ) -> (Float, Float)? {
        var tNear = -Float.greatestFiniteMagnitude
        var tFar = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let oa = axis == 0 ? o.0 : (axis == 1 ? o.1 : o.2)
            let da = axis == 0 ? d.0 : (axis == 1 ? d.1 : d.2)
            let ha = axis == 0 ? h.0 : (axis == 1 ? h.1 : h.2)
            if abs(da) < 1e-8 {
                if oa < -ha || oa > ha { return nil }
                continue
            }
            let inv = 1 / da
            var t0 = (-ha - oa) * inv
            var t1 = (ha - oa) * inv
            if t0 > t1 { swap(&t0, &t1) }
            tNear = max(tNear, t0)
            tFar = min(tFar, t1)
        }
        return tNear < tFar ? (tNear, tFar) : nil
    }

    @inline(__always)
    static func castPixel(
        _ s: VolumeRenderSetup,
        _ px: Int, _ py: Int,
        _ field: VoxelSampler,
        _ occField: VoxelSampler?,
        _ tf: UnsafePointer<Float>,
        _ pal: UnsafePointer<Float>?
    ) -> (Float, Float, Float) {
        let u = (Float(px) + 0.5 - Float(s.width) * 0.5) * s.pixelSize
        let v = (Float(s.height) * 0.5 - Float(py) - 0.5) * s.pixelSize
        let o = (u * s.right.0 + v * s.up.0, u * s.right.1 + v * s.up.1, u * s.right.2 + v * s.up.2)
        guard let (tNear, tFar) = intersect(o, s.dir, (s.hx, s.hy, s.hz)) else { return s.background }

        // World → continuous voxel index: c = (p + h) / spacing - 0.5.
        let c0x = (o.0 + s.hx) / s.sx - 0.5
        let c0y = (o.1 + s.hy) / s.sy - 0.5
        let c0z = (o.2 + s.hz) / s.sz - 0.5
        let dvx = s.dir.0 / s.sx, dvy = s.dir.1 / s.sy, dvz = s.dir.2 / s.sz
        let count = max(1, Int((tFar - tNear) / s.stepMM))
        let jitter: Float = s.mode == .dvr || s.mode == .labels ? rayStartJitter(px, py) : 0.5
        let tStart = tNear + jitter * s.stepMM
        let lastEntry = Float(VolumeRenderSetup.transferTableSize - 1)

        @inline(__always) func tfIndex(_ value: Float) -> Int {
            let t = min(max((value - s.windowLow) * s.windowInvWidth, 0), 1)
            return Int(t * lastEntry + 0.5) * 4
        }

        switch s.mode {
        case .mip, .minIP:
            let isMax = s.mode == .mip
            let masked = s.minIPMasked && occField != nil
            var best: Float = isMax ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude
            var found = false
            // MinIP background (`MinIPBackground`): samples touching the flat
            // floor are dropped while outside the object — before the first and
            // after the last foreground sample; a run between two foreground
            // samples is committed when the second arrives.
            var pending = Float.greatestFiniteMagnitude
            var hasPending = false
            for n in 0..<count {
                let t = tStart + Float(n) * s.stepMM
                let x = c0x + t * dvx, y = c0y + t * dvy, z = c0z + t * dvz
                let val = field.trilinear(x, y, z)
                if masked && occField!.trilinear(x, y, z) < 0.999 {
                    if found {
                        pending = min(pending, val)
                        hasPending = true
                    }
                    continue
                }
                if hasPending {
                    best = min(best, pending)
                    hasPending = false
                }
                best = isMax ? max(best, val) : min(best, val)
                found = true
            }
            // MinIP ray through background only: show the background colour.
            if !found { return s.background }
            let i = tfIndex(best)
            return (tf[i], tf[i + 1], tf[i + 2])

        case .dvr, .labels:
            let labels = s.mode == .labels
            var cr: Float = 0, cg: Float = 0, cb: Float = 0, ca: Float = 0
            let shadingField = labels ? occField! : field
            for n in 0..<count {
                let t = tStart + Float(n) * s.stepMM
                let x = c0x + t * dvx, y = c0y + t * dvy, z = c0z + t * dvz
                var r: Float, g: Float, b: Float, a: Float
                if labels {
                    let idx = Int(field.nearest(x, y, z)) * 4
                    if idx == 0 { continue }
                    a = pal![idx + 3]
                    if a <= 0 { continue }
                    r = pal![idx]; g = pal![idx + 1]; b = pal![idx + 2]
                } else {
                    let i = tfIndex(field.trilinear(x, y, z))
                    a = tf[i + 3]
                    if a <= 0.0005 { continue }
                    r = tf[i]; g = tf[i + 1]; b = tf[i + 2]
                }
                if s.shading {
                    let f = shadeFactor(s, shadingField, x, y, z, floor: labels ? 1e-3 : s.gradientFloor)
                    r = min(1, r * f.diffuse + f.specular)
                    g = min(1, g * f.diffuse + f.specular)
                    b = min(1, b * f.diffuse + f.specular)
                }
                let w = (1 - ca) * a
                cr += w * r; cg += w * g; cb += w * b
                ca += w
                if ca >= s.earlyTermination { break }
            }
            let rest = 1 - ca
            return (cr + rest * s.background.0, cg + rest * s.background.1, cb + rest * s.background.2)
        }
    }

    /// Headlight Blinn-Phong from central-difference gradients (physical units).
    /// Two-sided, so it works for both bright-on-dark and dark-on-bright edges.
    @inline(__always)
    static func shadeFactor(
        _ s: VolumeRenderSetup, _ f: VoxelSampler, _ x: Float, _ y: Float, _ z: Float, floor: Float
    ) -> (diffuse: Float, specular: Float) {
        let gx = (f.trilinear(x + 1, y, z) - f.trilinear(x - 1, y, z)) / (2 * s.sx)
        let gy = (f.trilinear(x, y + 1, z) - f.trilinear(x, y - 1, z)) / (2 * s.sy)
        let gz = (f.trilinear(x, y, z + 1) - f.trilinear(x, y, z - 1)) / (2 * s.sz)
        let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
        if mag < floor { return (1, 0) }
        // Light and view both toward the eye (-dir).
        let ndotl = abs(gx * s.dir.0 + gy * s.dir.1 + gz * s.dir.2) / mag
        let spec = pow(ndotl, 24) * 0.25
        return (0.3 + 0.7 * ndotl, spec)
    }
}
