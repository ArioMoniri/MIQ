import Foundation

/// Coarse traffic-light rating for one QC metric.
///
/// Levels come from conservative, *heuristic* thresholds. Image-quality metrics are strongly
/// modality-, sequence-, scanner- and protocol-dependent, so a level only says whether a value
/// sits inside a broad range commonly seen for structural MRI. It is a data-QC hint, never a
/// statement about the subject.
public enum QCLevel: String, Sendable, Hashable, CaseIterable {
    /// Inside the broad typical range (green).
    case typical
    /// Near the edge of the typical range (amber).
    case borderline
    /// Outside the typical range (red); worth a look at the data.
    case atypical
    /// Not rated: metric not applicable (CT, label map, colour data) or not computable.
    case notAssessed

    public var displayName: String {
        switch self {
        case .typical: return "Typical"
        case .borderline: return "Borderline"
        case .atypical: return "Atypical"
        case .notAssessed: return "Not assessed"
        }
    }
}

/// Identifies a QC metric. Definitions follow MRIQC's image-quality metrics for T1w data,
/// computed here on a coarse grid with a model-free head mask, so absolute values are only
/// loosely comparable to MRIQC's. See https://mriqc.readthedocs.io/en/latest/iqms/t1w.html
public enum QCMetricID: String, Sendable, Hashable, CaseIterable {
    /// Foreground mean / foreground standard deviation inside the head mask.
    case snr
    /// Dietrich SNR: foreground mean / (air std × √(2 / (4 − π))). Rayleigh-corrected.
    case snrDietrich
    /// Contrast-to-noise between the two brightest intensity classes inside the mask
    /// (approximate GM/WM on T1w): |μ₁ − μ₂| / √(σ_air² + σ₁² + σ₂²).
    case cnr
    /// Coefficient of joint variation: (σ₁ + σ₂) / |μ₁ − μ₂|. Lower is better.
    case cjv
    /// Entropy focus criterion over the whole grid, normalised to 0…1. Lower is sharper.
    case efc
    /// Foreground-background energy ratio: median(fg²) / median(air²). Higher is better.
    case fber
    /// Fraction of air voxels above a robust noise ceiling (ghosting / structured noise).
    case backgroundArtifacts

    public var displayName: String {
        switch self {
        case .snr: return "SNR"
        case .snrDietrich: return "SNR (air-based)"
        case .cnr: return "CNR"
        case .cjv: return "CJV"
        case .efc: return "EFC"
        case .fber: return "FBER"
        case .backgroundArtifacts: return "Background signal"
        }
    }
}

public struct QCMetric: Sendable, Hashable {
    public let id: QCMetricID
    /// nil when the metric could not be computed (e.g. zero-filled background, no air region).
    public let value: Double?
    public let level: QCLevel

    public init(id: QCMetricID, value: Double?, level: QCLevel) {
        self.id = id
        self.value = value
        self.level = level
    }

    /// Value formatted for the metadata panel ("12.3", "0.42", "1.8 %", "–").
    public var formattedValue: String {
        guard let value else { return "–" }
        switch id {
        case .backgroundArtifacts: return QCFormat.decimal(value * 100, digits: 1) + " %"
        case .efc, .cjv: return QCFormat.decimal(value, digits: 2)
        case .fber where value >= 1000: return String(format: "%.2g", value)
        default: return QCFormat.decimal(value, digits: 1)
        }
    }
}

/// MRIQC-inspired image-quality metrics for one volume.
public struct QCReport: Sendable {
    /// Metrics in display order. Empty only when `isAssessed` is false and nothing was computed.
    public let metrics: [QCMetric]
    /// false when metrics were skipped (CT, label map, colour data, no usable mask).
    public let isAssessed: Bool
    /// Short neutral explanation when metrics were skipped or partially unavailable.
    public let note: String?

    public init(metrics: [QCMetric], isAssessed: Bool, note: String?) {
        self.metrics = metrics
        self.isAssessed = isAssessed
        self.note = note
    }

    public func metric(_ id: QCMetricID) -> QCMetric? {
        metrics.first { $0.id == id }
    }

    /// The least favourable level across rated metrics (`.notAssessed` when none are rated).
    public var overallLevel: QCLevel {
        let rated = metrics.map(\.level).filter { $0 != .notAssessed }
        if rated.contains(.atypical) { return .atypical }
        if rated.contains(.borderline) { return .borderline }
        return rated.isEmpty ? .notAssessed : .typical
    }

    static func skipped(_ note: String) -> QCReport {
        QCReport(metrics: QCMetricID.allCases.map { QCMetric(id: $0, value: nil, level: .notAssessed) },
                 isAssessed: false, note: note)
    }
}

