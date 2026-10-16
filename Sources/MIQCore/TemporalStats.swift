import Foundation

/// Voxelwise temporal statistics of a 4D series, on the series' own grid.
public struct TemporalStatMaps: Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    /// Canonical x-fastest buffers, `width * height * depth` long.
    public let mean: [Float]
    public let standardDeviation: [Float]
    /// mean / std; 0 where std is ≈ 0 relative to the mean (constant voxels,
    /// background) so flat regions don't read as infinitely stable.
    public let tsnr: [Float]
    /// The volume indices the statistics were computed over.
    public let sampledVolumes: [Int]
}

/// One-glance quality summary of a 4D series.
public struct TemporalSummary: Sendable {
    public let volumeCount: Int
    public let sampledVolumeCount: Int
    /// Median tSNR inside the foreground mask; `nil` when the mask is empty.
    public let medianTSNR: Float?
    public let foregroundVoxelCount: Int
    /// Normalised framewise difference trace (see `TemporalStats.framewiseDifference`),
    /// `trace[i]` between volumes `i` and `i + 1`.
    public let framewiseDifference: [Float]
    /// Transitions whose difference exceeds median + 5·MAD of the trace, as the
    /// index of the *later* volume of the pair.
    public let highDifferenceTransitions: [Int]
    /// Volumes flagged as isolated spikes: both the transition into and out of
    /// them are high (at either end of the series: its one transition is high
    /// and the neighbour's other transition is not).
    public let spikeFrames: [Int]

    public var spikeCount: Int { spikeFrames.count }
}

public enum TemporalStats {
    /// Default cap on volumes read for the voxelwise maps.
    public static let defaultMaxVolumes = 64
    /// Default cap on voxels sampled per volume for the framewise trace.
    public static let defaultTraceVoxels = 32 * 1024

    /// Spatial size (in voxels) of every volume in a series.
    public struct Grid: Sendable, Hashable {
        public var width: Int
        public var height: Int
        public var depth: Int

        public init(width: Int, height: Int, depth: Int) {
            self.width = width
            self.height = height
            self.depth = depth
        }
    }

    /// `cap` evenly spaced indices covering `0..<volumeCount` (always including
    /// the first and last when `cap >= 2`); all indices when `volumeCount <= cap`.
    public static func sampleIndices(volumeCount: Int, cap: Int = defaultMaxVolumes) -> [Int] {
        guard volumeCount > 0, cap > 0 else { return [] }
        if volumeCount <= cap { return Array(0..<volumeCount) }
        if cap == 1 { return [0] }
        var out: [Int] = []
        out.reserveCapacity(cap)
        for i in 0..<cap {
            let idx = Int((Double(i) * Double(volumeCount - 1) / Double(cap - 1)).rounded())
            if out.last != idx { out.append(idx) }
        }
        return out
    }

