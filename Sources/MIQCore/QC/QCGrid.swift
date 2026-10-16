import Foundation

/// A coarse, point-sampled copy of one 3D volume, the working grid for every QC stage.
///
/// Quality-control heuristics never need full resolution: a head mask, tissue statistics and
/// the face-region check are all stable on a grid of at most ~64–96 cells per axis. Each grid
/// cell takes the *single* scaled voxel at its centre (nearest-neighbour point sampling, not a
/// block average) so the noise statistics the metrics depend on (background std, SNR) are those
/// of real voxels rather than of an averaged, artificially smooth image.
///
/// Grid axes are the storage axes (x, y, z), so `MIQHeader.orientationFrame` applies directly.
struct QCGrid: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    /// Source voxels per grid cell along x / y / z (the downsample factor).
    let stepX: Int
    let stepY: Int
    let stepZ: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceDepth: Int
    /// Sanitised source voxel spacing in mm (see `sanitizedSpacing`).
    let spacingX: Float
    let spacingY: Float
    let spacingZ: Float
    /// Scaled intensities, x fastest. Non-finite voxels are stored as 0 and counted below.
    var values: [Float]
    let nonFiniteCount: Int

    var count: Int { width * height * depth }

    @inline(__always)
    func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (z * height + y) * width + x
    }

    /// Storage coordinate of the voxel sampled for grid cell `i` along an axis.
    @inline(__always)
    static func sourceCoordinate(cell i: Int, step: Int, sourceDim: Int) -> Int {
        min(sourceDim - 1, i * step + step / 2)
    }

    /// Physical extent (mm) a grid cell covers along an axis; edge cells may be partial.
    @inline(__always)
    static func cellExtent(cell i: Int, step: Int, sourceDim: Int, spacing: Float) -> Double {
        Double(max(0, min(step, sourceDim - i * step))) * Double(spacing)
    }

    /// Smallest integer step that keeps `dim / step` within `maxDimension`.
    static func step(for dim: Int, maxDimension: Int) -> Int {
        guard dim > 0, maxDimension > 0 else { return 1 }
        return max(1, (dim + maxDimension - 1) / maxDimension)
    }

    /// Samples volume `volumeIndex` of `volume`. Returns nil for RGB data or empty volumes.
    /// Throws `CancellationError` when the enclosing task is cancelled (checked once per z-plane).
    static func sample(volume: MIQVolume, volumeIndex: Int, maxDimension: Int) throws -> QCGrid? {
        let header = volume.image.header
        if header.datatype == .rgb24 || header.datatype == .rgba32 { return nil }
        let w = volume.width
        let h = volume.height
        let d = volume.depth
        guard w > 0, h > 0, d > 0 else { return nil }
        let t = min(max(0, volumeIndex), volume.volumes - 1)

        let sx = step(for: w, maxDimension: maxDimension)
        let sy = step(for: h, maxDimension: maxDimension)
        let sz = step(for: d, maxDimension: maxDimension)
        let gw = (w + sx - 1) / sx
        let gh = (h + sy - 1) / sy
        let gd = (d + sz - 1) / sz

        let xs = (0..<gw).map { sourceCoordinate(cell: $0, step: sx, sourceDim: w) }
        let ys = (0..<gh).map { sourceCoordinate(cell: $0, step: sy, sourceDim: h) }

        // Decode straight from the payload (same conversion and scaling as `MIQVolume.voxel`,
        // without its per-call header lookups); out-of-payload voxels read as 0, like `voxel`.
        let image = volume.image
        let bpv = header.datatype.bytesPerVoxel
        let payloadCount = image.payloadCount
        let base = image.payloadOffset
        let slope = header.sclSlope
        let intercept = header.sclInter
        let read = scalarReader(datatype: header.datatype, littleEndian: header.littleEndian)

        var values = [Float](repeating: 0, count: gw * gh * gd)
        var nonFinite = 0
        try image.storage.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try values.withUnsafeMutableBufferPointer { out in
                var write = 0
                for gz in 0..<gd {
                    try Task.checkCancellation()
                    let z = sourceCoordinate(cell: gz, step: sz, sourceDim: d)
                    for y in ys {
                        for x in xs {
                            let byteOffset = image.voxelElementIndex(x: x, y: y, z: z, t: t) * bpv
                            if byteOffset >= 0 && byteOffset + bpv <= payloadCount {
                                var v = read(raw, base + byteOffset)
                                if slope != 0 { v = v * slope + intercept }
                                if v.isFinite {
                                    out[write] = v
                                } else {
                                    nonFinite += 1
                                }
                            }
                            write += 1
                        }
                    }
                }
            }
        }

        return QCGrid(
            width: gw, height: gh, depth: gd,
            stepX: sx, stepY: sy, stepZ: sz,
            sourceWidth: w, sourceHeight: h, sourceDepth: d,
            spacingX: sanitizedSpacing(header.pixdim[safe: 1] ?? 1),
            spacingY: sanitizedSpacing(header.pixdim[safe: 2] ?? 1),
            spacingZ: sanitizedSpacing(header.pixdim[safe: 3] ?? 1),
            values: values,
            nonFiniteCount: nonFinite
        )
    }

    /// Scalar decoder for one datatype; mirrors `MIQVolume`'s private reader bit for bit
    /// (64-bit types go through Double).
    static func scalarReader(datatype: MIQDatatype, littleEndian le: Bool) -> (UnsafeRawBufferPointer, Int) -> Float {
        switch datatype {
        case .uint8:
            return { Float($0.loadUnaligned(fromByteOffset: $1, as: UInt8.self)) }
        case .int8:
            return { Float(Int8(bitPattern: $0.loadUnaligned(fromByteOffset: $1, as: UInt8.self))) }
        case .int16:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt16.self); return Float(Int16(bitPattern: le ? u : u.byteSwapped)) }
        case .uint16:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt16.self); return Float(le ? u : u.byteSwapped) }
        case .int32:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(Int32(bitPattern: le ? u : u.byteSwapped)) }
        case .uint32:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(le ? u : u.byteSwapped) }
        case .float32:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(bitPattern: le ? u : u.byteSwapped) }
        case .float64:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt64.self); return Float(Double(bitPattern: le ? u : u.byteSwapped)) }
        case .int64:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt64.self); return Float(Double(Int64(bitPattern: le ? u : u.byteSwapped))) }
        case .uint64:
            return { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt64.self); return Float(Double(le ? u : u.byteSwapped)) }
        case .rgb24, .rgba32:
            return { _, _ in 0 }
        }
    }
}

