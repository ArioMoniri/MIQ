import Foundation
import Testing
@testable import MIQCore

/// Synthetic phantoms for the model-free data-QC features (`Sources/MIQCore/QC`).
enum QCPhantom {
    /// RAS+ storage: x → R, y → A, z → S.
    static let rasFrame = OrientationFrame(
        axes: [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true),
        ],
        source: .sform
    )

    /// Deterministic standard-normal generator (LCG + Box–Muller).
    struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func normal() -> Double {
            let u1 = uniform(), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    static func image(
        dims: [Int],
        spacing: Float,
        datatype: MIQDatatype,
        frame: OrientationFrame?,
        value: (Int, Int, Int, Int) -> Float
    ) -> MIQVolume {
        let w = dims[0], h = dims[1], d = dims[2], t = dims.count > 3 ? dims[3] : 1
        let bpv = datatype.bytesPerVoxel
        var data = Data(count: w * h * d * t * bpv)
        data.withUnsafeMutableBytes { raw in
            var o = 0
            for tt in 0..<t {
                for z in 0..<d {
                    for y in 0..<h {
                        for x in 0..<w {
                            let v = value(x, y, z, tt)
                            switch datatype {
                            case .float32: raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                            case .int16: raw.storeBytes(of: Int16(v).littleEndian, toByteOffset: o, as: Int16.self)
                            case .uint8: raw.storeBytes(of: UInt8(max(0, min(255, v))), toByteOffset: o, as: UInt8.self)
                            default: fatalError("unsupported phantom datatype")
                            }
                            o += bpv
                        }
                    }
                }
            }
        }
        let header = MIQHeader(
            littleEndian: true,
            dimensions: t > 1 ? [w, h, d, t] : [w, h, d],
            pixdim: [1, spacing, spacing, spacing, 1],
            datatype: datatype,
            voxOffset: 0,
            sclSlope: 0,
            sclInter: 0,
            qformCode: 0,
            sformCode: frame == nil ? 0 : 1,
            srowX: [spacing, 0, 0, 0],
            srowY: [0, spacing, 0, 0],
            srowZ: [0, 0, spacing, 0],
            orientationFrame: frame
        )
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }

    enum Face { case present, defaced }

    /// 128³ at 2 mm: an ellipsoid "head" (radii R 75, A 90, S 110 mm) centred 8 mm below
    /// the FOV centre, with a scalp shell (300), "GM" (400) and a "WM" core (600), plus
    /// Gaussian noise (σ 10) inside and Rayleigh-like |noise| outside.
    static func head(
        face: Face = .present,
        frame: OrientationFrame? = rasFrame,
        zeroBackground: Bool = false,
        backgroundArtifact: Bool = false
    ) -> MIQVolume {
        let n = 128, sp: Float = 2
        var noise = Noise(state: 42)
        return image(dims: [n, n, n], spacing: sp, datatype: .float32, frame: frame) { x, y, z, _ in
            let r = (Double(x) - 64) * 2, a = (Double(y) - 64) * 2, s = (Double(z) - 60) * 2
            let e = (r / 75) * (r / 75) + (a / 90) * (a / 90) + (s / 110) * (s / 110)
            var inside = e <= 1
            var level = 0.0
            if inside {
                level = e > 0.85 ? 300 : (e > 0.35 ? 400 : 600)
            }
            switch face {
            case .present:
                // Midline nose/maxilla protrusion in front of the ellipsoid.
                if abs(r) < 16 && a > 70 && a < 104 && s > -45 && s < 0 {
                    inside = true
                    level = 300
                }
            case .defaced:
                // Planar defacing cut: nothing anterior to A = 30 mm below S = 20 mm.
                if a > 30 && s < 20 {
                    inside = false
                }
            }
            if inside {
                return Float(level + 10 * noise.normal())
            }
            if backgroundArtifact && x < 40 && y < 40 && z > 96 {
                return Float(150 + 10 * noise.normal())
            }
            return zeroBackground ? 0 : Float(abs(10 * noise.normal()))
        }
    }
}

