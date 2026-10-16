import Foundation

/// Where a sequence/modality guess came from.
public enum QCSequenceSource: String, Sendable, Hashable {
    /// BIDS suffix or a recognisable token in the file name.
    case filename
    /// Optional header hints passed in by the caller (NIfTI intent code, description text).
    case header
    /// Voxel values: datatype + few unique values (label map), Hounsfield range (CT).
    case intensity
    /// Shape: number of volumes and how their mean intensity varies (4D series).
    case dimensions
}

/// Heuristic sequence / modality guess. Strings are neutral labels for a metadata panel;
/// the guess is informational and can be wrong.
public struct QCSequenceGuess: Sendable, Hashable {
    /// Short label, e.g. "T1w", "FLAIR", "CT", "Segmentation", "4D series".
    public let label: String
    public let source: QCSequenceSource
    /// 0…1.
    public let confidence: Double

    public init(label: String, source: QCSequenceSource, confidence: Double) {
        self.label = label
        self.source = source
        self.confidence = confidence
    }

    /// "Likely sequence: FLAIR (heuristic)".
    public var displayText: String {
        "Likely sequence: \(label) (heuristic)"
    }
}

/// Evidence derived from voxel data that the sequence guesser can use. All optional so the
/// filename rules can be exercised (and used) without touching voxels.
public struct QCIntensityEvidence: Sendable, Hashable {
    public var isLabelMap: Bool
    /// Label map with exactly two values (0 and one label).
    public var isBinaryMask: Bool
    public var looksLikeCT: Bool
    /// Coefficient of variation of per-volume mean intensity, for 4D data (nil when 3D or
    /// not all volumes are loaded).
    public var volumeMeanVariation: Double?

    public init(isLabelMap: Bool = false, isBinaryMask: Bool = false, looksLikeCT: Bool = false, volumeMeanVariation: Double? = nil) {
        self.isLabelMap = isLabelMap
        self.isBinaryMask = isBinaryMask
        self.looksLikeCT = looksLikeCT
        self.volumeMeanVariation = volumeMeanVariation
    }
}

public enum QCSequenceGuesser {
    /// BIDS suffixes (lower-cased) → display label.
    static let bidsSuffixes: [String: String] = [
        "t1w": "T1w", "t2w": "T2w", "flair": "FLAIR", "t2starw": "T2*w", "pdw": "PDw",
        "pd": "PDw", "t2star": "T2*w", "inplanet1": "T1w", "inplanet2": "T2w",
        "t1map": "T1 map", "t2map": "T2 map", "unit1": "T1w (UNIT1)",
        "dwi": "DWI", "bold": "BOLD", "cbv": "CBV", "sbref": "SBRef", "asl": "ASL",
        "m0scan": "ASL M0", "angio": "Angio", "swi": "SWI", "pet": "PET",
        "epi": "Field map", "phasediff": "Field map", "fieldmap": "Field map",
        "magnitude": "Field map", "magnitude1": "Field map", "magnitude2": "Field map",
        "phase1": "Field map", "phase2": "Field map",
        "mask": "Mask", "dseg": "Segmentation", "probseg": "Probabilistic segmentation",
        "ct": "CT",
    ]

    /// Looser tokens found anywhere in a non-BIDS name (lower-cased, split on non-alphanumerics).
    static let looseTokens: [(tokens: Set<String>, label: String)] = [
        (["flair", "tirm", "spcir"], "FLAIR"),
        (["mprage", "mp2rage", "spgr", "bravo", "tfl", "t1", "t1w", "t1mprage"], "T1w"),
        (["t2", "t2w", "t2tse"], "T2w"),
        (["swi"], "SWI"),
        (["tof", "angio", "mra"], "Angio"),
        (["dwi", "dti", "diffusion", "dmri", "hardi"], "DWI"),
        (["bold", "fmri", "rsfmri"], "BOLD"),
        (["aseg", "aparc", "wmparc", "seg", "dseg", "labels", "label", "parcellation"], "Segmentation"),
        (["mask", "brainmask"], "Mask"),
        (["ct", "cta"], "CT"),
        (["pet"], "PET"),
    ]

