import Foundation

/// Read-only explanation of *how* a volume's orientation was derived, for the
/// metadata panel. It never changes rendering: `OrientationFrame` stays the single
/// source of truth for labels and slice planning. This only makes the derivation
/// visible — which header transform was used, how far it is from axis-aligned,
/// and (for NIfTI) whether the qform and sform tell conflicting stories.
public struct OrientationDiagnostics: Sendable, Equatable {

    /// Which header transform the orientation came from.
    public enum TransformSource: String, Sendable, Equatable {
        /// NIfTI `sform` (srow_x/y/z), used when `sform_code > 0` and non-degenerate.
        case sform
        /// NIfTI `qform` quaternion, used when the sform is absent or degenerate.
        case qform
        /// NRRD anatomical `space` + `space directions`.
        case nrrdSpace
        /// MRtrix MIF `transform:` field (composed with `layout:`).
        case mifTransform
        /// MRtrix MIF without a `transform:` field. The format defines that as an
        /// identity (RAS) affine, so the labels are as reliable as MRtrix's own —
        /// but the file itself states nothing.
        case mifDefault
        /// FreeSurfer MGH/MGZ direction cosines (`goodRASFlag != 0`).
        case mghVox2ras
        /// ITK MetaImage `TransformMatrix` + `Offset` (LPS, converted to RAS).
        case metaImage
        /// No usable transform: orientation is unknown and labels read "?".
        case none

        /// Short panel label.
        public var label: String {
            switch self {
            case .sform: return "sform"
            case .qform: return "qform"
            case .nrrdSpace: return "NRRD space"
            case .mifTransform: return "MIF transform"
            case .mifDefault: return "MIF default"
            case .mghVox2ras: return "vox2ras"
            case .metaImage: return "MetaImage transform"
            case .none: return "no transform"
            }
        }

        /// Maps a frame's provenance onto the diagnostics vocabulary. MIF maps to
        /// `.mifTransform`; the MIF parser reports `.mifDefault` explicitly.
        init(_ source: OrientationSource) {
            switch source {
            case .sform: self = .sform
            case .qform: self = .qform
            case .mifLayout: self = .mifTransform
            case .mghDirectionCosines: self = .mghVox2ras
            case .nrrdSpaceDirections: self = .nrrdSpace
            case .metaImageTransform: self = .metaImage
            }
        }
    }

    /// How a NIfTI file's qform and sform disagree, when both codes are > 0.
    /// Checked in order of severity; the first that applies wins.
    public enum QSConflict: String, Sendable, Equatable {
        /// The two 3×3 matrices have determinants of opposite sign. One of them is a
        /// mirror image of the other, and the NIfTI spec gives no way to tell which is
        /// right — left/right is undecidable.
        case handedness
        /// Same handedness, but the 3-letter axis codes differ (e.g. axes swapped).
        case axisCodes
        /// Same axis codes, but at least one voxel-axis direction differs by more than
        /// `OrientationDiagnostics.minorConflictToleranceDegrees`.
        case minor
    }

    /// Angle (degrees) above which two corresponding qform/sform axis directions count
    /// as a `.minor` conflict. 0.1° sits far above float32 storage noise (~1e-4°) while
    /// staying well below anything visible in a preview.
    public static let minorConflictToleranceDegrees: Double = 0.1

    /// Obliquity (degrees) below which a transform is treated as axis-aligned. Float32
    /// direction cosines alone produce ~1e-5° of apparent tilt.
    public static let obliquityToleranceDegrees: Double = 0.01

    public let transformSource: TransformSource
    /// The storage orientation code ("RAS", "LPS", ...), or nil when unknown.
    public let axisCodes: String?
    /// The largest angle (degrees) between any voxel axis and its nearest world axis:
    /// 0 for an axis-aligned volume, up to ~54.7° for maximal obliquity. nil when unknown.
    public let obliquityDegrees: Double?
    /// NIfTI only: how the qform and sform disagree; nil when they agree, or when
    /// fewer than two of them are present.
    public let qformSformConflict: QSConflict?
    /// NIfTI only: the qform's axis codes when a conflict is reported, so the warning
    /// can name both sides.
    public let qformAxisCodes: String?
    /// MRtrix MIF only: the orientation code of MRtrix's *image* axes (the
    /// `transform:` columns alone), i.e. the axes `mrinfo`, `mrview` and MRtrix
    /// voxel indices refer to. `axisCodes` describes MIQ's voxel grid instead,
    /// which walks the payload in storage order: with `layout: -0,+1,+2` and an
    /// RAS transform the stored x runs right→left, so MIQ's grid (and its
    /// "stored" view) is LAS while MRtrix calls the same image RAS with strides
    /// -1,2,3. `nil` for other formats.
    public let imageAxisCodes: String?

    public init(
        transformSource: TransformSource,
        axisCodes: String?,
        obliquityDegrees: Double?,
        qformSformConflict: QSConflict? = nil,
        qformAxisCodes: String? = nil,
        imageAxisCodes: String? = nil
    ) {
        self.imageAxisCodes = imageAxisCodes
        self.transformSource = transformSource
        self.axisCodes = axisCodes
        self.obliquityDegrees = obliquityDegrees
        self.qformSformConflict = qformSformConflict
        self.qformAxisCodes = qformAxisCodes
    }

    /// Diagnostics for a volume whose orientation could not be determined.
    public static let unknown = OrientationDiagnostics(transformSource: .none, axisCodes: nil, obliquityDegrees: nil)

