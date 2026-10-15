import Foundation

/// A coarse foreground ("head") mask computed without any model.
///
/// Pipeline, all on the downsampled `QCGrid`:
/// 1. Otsu threshold on the scaled intensities (range clipped to the 99.5th percentile so a
///    few hot voxels cannot drag the threshold up).
/// 2. Morphological closing (6-neighbourhood dilate, then erode) to bridge thin gaps
///    such as dark skull or CSF between scalp and brain.
/// 3. Largest 6-connected component, discarding background noise specks and ghosts.
/// 4. 2D hole filling slice-by-slice along each storage axis, so dark interior structures
///    (ventricles, sinuses) are part of the mask.
///
/// This is a data-QC aid, a *head/foreground* mask, not a brain extraction or segmentation.
public struct QCHeadMask: Sendable {
    /// Grid dimensions (cells along storage x / y / z).
    public let width: Int
    public let height: Int
    public let depth: Int
    /// Downsample factor: source voxels per grid cell along x / y / z.
    public let stepX: Int
    public let stepY: Int
    public let stepZ: Int
    /// One byte per grid cell (x fastest): 1 = foreground, 0 = background.
    public let cells: [UInt8]
    /// Number of foreground cells.
    public let foregroundCount: Int
    /// Intensity threshold the mask was seeded with (Otsu), in scaled units.
    public let threshold: Float
    /// Physical volume covered by the foreground, in millilitres. Edge cells that cover fewer
    /// than `step` source voxels are accounted for exactly, so this equals the source-resolution
    /// voxel count × voxel volume of the upsampled mask.
    public let volumeMilliliters: Double

    @inline(__always)
    public func contains(x: Int, y: Int, z: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return false }
        return cells[(z * height + y) * width + x] != 0
    }

    /// Whether the source voxel at storage coordinate (x, y, z) falls in a foreground cell.
    public func containsSourceVoxel(x: Int, y: Int, z: Int) -> Bool {
        guard x >= 0, y >= 0, z >= 0 else { return false }
        return contains(x: x / stepX, y: y / stepY, z: z / stepZ)
    }

    /// Default grid size for mask computation (cells per axis). 64³ keeps a 256³ volume at a
    /// 4× downsample, which is ample for a head outline and well inside the time budget.
    public static let defaultMaxGridDimension = 64

    /// Computes the head mask for volume `volumeIndex` of `volume`. Returns nil for RGB data,
    /// empty volumes or constant images (no threshold exists). Throws `CancellationError`.
    public static func compute(
        volume: MIQVolume,
        volumeIndex: Int = 0,
        maxGridDimension: Int = defaultMaxGridDimension
    ) throws -> QCHeadMask? {
        guard let grid = try QCGrid.sample(volume: volume, volumeIndex: volumeIndex, maxDimension: maxGridDimension) else {
            return nil
        }
        return try compute(grid: grid)
    }

    static func compute(grid: QCGrid, closingRadius: Int = 1) throws -> QCHeadMask? {
        guard let range = QCStats.range(grid.values), range.max > range.min else { return nil }
        let lo = range.min
        let hi = QCStats.approximatePercentile(grid.values, 99.5, low: lo, high: range.max)
        guard hi > lo, let threshold = QCStats.otsuThreshold(grid.values, low: lo, high: hi) else { return nil }

        let dims = MaskDims(w: grid.width, h: grid.height, d: grid.depth)
        var mask = grid.values.map { $0 > threshold ? UInt8(1) : 0 }
        try Task.checkCancellation()

        for _ in 0..<closingRadius { mask = QCMorphology.dilate(mask, dims) }
        for _ in 0..<closingRadius { mask = QCMorphology.erode(mask, dims) }
        try Task.checkCancellation()

        mask = QCMorphology.largestComponent(mask, dims)
        try Task.checkCancellation()

        QCMorphology.fillHoles2D(&mask, dims)

        var count = 0
        var volumeMM3 = 0.0
        let ex = (0..<grid.width).map { QCGrid.cellExtent(cell: $0, step: grid.stepX, sourceDim: grid.sourceWidth, spacing: grid.spacingX) }
        let ey = (0..<grid.height).map { QCGrid.cellExtent(cell: $0, step: grid.stepY, sourceDim: grid.sourceHeight, spacing: grid.spacingY) }
        let ez = (0..<grid.depth).map { QCGrid.cellExtent(cell: $0, step: grid.stepZ, sourceDim: grid.sourceDepth, spacing: grid.spacingZ) }
        var i = 0
        for z in 0..<grid.depth {
            for y in 0..<grid.height {
                let rowArea = ey[y] * ez[z]
                for x in 0..<grid.width {
                    if mask[i] != 0 {
                        count += 1
                        volumeMM3 += ex[x] * rowArea
                    }
                    i += 1
                }
            }
        }
        guard count > 0 else { return nil }

        return QCHeadMask(
            width: grid.width, height: grid.height, depth: grid.depth,
            stepX: grid.stepX, stepY: grid.stepY, stepZ: grid.stepZ,
            cells: mask,
            foregroundCount: count,
            threshold: threshold,
            volumeMilliliters: volumeMM3 / 1000
        )
    }

    /// "Head mask: 1 520 mL". Deliberately labelled as a head/foreground mask, never as brain volume.
    var volumeDisplayText: String {
        "Head mask: \(QCFormat.groupedInteger(volumeMilliliters)) mL"
    }
}

struct MaskDims {
    let w: Int
    let h: Int
    let d: Int
    var count: Int { w * h * d }
}

