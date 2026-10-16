import Foundation

/// Scalar source volume handed to the neural pipeline: voxels in storage order
/// (x fastest, then y, then z) plus the voxel→world (RAS mm) transform.
///
/// Only the transform's linear part (directions × spacing) matters: the model grid
/// is centred on the volume's own centre, so the origin cancels out.
public struct NeuralInputVolume: Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    public let voxels: [Float]
    public let voxelToWorld: NeuralAffine

    public init(width: Int, height: Int, depth: Int, voxels: [Float], voxelToWorld: NeuralAffine) throws {
        guard width > 0, height > 0, depth > 0, voxels.count == width * height * depth else {
            throw NeuralModelError.invalidInput("voxel count does not match \(width)×\(height)×\(depth)")
        }
        guard voxelToWorld.inverted() != nil else {
            throw NeuralModelError.invalidInput("voxel-to-world transform is singular")
        }
        self.width = width
        self.height = height
        self.depth = depth
        self.voxels = voxels
        self.voxelToWorld = voxelToWorld
    }

    /// Extracts one 3-D frame of a parsed volume (scaled values, non-finite → 0) and
    /// derives its voxel→world transform from the header:
    /// - NIfTI sform / NRRD space-direction columns as stored (they include spacing);
    /// - MGH direction cosines × sanitised `pixdim` spacings;
    /// - otherwise the axis-aligned `orientationFrame` × spacings (qform-only NIfTI and
    ///   MIF: obliquity is dropped, which is harmless for a preview mask);
    /// - otherwise identity directions (assumed RAS) × spacings.
    public init(volume: MIQVolume, volumeIndex: Int = 0) throws {
        let header = volume.image.header
        let w = volume.width
        let h = volume.height
        let d = volume.depth
        guard w > 0, h > 0, d > 0 else { throw NeuralModelError.invalidInput("empty volume") }
        guard volumeIndex >= 0, volumeIndex < volume.volumes else {
            throw NeuralModelError.invalidInput("volume index \(volumeIndex) out of range")
        }
        var values = [Float](repeating: 0, count: w * h * d)
        var i = 0
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    let v = volume.voxel(x: x, y: y, z: z, t: volumeIndex)
                    values[i] = v.isFinite ? v : 0
                    i += 1
                }
            }
        }
        try self.init(width: w, height: h, depth: d, voxels: values, voxelToWorld: Self.affine(for: header))
    }

    static func affine(for header: MIQHeader) -> NeuralAffine {
        let spacing = (1...3).map { Double(sanitizedSpacing(header.pixdim[safe: $0] ?? 1)) }
        var columns: [(Double, Double, Double)]?
        var unitColumns = true
        if header.orientationFrame?.source != .qform,
           header.srowX.count >= 3, header.srowY.count >= 3, header.srowZ.count >= 3 {
            // NIfTI sform and NRRD space directions carry the spacing in their columns;
            // MGH direction cosines are unit vectors with spacing kept in pixdim.
            let scaledColumns = header.orientationFrame?.source == .sform
                || header.orientationFrame?.source == .nrrdSpaceDirections
            var cols: [(Double, Double, Double)] = []
            for axis in 0..<3 {
                let v = (Double(header.srowX[axis]), Double(header.srowY[axis]), Double(header.srowZ[axis]))
                let n = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
                guard n.isFinite, n > 0 else { break }
                let scale = scaledColumns ? 1 : spacing[axis] / n
                cols.append((v.0 * scale, v.1 * scale, v.2 * scale))
            }
            if cols.count == 3 { columns = cols; unitColumns = false }
        }
        if columns == nil, let frame = header.orientationFrame, frame.axes.count == 3 {
            columns = frame.axes.map { axis in
                let s: Double = axis.positive ? 1 : -1
                switch axis.axis {
                case .rightLeft: return (s, 0, 0)
                case .anteriorPosterior: return (0, s, 0)
                case .superiorInferior: return (0, 0, s)
                }
            }
        }
        let cols = columns ?? [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        let s = unitColumns ? spacing : [1, 1, 1]
        let candidate = NeuralAffine(entries: [
            cols[0].0 * s[0], cols[1].0 * s[1], cols[2].0 * s[2], 0,
            cols[0].1 * s[0], cols[1].1 * s[1], cols[2].1 * s[2], 0,
            cols[0].2 * s[0], cols[1].2 * s[1], cols[2].2 * s[2], 0,
        ])
        return candidate.inverted() == nil ? .scaling(spacing[0], spacing[1], spacing[2]) : candidate
    }
}

