import Foundation

/// A volume prepared for 3D rendering: one timepoint, scaled to physical values
/// (`scl_slope`/`scl_inter` applied), reoriented into patient **RAS** index order
/// (axis 0 → +R, 1 → +A, 2 → +S) and downsampled so no axis exceeds
/// `maxDimension`. Build it once per volume/timepoint and re-render it for every
/// camera change — building reads the source volume, rendering does not.
///
/// Orientation comes from `MIQHeader.orientationFrame`, so obliquity is snapped
/// to the nearest anatomical axis exactly as the 2D slice views do. When the
/// frame is unknown the storage axes are taken as R/A/S unchanged and
/// `orientationKnown` is `false` (the UI should not label the view anatomically).
///
/// Storage is a reference-typed buffer, so copying a grid is cheap and the
/// Metal path can cache its 3D texture per grid.
public struct VolumeRenderGrid: Sendable {
    /// Voxel counts along R, A, S.
    public let dimensions: (x: Int, y: Int, z: Int)
    /// Physical voxel size in millimetres along R, A, S (after downsampling).
    public let spacing: (x: Float, y: Float, z: Float)
    /// `true` when the RAS mapping came from a header orientation frame.
    public let orientationKnown: Bool
    /// Finite value range of the grid (label index range for label grids).
    public let valueRange: (min: Float, max: Float)
    /// Robust 1st–99.5th percentile window of the grid's foreground; a sensible
    /// default when the caller has no window. `nil` for label grids / all-NaN data.
    public let suggestedWindow: MIQIntensityWindowBounds?
    /// For label grids: the distinct label values, `labels[0] == 0` (background).
    /// Voxel values in a label grid are *indices* into this array. `nil` for
    /// intensity grids.
    public let labels: [Int]?
    /// Intensity grids only: the flat background MinIP ignores
    /// (`MinIPBackground.floor` of the grid values — zero fill, CT padding), or
    /// `nil` when the grid has none and MinIP takes every sample.
    public let minIPBackgroundFloor: Float?

    let storage: Storage

    final class Storage: @unchecked Sendable {
        /// RAS-ordered values, x fastest. Immutable after init.
        let values: [Float]
        /// Label grids: 1 where the label is non-background, else 0 —
        /// trilinearly sampled for smooth surface normals. Intensity grids with a
        /// `minIPBackgroundFloor`: 1 where the value is above it; MinIP keeps a
        /// sample only where this interpolates to ~1, i.e. no background voxel
        /// contributes to it (else every ray would pick up the dark partial-volume
        /// blend at the head's edge).
        let occupancy: [Float]?

        init(values: [Float], occupancy: [Float]?) {
            self.values = values
            self.occupancy = occupancy
        }
    }

    public var isLabelGrid: Bool { labels != nil }
    public var voxelCount: Int { dimensions.x * dimensions.y * dimensions.z }