struct QCHeadMaskTests {
    @Test
    func ellipsoidMaskVolumeMatchesGeometry() throws {
        let volume = QCPhantom.head(face: .defaced)
        let mask = try #require(try QCHeadMask.compute(volume: volume))
        #expect(mask.width == 64 && mask.height == 64 && mask.depth == 64)
        #expect(mask.stepX == 2 && mask.stepY == 2 && mask.stepZ == 2)
        // Ellipsoid minus the defacing wedge; full ellipsoid = 4/3·π·75·90·110 mm³ ≈ 3 110 mL.
        #expect(mask.volumeMilliliters > 2_300 && mask.volumeMilliliters < 3_200)
        // Interior (dark-free here, but hole filling must keep the core) and air.
        #expect(mask.containsSourceVoxel(x: 64, y: 64, z: 60))
        #expect(!mask.containsSourceVoxel(x: 2, y: 2, z: 2))
        #expect(mask.volumeDisplayText.hasPrefix("Head mask: "))
        #expect(mask.volumeDisplayText.hasSuffix(" mL"))
    }

    @Test
    func holeFillingAndLargestComponent() throws {
        // A sphere with a dark interior cavity, plus a disconnected bright speck.
        let volume = QCPhantom.image(dims: [48, 48, 48], spacing: 1, datatype: .float32, frame: nil) { x, y, z, _ in
            let dx = Double(x) - 24, dy = Double(y) - 24, dz = Double(z) - 24
            let r = (dx * dx + dy * dy + dz * dz).squareRoot()
            if r < 6 { return 0 }          // cavity (e.g. ventricle-like dark region)
            if r < 18 { return 500 }
            if x == 2 && y == 2 && z == 2 { return 500 } // isolated speck
            return 0
        }
        let mask = try #require(try QCHeadMask.compute(volume: volume))
        #expect(mask.stepX == 1)
        #expect(mask.contains(x: 24, y: 24, z: 24), "cavity filled")
        #expect(!mask.contains(x: 2, y: 2, z: 2), "speck removed")
        // 4/3·π·18³ ≈ 24.4 mL at 1 mm.
        #expect(abs(mask.volumeMilliliters - 24.4) < 3)
    }

    @Test
    func constantVolumeHasNoMask() throws {
        let volume = QCPhantom.image(dims: [8, 8, 8], spacing: 1, datatype: .float32, frame: nil) { _, _, _, _ in 7 }
        #expect(try QCHeadMask.compute(volume: volume) == nil)
    }

    @Test
    func groupedVolumeFormatting() {
        #expect(QCFormat.groupedInteger(1520.4) == "1 520")
        #expect(QCFormat.groupedInteger(999) == "999")
        #expect(QCFormat.groupedInteger(1_234_567) == "1 234 567")
    }

    @Test
    func maskOn256CubeIsFast() throws {
        let n = 256
        let volume = QCPhantom.image(dims: [n, n, n], spacing: 1, datatype: .uint8, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x - 128) / 80, dy = Float(y - 128) / 95, dz = Float(z - 120) / 110
            return dx * dx + dy * dy + dz * dz <= 1 ? 180 : Float((x &* 7 &+ y &* 13 &+ z &* 3) % 5)
        }
        let clock = ContinuousClock()
        var mask: QCHeadMask?
        let elapsed = try clock.measure { mask = try QCHeadMask.compute(volume: volume) }
        let m = try #require(mask)
        #expect(m.stepX == 4 && m.width == 64)
        // Loose regression guard only: debug builds on shared CI runners vary a lot.
        // The real budget (~150 ms release) is tracked by the printed timing.
        #expect(elapsed < .seconds(20), "head mask took \(elapsed)")
        let full = try clock.measure { _ = try QCAnalyzer.analyze(volume: volume, fileName: "sub-01_T1w.nii.gz") }
        #expect(full < .seconds(60), "full analysis took \(full)")
        print("QC timing 256³: mask \(elapsed), full analysis \(full)")
    }
}