/// Computes `QCReport` metrics from a grid and its head mask.
enum QCMetricsCalculator {
    /// Conservative, heuristic level thresholds (structural-MRI oriented). Each pair is
    /// (borderline boundary, atypical boundary) in the metric's "worse" direction.
    /// Chosen wide on purpose: they flag gross problems, not subtle protocol differences.
    enum Thresholds {
        static let snr = (borderline: 2.0, atypical: 1.0)              // higher is better
        static let snrDietrich = (borderline: 8.0, atypical: 4.0)      // higher is better
        static let cnr = (borderline: 1.0, atypical: 0.5)              // higher is better
        static let cjv = (borderline: 0.8, atypical: 1.2)              // lower is better
        static let efc = (borderline: 0.7, atypical: 0.85)             // lower is better
        static let fber = (borderline: 50.0, atypical: 10.0)           // higher is better
        static let background = (borderline: 0.02, atypical: 0.08)     // lower is better
    }

    static func levelHigherIsBetter(_ v: Double?, _ t: (borderline: Double, atypical: Double)) -> QCLevel {
        guard let v, v.isFinite else { return .notAssessed }
        if v < t.atypical { return .atypical }
        if v < t.borderline { return .borderline }
        return .typical
    }

    static func levelLowerIsBetter(_ v: Double?, _ t: (borderline: Double, atypical: Double)) -> QCLevel {
        guard let v, v.isFinite else { return .notAssessed }
        if v > t.atypical { return .atypical }
        if v > t.borderline { return .borderline }
        return .typical
    }

    /// Air ring margin (grid cells) between the head mask and the region treated as air, so
    /// partial-volume edge voxels do not inflate background statistics.
    static let airMargin = 2

