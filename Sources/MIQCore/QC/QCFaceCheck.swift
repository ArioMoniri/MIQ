import Foundation

/// Outcome of the face-present / defaced heuristic.
public enum QCFacePresence: String, Sendable, Hashable {
    /// Foreground mass extends into the anterior-inferior (face) region as for an intact head.
    case facePresentLikely
    /// The anterior-inferior region is missing mass compared with the forehead, as after
    /// defacing (or for skull-stripped / brain-only images).
    case defacedLikely
    /// Not determinable: unknown orientation, unsuitable field of view, non-head-sized mask,
    /// or an ambiguous measurement.
    case unknown
}

/// Heuristic face-region check. This is a privacy/data-handling aid only: it estimates whether
/// facial features are likely still present in the data, e.g. before sharing. It can be wrong
/// in both directions and must not be relied on as a de-identification guarantee.
public struct QCFaceCheck: Sendable, Hashable {
    public let presence: QCFacePresence
    /// 0…1, capped below 1 because this is a geometric heuristic.
    public let confidence: Double
    /// Short neutral explanation, mainly for `.unknown`.
    public let reason: String?
    /// Anterior extent of the face slab minus that of the forehead slab, as a fraction of the
    /// mask's anterior-posterior length (≈ 0 or positive for an intact face, clearly negative
    /// after a defacing cut). nil when not measured.
    public let anteriorProtrusion: Double?
    /// Anterior foreground per slice in the face slab / in the forehead slab. nil when not measured.
    public let anteriorMassRatio: Double?

    public init(presence: QCFacePresence, confidence: Double, reason: String?,
                anteriorProtrusion: Double? = nil, anteriorMassRatio: Double? = nil) {
        self.presence = presence
        self.confidence = confidence
        self.reason = reason
        self.anteriorProtrusion = anteriorProtrusion
        self.anteriorMassRatio = anteriorMassRatio
    }

    static func unknown(_ reason: String) -> QCFaceCheck {
        QCFaceCheck(presence: .unknown, confidence: 0, reason: reason)
    }

    public var displayText: String {
        switch presence {
        case .facePresentLikely: return "Face likely present (heuristic)"
        case .defacedLikely: return "Face likely removed (heuristic)"
        case .unknown: return "Face check: unknown"
        }
    }
}

enum QCFaceDetector {
    /// Slab bounds, as fractions of the head's anterior-posterior length L measured down from
    /// the top of the mask. With L ≈ 180–200 mm for adults, the forehead slab sits ~40–90 mm
    /// below the vertex (frontal bone in front of the frontal lobes) and the face slab
    /// ~105–165 mm below (orbits, nose, maxilla), which defacing tools remove.
    static let foreheadSlab = (top: 0.20, bottom: 0.45)
    static let faceSlab = (top: 0.55, bottom: 0.85)
    /// Lateral band (fraction of left-right width either side of centre) the extents are
    /// measured in, so the midline face (nose) dominates rather than ears or cheeks.
    static let lateralBand = 0.3
    /// Plausible adult/paediatric head A-P length (mm); outside this the mask is not a head.
    static let headLengthRange = 120.0...280.0

