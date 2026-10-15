import Foundation

/// What a sibling file is expected to be, relative to the image it was found for.
public enum SiblingRole: String, Sendable, Hashable {
    /// Discrete label map (BIDS `_dseg`, FreeSurfer `aseg`/`aparc+aseg`, FSL `_seg`).
    case segmentation
    /// Binary mask (BIDS `_mask`, FSL `_brain_mask`).
    case mask
    /// Probabilistic segmentation (BIDS `_probseg`, FSL `_pve_N`).
    case probabilisticSegmentation
    /// A TotalSegmentator output directory (or its single multi-label file).
    case segmentationDirectory
    /// The anatomical image a segmentation was derived from.
    case anatomical
    /// Fractional anisotropy map paired with a diffusion vector field.
    case fractionalAnisotropy
}

public struct SiblingCandidate: Sendable, Hashable {
    /// Entry name exactly as it appeared in the directory listing.
    public let fileName: String
    public let role: SiblingRole
    /// Higher is a better match; candidates are returned sorted by it.
    public let score: Int

    public init(fileName: String, role: SiblingRole, score: Int) {
        self.fileName = fileName
        self.role = role
        self.score = score
    }
}

/// Proposes overlay ↔ anatomical pairings among the files of one directory using
/// BIDS, FreeSurfer, FSL and TotalSegmentator naming conventions.
///
/// Pure string logic over a directory listing (entry names only), so it is
/// testable and sandbox-agnostic: the caller lists the directory (see
/// `listing(of:)`), and handles the failure when the sandbox forbids it.
///
/// BIDS matching requires the same `sub-` and `ses-` entities (both present and
/// equal, or both absent); `acq-`, `run-`, `rec-`, `ce-`, `echo-` and `space-`
/// must agree whenever *both* names carry them. Shared entities raise the score.
public enum SiblingFiles {
    /// Image extensions recognised, longest first so `.nii.gz` wins over `.gz`.
    static let imageExtensions = [".nii.gz", ".mif.gz", ".nii", ".mgz", ".mgh", ".nrrd", ".nhdr", ".mif"]

    /// BIDS anatomical/functional suffixes accepted as the "anatomical" end of a pairing.
    static let anatomicalSuffixes: Set<String> = [
        "T1w", "T2w", "FLAIR", "PDw", "PD", "T2starw", "T1map", "T2map", "MTw", "UNIT1",
        "inplaneT1", "inplaneT2", "angio", "boldref", "sbref", "bold", "dwi", "T1", "T2",
    ]

    /// Entities that must match exactly (both present and equal, or both absent).
    static let requiredEntities = ["sub", "ses"]
    /// Entities that must agree only when both names have them.
    static let compatibleEntities = ["acq", "run", "rec", "ce", "echo", "space", "res", "hemi"]

    static let freeSurferSegmentations: [(name: String, role: SiblingRole, score: Int)] = [
        ("aparc+aseg", .segmentation, 100),
        ("aseg", .segmentation, 95),
        ("aparc.a2009s+aseg", .segmentation, 90),
        ("aparc.DKTatlas+aseg", .segmentation, 89),
        ("wmparc", .segmentation, 85),
        ("synthseg", .segmentation, 84),
        ("aseg.presurf", .segmentation, 80),
        ("ribbon", .segmentation, 75),
    ]
    static let freeSurferAnatomicals: [(name: String, score: Int)] = [
        ("T1", 100), ("brain", 95), ("norm", 90), ("nu", 85), ("orig", 80), ("brainmask", 70), ("rawavg", 60),
    ]

    // MARK: - Name parsing