struct QCMetricsTests {
    @Test
    func phantomMetricsAreInPlausibleRanges() throws {
        let summary = try QCAnalyzer.analyze(volume: QCPhantom.head(), fileName: "sub-01_T1w.nii.gz")
        #expect(summary.contentKind == .anatomical)
        let r = summary.report
        #expect(r.isAssessed)
        let snr = try #require(r.metric(.snr)?.value)
        #expect(snr > 1 && snr < 20)
        let snrD = try #require(r.metric(.snrDietrich)?.value)
        #expect(snrD > 20) // fg mean ~400 vs air σ ~6
        let cnr = try #require(r.metric(.cnr)?.value)
        #expect(cnr > 3)
        let cjv = try #require(r.metric(.cjv)?.value)
        #expect(cjv > 0 && cjv < 0.5)
        let efc = try #require(r.metric(.efc)?.value)
        #expect(efc > 0 && efc < 1)
        let fber = try #require(r.metric(.fber)?.value)
        #expect(fber > 100)
        let bg = try #require(r.metric(.backgroundArtifacts)?.value)
        #expect(bg < 0.01)
        #expect(r.metric(.backgroundArtifacts)?.level == .typical)
        #expect(r.metric(.cnr)?.level == .typical)
        #expect(summary.metricLines.count == QCMetricID.allCases.count)
    }

    @Test
    func backgroundArtifactIsFlagged() throws {
        let clean = try QCAnalyzer.analyze(volume: QCPhantom.head())
        let ghost = try QCAnalyzer.analyze(volume: QCPhantom.head(backgroundArtifact: true))
        let a = try #require(clean.report.metric(.backgroundArtifacts)?.value)
        let b = try #require(ghost.report.metric(.backgroundArtifacts)?.value)
        #expect(b > a)
        #expect(b > 0.02)
        #expect(ghost.report.metric(.backgroundArtifacts)?.level != .typical)
        #expect(ghost.report.overallLevel != .typical)
    }

    @Test
    func zeroFilledBackgroundSkipsAirMetrics() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(zeroBackground: true))
        #expect(s.report.metric(.snrDietrich)?.value == nil)
        #expect(s.report.metric(.snrDietrich)?.level == .notAssessed)
        #expect(s.report.metric(.fber)?.value == nil)
        #expect(s.report.metric(.snr)?.value != nil)
        #expect(s.report.note?.contains("zero-filled") == true)
    }

    @Test
    func entropyFocusCriterionBounds() throws {
        // Uniform image → maximal entropy → EFC 1. A single bright voxel → EFC 0.
        let uniform = try #require(QCMetricsCalculator.entropyFocusCriterion([Float](repeating: 5, count: 1000)))
        #expect(abs(uniform - 1) < 1e-9)
        var spike = [Float](repeating: 0, count: 1000)
        spike[10] = 100
        let focused = try #require(QCMetricsCalculator.entropyFocusCriterion(spike))
        #expect(abs(focused) < 1e-9)
        #expect(QCMetricsCalculator.entropyFocusCriterion([Float](repeating: 0, count: 10)) == nil)
    }

    @Test
    func otsuSplitsBimodalValues() throws {
        let values: [Float] = Array(repeating: 10, count: 500) + Array(repeating: 200, count: 300)
        let t = try #require(QCStats.otsuThreshold(values, low: 0, high: 255))
        #expect(t > 10 && t <= 200)
    }

    @Test
    func kMeansOrdersClassesDarkToBright() throws {
        var noise = QCPhantom.Noise(state: 7)
        var values: [Float] = []
        for c in [100.0, 400.0, 700.0] {
            for _ in 0..<500 { values.append(Float(c + 15 * noise.normal())) }
        }
        let classes = try #require(QCMetricsCalculator.kMeans3(values.shuffled()))
        #expect(abs(classes[0].mean - 100) < 10)
        #expect(abs(classes[1].mean - 400) < 10)
        #expect(abs(classes[2].mean - 700) < 10)
    }

    @Test
    func levelsAreConservativeAndDirectional() {
        typealias C = QCMetricsCalculator
        #expect(C.levelHigherIsBetter(10, C.Thresholds.snr) == .typical)
        #expect(C.levelHigherIsBetter(1.5, C.Thresholds.snr) == .borderline)
        #expect(C.levelHigherIsBetter(0.5, C.Thresholds.snr) == .atypical)
        #expect(C.levelLowerIsBetter(0.3, C.Thresholds.cjv) == .typical)
        #expect(C.levelLowerIsBetter(2, C.Thresholds.cjv) == .atypical)
        #expect(C.levelLowerIsBetter(nil, C.Thresholds.cjv) == .notAssessed)
        #expect(C.levelLowerIsBetter(.nan, C.Thresholds.cjv) == .notAssessed)
    }
}