/// Intensity normalisation applied to the conformed grid before inference.
public enum NeuralNormalization: Sendable, Hashable {
    /// `(x − min) / (max − min)` — brainchop web app (`minMaxNormalizeVolumeData`).
    case minMax
    /// `clip((x − q_lo) / (q_hi − q_lo + 1e-3), 0, 1)` — brainchop-cli `qnormalize`
    /// (defaults 0.02 / 0.98) and the web app's `quantileNormalizeVolumeData` (0.05/0.95).
    case quantile(lower: Float, upper: Float)
}

/// The model-space sampling grid: a cube of `size³` voxels at `spacing` mm in
/// FreeSurfer "conformed" LIA orientation (axis 0 → Left, 1 → Inferior, 2 → Anterior),
/// centred on the source volume. This is the layout niimath/niivue `conform` produce and
/// brainchop then transposes to (i, j, k) before inference, so tensor axes (D, H, W) map
/// to grid axes (i, j, k) directly.
struct NeuralGrid {
    let size: Int
    let spacing: Double
    let gridToWorld: NeuralAffine

    init(size: Int, spacing: Double, centredOn source: NeuralInputVolume) {
        self.size = size
        self.spacing = spacing
        let (cx, cy, cz) = source.voxelToWorld.apply(
            Double(source.width - 1) / 2, Double(source.height - 1) / 2, Double(source.depth - 1) / 2
        )
        let half = Double(size - 1) / 2
        let s = spacing
        // world = centre + R · s · (ijk − half), with LIA columns.
        gridToWorld = NeuralAffine(entries: [
            -s, 0, 0, cx + s * half,
            0, 0, s, cy - s * half,
            0, -s, 0, cz + s * half,
        ])
    }
}

/// Inclusive-exclusive crop box inside the grid.
struct NeuralCropBox: Equatable {
    var lower: [Int]
    var upper: [Int]
    var extent: [Int] { (0..<3).map { upper[$0] - lower[$0] } }
    var isEmpty: Bool { extent.contains { $0 <= 0 } }
}

/// A borrowed scalar field for trilinear sampling: `base` points at
/// `width × height × depth` floats in storage order (x fastest). Only valid inside
/// the `withUnsafe…Pointer` scope that produced `base`.
struct NeuralSampleField {
    let base: UnsafePointer<Float>
    let width: Int
    let height: Int
    let depth: Int
}

enum NeuralConform {
    /// Trilinear sample of the source at fractional voxel coordinates; `outside`
    /// beyond the volume (half-voxel tolerance at the borders, clamped).
    @inline(__always)
    static func trilinear(_ field: NeuralSampleField, _ x: Double, _ y: Double, _ z: Double, outside: Float) -> Float {
        let src = field.base
        let w = field.width
        let h = field.height
        let d = field.depth
        if x < -0.5 || y < -0.5 || z < -0.5 || x > Double(w) - 0.5 || y > Double(h) - 0.5 || z > Double(d) - 0.5 {
            return outside
        }
        let cx = min(max(x, 0), Double(w - 1))
        let cy = min(max(y, 0), Double(h - 1))
        let cz = min(max(z, 0), Double(d - 1))
        let x0 = min(Int(cx), max(0, w - 2))
        let y0 = min(Int(cy), max(0, h - 2))
        let z0 = min(Int(cz), max(0, d - 2))
        let x1 = min(x0 + 1, w - 1)
        let y1 = min(y0 + 1, h - 1)
        let z1 = min(z0 + 1, d - 1)
        let fx = Float(cx - Double(x0))
        let fy = Float(cy - Double(y0))
        let fz = Float(cz - Double(z0))
        let plane = w * h
        @inline(__always) func at(_ xi: Int, _ yi: Int, _ zi: Int) -> Float { src[zi * plane + yi * w + xi] }
        let c00 = at(x0, y0, z0) + (at(x1, y0, z0) - at(x0, y0, z0)) * fx
        let c10 = at(x0, y1, z0) + (at(x1, y1, z0) - at(x0, y1, z0)) * fx
        let c01 = at(x0, y0, z1) + (at(x1, y0, z1) - at(x0, y0, z1)) * fx
        let c11 = at(x0, y1, z1) + (at(x1, y1, z1) - at(x0, y1, z1)) * fx
        let c0 = c00 + (c10 - c00) * fy
        let c1 = c01 + (c11 - c01) * fy
        return c0 + (c1 - c0) * fz
    }