    /// True when the transform is measurably tilted relative to the world axes, i.e. the
    /// anatomical labels are nearest-axis approximations.
    public var isOblique: Bool {
        (obliquityDegrees ?? 0) > Self.obliquityToleranceDegrees
    }

    /// One-line summary for the metadata panel, e.g. "RAS · oblique 23° · sform",
    /// "LPS · NRRD space", or "Unknown · no transform". A MIF whose layout
    /// reorders or flips its image axes adds what MRtrix calls them:
    /// "LAS · MRtrix image axes RAS · MIF transform" (see `imageAxisCodes`).
    public var displaySummary: String {
        var parts = [axisCodes ?? "Unknown"]
        if isOblique, let degrees = obliquityDegrees {
            parts.append(degrees < 0.5 ? "oblique <1°" : "oblique \(Int(degrees.rounded()))°")
        }
        if let imageAxisCodes, axisCodes != nil, imageAxisCodes != axisCodes {
            parts.append("MRtrix image axes \(imageAxisCodes)")
        }
        parts.append(transformSource.label)
        return parts.joined(separator: " · ")
    }

    /// Short caution for the metadata panel, or nil when nothing needs flagging.
    public var warning: String? {
        switch qformSformConflict {
        case .handedness:
            return "qform and sform disagree on left/right — other tools may show this image flipped"
        case .axisCodes:
            if let q = qformAxisCodes, let s = axisCodes {
                return "qform (\(q)) and sform (\(s)) disagree — other tools may orient this image differently"
            }
            return "qform and sform disagree — other tools may orient this image differently"
        case .minor, nil:
            break
        }
        if transformSource == .none {
            return "Header has no anatomical orientation — labels unknown"
        }
        return nil
    }

    // MARK: - Builders

    /// Diagnostics for a resolved frame and the matrix it came from (three rows, world
    /// x/y/z; columns are voxel axes). Obliquity is nil when `rows` is nil or degenerate.
    static func make(
        frame: OrientationFrame?,
        source: TransformSource? = nil,
        rows: [[Float]]?,
        qformSformConflict: QSConflict? = nil,
        qformAxisCodes: String? = nil,
        imageAxisCodes: String? = nil
    ) -> OrientationDiagnostics {
        guard let frame else { return .unknown }
        return OrientationDiagnostics(
            transformSource: source ?? TransformSource(frame.source),
            axisCodes: frame.axes.map(\.letter).joined(),
            obliquityDegrees: rows.flatMap(obliquityDegrees(rows:)),
            qformSformConflict: qformSformConflict,
            qformAxisCodes: qformAxisCodes,
            imageAxisCodes: imageAxisCodes
        )
    }

    /// Largest angle between any voxel-axis column of `rows` and its nearest world axis.
    /// Invariant under axis permutation and flips, so a MIF transform gives the same
    /// value whatever its layout. Returns nil when a column is zero or non-finite.
    public static func obliquityDegrees(rows: [[Float]]) -> Double? {
        guard let columns = unitColumns(rows) else { return nil }
        var worst = 0.0
        for c in columns {
            let dominant = min(1, max(abs(c[0]), abs(c[1]), abs(c[2])))
            worst = max(worst, acos(dominant) * 180 / .pi)
        }
        return worst
    }

    /// Compares a NIfTI sform and qform (each three world rows; spacing in the sform is
    /// normalised away). See `QSConflict` for the order of checks. Returns nil when they
    /// agree within `minorConflictToleranceDegrees` or either matrix is degenerate.
    static func qformSformConflict(sformRows: [[Float]], qformRows: [[Float]]) -> QSConflict? {
        guard let s = unitColumns(sformRows), let q = unitColumns(qformRows) else { return nil }
        let detS = determinant(s)
        let detQ = determinant(q)
        guard abs(detS) > 1e-6, abs(detQ) > 1e-6 else { return nil }
        if (detS > 0) != (detQ > 0) { return .handedness }

        let sCodes = OrientationFrame.from(srowX: sformRows[0], srowY: sformRows[1], srowZ: sformRows[2], source: .sform)
        let qCodes = OrientationFrame.from(srowX: qformRows[0], srowY: qformRows[1], srowZ: qformRows[2], source: .qform)
        if let sCodes, let qCodes, sCodes.axes != qCodes.axes { return .axisCodes }

        var worst = 0.0
        for i in 0..<3 {
            let dot = s[i][0] * q[i][0] + s[i][1] * q[i][1] + s[i][2] * q[i][2]
            worst = max(worst, acos(min(1, max(-1, dot))) * 180 / .pi)
        }
        return worst > minorConflictToleranceDegrees ? .minor : nil
    }

    /// The three voxel-axis columns of a 3-row matrix, normalised to unit length.
    private static func unitColumns(_ rows: [[Float]]) -> [[Double]]? {
        guard rows.count >= 3 else { return nil }
        var columns: [[Double]] = []
        for col in 0..<3 {
            let v = (0..<3).map { Double(rows[$0][safe: col] ?? 0) }
            let norm = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
            guard norm.isFinite, norm > 0 else { return nil }
            columns.append(v.map { $0 / norm })
        }
        return columns
    }

    /// Determinant of the matrix whose columns are `c`: the triple product c0 · (c1 × c2).
    private static func determinant(_ c: [[Double]]) -> Double {
        let cross = [
            c[1][1] * c[2][2] - c[1][2] * c[2][1],
            c[1][2] * c[2][0] - c[1][0] * c[2][2],
            c[1][0] * c[2][1] - c[1][1] * c[2][0]
        ]
        return c[0][0] * cross[0] + c[0][1] * cross[1] + c[0][2] * cross[2]
    }
}