struct QCFaceCheckTests {
    @Test
    func intactFaceIsLikelyPresent() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(face: .present))
        #expect(s.faceCheck.presence == .facePresentLikely, "\(s.faceCheck)")
        #expect(s.faceCheck.confidence > 0.5 && s.faceCheck.confidence < 1)
        #expect(s.displayLines.contains { $0.text == "Face: Likely present (heuristic)" })
    }

    @Test
    func defacedHeadIsLikelyDefaced() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(face: .defaced))
        #expect(s.faceCheck.presence == .defacedLikely, "\(s.faceCheck)")
        #expect(s.faceCheck.confidence > 0.5 && s.faceCheck.confidence < 1)
        #expect((s.faceCheck.anteriorProtrusion ?? 0) < -0.12)
    }

    @Test
    func flippedStorageAxesStillWork() throws {
        // Same intact phantom stored with A and S axes reversed (LPI-ish frame): build the
        // volume by mirroring y and z and declare those axes negative.
        let source = QCPhantom.head(face: .defaced)
        let frame = OrientationFrame(
            axes: [
                StorageAxisOrientation(axis: .rightLeft, positive: true),
                StorageAxisOrientation(axis: .anteriorPosterior, positive: false),
                StorageAxisOrientation(axis: .superiorInferior, positive: false),
            ],
            source: .sform
        )
        let mirrored = QCPhantom.image(dims: [128, 128, 128], spacing: 2, datatype: .float32, frame: frame) { x, y, z, _ in
            source.voxel(x: x, y: 127 - y, z: 127 - z)
        }
        let s = try QCAnalyzer.analyze(volume: mirrored)
        #expect(s.faceCheck.presence == .defacedLikely, "\(s.faceCheck)")
    }

    @Test
    func unknownOrientationGivesUnknown() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(face: .present, frame: nil))
        #expect(s.faceCheck.presence == .unknown)
        #expect(s.faceCheck.reason == "Orientation unknown")
        #expect(!s.displayLines.contains { $0.label == "Face" })
    }

    @Test
    func nonHeadSizedForegroundGivesUnknown() throws {
        let tiny = QCPhantom.image(dims: [32, 32, 32], spacing: 1, datatype: .float32, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x - 16), dy = Float(y - 16), dz = Float(z - 16)
            return dx * dx + dy * dy + dz * dz < 100 ? 500 : 0
        }
        let s = try QCAnalyzer.analyze(volume: tiny)
        #expect(s.faceCheck.presence == .unknown)
    }
}