    /// `name` without a recognised image extension (unchanged when none matches).
    public static func stripImageExtension(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in imageExtensions where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static func hasImageExtension(_ name: String) -> Bool {
        let lower = name.lowercased()
        return imageExtensions.contains { lower.hasSuffix($0) }
    }

    /// A BIDS-style name split into key-value entities and a trailing suffix.
    struct BIDSName {
        var entities: [String: String] = [:]
        var entityOrder: [String] = []
        var suffix: String = ""

        init(_ fileName: String) {
            let parts = stripImageExtension(fileName).split(separator: "_").map(String.init)
            for (i, part) in parts.enumerated() {
                if let dash = part.firstIndex(of: "-"), dash != part.startIndex {
                    let key = String(part[..<dash])
                    entities[key] = String(part[part.index(after: dash)...])
                    entityOrder.append(key)
                } else if i == parts.count - 1 {
                    suffix = part
                }
            }
        }

        var isBIDS: Bool { entities["sub"] != nil }
    }

    /// Entity-compatibility score: `nil` when incompatible, else the count of
    /// shared equal entities.
    static func entityScore(_ a: BIDSName, _ b: BIDSName) -> Int? {
        for key in requiredEntities where a.entities[key] != b.entities[key] { return nil }
        var shared = 0
        for key in compatibleEntities {
            if let va = a.entities[key], let vb = b.entities[key] {
                if va != vb { return nil }
                shared += 1
            }
        }
        return shared
    }

    // MARK: - Overlay candidates (image → seg)

    /// Overlay candidates for an anatomical/functional image `fileName`, chosen
    /// from `listing` (names of the entries in the same directory). Never returns
    /// `fileName` itself.
    public static func overlayCandidates(for fileName: String, in listing: [String]) -> [SiblingCandidate] {
        let stem = stripImageExtension(fileName)
        let me = BIDSName(fileName)
        var out: [SiblingCandidate] = []

        for entry in listing where entry != fileName {
            let entryStem = stripImageExtension(entry)
            let isImage = hasImageExtension(entry)

            // TotalSegmentator: an output directory (`segmentations`, `<stem>_seg…`
            // without extension, `*totalseg*`) or the `--ml` multi-label file.
            if !isImage {
                let lower = entry.lowercased()
                if lower == "segmentations" || lower.contains("totalseg")
                    || lower == stem.lowercased() + "_seg" || lower == stem.lowercased() + "_segmentations" {
                    out.append(SiblingCandidate(fileName: entry, role: .segmentationDirectory, score: 40))
                }
                continue
            }
            if entryStem.lowercased() == "segmentations" {
                out.append(SiblingCandidate(fileName: entry, role: .segmentationDirectory, score: 45))
                continue
            }

            // FreeSurfer mri/ directory: segmentations next to T1/brain/orig.
            if freeSurferAnatomicals.contains(where: { $0.name == stem }),
               let fs = freeSurferSegmentations.first(where: { $0.name == entryStem }) {
                out.append(SiblingCandidate(fileName: entry, role: fs.role, score: fs.score))
                continue
            }

            // BIDS derivatives: same subject/session, seg-like suffix.
            let other = BIDSName(entry)
            if me.isBIDS, other.isBIDS, let role = overlayRole(forBIDSSuffix: other.suffix),
               let shared = entityScore(me, other) {
                out.append(SiblingCandidate(fileName: entry, role: role, score: 60 + 5 * shared + roleBonus(role)))
                continue
            }

            // Plain prefix convention: `<stem>_seg`, `<stem>_mask`, `<stem>_brain_mask`,
            // `<stem>_pve_1`, `<stem>_dseg` … (FSL bet/fast, nnU-Net, many tools).
            if entryStem.count > stem.count + 1, entryStem.hasPrefix(stem + "_") {
                let rest = String(entryStem.dropFirst(stem.count + 1)).lowercased()
                if let role = overlayRole(forPlainSuffix: rest) {
                    out.append(SiblingCandidate(fileName: entry, role: role, score: 50 + roleBonus(role)))
                }
            }
        }
        return sorted(out)
    }

    static func overlayRole(forBIDSSuffix suffix: String) -> SiblingRole? {
        switch suffix {
        case "dseg": return .segmentation
        case "mask": return .mask
        case "probseg": return .probabilisticSegmentation
        default: return nil
        }
    }

    static func overlayRole(forPlainSuffix rest: String) -> SiblingRole? {
        if rest == "seg" || rest == "dseg" || rest == "aseg" || rest == "labels" || rest.hasSuffix("_seg")
            || rest == "segmentation" || rest.hasSuffix("_dseg") {
            return .segmentation
        }
        if rest == "mask" || rest.hasSuffix("_mask") { return .mask }
        if rest == "probseg" || rest.hasPrefix("pve_") || rest.hasPrefix("prob") { return .probabilisticSegmentation }
        return nil
    }

    static func roleBonus(_ role: SiblingRole) -> Int {
        switch role {
        case .segmentation: return 10
        case .mask: return 5
        default: return 0
        }
    }

    // MARK: - Anatomical candidates (seg → image)

    /// Whether `fileName` itself looks like a segmentation/mask by convention.
    public static func looksLikeSegmentation(_ fileName: String) -> Bool {
        let stem = stripImageExtension(fileName)
        if freeSurferSegmentations.contains(where: { $0.name == stem }) { return true }
        if stem.lowercased() == "segmentations" { return true }
        let name = BIDSName(fileName)
        if name.isBIDS, overlayRole(forBIDSSuffix: name.suffix) != nil { return true }
        guard let underscore = stem.firstIndex(of: "_") else { return false }
        let rest = String(stem[stem.index(after: underscore)...]).lowercased()
        let tokens = rest.split(separator: "_").map(String.init)
        let lastToken = tokens.last ?? rest
        return overlayRole(forPlainSuffix: lastToken) != nil
            || overlayRole(forPlainSuffix: rest) != nil
            || tokens.contains("pve")
    }

    /// Anatomical candidates for a segmentation/mask `fileName` among `listing`.
    public static func anatomicalCandidates(forSegmentation fileName: String, in listing: [String]) -> [SiblingCandidate] {
        let stem = stripImageExtension(fileName)
        let me = BIDSName(fileName)
        var out: [SiblingCandidate] = []
        let isFreeSurferSeg = freeSurferSegmentations.contains { $0.name == stem }

        // Plain-convention base names: drop recognised trailing segments.
        var plainBases: [String] = []
        var parts = stem.split(separator: "_").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            plainBases.append(parts.joined(separator: "_"))
        }

        for entry in listing where entry != fileName && hasImageExtension(entry) {
            let entryStem = stripImageExtension(entry)
            if isFreeSurferSeg, let fs = freeSurferAnatomicals.first(where: { $0.name == entryStem }) {
                out.append(SiblingCandidate(fileName: entry, role: .anatomical, score: fs.score))
                continue
            }
            if looksLikeSegmentation(entry) { continue }
            let other = BIDSName(entry)
            if me.isBIDS, other.isBIDS, anatomicalSuffixes.contains(other.suffix),
               let shared = entityScore(me, other) {
                // T1w is the conventional reference for anatomical derivatives.
                let preference = other.suffix == "T1w" ? 5 : 0
                out.append(SiblingCandidate(fileName: entry, role: .anatomical, score: 60 + 5 * shared + preference))
                continue
            }
            if let depth = plainBases.firstIndex(of: entryStem) {
                out.append(SiblingCandidate(fileName: entry, role: .anatomical, score: 55 - depth))
            }
        }
        return sorted(out)
    }