    /// Resamples `source` onto `grid` (trilinear, box-supersampled when the grid is
    /// coarser than the source) and returns a single-channel tensor in (i, j, k) order.
    /// Voxels outside the source field of view get the source minimum.
    static func resample(_ source: NeuralInputVolume, onto grid: NeuralGrid, maxThreads: Int, cancel: NeuralCancellationToken?) throws -> NeuralTensor {
        guard let worldToSource = source.voxelToWorld.inverted() else {
            throw NeuralModelError.invalidInput("voxel-to-world transform is singular")
        }
        let gridToSource = worldToSource.concatenating(grid.gridToWorld)
        let n = grid.size
        let minSpacing = (0..<3).map { axis -> Double in
            let c = source.voxelToWorld.column(axis)
            return (c.0 * c.0 + c.1 * c.1 + c.2 * c.2).squareRoot()
        }.min() ?? 1
        let supersample = max(1, min(3, Int((grid.spacing / max(minSpacing, 1e-6)).rounded())))
        let offsets: [Double] = (0..<supersample).map { (Double($0) + 0.5) / Double(supersample) - 0.5 }
        let outside = source.voxels.min() ?? 0
        let weight = 1 / Float(supersample * supersample * supersample)
        var out = NeuralTensor(depth: n, height: n, width: n, channels: 1)
        let m = gridToSource.entries
        try source.voxels.withUnsafeBufferPointer { srcBuffer in
            try out.data.withUnsafeMutableBufferPointer { outBuffer in
                let field = NeuralSampleField(
                    base: srcBuffer.baseAddress!, width: source.width, height: source.height, depth: source.depth
                )
                let dst = outBuffer.baseAddress!
                // Resamples grid rows `(i, j)` in `range`; one chunk of the parallel loop.
                func resampleRows(_ range: Range<Int>, _: Int) {
                    for row in range {
                        let i = row / n
                        let j = row % n
                        for k in 0..<n {
                            var acc: Float = 0
                            for oi in offsets {
                                for oj in offsets {
                                    for ok in offsets {
                                        let gi = Double(i) + oi
                                        let gj = Double(j) + oj
                                        let gk = Double(k) + ok
                                        let x = m[0] * gi + m[1] * gj + m[2] * gk + m[3]
                                        let y = m[4] * gi + m[5] * gj + m[6] * gk + m[7]
                                        let z = m[8] * gi + m[9] * gj + m[10] * gk + m[11]
                                        acc += trilinear(field, x, y, z, outside: outside)
                                    }
                                }
                            }
                            dst[row * n + k] = acc * weight
                        }
                    }
                }
                try NeuralParallel.forEachChunk(count: n * n, chunk: 16, maxThreads: maxThreads, cancel: cancel, resampleRows)
            }
        }
        return out
    }

    /// Value at quantile `q` (0…1) using a strided sample of at most ~2M values.
    static func quantiles(_ data: [Float], _ qs: [Float]) -> [Float] {
        guard !data.isEmpty else { return qs.map { _ in 0 } }
        let stride = max(1, data.count / 2_000_000)
        var sample: [Float] = []
        sample.reserveCapacity(data.count / stride + 1)
        var i = 0
        while i < data.count { sample.append(data[i]); i += stride }
        sample.sort()
        return qs.map { q in
            let pos = Float(sample.count - 1) * min(max(q, 0), 1)
            let lo = Int(pos.rounded(.down))
            let hi = min(sample.count - 1, lo + 1)
            let f = pos - Float(lo)
            return sample[lo] + (sample[hi] - sample[lo]) * f
        }
    }