struct QCSequenceGuessTests {
    @Test(arguments: [
        ("sub-01_T1w.nii.gz", "T1w"),
        ("sub-01_ses-02_acq-mprage_T1w.nii", "T1w"),
        ("sub-01_T2w.nii.gz", "T2w"),
        ("sub-01_FLAIR.nii.gz", "FLAIR"),
        ("sub-01_dir-AP_dwi.nii.gz", "DWI"),
        ("sub-01_task-rest_bold.nii.gz", "BOLD"),
        ("sub-01_T2starw.nii.gz", "T2*w"),
        ("sub-01_PDw.nii.gz", "PDw"),
        ("sub-01_angio.nii.gz", "Angio"),
        ("sub-01_swi.nii.gz", "SWI"),
        ("sub-01_desc-brain_mask.nii.gz", "Mask"),
        ("sub-01_desc-aseg_dseg.nii.gz", "Segmentation"),
        ("sub-01_label-GM_probseg.nii.gz", "Probabilistic segmentation"),
        ("sub-01_ct.nii.gz", "CT"),
        ("/data/bids/sub-01/anat/sub-01_T1w.mif.gz", "T1w"),
    ])
    func bidsSuffix(name: String, label: String) throws {
        let g = try #require(QCSequenceGuesser.guess(fileName: name))
        #expect(g.label == label)
        #expect(g.source == .filename)
        #expect(g.confidence >= 0.9)
    }

    @Test
    func freeSurferAndLooseTokens() throws {
        #expect(QCSequenceGuesser.guess(fileName: "aparc+aseg.mgz")?.label == "Segmentation")
        #expect(QCSequenceGuesser.guess(fileName: "orig.mgz")?.label == "T1w")
        let loose = try #require(QCSequenceGuesser.guess(fileName: "patient_3D_FLAIR_sag.nii"))
        #expect(loose.label == "FLAIR")
        #expect(loose.confidence == 0.5)
        #expect(QCSequenceGuesser.guess(fileName: "t2_flair.nii.gz")?.label == "FLAIR")
        #expect(QCSequenceGuesser.guess(fileName: "scan.nii.gz") == nil)
    }

    @Test
    func displayTextIsNeutral() {
        let g = QCSequenceGuess(label: "FLAIR", source: .filename, confidence: 0.9)
        #expect(g.displayText == "Likely sequence: FLAIR (heuristic)")
    }

    @Test
    func headerHintsAndPrecedence() throws {
        let intent = try #require(QCSequenceGuesser.guess(fileName: "scan.nii", volumes: 1, intentCode: 1002))
        #expect(intent.label == "Segmentation" && intent.source == .header)
        let desc = try #require(QCSequenceGuesser.guess(fileName: nil, volumes: 1, descrip: "MPRAGE 1mm iso"))
        #expect(desc.label == "T1w" && desc.source == .header)
        // A BIDS suffix outranks intensity evidence.
        let bids = QCSequenceGuesser.guess(fileName: "x_T1w.nii", volumes: 1, evidence: QCIntensityEvidence(looksLikeCT: true))
        #expect(bids?.label == "T1w")
        // Intensity evidence outranks a loose token.
        let ct = QCSequenceGuesser.guess(fileName: "head_t1.nii", volumes: 1, evidence: QCIntensityEvidence(looksLikeCT: true))
        #expect(ct?.label == "CT" && ct?.source == .intensity)
    }

    @Test
    func dimensionRules() {
        let dwi = QCSequenceGuesser.guess(fileName: nil, volumes: 33, evidence: QCIntensityEvidence(volumeMeanVariation: 0.4))
        #expect(dwi?.label == "DWI" && dwi?.source == .dimensions)
        let bold = QCSequenceGuesser.guess(fileName: nil, volumes: 200, evidence: QCIntensityEvidence(volumeMeanVariation: 0.01))
        #expect(bold?.label == "BOLD")
        let other = QCSequenceGuesser.guess(fileName: nil, volumes: 3)
        #expect(other?.label == "4D series")
        #expect(QCSequenceGuesser.guess(fileName: nil, volumes: 1) == nil)
    }