    /// Direct initializer from RAS-ordered values (x fastest). Non-finite values
    /// become 0. With `labels`, `values` must already hold label *indices* into it.
    init(
        values: [Float],
        dimensions: (x: Int, y: Int, z: Int),
        spacing: (x: Float, y: Float, z: Float),
        orientationKnown: Bool,
        labels: [Int]? = nil
    ) {
        precondition(values.count == dimensions.x * dimensions.y * dimensions.z)
        var clean = values
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for i in clean.indices {
            let v = clean[i]
            if !v.isFinite { clean[i] = 0; continue }
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        if lo > hi { lo = 0; hi = 0 }
        self.dimensions = dimensions
        self.spacing = spacing
        self.orientationKnown = orientationKnown
        self.valueRange = (lo, hi)
        self.labels = labels
        if labels != nil {
            self.storage = Storage(values: clean, occupancy: clean.map { $0 != 0 ? 1 : 0 })
            self.suggestedWindow = nil
            self.minIPBackgroundFloor = nil
        } else {
            let floor = MinIPBackground.floor(of: clean)
            self.minIPBackgroundFloor = floor
            self.storage = Storage(values: clean, occupancy: floor.map { f in clean.map { $0 > f ? 1 : 0 } })
            let stride = max(1, clean.count / 262_144)
            var sample = [Float]()
            sample.reserveCapacity(clean.count / stride + 1)
            var i = 0
            while i < clean.count { sample.append(clean[i]); i += stride }
            self.suggestedWindow = IntensityWindow.bounds(for: sample, lowerPercentile: 1, upperPercentile: 99.5)
                .map { MIQIntensityWindowBounds(low: $0.low, high: $0.high) }
        }
    }

    /// Builds a render grid from timepoint `volumeIndex` of `volume`.
    ///
    /// Downsampling is per axis to `min(n, maxDimension)` voxels: intensity grids
    /// average (up to) two source voxels per axis per output voxel — a cheap box
    /// filter that caps reads at 8 per output voxel — while label grids take the
    /// nearest source voxel (labels must never blend). The voxel spacing grows to
    /// keep the physical extent, so anisotropic downsampling preserves shape.
    ///
    /// Pass `asLabels: true` when `MIQVolume.centerInteractiveState` returned a
    /// segmentation LUT; values are rounded to integer labels.
    public init(
        volume: MIQVolume,
        volumeIndex: Int = 0,
        maxDimension: Int = 128,
        asLabels: Bool = false
    ) {
        self.init(volume: volume, volumeIndex: volumeIndex, maxDimension: maxDimension, asLabels: asLabels, useFastReader: true)
    }

    /// `useFastReader: false` forces the per-voxel `MIQVolume.voxel` path — the
    /// reference the raw reader is tested against.
    init(
        volume: MIQVolume,
        volumeIndex: Int,
        maxDimension: Int,
        asLabels: Bool,
        useFastReader: Bool
    ) {
        let header = volume.image.header
        let storageDims = [max(1, volume.width), max(1, volume.height), max(1, volume.depth)]
        let storageSpacing = (1...3).map { sanitizedSpacing(header.pixdim[safe: $0] ?? 1) }
        let t = min(max(0, volumeIndex), max(0, volume.volumes - 1))

        // RAS axis a ← storage axis rasToStorage[a], flipped when !positive.
        var rasToStorage = [0, 1, 2]
        var rasFlip = [false, false, false]
        var known = false
        if let frame = header.orientationFrame, frame.axes.count == 3 {
            var mapping = [-1, -1, -1]
            var flips = [false, false, false]
            for (k, ax) in frame.axes.enumerated() {
                let a: Int
                switch ax.axis {
                case .rightLeft: a = 0
                case .anteriorPosterior: a = 1
                case .superiorInferior: a = 2
                }
                mapping[a] = k
                flips[a] = !ax.positive
            }
            if !mapping.contains(-1) {
                rasToStorage = mapping
                rasFlip = flips
                known = true
            }
        }

        let maxDim = max(1, maxDimension)
        var outDims = [0, 0, 0]
        var outSpacing: [Float] = [1, 1, 1]
        // Per RAS axis, per output index: up to two *storage* coordinates.
        var taps: [[(Int, Int)]] = [[], [], []]
        for a in 0..<3 {
            let k = rasToStorage[a]
            let n = storageDims[k]
            let m = min(n, maxDim)
            outDims[a] = m
            outSpacing[a] = storageSpacing[k] * Float(n) / Float(m)
            var axisTaps = [(Int, Int)]()
            axisTaps.reserveCapacity(m)
            for i in 0..<m {
                let lo = i * n / m
                let hi = max(lo + 1, (i + 1) * n / m)  // exclusive
                var first: Int
                var second: Int
                if asLabels {
                    first = (lo + hi - 1) / 2
                    second = first
                } else {
                    first = lo
                    second = hi - 1
                }
                if rasFlip[a] {
                    first = n - 1 - first
                    second = n - 1 - second
                }
                axisTaps.append((first, second))
            }
            taps[a] = axisTaps
        }

        let nx = outDims[0], ny = outDims[1], nz = outDims[2]
        let plane = nx * ny
        var raw = [Float](repeating: 0, count: plane * nz)
        let tapsX = taps[0], tapsY = taps[1], tapsZ = taps[2]
        // Storage axis k reads RAS coordinate inv[k].
        var inv = [0, 1, 2]
        for a in 0..<3 { inv[rasToStorage[a]] = a }
        let fill = FillPlan(
            nx: nx, ny: ny, nz: nz, tapsX: tapsX, tapsY: tapsY, tapsZ: tapsZ,
            i0: inv[0], i1: inv[1], i2: inv[2], labels: asLabels
        )
        raw.withUnsafeMutableBufferPointer { buf in
            let out = SendablePointer(buf.baseAddress!)
            let image = volume.image
            let fast = useFastReader && RawVoxelSource.supports(image)
            if fast {
                image.storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    let source = RawVoxelSource(image: image, bytes: bytes, t: t)
                    Self.fill(fill, source: source, out: out)
                }
            } else {
                Self.fill(fill, source: VolumeVoxelSource(volume: volume, t: t), out: out)
            }
        }

        var labelTable: [Int]? = nil
        if asLabels {
            // Compact label values to dense indices (0 stays background).
            var index: [Int: Int] = [0: 0]
            var table = [0]
            var lastValue: Float = 0
            var lastIndex: Float = 0
            for i in raw.indices {
                let v = raw[i]
                if v == lastValue { raw[i] = lastIndex; continue }
                let label = Int(v)
                let idx: Int
                if let existing = index[label] {
                    idx = existing
                } else {
                    idx = table.count
                    index[label] = idx
                    table.append(label)
                }
                lastValue = v
                lastIndex = Float(idx)
                raw[i] = lastIndex
            }
            labelTable = table
        }

        self.init(
            values: raw,
            dimensions: (nx, ny, nz),
            spacing: (outSpacing[0], outSpacing[1], outSpacing[2]),
            orientationKnown: known,
            labels: labelTable
        )
    }