/// Binary morphology on byte masks, 6-connectivity throughout.
enum QCMorphology {
    /// Out-of-range neighbours count as background.
    static func dilate(_ m: [UInt8], _ s: MaskDims) -> [UInt8] {
        var out = m
        let plane = s.w * s.h
        var i = 0
        for z in 0..<s.d {
            for y in 0..<s.h {
                for x in 0..<s.w {
                    if m[i] == 0 {
                        if (x > 0 && m[i - 1] != 0) || (x < s.w - 1 && m[i + 1] != 0)
                            || (y > 0 && m[i - s.w] != 0) || (y < s.h - 1 && m[i + s.w] != 0)
                            || (z > 0 && m[i - plane] != 0) || (z < s.d - 1 && m[i + plane] != 0) {
                            out[i] = 1
                        }
                    }
                    i += 1
                }
            }
        }
        return out
    }

    /// Out-of-range neighbours count as foreground, so closing never erodes a mask that
    /// touches the field-of-view edge (common for tight head FOVs).
    static func erode(_ m: [UInt8], _ s: MaskDims) -> [UInt8] {
        var out = m
        let plane = s.w * s.h
        var i = 0
        for z in 0..<s.d {
            for y in 0..<s.h {
                for x in 0..<s.w {
                    if m[i] != 0 {
                        if (x > 0 && m[i - 1] == 0) || (x < s.w - 1 && m[i + 1] == 0)
                            || (y > 0 && m[i - s.w] == 0) || (y < s.h - 1 && m[i + s.w] == 0)
                            || (z > 0 && m[i - plane] == 0) || (z < s.d - 1 && m[i + plane] == 0) {
                            out[i] = 0
                        }
                    }
                    i += 1
                }
            }
        }
        return out
    }

    /// Keeps only the largest 6-connected foreground component.
    static func largestComponent(_ m: [UInt8], _ s: MaskDims) -> [UInt8] {
        let n = s.count
        var label = [Int32](repeating: 0, count: n)
        var stack = [Int32]()
        stack.reserveCapacity(1024)
        let plane = s.w * s.h
        var current: Int32 = 0
        var bestLabel: Int32 = 0
        var bestSize = 0
        for seed in 0..<n where m[seed] != 0 && label[seed] == 0 {
            current += 1
            label[seed] = current
            stack.append(Int32(seed))
            var size = 0
            while let top = stack.popLast() {
                let i = Int(top)
                size += 1
                let x = i % s.w
                let y = (i / s.w) % s.h
                let z = i / plane
                @inline(__always) func visit(_ j: Int) {
                    if m[j] != 0 && label[j] == 0 {
                        label[j] = current
                        stack.append(Int32(j))
                    }
                }
                if x > 0 { visit(i - 1) }
                if x < s.w - 1 { visit(i + 1) }
                if y > 0 { visit(i - s.w) }
                if y < s.h - 1 { visit(i + s.w) }
                if z > 0 { visit(i - plane) }
                if z < s.d - 1 { visit(i + plane) }
            }
            if size > bestSize {
                bestSize = size
                bestLabel = current
            }
        }
        guard bestLabel > 0 else { return m }
        return label.map { $0 == bestLabel ? 1 : 0 }
    }

    /// Fills background regions not 4-connected to the slice border, slice by slice along
    /// each of the three storage axes in turn.
    static func fillHoles2D(_ m: inout [UInt8], _ s: MaskDims) {
        let plane = s.w * s.h
        // (sliceCount, sliceStride, uCount, uStride, vCount, vStride)
        let layouts = [
            (s.d, plane, s.w, 1, s.h, s.w),   // axial-in-storage: z slices
            (s.h, s.w, s.w, 1, s.d, plane),   // y slices
            (s.w, 1, s.h, s.w, s.d, plane),   // x slices
        ]
        for (sliceCount, sliceStride, uCount, uStride, vCount, vStride) in layouts {
            var outside = [Bool](repeating: false, count: uCount * vCount)
            var stack = [Int]()
            for k in 0..<sliceCount {
                let base = k * sliceStride
                for i in 0..<outside.count { outside[i] = false }
                @inline(__always) func at(_ u: Int, _ v: Int) -> Int { base + u * uStride + v * vStride }
                func seed(_ u: Int, _ v: Int) {
                    let local = v * uCount + u
                    if !outside[local] && m[at(u, v)] == 0 {
                        outside[local] = true
                        stack.append(local)
                    }
                }
                for u in 0..<uCount { seed(u, 0); seed(u, vCount - 1) }
                for v in 0..<vCount { seed(0, v); seed(uCount - 1, v) }
                while let local = stack.popLast() {
                    let u = local % uCount
                    let v = local / uCount
                    if u > 0 { seed(u - 1, v) }
                    if u < uCount - 1 { seed(u + 1, v) }
                    if v > 0 { seed(u, v - 1) }
                    if v < vCount - 1 { seed(u, v + 1) }
                }
                for v in 0..<vCount {
                    for u in 0..<uCount where !outside[v * uCount + u] {
                        m[at(u, v)] = 1
                    }
                }
            }
        }
    }
}

enum QCFormat {
    /// Rounds and groups thousands with a plain space ("1 520"), locale-independent so the
    /// panel and the tests read the same everywhere.
    static func groupedInteger(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let rounded = Int(value.rounded())
        let digits = String(abs(rounded))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return rounded < 0 ? "-" + out : out
    }

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}