    /// Temporal mean, standard deviation (population, n) and tSNR over up to
    /// `maxVolumes` evenly spaced volumes. Uses Welford's update in `Double` so a
    /// large mean doesn't cancel a small variance. `nil` for fewer than 2 volumes,
    /// a payload missing volumes (re-parse with `fullyDecompress: true`), or
    /// cancellation (checked per volume and per z-plane).
    public static func maps(
        for volume: MIQVolume,
        maxVolumes: Int = defaultMaxVolumes,
        isCancelled: () -> Bool = { false }
    ) -> TemporalStatMaps? {
        guard volume.volumes >= 2, volume.containsAllVolumes else { return nil }
        let indices = sampleIndices(volumeCount: volume.volumes, cap: max(2, maxVolumes))
        let count = volume.width * volume.height * volume.depth
        guard count > 0 else { return nil }
        var mean = [Double](repeating: 0, count: count)
        var m2 = [Double](repeating: 0, count: count)
        var n = 0.0
        for t in indices {
            if isCancelled() || Task.isCancelled { return nil }
            guard let values = volume.decodedValues(volumeIndex: t, isCancelled: isCancelled) else { return nil }
            n += 1
            for i in 0..<count {
                let x = Double(values[i].isFinite ? values[i] : 0)
                let delta = x - mean[i]
                mean[i] += delta / n
                m2[i] += delta * (x - mean[i])
            }
        }
        var meanF = [Float](repeating: 0, count: count)
        var stdF = [Float](repeating: 0, count: count)
        var tsnrF = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = (max(0, m2[i]) / n).squareRoot()
            meanF[i] = Float(mean[i])
            stdF[i] = Float(s)
            // Guard std ≈ 0: absolute floor plus a relative one (float32 data
            // carries ~1e-7 relative noise even when nominally constant).
            if s > 1e-6 * max(1, abs(mean[i])) {
                tsnrF[i] = Float(mean[i] / s)
            }
        }
        return TemporalStatMaps(
            width: volume.width, height: volume.height, depth: volume.depth,
            mean: meanF, standardDeviation: stdF, tsnr: tsnrF, sampledVolumes: indices
        )
    }

    /// Framewise mean absolute difference between consecutive volumes (a DVARS-like
    /// gross-motion / spike trace), over a regular spatial subsample of at most
    /// `maxVoxels` voxels, normalised by the mean absolute intensity of those
    /// voxels in volume 0 and expressed in percent. `trace.count == volumes - 1`.
    /// `nil` for < 2 volumes, missing volumes, or cancellation.
    public static func framewiseDifference(
        for volume: MIQVolume,
        maxVoxels: Int = defaultTraceVoxels,
        isCancelled: () -> Bool = { false }
    ) -> [Float]? {
        guard volume.volumes >= 2, volume.containsAllVolumes else { return nil }
        let w = volume.width
        let h = volume.height
        let d = volume.depth
        let total = w * h * d
        guard total > 0 else { return nil }
        // Isotropic stride s with ceil(w/s)·ceil(h/s)·ceil(d/s) ≤ maxVoxels.
        let coords = traceCoordinates(width: w, height: h, depth: d, maxVoxels: maxVoxels)
        func read(_ t: Int) -> [Float] {
            coords.map { c in
                let v = volume.voxel(x: c.0, y: c.1, z: c.2, t: t)
                return v.isFinite ? v : 0
            }
        }
        var previous = read(0)
        var scale = 0.0
        for v in previous { scale += Double(abs(v)) }
        scale /= Double(max(1, previous.count))
        let norm = scale > 0 ? 100 / scale : 1
        var trace: [Float] = []
        trace.reserveCapacity(volume.volumes - 1)
        for t in 1..<volume.volumes {
            if isCancelled() || Task.isCancelled { return nil }
            let current = read(t)
            var sum = 0.0
            for i in 0..<current.count { sum += Double(abs(current[i] - previous[i])) }
            trace.append(Float(sum / Double(max(1, current.count)) * norm))
            previous = current
        }
        return trace
    }

    /// Median of finite values; `nil` when empty.
    static func median(_ values: [Float]) -> Float? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Foreground mask: mean intensity > `fraction` × robust max (99th percentile
    /// of the finite mean map).
    public static func foregroundMask(mean: [Float], fraction: Float = 0.1) -> [Bool] {
        let finite = mean.filter(\.isFinite).sorted()
        guard let top = finite.last else { return Array(repeating: false, count: mean.count) }
        let robustMax = finite[min(finite.count - 1, Int(Double(finite.count - 1) * 0.99))]
        let threshold = (robustMax > 0 ? robustMax : top) * fraction
        return mean.map { $0.isFinite && $0 > threshold }
    }

    /// Classifies a framewise trace: high transitions (> median + 5·MAD, with
    /// MAD floored at 1% of the median so a noise-free trace isn't all "high")
    /// and isolated spike volumes.
    public static func spikes(in trace: [Float], madMultiplier: Float = 5) -> (high: [Int], spikes: [Int]) {
        guard let med = median(trace) else { return ([], []) }
        let mad = median(trace.map { abs($0 - med) }) ?? 0
        let threshold = med + madMultiplier * max(mad, 0.01 * abs(med), 1e-6)
        let isHigh = trace.map { $0.isFinite && $0 > threshold }
        let high = isHigh.enumerated().filter(\.element).map { $0.offset + 1 }
        var spikeFrames: [Int] = []
        let frames = trace.count + 1
        func isHighAt(_ i: Int) -> Bool { i >= 0 && i < isHigh.count && isHigh[i] }
        for f in 0..<frames {
            if f == 0 || f == frames - 1 {
                // An end volume has one transition; it's the outlier only when the
                // neighbouring volume's other transition is normal (otherwise the
                // neighbour is the spike and this transition just leads into it).
                let edge = f == 0 ? 0 : f - 1
                let neighbourOther = f == 0 ? 1 : f - 2
                if isHighAt(edge) && !isHighAt(neighbourOther) && frames > 2 { spikeFrames.append(f) }
            } else if isHighAt(f - 1) && isHighAt(f) {
                spikeFrames.append(f)
            }
        }
        return (high, spikeFrames)
    }

    /// Full summary: maps over ≤ `maxVolumes` sampled volumes, median tSNR within
    /// the foreground mask, and the framewise trace's spikes.
    public static func summary(
        for volume: MIQVolume,
        maxVolumes: Int = defaultMaxVolumes,
        maxTraceVoxels: Int = defaultTraceVoxels,
        isCancelled: () -> Bool = { false }
    ) -> TemporalSummary? {
        guard let maps = maps(for: volume, maxVolumes: maxVolumes, isCancelled: isCancelled),
              let trace = framewiseDifference(for: volume, maxVoxels: maxTraceVoxels, isCancelled: isCancelled)
        else { return nil }
        return summary(maps: maps, trace: trace, volumeCount: volume.volumes)
    }

    /// `summary(for:)` for a series that is not in memory, in **one forward
    /// pass**: `volumeAt(t)` supplies timepoint `t` as a *single-volume*
    /// `MIQVolume` addressed at `volumeIndex: 0` (`NiftiVolumeReader.volume(at:)`),
    /// and is called exactly once per `t`, in ascending order — so a gzip
    /// stream is inflated once and never rewinds, and only one volume (plus the
    /// running maps) is resident at a time. The sampled volumes feed the maps,
    /// every volume feeds the framewise trace (its voxel subsample only). The
    /// result is identical to `summary(for:)` on the same data.
    ///
    /// Every volume must be `grid`-sized; `nil` for fewer than 2 volumes, an
    /// empty grid, a volume of another size, or cancellation (checked per
    /// volume, via `isCancelled` and the task). Rethrows `volumeAt`'s errors.
    public static func summary(
        volumeCount: Int,
        grid: Grid,
        maxVolumes: Int = defaultMaxVolumes,
        maxTraceVoxels: Int = defaultTraceVoxels,
        isCancelled: () -> Bool = { false },
        volumeAt: (Int) throws -> MIQVolume
    ) throws -> TemporalSummary? {
        let width = grid.width
        let height = grid.height
        let depth = grid.depth
        guard volumeCount >= 2 else { return nil }
        let count = width * height * depth
        guard count > 0 else { return nil }
        let indices = sampleIndices(volumeCount: volumeCount, cap: max(2, maxVolumes))
        let sampled = Set(indices)
        let coords = traceCoordinates(width: width, height: height, depth: depth, maxVoxels: maxTraceVoxels)

        var mean = [Double](repeating: 0, count: count)
        var m2 = [Double](repeating: 0, count: count)
        var n = 0.0
        var previous: [Float] = []
        var norm = 1.0
        var trace: [Float] = []
        trace.reserveCapacity(volumeCount - 1)

        for t in 0..<volumeCount {
            if isCancelled() || Task.isCancelled { return nil }
            let volume = try volumeAt(t)
            guard volume.width == width, volume.height == height, volume.depth == depth else { return nil }
            if sampled.contains(t) {
                guard let values = volume.decodedValues(volumeIndex: 0, isCancelled: isCancelled) else { return nil }
                n += 1
                for i in 0..<count {
                    let x = Double(values[i].isFinite ? values[i] : 0)
                    let delta = x - mean[i]
                    mean[i] += delta / n
                    m2[i] += delta * (x - mean[i])
                }
            }
            let current = coords.map { c -> Float in
                let v = volume.voxel(x: c.0, y: c.1, z: c.2, t: 0)
                return v.isFinite ? v : 0
            }
            if t == 0 {
                var scale = 0.0
                for v in current { scale += Double(abs(v)) }
                scale /= Double(max(1, current.count))
                norm = scale > 0 ? 100 / scale : 1
            } else {
                var sum = 0.0
                for i in 0..<current.count { sum += Double(abs(current[i] - previous[i])) }
                trace.append(Float(sum / Double(max(1, current.count)) * norm))
            }
            previous = current
        }

        var meanF = [Float](repeating: 0, count: count)
        var stdF = [Float](repeating: 0, count: count)
        var tsnrF = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = (max(0, m2[i]) / n).squareRoot()
            meanF[i] = Float(mean[i])
            stdF[i] = Float(s)
            if s > 1e-6 * max(1, abs(mean[i])) {
                tsnrF[i] = Float(mean[i] / s)
            }
        }
        let maps = TemporalStatMaps(
            width: width, height: height, depth: depth,
            mean: meanF, standardDeviation: stdF, tsnr: tsnrF, sampledVolumes: indices
        )
        return summary(maps: maps, trace: trace, volumeCount: volumeCount)
    }

    /// The regular voxel subsample `framewiseDifference` reads (isotropic
    /// stride, at most `maxVoxels` points), x fastest.
    static func traceCoordinates(width w: Int, height h: Int, depth d: Int, maxVoxels: Int) -> [(Int, Int, Int)] {
        let total = w * h * d
        guard total > 0 else { return [] }
        var stride = max(1, Int(pow(Double(total) / Double(max(1, maxVoxels)), 1.0 / 3.0).rounded(.down)))
        while ((w + stride - 1) / stride) * ((h + stride - 1) / stride) * ((d + stride - 1) / stride) > max(1, maxVoxels) {
            stride += 1
        }
        var coords: [(Int, Int, Int)] = []
        for z in Swift.stride(from: 0, to: d, by: stride) {
            for y in Swift.stride(from: 0, to: h, by: stride) {
                for x in Swift.stride(from: 0, to: w, by: stride) { coords.append((x, y, z)) }
            }
        }
        return coords
    }

    /// Summary from already-computed maps and trace.
    public static func summary(maps: TemporalStatMaps, trace: [Float], volumeCount: Int) -> TemporalSummary {
        let mask = foregroundMask(mean: maps.mean)
        var inside: [Float] = []
        for i in 0..<mask.count where mask[i] { inside.append(maps.tsnr[i]) }
        let classified = spikes(in: trace)
        return TemporalSummary(
            volumeCount: volumeCount,
            sampledVolumeCount: maps.sampledVolumes.count,
            medianTSNR: median(inside),
            foregroundVoxelCount: inside.count,
            framewiseDifference: trace,
            highDifferenceTransitions: classified.high,
            spikeFrames: classified.spikes
        )
    }
}

extension TemporalStatMaps {
    public enum Kind: Sendable { case mean, standardDeviation, tsnr }

    /// The chosen map as a volume on `reference`'s grid (the 4D series it was
    /// computed from), ready to slice/window like any image.
    public func volume(_ kind: Kind, onGridOf reference: MIQVolume) -> MIQVolume? {
        guard reference.width == width, reference.height == height, reference.depth == depth else { return nil }
        let values: [Float]
        switch kind {
        case .mean: values = mean
        case .standardDeviation: values = standardDeviation
        case .tsnr: values = tsnr
        }
        return MIQVolume.derivedVolume(values: values, onGridOf: reference)
    }
}