    static func detect(grid: QCGrid, mask: QCHeadMask, frame: OrientationFrame?) -> QCFaceCheck {
        guard let frame, frame.axes.count >= 3 else { return .unknown("Orientation unknown") }
        guard let rAxis = frame.axes.firstIndex(where: { $0.axis == .rightLeft }),
              let aAxis = frame.axes.firstIndex(where: { $0.axis == .anteriorPosterior }),
              let sAxis = frame.axes.firstIndex(where: { $0.axis == .superiorInferior }),
              rAxis < 3, aAxis < 3, sAxis < 3 else {
            return .unknown("Orientation unknown")
        }

        // Per-axis world coordinate (mm, +R / +A / +S) of each grid cell centre's sampled voxel.
        let steps = [grid.stepX, grid.stepY, grid.stepZ]
        let gdims = [grid.width, grid.height, grid.depth]
        let sdims = [grid.sourceWidth, grid.sourceHeight, grid.sourceDepth]
        let spacing = [grid.spacingX, grid.spacingY, grid.spacingZ]
        func coords(_ axis: Int) -> [Double] {
            let sign: Double = frame.axes[axis].positive ? 1 : -1
            return (0..<gdims[axis]).map {
                sign * Double(QCGrid.sourceCoordinate(cell: $0, step: steps[axis], sourceDim: sdims[axis])) * Double(spacing[axis])
            }
        }
        let axisCoords = [coords(0), coords(1), coords(2)]
        let rC = axisCoords[rAxis], aC = axisCoords[aAxis], sC = axisCoords[sAxis]

        var rMin = Double.infinity, rMax = -Double.infinity
        var aMin = Double.infinity, aMax = -Double.infinity
        var sMax = -Double.infinity
        forEachForeground(mask) { p in
            let r = rC[p[rAxis]], a = aC[p[aAxis]], s = sC[p[sAxis]]
            rMin = min(rMin, r); rMax = max(rMax, r)
            aMin = min(aMin, a); aMax = max(aMax, a)
            sMax = max(sMax, s)
        }
        let length = aMax - aMin
        guard length.isFinite, headLengthRange.contains(length) else {
            return .unknown("Foreground is not head-sized")
        }
        let fovSMin = sC.min() ?? 0
        guard fovSMin <= sMax - faceSlab.bottom * length else {
            return .unknown("Field of view does not cover the face region")
        }
        // A mask that runs into the top of the FOV has no reliable vertex reference.
        if sMax >= (sC.max() ?? sMax) {
            return .unknown("Head touches the top of the field of view")
        }

        let rCentre = (rMin + rMax) / 2
        let rHalfBand = (rMax - rMin) / 2 * lateralBand
        let anteriorCut = aMin + 0.6 * length
        var foreheadA: [Double] = [], faceA: [Double] = []
        var foreheadMass = 0, faceMass = 0
        forEachForeground(mask) { p in
            let r = rC[p[rAxis]]
            guard abs(r - rCentre) <= rHalfBand else { return }
            let depthBelowTop = (sMax - sC[p[sAxis]]) / length
            let a = aC[p[aAxis]]
            if depthBelowTop >= foreheadSlab.top && depthBelowTop < foreheadSlab.bottom {
                foreheadA.append(a)
                if a > anteriorCut { foreheadMass += 1 }
            } else if depthBelowTop >= faceSlab.top && depthBelowTop < faceSlab.bottom {
                faceA.append(a)
                if a > anteriorCut { faceMass += 1 }
            }
        }
        guard foreheadA.count >= 20, foreheadMass > 0 else {
            return .unknown("Forehead region not resolved")
        }

        // Normalise mass by slab thickness so the two slabs compare per unit height.
        let thicknessRatio = (foreheadSlab.bottom - foreheadSlab.top) / (faceSlab.bottom - faceSlab.top)
        let massRatio = Double(faceMass) / Double(foreheadMass) * thicknessRatio

        func p95(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))]
        }
        let foreheadFront = p95(foreheadA)
        // An empty face slab (mask ends above it) is the extreme defaced/brain-only case.
        let protrusion = faceA.isEmpty ? -1.0 : (p95(faceA) - foreheadFront) / length

        if protrusion >= -0.06 && massRatio >= 0.3 {
            let conf = min(0.9, 0.55 + (protrusion + 0.06) * 3 + min(massRatio, 1.5) * 0.1)
            return QCFaceCheck(presence: .facePresentLikely, confidence: conf, reason: nil,
                               anteriorProtrusion: protrusion, anteriorMassRatio: massRatio)
        }
        if protrusion <= -0.12 || massRatio < 0.15 {
            let conf = min(0.9, 0.55 + max(0, -0.12 - protrusion) * 2 + max(0, 0.15 - massRatio))
            return QCFaceCheck(presence: .defacedLikely, confidence: conf, reason: nil,
                               anteriorProtrusion: protrusion, anteriorMassRatio: massRatio)
        }
        return QCFaceCheck(presence: .unknown, confidence: 0.2, reason: "Ambiguous face-region extent",
                           anteriorProtrusion: protrusion, anteriorMassRatio: massRatio)
    }

    private static func forEachForeground(_ mask: QCHeadMask, _ body: ([Int]) -> Void) {
        var i = 0
        var p = [0, 0, 0]
        for z in 0..<mask.depth {
            p[2] = z
            for y in 0..<mask.height {
                p[1] = y
                for x in 0..<mask.width {
                    if mask.cells[i] != 0 {
                        p[0] = x
                        body(p)
                    }
                    i += 1
                }
            }
        }
    }
}