    static func compute(grid: QCGrid, mask: QCHeadMask) throws -> QCReport {
        let dims = MaskDims(w: grid.width, h: grid.height, d: grid.depth)
        var grown = mask.cells
        for _ in 0..<airMargin { grown = QCMorphology.dilate(grown, dims) }
        try Task.checkCancellation()

        var fg = [Float]()
        fg.reserveCapacity(mask.foregroundCount)
        var air = [Float]()
        air.reserveCapacity(grid.count - mask.foregroundCount)
        for i in 0..<grid.count {
            if mask.cells[i] != 0 {
                fg.append(grid.values[i])
            } else if grown[i] == 0 {
                air.append(grid.values[i])
            }
        }
        guard fg.count >= 8 else { return .skipped("Foreground too small to assess") }
        var notes: [String] = []

        // An air region below ~1% of the grid (tight FOV) gives no usable noise estimate.
        let hasAir = air.count >= max(32, grid.count / 100)
        if !hasAir { notes.append("Little background in field of view") }

        // SNR — MRIQC `snr`: μ_fg / (σ_fg · √(n/(n−1))); `meanStd` already Bessel-corrects.
        let fgStats = QCStats.meanStd(fg)
        let snr: Double? = fgStats.std > 0 ? fgStats.mean / fgStats.std : nil

        // Air statistics.
        let airStats = hasAir ? QCStats.meanStd(air) : (mean: 0.0, std: 0.0, count: 0)
        let fgEnergyScale = max(abs(fgStats.mean), 1e-12)
        let airIsZeroFilled = hasAir && airStats.std <= fgEnergyScale * 1e-6
        if airIsZeroFilled { notes.append("Background is zero-filled") }

        // SNR_D — MRIQC `snrd` (Dietrich 2007): μ_fg / (σ_air · √(2/(4−π))).
        let snrD: Double? = (hasAir && !airIsZeroFilled)
            ? fgStats.mean / (airStats.std * (2.0 / (4.0 - Double.pi)).squareRoot())
            : nil

        // Tissue split: 1D k-means (3 classes) inside the mask. On T1w the two brighter
        // classes approximate GM and WM (the darkest absorbs CSF, skull and background edge).
        try Task.checkCancellation()
        let classes = kMeans3(fg)
        var cnr: Double?
        var cjv: Double?
        if let classes {
            let a = classes[1]
            let b = classes[2]
            let delta = abs(b.mean - a.mean)
            if delta > 0 {
                // MRIQC `cnr`: |μ_WM − μ_GM| / √(σ_air² + σ_WM² + σ_GM²)
                let airVar = (hasAir && !airIsZeroFilled) ? airStats.std * airStats.std : 0
                let denom = (airVar + a.std * a.std + b.std * b.std).squareRoot()
                cnr = denom > 0 ? delta / denom : nil
                // MRIQC `cjv`: (σ_WM + σ_GM) / |μ_WM − μ_GM|
                cjv = (a.std + b.std) / delta
            }
        }

        // EFC — MRIQC `efc`: entropy of the intensity "image energy" distribution, normalised
        // by its maximum (uniform image). Negative intensities are clamped to 0.
        let efc = entropyFocusCriterion(grid.values)

        // FBER — MRIQC `fber`: median(|fg|²) / median(|air|²). A zero median background (common
        // with zero-filled or masked air) falls back to mean energy; zero energy → not computable.
        var fber: Double?
        if hasAir && !airIsZeroFilled {
            let fgE = median(fg.map { $0 * $0 })
            var airE = median(air.map { $0 * $0 })
            if airE <= 0 { airE = air.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(air.count) }
            if airE > 0 { fber = fgE / airE }
        }

        // Background artifacts — inspired by MRIQC's QI1 (fraction of air voxels with
        // artefactual intensity). Ceiling = median + 6 robust σ (1.4826 · MAD), and at least
        // 5% of the way to the foreground median, so pure Rayleigh noise rarely exceeds it
        // while ghosts / wrap-around / spikes do.
        var bgFraction: Double?
        if hasAir {
            let sortedAir = air.sorted()
            let med = QCStats.percentile(sorted: sortedAir, 50)
            let deviations = sortedAir.map { abs($0 - med) }.sorted()
            let mad = QCStats.percentile(sorted: deviations, 50)
            let fgMedian = Float(median(fg))
            let ceiling = max(med + 6 * 1.4826 * mad, med + 0.05 * (fgMedian - med))
            if fgMedian > med {
                let above = air.reduce(0) { $1 > ceiling ? $0 + 1 : $0 }
                bgFraction = Double(above) / Double(air.count)
            }
        }

        let metrics: [QCMetric] = [
            QCMetric(id: .snr, value: snr, level: levelHigherIsBetter(snr, Thresholds.snr)),
            QCMetric(id: .snrDietrich, value: snrD, level: levelHigherIsBetter(snrD, Thresholds.snrDietrich)),
            QCMetric(id: .cnr, value: cnr, level: levelHigherIsBetter(cnr, Thresholds.cnr)),
            QCMetric(id: .cjv, value: cjv, level: levelLowerIsBetter(cjv, Thresholds.cjv)),
            QCMetric(id: .efc, value: efc, level: levelLowerIsBetter(efc, Thresholds.efc)),
            QCMetric(id: .fber, value: fber, level: levelHigherIsBetter(fber, Thresholds.fber)),
            QCMetric(id: .backgroundArtifacts, value: bgFraction, level: levelLowerIsBetter(bgFraction, Thresholds.background)),
        ]
        return QCReport(metrics: metrics, isAssessed: true, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    static func median(_ values: [Float]) -> Double {
        Double(QCStats.percentile(sorted: values.sorted(), 50))
    }

    /// EFC = (1/E_max) · Σ (x_j / B_max) · ln(x_j / B_max), B_max = √Σ x_j²,
    /// E_max = N · (1/√N) · ln(1/√N). Returns nil for an all-zero image.
    static func entropyFocusCriterion(_ values: [Float]) -> Double? {
        let n = Double(values.count)
        guard n > 1 else { return nil }
        var energy = 0.0
        for v in values where v > 0 { energy += Double(v) * Double(v) }
        guard energy > 0 else { return nil }
        let bMax = energy.squareRoot()
        var sum = 0.0
        for v in values where v > 0 {
            let r = Double(v) / bMax
            sum += r * log(r)
        }
        let eMax = n * (1 / n.squareRoot()) * log(1 / n.squareRoot())
        return sum / eMax
    }

    struct TissueClass {
        let mean: Double
        let std: Double
        let count: Int
    }

    /// 1D k-means with 3 clusters on a 256-bin histogram (fast, deterministic), initialised
    /// at the 20th / 50th / 80th percentiles. Classes are returned dark → bright; then exact
    /// per-class mean/std are taken from the raw values. nil when a class ends up empty.
    static func kMeans3(_ values: [Float]) -> [TissueClass]? {
        let sorted = values.sorted()
        guard sorted.count >= 3 else { return nil }
        let lo = QCStats.percentile(sorted: sorted, 0.5)
        let hi = QCStats.percentile(sorted: sorted, 99.5)
        guard hi > lo else { return nil }
        let bins = 256
        let width = Double(hi - lo) / Double(bins)
        var hist = [Double](repeating: 0, count: bins)
        for v in sorted {
            hist[min(bins - 1, max(0, Int(Double(v - lo) / width)))] += 1
        }
        var centers = [20.0, 50.0, 80.0].map { Double(QCStats.percentile(sorted: sorted, $0)) }
        for _ in 0..<50 {
            var sums = [0.0, 0.0, 0.0]
            var counts = [0.0, 0.0, 0.0]
            for b in 0..<bins where hist[b] > 0 {
                let x = Double(lo) + (Double(b) + 0.5) * width
                let k = nearest(x, centers)
                sums[k] += x * hist[b]
                counts[k] += hist[b]
            }
            var moved = false
            for k in 0..<3 where counts[k] > 0 {
                let c = sums[k] / counts[k]
                if abs(c - centers[k]) > width * 0.01 { moved = true }
                centers[k] = c
            }
            centers.sort()
            if !moved { break }
        }
        var groups: [[Float]] = [[], [], []]
        for v in values { groups[nearest(Double(v), centers)].append(v) }
        var result: [TissueClass] = []
        for g in groups {
            guard g.count >= 2 else { return nil }
            let s = QCStats.meanStd(g)
            result.append(TissueClass(mean: s.mean, std: s.std, count: s.count))
        }
        return result
    }

    @inline(__always)
    private static func nearest(_ x: Double, _ c: [Double]) -> Int {
        var best = 0
        var bestD = abs(x - c[0])
        for k in 1..<c.count {
            let d = abs(x - c[k])
            if d < bestD { bestD = d; best = k }
        }
        return best
    }
}