    /// Output grid geometry and per-axis source taps for `fill`.
    private struct FillPlan: Sendable {
        let nx: Int, ny: Int, nz: Int
        let tapsX: [(Int, Int)], tapsY: [(Int, Int)], tapsZ: [(Int, Int)]
        /// Storage axis 0/1/2 reads RAS coordinate i0/i1/i2.
        let i0: Int, i1: Int, i2: Int
        let labels: Bool
    }

    /// Fills the RAS grid in parallel over output z planes. Generic so each
    /// source's `value` inlines into the loop.
    private static func fill<S: GridVoxelSource>(_ f: FillPlan, source: S, out: SendablePointer<Float>) {
        let plane = f.nx * f.ny
        DispatchQueue.concurrentPerform(iterations: f.nz) { k in
            let (zk0, zk1) = f.tapsZ[k]
            let zCount = zk0 == zk1 ? 1 : 2
            for j in 0..<f.ny {
                let (yj0, yj1) = f.tapsY[j]
                let yCount = yj0 == yj1 ? 1 : 2
                let rowBase = k * plane + j * f.nx
                for i in 0..<f.nx {
                    let (xi0, xi1) = f.tapsX[i]
                    if f.labels {
                        let v = source.value(
                            pick(f.i0, xi0, yj0, zk0), pick(f.i1, xi0, yj0, zk0), pick(f.i2, xi0, yj0, zk0)
                        )
                        out.pointer[rowBase + i] = (v.isFinite && abs(v) < 1e9) ? v.rounded() : 0
                        continue
                    }
                    let xCount = xi0 == xi1 ? 1 : 2
                    var sum: Float = 0
                    var count: Float = 0
                    for zi in 0..<zCount {
                        let zz = zi == 0 ? zk0 : zk1
                        for yi in 0..<yCount {
                            let yy = yi == 0 ? yj0 : yj1
                            for xi in 0..<xCount {
                                let xx = xi == 0 ? xi0 : xi1
                                let v = source.value(pick(f.i0, xx, yy, zz), pick(f.i1, xx, yy, zz), pick(f.i2, xx, yy, zz))
                                if v.isFinite { sum += v; count += 1 }
                            }
                        }
                    }
                    out.pointer[rowBase + i] = count > 0 ? sum / count : 0
                }
            }
        }
    }

    /// Selects the RAS coordinate (r, a or s) that storage axis reads.
    @inline(__always)
    private static func pick(_ which: Int, _ r: Int, _ a: Int, _ s: Int) -> Int {
        which == 0 ? r : (which == 1 ? a : s)
    }
}