    /// FreeSurfer subject-directory volumes (exact basename) → label.
    static let freeSurferNames: [String: String] = [
        "t1": "T1w", "orig": "T1w", "rawavg": "T1w", "nu": "T1w", "norm": "T1w",
        "brain": "T1w", "brainmask": "Mask", "aseg": "Segmentation",
        "aparc+aseg": "Segmentation", "aparc.a2009s+aseg": "Segmentation",
        "aparc.dktatlas+aseg": "Segmentation", "wmparc": "Segmentation",
        "wm": "Segmentation", "filled": "Segmentation", "ribbon": "Segmentation",
    ]

    static let knownExtensions = ["gz", "nii", "mgz", "mgh", "mif", "nrrd", "nhdr", "img", "hdr"]

    /// File name without directories or known (possibly compound) extensions, lower-cased.
    static func stem(_ fileName: String) -> String {
        var name = (fileName as NSString).lastPathComponent.lowercased()
        while let dot = name.lastIndex(of: "."), knownExtensions.contains(String(name[name.index(after: dot)...])) {
            name = String(name[..<dot])
        }
        return name
    }

    /// Guess from the file name alone. BIDS suffix (`sub-01_T1w.nii.gz`) → 0.9; FreeSurfer
    /// basename (`aseg.mgz`) → 0.7; loose token (`MPRAGE_sag.nii`) → 0.5.
    public static func guess(fileName: String) -> QCSequenceGuess? {
        let s = stem(fileName)
        guard !s.isEmpty else { return nil }
        if let underscore = s.lastIndex(of: "_") {
            let suffix = String(s[s.index(after: underscore)...])
            if let label = bidsSuffixes[suffix] {
                return QCSequenceGuess(label: label, source: .filename, confidence: 0.9)
            }
        }
        if let label = freeSurferNames[s] {
            return QCSequenceGuess(label: label, source: .filename, confidence: 0.7)
        }
        let tokens = Set(s.split { !$0.isLetter && !$0.isNumber && $0 != "+" }.map(String.init))
        for entry in looseTokens where !entry.tokens.isDisjoint(with: tokens) {
            return QCSequenceGuess(label: entry.label, source: .filename, confidence: 0.5)
        }
        return nil
    }

    /// Combines every available rule. Precedence: filename BIDS/FreeSurfer suffix, header
    /// hints, label-map / CT intensity evidence, loose filename token, 4D shape.
    /// - Parameters:
    ///   - intentCode: optional NIfTI `intent_code` (1002 = label, 1003 = NeuroNames label).
    ///   - descrip: optional free-text description (e.g. NIfTI `descrip`); only matched
    ///     against fixed keywords, never echoed.
    public static func guess(
        fileName: String?,
        volumes: Int,
        evidence: QCIntensityEvidence = QCIntensityEvidence(),
        intentCode: Int? = nil,
        descrip: String? = nil
    ) -> QCSequenceGuess? {
        let fromName = fileName.flatMap { guess(fileName: $0) }
        if let fromName, fromName.confidence >= 0.7 { return fromName }

        if let intentCode, intentCode == 1002 || intentCode == 1003 {
            return QCSequenceGuess(label: "Segmentation", source: .header, confidence: 0.8)
        }
        if let descrip, let label = keywordLabel(in: descrip) {
            return QCSequenceGuess(label: label, source: .header, confidence: 0.6)
        }
        if evidence.isLabelMap {
            return QCSequenceGuess(label: evidence.isBinaryMask ? "Mask" : "Segmentation", source: .intensity, confidence: 0.7)
        }
        if evidence.looksLikeCT {
            return QCSequenceGuess(label: "CT", source: .intensity, confidence: 0.7)
        }
        if let fromName { return fromName }

        if volumes > 1 {
            // DWI series mix bright b=0 volumes with much darker diffusion-weighted ones, so
            // their per-volume means vary a lot; BOLD series are near-constant over time.
            if let cv = evidence.volumeMeanVariation {
                if cv >= 0.15 && volumes >= 6 {
                    return QCSequenceGuess(label: "DWI", source: .dimensions, confidence: 0.4)
                }
                if cv <= 0.03 && volumes >= 20 {
                    return QCSequenceGuess(label: "BOLD", source: .dimensions, confidence: 0.4)
                }
            }
            return QCSequenceGuess(label: "4D series", source: .dimensions, confidence: 0.3)
        }
        return nil
    }