// MARK: - Small statistics helpers shared by the QC stages

enum QCStats {
    /// Minimum and maximum, or nil for an empty array.
    static func range(_ values: [Float]) -> (min: Float, max: Float)? {
        guard var lo = values.first else { return nil }
        var hi = lo
        for v in values {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return (lo, hi)
    }

    /// Approximate percentile via a 4096-bin histogram over [lo, hi]; avoids sorting the whole
    /// grid. Resolution is (hi − lo) / 4096, ample for picking a threshold range.
    static func approximatePercentile(_ values: [Float], _ p: Double, low lo: Float, high hi: Float) -> Float {
        guard hi > lo, !values.isEmpty else { return lo }
        let bins = 4096
        var hist = [Int](repeating: 0, count: bins)
        let scale = Float(bins) / (hi - lo)
        for v in values { hist[Swift.min(bins - 1, Swift.max(0, Int((v - lo) * scale)))] += 1 }
        let target = Swift.max(1, Int((Swift.min(Swift.max(p, 0), 100) / 100 * Double(values.count)).rounded(.up)))
        var cumulative = 0
        for b in 0..<bins {
            cumulative += hist[b]
            if cumulative >= target { return Swift.min(hi, lo + Float(b + 1) / scale) }
        }
        return hi
    }

    /// Linear-interpolated percentile (`p` in 0...100) of an ascending-sorted array.
    static func percentile(sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let rank = min(max(p, 0), 100) / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = Float(rank - Double(lo))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    /// Mean and sample standard deviation (Bessel-corrected, as MRIQC's `n/(n-1)` factor).
    static func meanStd<S: Sequence>(_ values: S) -> (mean: Double, std: Double, count: Int) where S.Element == Float {
        var n = 0
        var mean = 0.0
        var m2 = 0.0
        for v in values {
            n += 1
            let x = Double(v)
            let delta = x - mean
            mean += delta / Double(n)
            m2 += delta * (x - mean)
        }
        guard n > 0 else { return (0, 0, 0) }
        let variance = n > 1 ? m2 / Double(n - 1) : 0
        return (mean, variance.squareRoot(), n)
    }

    /// Otsu's between-class-variance threshold over a 256-bin histogram of `values`
    /// restricted to `[low, high]` (values outside are clamped into the end bins).
    /// Returns nil when the range is degenerate.
    static func otsuThreshold<S: Sequence>(_ values: S, low: Float, high: Float, bins: Int = 256) -> Float? where S.Element == Float {
        guard high > low, high.isFinite, low.isFinite else { return nil }
        var hist = [Double](repeating: 0, count: bins)
        let scale = Float(bins) / (high - low)
        var total = 0.0
        for v in values {
            let b = min(bins - 1, max(0, Int((v - low) * scale)))
            hist[b] += 1
            total += 1
        }
        guard total > 0 else { return nil }
        var sumAll = 0.0
        for i in 0..<bins { sumAll += Double(i) * hist[i] }
        var weightBg = 0.0
        var sumBg = 0.0
        var best = -1.0
        var bestIndex = 0
        for i in 0..<(bins - 1) {
            weightBg += hist[i]
            guard weightBg > 0 else { continue }
            let weightFg = total - weightBg
            guard weightFg > 0 else { break }
            sumBg += Double(i) * hist[i]
            let meanBg = sumBg / weightBg
            let meanFg = (sumAll - sumBg) / weightFg
            let between = weightBg * weightFg * (meanBg - meanFg) * (meanBg - meanFg)
            if between > best {
                best = between
                bestIndex = i
            }
        }
        // Threshold sits at the upper edge of the last background bin.
        return low + Float(bestIndex + 1) / scale
    }
}