/// Raw pointer wrapper for disjoint parallel writes (each worker owns its own
/// index range, so there is no data race).
struct SendablePointer<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    init(_ pointer: UnsafeMutablePointer<T>) { self.pointer = pointer }
}

/// A scaled-voxel reader in storage coordinates for one timepoint.
protocol GridVoxelSource: Sendable {
    func value(_ x: Int, _ y: Int, _ z: Int) -> Float
}

/// Reference source: `MIQVolume.voxel` (handles every datatype).
private struct VolumeVoxelSource: GridVoxelSource {
    let volume: MIQVolume
    let t: Int

    @inline(__always)
    func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        volume.voxel(x: x, y: y, z: z, t: t)
    }
}

/// Fast source reading the payload bytes directly — same arithmetic as
/// `MIQVolume.voxel`/`rawVoxelValue` (including `scl_slope`/`scl_inter` and
/// the out-of-payload → 0 rule) without per-voxel `Data` subscripting. Only
/// valid inside the `withUnsafeBytes` scope it was created in.
private struct RawVoxelSource: GridVoxelSource, @unchecked Sendable {
    enum Kind { case u8, i8, i16, u16, i32, u32, f32, f64 }

    let base: UnsafeRawPointer?
    let payloadCount: Int
    let kind: Kind
    let bytesPerVoxel: Int
    let littleEndian: Bool
    let slope: Float
    let intercept: Float
    let strideX: Int, strideY: Int, strideZ: Int
    let timeOffset: Int

    static func kind(of datatype: MIQDatatype) -> Kind? {
        switch datatype {
        case .uint8: return .u8
        case .int8: return .i8
        case .int16: return .i16
        case .uint16: return .u16
        case .int32: return .i32
        case .uint32: return .u32
        case .float32: return .f32
        case .float64: return .f64
        case .int64, .uint64, .rgb24, .rgba32: return nil
        }
    }

    static func supports(_ image: MIQImage) -> Bool {
        kind(of: image.header.datatype) != nil
    }

    init(image: MIQImage, bytes: UnsafeRawBufferPointer, t: Int) {
        let header = image.header
        base = bytes.baseAddress.map { $0 + image.payloadOffset }
        payloadCount = image.payloadCount
        kind = Self.kind(of: header.datatype)!
        bytesPerVoxel = header.datatype.bytesPerVoxel
        littleEndian = header.littleEndian
        slope = header.sclSlope
        intercept = header.sclInter
        // Mirrors MIQImage.voxelElementIndex.
        if let s = image.payloadElementStrides, s.count >= 4 {
            strideX = s[0]; strideY = s[1]; strideZ = s[2]
            timeOffset = t * s[3]
        } else {
            strideX = 1
            strideY = header.width
            strideZ = header.width * header.height
            timeOffset = t * header.width * header.height * header.depth
        }
    }

    @inline(__always)
    func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        let element = x * strideX + y * strideY + z * strideZ + timeOffset
        let offset = element * bytesPerVoxel
        guard let base, offset >= 0, offset + bytesPerVoxel <= payloadCount else { return 0 }
        let raw: Float
        switch kind {
        case .u8:
            raw = Float(base.load(fromByteOffset: offset, as: UInt8.self))
        case .i8:
            raw = Float(Int8(bitPattern: base.load(fromByteOffset: offset, as: UInt8.self)))
        case .i16:
            raw = Float(Int16(bitPattern: u16(offset)))
        case .u16:
            raw = Float(u16(offset))
        case .i32:
            raw = Float(Int32(bitPattern: u32(offset)))
        case .u32:
            raw = Float(u32(offset))
        case .f32:
            raw = Float(bitPattern: u32(offset))
        case .f64:
            let v = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            raw = Float(Double(bitPattern: littleEndian ? UInt64(littleEndian: v) : UInt64(bigEndian: v)))
        }
        return slope != 0 ? raw * slope + intercept : raw
    }

    @inline(__always)
    private func u16(_ offset: Int) -> UInt16 {
        let v = base!.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        return littleEndian ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
    }

    @inline(__always)
    private func u32(_ offset: Int) -> UInt32 {
        let v = base!.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        return littleEndian ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
    }
}