    @Test
    func fourDVolumeMeanVariationFromData() throws {
        let dwi = QCPhantom.image(dims: [16, 16, 8, 10], spacing: 2, datatype: .float32, frame: nil) { x, _, _, t in
            (t == 0 ? 1000 : 300) + Float(x)
        }
        let s = try QCAnalyzer.analyze(volume: dwi)
        #expect(s.sequenceGuess?.label == "DWI")
        #expect(s.faceCheck.reason == "4D series")
        var noise = QCPhantom.Noise(state: 3)
        let bold = QCPhantom.image(dims: [16, 16, 8, 30], spacing: 3, datatype: .float32, frame: nil) { x, _, _, _ in
            500 + Float(x) + Float(noise.normal())
        }
        #expect(try QCAnalyzer.analyze(volume: bold).sequenceGuess?.label == "BOLD")
    }

    @Test
    func labelMapDetectedAndSkipped() throws {
        let seg = QCPhantom.image(dims: [40, 40, 40], spacing: 1, datatype: .int16, frame: QCPhantom.rasFrame) { x, y, z, _ in
            if x < 8 || y < 8 || z < 8 { return 0 }
            if x < 20 { return y < 20 ? 2 : 41 }
            return z < 20 ? 3 : 42
        }
        let s = try QCAnalyzer.analyze(volume: seg, fileName: "labels_volume.nii.gz")
        #expect(s.contentKind == .labelMap)
        #expect(s.sequenceGuess?.label == "Segmentation")
        #expect(!s.report.isAssessed)
        #expect(s.headMask == nil)
        #expect(!s.displayLines.contains { $0.label == "Head mask" })

        let binary = QCPhantom.image(dims: [20, 20, 20], spacing: 1, datatype: .uint8, frame: nil) { x, _, _, _ in x > 10 ? 1 : 0 }
        let b = try QCAnalyzer.analyze(volume: binary, fileName: "thing.nii")
        #expect(b.contentKind == .labelMap)
        #expect(b.sequenceGuess?.label == "Mask")
        #expect(b.sequenceGuess?.source == .intensity)
    }

    @Test
    func noisyUInt8MRIIsNotALabelMap() throws {
        var noise = QCPhantom.Noise(state: 11)
        let v = QCPhantom.image(dims: [40, 40, 40], spacing: 1, datatype: .uint8, frame: nil) { x, y, z, _ in
            let inside = abs(x - 20) < 14 && abs(y - 20) < 14 && abs(z - 20) < 14
            return Float((inside ? 150 : 5) + 12 * noise.normal()).rounded()
        }
        let s = try QCAnalyzer.analyze(volume: v)
        #expect(s.contentKind == .anatomical)
    }

