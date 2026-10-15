import Foundation

/// What kind of voxel content the QC pass decided it is looking at.
public enum QCContentKind: String, Sendable, Hashable {
    /// Scalar, non-CT intensity image (typically MRI). All metrics apply.
    case anatomical
    /// CT in Hounsfield units. MRI-oriented metrics are not rated.
    case ct
    /// Integer label map / segmentation / mask. Metrics, head mask and face check are skipped.
    case labelMap
    /// RGB / RGBA data. Not analysed.
    case colour
    /// Empty or constant volume.
    case empty
}

public struct QCOptions: Sendable, Hashable {
    /// Upper bound on grid cells per axis for every stage (mask, metrics, face check).
    public var maxGridDimension: Int
    /// Which volume of a 4D series to analyse.
    public var volumeIndex: Int
    public var computeMetrics: Bool
    public var checkFace: Bool
    /// Optional NIfTI `intent_code`, when the caller has it (not read from `MIQHeader`).
    public var intentCode: Int?
    /// Optional header description text, matched only against fixed sequence keywords.
    public var descrip: String?

    public init(
        maxGridDimension: Int = QCHeadMask.defaultMaxGridDimension,
        volumeIndex: Int = 0,
        computeMetrics: Bool = true,
        checkFace: Bool = true,
        intentCode: Int? = nil,
        descrip: String? = nil
    ) {
        self.maxGridDimension = maxGridDimension
        self.volumeIndex = volumeIndex
        self.computeMetrics = computeMetrics
        self.checkFace = checkFace
        self.intentCode = intentCode
        self.descrip = descrip
    }
}

/// Result of a full QC pass. Everything here is a heuristic data-quality aid, not a diagnosis.
public struct QCSummary: Sendable {
    public let contentKind: QCContentKind
    public let sequenceGuess: QCSequenceGuess?
    public let headMask: QCHeadMask?
    public let report: QCReport
    public let faceCheck: QCFaceCheck

    /// Head/foreground mask volume in mL (nil when no mask was computed).
    public var headMaskVolumeMilliliters: Double? { headMask?.volumeMilliliters }

    /// Compact rows for the metadata panel (label/value split like `MIQMetadata`).
    public var displayLines: [MetadataEntry] {
        var lines: [MetadataEntry] = []
        if let sequenceGuess {
            lines.append(MetadataEntry(field: nil, label: "Likely sequence", value: "\(sequenceGuess.label) (heuristic)"))
        }
        if let headMask {
            lines.append(MetadataEntry(field: nil, label: "Head mask", value: "\(QCFormat.groupedInteger(headMask.volumeMilliliters)) mL"))
        }
        switch faceCheck.presence {
        case .facePresentLikely:
            lines.append(MetadataEntry(field: nil, label: "Face", value: "Likely present (heuristic)"))
        case .defacedLikely:
            lines.append(MetadataEntry(field: nil, label: "Face", value: "Likely removed (heuristic)"))
        case .unknown:
            break
        }
        if report.isAssessed {
            let rated = report.metrics.filter { $0.level != .notAssessed }
            let flagged = rated.filter { $0.level != .typical }.count
            let detail = flagged == 0 ? "\(rated.count) metrics" : "\(flagged) of \(rated.count) metrics flagged"
            lines.append(MetadataEntry(field: nil, label: "Data QC", value: "\(report.overallLevel.displayName) (\(detail), heuristic)"))
        }
        return lines
    }

    /// One row per metric ("SNR: 12.3 · Typical"), for an expanded panel.
    var metricLines: [MetadataEntry] {
        guard report.isAssessed else { return [] }
        return report.metrics.map {
            MetadataEntry(field: nil, label: $0.id.displayName, value: "\($0.formattedValue) · \($0.level.displayName)")
        }
    }
}

public enum QCAnalyzer {
    /// Runs every QC stage on one volume. Synchronous and CPU-bound: call it off the main
    /// thread (e.g. inside `Task.detached`). Cancellation is checked between stages and inside
    /// the sampling loop; a cancelled task throws `CancellationError`.
    ///
    /// Stages: sample grid → classify content (label map / CT) → sequence guess → head mask
    /// → metrics (anatomical only) → face check (3D anatomical or CT only).
    public static func analyze(
        volume: MIQVolume,
        fileName: String? = nil,
        options: QCOptions = QCOptions()
    ) throws -> QCSummary {
        let header = volume.image.header
        try Task.checkCancellation()

        guard let grid = try QCGrid.sample(volume: volume, volumeIndex: options.volumeIndex, maxDimension: options.maxGridDimension) else {
            let isColour = header.datatype == .rgb24 || header.datatype == .rgba32
            let kind: QCContentKind = isColour ? .colour : .empty
            return QCSummary(
                contentKind: kind,
                sequenceGuess: QCSequenceGuesser.guess(fileName: fileName, volumes: header.volumes,
                                                       intentCode: options.intentCode, descrip: options.descrip),
                headMask: nil,
                report: .skipped(isColour ? "Colour data not assessed" : "Empty volume"),
                faceCheck: .unknown(isColour ? "Colour data" : "Empty volume")
            )
        }
        try Task.checkCancellation()

        // Content classification.
        let label = QCContentClassifier.labelMapEvidence(grid: grid, datatype: header.datatype)
        let ct = !label.isLabel && QCContentClassifier.looksLikeCT(grid: grid)
        let variation = try QCContentClassifier.volumeMeanVariation(volume: volume)
        try Task.checkCancellation()

        let guess = QCSequenceGuesser.guess(
            fileName: fileName,
            volumes: header.volumes,
            evidence: QCIntensityEvidence(isLabelMap: label.isLabel, isBinaryMask: label.isBinary,
                                          looksLikeCT: ct, volumeMeanVariation: variation),
            intentCode: options.intentCode,
            descrip: options.descrip
        )
        let labelByName = ["Segmentation", "Mask", "Probabilistic segmentation"].contains(guess?.label ?? "")
        let kind: QCContentKind
        if label.isLabel || (labelByName && guess?.source != .intensity) {
            kind = .labelMap
        } else if ct || guess?.label == "CT" {
            kind = .ct
        } else {
            kind = .anatomical
        }

        if let range = QCStats.range(grid.values), range.min == range.max {
            return QCSummary(contentKind: .empty, sequenceGuess: guess, headMask: nil,
                             report: .skipped("Constant volume"), faceCheck: .unknown("Constant volume"))
        }
        if kind == .labelMap {
            return QCSummary(contentKind: kind, sequenceGuess: guess, headMask: nil,
                             report: .skipped("Label map not assessed"), faceCheck: .unknown("Label map"))
        }
        try Task.checkCancellation()

        let mask = try QCHeadMask.compute(grid: grid)
        try Task.checkCancellation()

        let report: QCReport
        if !options.computeMetrics {
            report = .skipped("Metrics disabled")
        } else if kind == .ct {
            report = .skipped("CT not assessed (MRI metrics)")
        } else if let mask {
            report = try QCMetricsCalculator.compute(grid: grid, mask: mask)
        } else {
            report = .skipped("No foreground found")
        }
        try Task.checkCancellation()

        let face: QCFaceCheck
        if !options.checkFace {
            face = .unknown("Face check disabled")
        } else if header.volumes > 1 {
            face = .unknown("4D series")
        } else if let mask {
            face = QCFaceDetector.detect(grid: grid, mask: mask, frame: header.orientationFrame)
        } else {
            face = .unknown("No foreground found")
        }

        return QCSummary(contentKind: kind, sequenceGuess: guess, headMask: mask, report: report, faceCheck: face)
    }
}