    /// Emulates niimath/niivue `conform`'s uint8 output (robust 0…99.9 % range,
    /// quantised to 256 levels), then applies the model's own normalisation.
    static func normalise(_ tensor: inout NeuralTensor, mode: NeuralNormalization) {
        guard let lo = tensor.data.min() else { return }
        var hi = quantiles(tensor.data, [0.999])[0]
        // Also falls back when either bound is NaN (the original `!(hi > lo)` semantics).
        if hi.isNaN || lo.isNaN || hi <= lo { hi = tensor.data.max() ?? lo }
        let range = hi - lo
        if range > 0 {
            let inv = 255 / range
            for i in tensor.data.indices {
                tensor.data[i] = min(255, max(0, ((tensor.data[i] - lo) * inv).rounded(.down)))
            }
        } else {
            for i in tensor.data.indices { tensor.data[i] = 0 }
        }
        switch mode {
        case .minMax:
            let mn = tensor.data.min() ?? 0
            let mx = tensor.data.max() ?? 0
            let span = mx - mn
            for i in tensor.data.indices { tensor.data[i] = span > 0 ? (tensor.data[i] - mn) / span : 0 }
        case .quantile(let lower, let upper):
            let q = quantiles(tensor.data, [lower, upper])
            let span = q[1] - q[0] + 1e-3
            for i in tensor.data.indices { tensor.data[i] = min(1, max(0, (tensor.data[i] - q[0]) / span)) }
        }
    }

    /// Bounding box of voxels above `threshold · max` (or `> 0` when threshold is 0),
    /// padded by `padding` voxels and clamped to the grid — brainchop's `cropAndGetCorner`.
    static func cropBox(_ tensor: NeuralTensor, threshold: Float, padding: Int) -> NeuralCropBox {
        let n = [tensor.depth, tensor.height, tensor.width]
        let maxValue = tensor.data.max() ?? 0
        let cut = threshold > 0 ? maxValue * threshold : 0
        var lower = n
        var upper = [-1, -1, -1]
        var idx = 0
        for d in 0..<n[0] {
            for h in 0..<n[1] {
                for w in 0..<n[2] {
                    if tensor.data[idx] > cut {
                        lower[0] = min(lower[0], d); upper[0] = max(upper[0], d)
                        lower[1] = min(lower[1], h); upper[1] = max(upper[1], h)
                        lower[2] = min(lower[2], w); upper[2] = max(upper[2], w)
                    }
                    idx += 1
                }
            }
        }
        if upper[0] < 0 { return NeuralCropBox(lower: [0, 0, 0], upper: [0, 0, 0]) }
        return NeuralCropBox(
            lower: (0..<3).map { max(0, lower[$0] - padding) },
            upper: (0..<3).map { min(n[$0], upper[$0] + 1 + padding) }
        )
    }

    static func crop(_ tensor: NeuralTensor, to box: NeuralCropBox) -> NeuralTensor {
        let e = box.extent
        var out = NeuralTensor(depth: e[0], height: e[1], width: e[2], channels: tensor.channels)
        let c = tensor.channels
        for d in 0..<e[0] {
            for h in 0..<e[1] {
                let src = tensor.index(d + box.lower[0], h + box.lower[1], box.lower[2])
                let dst = out.index(d, h, 0)
                for i in 0..<(e[2] * c) { out.data[dst + i] = tensor.data[src + i] }
            }
        }
        return out
    }

    /// Keeps only the largest 6-connected component of `mask` (true = foreground).
    static func largestComponent(_ mask: [Bool], dims: [Int]) -> [Bool] {
        let (nd, nh, nw) = (dims[0], dims[1], dims[2])
        var componentID = [Int32](repeating: 0, count: mask.count)
        var bestID: Int32 = 0
        var bestSize = 0
        var current: Int32 = 0
        var stack: [Int] = []
        for start in mask.indices where mask[start] && componentID[start] == 0 {
            current += 1
            componentID[start] = current
            stack.append(start)
            var size = 0
            while let v = stack.popLast() {
                size += 1
                let w = v % nw
                let h = (v / nw) % nh
                let d = v / (nw * nh)
                @inline(__always) func visit(_ u: Int) {
                    if mask[u] && componentID[u] == 0 { componentID[u] = current; stack.append(u) }
                }
                if w > 0 { visit(v - 1) }
                if w < nw - 1 { visit(v + 1) }
                if h > 0 { visit(v - nw) }
                if h < nh - 1 { visit(v + nw) }
                if d > 0 { visit(v - nw * nh) }
                if d < nd - 1 { visit(v + nw * nh) }
            }
            if size > bestSize { bestSize = size; bestID = current }
        }
        return componentID.map { $0 == bestID && bestID != 0 }
    }
}