    @Test
    func ctDetectedFromHounsfieldRange() throws {
        let ct = QCPhantom.image(dims: [48, 48, 48], spacing: 1, datatype: .int16, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x - 24), dy = Float(y - 24), dz = Float(z - 24)
            let r = (dx * dx + dy * dy + dz * dz).squareRoot()
            if r < 16 { return 40 + Float((x + y + z) % 7) }
            if r < 19 { return 1200 }
            return -1000 - Float((x * y) % 20)
        }
        let s = try QCAnalyzer.analyze(volume: ct, fileName: "head.nii.gz")
        #expect(s.contentKind == .ct)
        #expect(s.sequenceGuess?.label == "CT")
        #expect(s.sequenceGuess?.source == .intensity)
        #expect(!s.report.isAssessed)
        #expect(s.report.metrics.allSatisfy { $0.level == .notAssessed })
        #expect(s.headMask != nil)
    }

    /// e2e regression: CT whose air is exactly −1024 (no noise outside the body, as
    /// scanners write padding / reconstructions often clamp) was called a label map,
    /// because the identical −1024 neighbour pairs swamped the equal-pair evidence.
    static func noiseFreeAirCT(tissueNoise: Bool) -> MIQVolume {
        var noise = QCPhantom.Noise(state: 7)
        return QCPhantom.image(dims: [48, 48, 48], spacing: 1, datatype: .int16, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x - 24), dy = Float(y - 24), dz = Float(z - 24)
            let r = (dx * dx + dy * dy + dz * dz).squareRoot()
            let hu: Float = r < 16 ? 30 : (r < 19 ? 1000 : -1024)
            guard tissueNoise, hu > -1000 else { return hu }
            return (hu + Float(5 * noise.normal())).rounded()
        }
    }

    @Test
    func ctWithNoiseFreeAirIsNotALabelMap() throws {
        let noisy = Self.noiseFreeAirCT(tissueNoise: true)
        let grid = try #require(try QCGrid.sample(volume: noisy, volumeIndex: 0, maxDimension: 48))
        // The background (mode) pairs no longer count as label-map evidence.
        #expect(!QCContentClassifier.labelMapEvidence(grid: grid, datatype: .int16).isLabel)
        let s = try QCAnalyzer.analyze(volume: noisy, fileName: "ct.nii.gz")
        #expect(s.contentKind == .ct)
        #expect(s.sequenceGuess?.label == "CT")

        // Fully piecewise-constant synthetic CT: the HU signature wins over label evidence.
        let flat = try QCAnalyzer.analyze(volume: Self.noiseFreeAirCT(tissueNoise: false), fileName: "ct.nii.gz")
        #expect(flat.contentKind == .ct)
    }

    @Test
    func labelMapWithNonZeroBackgroundStillDetected() throws {
        // Background stored as 2 (most frequent), blocky labels inside.
        let v = QCPhantom.image(dims: [32, 32, 32], spacing: 1, datatype: .int16, frame: nil) { x, y, z, _ in
            guard (4..<28).contains(x), (4..<28).contains(y), (4..<28).contains(z) else { return 2 }
            return Float(10 + (x / 8) + 3 * (y / 8))
        }
        let grid = try #require(try QCGrid.sample(volume: v, volumeIndex: 0, maxDimension: 32))
        #expect(QCContentClassifier.labelMapEvidence(grid: grid, datatype: .int16).isLabel)
    }
}

struct QCAnalyzerTests {
    @Test
    func displayLinesAreCompactAndNeutral() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(), fileName: "sub-01_FLAIR.nii.gz")
        let texts = s.displayLines.map(\.text)
        #expect(texts.contains("Likely sequence: FLAIR (heuristic)"))
        #expect(texts.contains { $0.hasPrefix("Head mask: ") && $0.hasSuffix(" mL") })
        #expect(texts.contains { $0.hasPrefix("Data QC: ") && $0.contains("heuristic") })
        #expect(s.displayLines.count <= 4)
        for text in texts + s.metricLines.map(\.text) {
            let lower = text.lowercased()
            for word in ["diagnos", "abnormal", "patholog", "lesion", "brain volume", "normal"] {
                #expect(!lower.contains(word), "\(text)")
            }
        }
    }

    @Test
    func colourDataIsNotAnalysed() throws {
        let header = MIQHeader(littleEndian: true, dimensions: [4, 4, 4], pixdim: [1, 1, 1, 1], datatype: .rgb24,
                               voxOffset: 0, sclSlope: 0, sclInter: 0, qformCode: 0, sformCode: 0,
                               srowX: [], srowY: [], srowZ: [])
        let v = MIQVolume(image: MIQImage(header: header, storage: Data(count: 4 * 4 * 4 * 3), payloadOffset: 0))
        let s = try QCAnalyzer.analyze(volume: v)
        #expect(s.contentKind == .colour)
        #expect(!s.report.isAssessed)
        #expect(s.displayLines.isEmpty)
    }

    @Test
    func cancelledTaskThrows() async {
        let volume = QCPhantom.head()
        let task = Task.detached { () throws -> QCSummary in
            withUnsafeCurrentTask { $0?.cancel() }
            return try QCAnalyzer.analyze(volume: volume)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test
    func optionsCanDisableStages() throws {
        let s = try QCAnalyzer.analyze(volume: QCPhantom.head(), options: QCOptions(computeMetrics: false, checkFace: false))
        #expect(!s.report.isAssessed)
        #expect(s.faceCheck.presence == .unknown)
        #expect(s.headMask != nil)
    }
}