    static func keywordLabel(in text: String) -> String? {
        let tokens = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        for entry in looseTokens where !entry.tokens.isDisjoint(with: tokens) {
            return entry.label
        }
        return nil
    }
}

// MARK: - Intensity evidence from a grid

enum QCContentClassifier {
    static let integerTypes: Set<MIQDatatype> = [.int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64]

    /// Label map: integer datatype, integral scaled values, at most 1000 distinct values on the
    /// grid, and piecewise-constant structure (most adjacent non-zero grid neighbours share a
    /// value — noisy MRI almost never does, even when stored as uint8).
    ///
    /// Neighbour pairs where both voxels hold the grid's most frequent value are left out
    /// along with zero pairs: that value is the background (0 for MRI and label maps, but
    /// e.g. −1024 for CT with noise-free air or padding), and a flat background says
    /// nothing about whether the *foreground* is piecewise constant.
    static func labelMapEvidence(grid: QCGrid, datatype: MIQDatatype) -> (isLabel: Bool, isBinary: Bool) {
        guard integerTypes.contains(datatype) else { return (false, false) }
        var counts: [Float: Int] = [:]
        for v in grid.values {
            if v != v.rounded() { return (false, false) }
            counts[v, default: 0] += 1
            if counts.count > 1000 { return (false, false) }
        }
        guard counts.count >= 2 else { return (false, false) }
        let unique = counts.count
        // Ties resolve to the smallest value so the result is deterministic.
        let mode = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
        var pairs = 0
        var equal = 0
        for z in 0..<grid.depth {
            for y in 0..<grid.height {
                let row = grid.index(0, y, z)
                for x in 0..<(grid.width - 1) {
                    let a = grid.values[row + x]
                    let b = grid.values[row + x + 1]
                    if a != 0 && b != 0 && !(a == mode && b == mode) {
                        pairs += 1
                        if a == b { equal += 1 }
                    }
                }
            }
        }
        // Two values only (a binary mask) is a label map regardless of neighbour structure.
        if unique == 2 { return (true, true) }
        guard pairs >= 8 else { return (false, false) }
        return (Double(equal) / Double(pairs) >= 0.5, false)
    }

    /// CT in Hounsfield units: a large mode near air (−1100…−900 HU, ≥ 5% of the grid) together
    /// with soft tissue (−100…200 HU, ≥ 5%). MRI magnitude is non-negative; MRI phase spreads
    /// roughly uniformly and fails the air-mode test.
    static func looksLikeCT(grid: QCGrid) -> Bool {
        var air = 0
        var soft = 0
        for v in grid.values {
            if v >= -1100 && v <= -900 { air += 1 } else if v >= -100 && v <= 200 { soft += 1 }
        }
        let n = Double(grid.count)
        return n > 0 && Double(air) / n >= 0.05 && Double(soft) / n >= 0.05
    }

    /// Coefficient of variation of per-volume mean intensity across a 4D series, sampled on a
    /// ≤16³ grid per volume. nil for 3D data or when not every volume is loaded.
    static func volumeMeanVariation(volume: MIQVolume, maxVolumes: Int = 512) throws -> Double? {
        let n = volume.volumes
        guard n > 1, volume.containsAllVolumes else { return nil }
        let stride = max(1, (n + maxVolumes - 1) / maxVolumes)
        var means: [Float] = []
        for t in Swift.stride(from: 0, to: n, by: stride) {
            try Task.checkCancellation()
            guard let g = try QCGrid.sample(volume: volume, volumeIndex: t, maxDimension: 16) else { return nil }
            means.append(Float(QCStats.meanStd(g.values).mean))
        }
        let s = QCStats.meanStd(means)
        guard s.mean != 0 else { return nil }
        return abs(s.std / s.mean)
    }
}