    // MARK: - FA for a vector field

    /// FA map candidates for a diffusion vector field (`dti_V1` → `dti_FA`).
    public static func fractionalAnisotropyCandidates(forVectorField fileName: String, in listing: [String]) -> [SiblingCandidate] {
        let stem = stripImageExtension(fileName)
        guard let range = stem.range(of: "V1", options: .backwards) else { return [] }
        let faStem = stem.replacingCharacters(in: range, with: "FA")
        return sorted(listing.compactMap { entry in
            guard entry != fileName, hasImageExtension(entry) else { return nil }
            let entryStem = stripImageExtension(entry)
            if entryStem == faStem { return SiblingCandidate(fileName: entry, role: .fractionalAnisotropy, score: 100) }
            if entryStem.lowercased() == faStem.lowercased() {
                return SiblingCandidate(fileName: entry, role: .fractionalAnisotropy, score: 90)
            }
            return nil
        })
    }

    // MARK: - Convenience

    /// Direction-detecting entry point: anatomical candidates when `fileName`
    /// looks like a segmentation, else overlay candidates (plus FA for a `V1` field).
    public static func candidates(for fileName: String, in listing: [String]) -> [SiblingCandidate] {
        if looksLikeSegmentation(fileName) {
            return anatomicalCandidates(forSegmentation: fileName, in: listing)
        }
        var result = overlayCandidates(for: fileName, in: listing)
        if DiffusionColor.isVectorFieldName(fileName) {
            result = sorted(result + fractionalAnisotropyCandidates(forVectorField: fileName, in: listing))
        }
        return result
    }

    /// Entry names of `directory`, or `nil` when it can't be listed (e.g. the
    /// Quick Look sandbox denies it). Hidden files are skipped.
    public static func listing(of directory: URL) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }
    }

    /// Candidate URLs for `url`, listing its parent directory; empty when listing fails.
    public static func candidateURLs(for url: URL) -> [(url: URL, candidate: SiblingCandidate)] {
        let directory = url.deletingLastPathComponent()
        guard let names = listing(of: directory) else { return [] }
        return candidates(for: url.lastPathComponent, in: names).map {
            (directory.appendingPathComponent($0.fileName), $0)
        }
    }

    static func sorted(_ candidates: [SiblingCandidate]) -> [SiblingCandidate] {
        var seen = Set<String>()
        return candidates
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fileName < $1.fileName }
            .filter { seen.insert($0.fileName).inserted }
    }
}
