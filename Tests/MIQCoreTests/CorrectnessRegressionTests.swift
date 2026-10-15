import Foundation
import Testing
@testable import MIQCore

/// Regression tests for review findings on world geometry (MGH `c_ras`, MIF
/// `transform:`), DEC colours for oblique FSL vectors, DICOM MONOCHROME1 and
/// per-frame rescale, modality-aware CT detection, and label-table colour scale.
struct CorrectnessRegressionTests {
    // MARK: - MGH c_ras

    /// 4³ uchar MGH with LIA cosines, voxel size `spacing` and c_ras = (10, 20, 30).
    static func mghBytes(spacing: Float = 1) -> Data {
        var b = [UInt8](repeating: 0, count: 284 + 64)
        func be32(_ v: Int32, _ o: Int) {
            let u = UInt32(bitPattern: v)
            for i in 0..<4 { b[o + i] = UInt8((u >> (24 - 8 * UInt32(i))) & 0xFF) }
        }
        func beF(_ v: Float, _ o: Int) { be32(Int32(bitPattern: v.bitPattern), o) }
        be32(1, 0); be32(4, 4); be32(4, 8); be32(4, 12); be32(1, 16); be32(0, 20)
        b[28] = 0; b[29] = 1
        beF(spacing, 30); beF(spacing, 34); beF(spacing, 38)
        // x_ras = (-1,0,0), y_ras = (0,0,-1), z_ras = (0,1,0)  (LIA)
        let cos: [Float] = [-1, 0, 0, 0, 0, -1, 0, 1, 0]
        for (i, c) in cos.enumerated() { beF(c, 42 + i * 4) }
        beF(10, 78); beF(20, 82); beF(30, 86)
        return Data(b)
    }

    @Test func mghCentreVoxelMapsToCras() throws {
        for spacing: Float in [1, 2] {
            let image = try MIQParser().parseMgh(Self.mghBytes(spacing: spacing))
            let volume = MIQVolume(image: image)
            let centre = volume.voxelToWorld.apply(2, 2, 2)
            #expect(abs(centre.x - 10) < 1e-5 && abs(centre.y - 20) < 1e-5 && abs(centre.z - 30) < 1e-5)
            // FreeSurfer vox2ras: P0 = c_ras − Mdc·diag(spacing)·(dim/2).
            let s = Double(spacing)
            let origin = volume.voxelToWorld.apply(0, 0, 0)
            #expect(abs(origin.x - (10 + 2 * s)) < 1e-5)
            #expect(abs(origin.y - (20 - 2 * s)) < 1e-5)
            #expect(abs(origin.z - (30 + 2 * s)) < 1e-5)
            // Display orientation is unchanged by the origin.
            #expect(image.header.orientationFrame?.axes.map(\.axis) == [.rightLeft, .superiorInferior, .anteriorPosterior])
            // The NIfTI export carries the same affine.
            let geometry = NiftiGeometry(volume: volume)
            #expect(abs(Double(geometry.srowX[3]) - origin.x) < 1e-4)
            #expect(abs(Double(geometry.srowY[3]) - origin.y) < 1e-4)
            #expect(abs(Double(geometry.srowZ[3]) - origin.z) < 1e-4)
        }
    }

    // MARK: - MIF transform

    static func mif(layout: String, transform: [String]?) throws -> MIQImage {
        let payload = [UInt8](0..<24)
        var offset = 0
        var header = ""
        while true {
            header = "mrtrix image\ndim: 2,3,4\nvox: 1,2,3\nlayout: \(layout)\ndatatype: UInt8\n"
            for row in transform ?? [] { header += "transform: \(row)\n" }
            header += "file: . \(offset)\nEND\n"
            if header.utf8.count == offset { break }
            offset = header.utf8.count
        }
        return try MIQParser().parseMif(Data(header.utf8) + Data(payload))
    }

    @Test func mifTransformReachesVoxelToWorld() throws {
        // 90° about S plus a translation; image axis 0 stored reversed.
        let image = try Self.mif(layout: "-0,+1,+2", transform: ["0,-1,0,10", "1,0,0,20", "0,0,1,30"])
        let volume = MIQVolume(image: image)
        let a = volume.voxelToWorld
        // Logical (0,0,0) is image (1,0,0): 1 mm along image x → world +A.
        let p0 = a.apply(0, 0, 0)
        #expect(abs(p0.x - 10) < 1e-5 && abs(p0.y - 21) < 1e-5 && abs(p0.z - 30) < 1e-5)
        // Logical (1,2,3) is image (0,2,3): mm (0,4,9) → R·mm + t = (6,20,39).
        let p1 = a.apply(1, 2, 3)
        #expect(abs(p1.x - 6) < 1e-5 && abs(p1.y - 20) < 1e-5 && abs(p1.z - 39) < 1e-5)
        // The affine's orientation agrees with the (unchanged) display frame.
        let h = image.header
        let fromRows = OrientationFrame.from(srowX: h.srowX, srowY: h.srowY, srowZ: h.srowZ, source: .mifLayout)
        #expect(fromRows?.axes == h.orientationFrame?.axes)
        #expect(h.sformCode == 0)
    }

    @Test func mifWithoutTransformIsIdentityAtOrigin() throws {
        let image = try Self.mif(layout: "+0,+1,+2", transform: nil)
        let a = MIQVolume(image: image).voxelToWorld
        let p = a.apply(1, 1, 1)
        #expect(abs(p.x - 1) < 1e-5 && abs(p.y - 2) < 1e-5 && abs(p.z - 3) < 1e-5)
    }

    // MARK: - DEC

    @Test func decObliqueFslVectorUndoesXFlip() {
        // 30° about S, det > 0. True direction (1,1,0)/√2 in voxel axes; FSL stores
        // it with x negated.
        let c = Float(cos(Double.pi / 6)), s = Float(sin(Double.pi / 6))
        let srow: [[Float]] = [[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0]]
        let v = 1 / Float(2).squareRoot()
        let volume = ModalityFixtures.floatVolume(
            width: 1, height: 1, depth: 1, volumes: 3, srow: srow, values: [-v, v, 0]
        )
        let rgb = DiffusionColor.color(components: volume, x: 0, y: 0, z: 0)
        #expect(rgb.r == 66 && rgb.g == 246 && rgb.b == 0)
        // Already-world vectors are not flipped.
        let world = DiffusionColor.color(components: volume, x: 0, y: 0, z: 0, frame: .world)
        #expect(world.r == 180 && world.g == 180)
    }

    // MARK: - DICOM

    static func monochrome(_ photometric: String, modality: String? = nil) -> Data {
        var b = DICOMTestBuilder()
        if let modality { b.string(0x0008, 0x0060, vr: "CS", modality) }
        b.string(0x0028, 0x0004, vr: "CS", photometric)
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 12)
        b.us(0x0028, 0x0103, 0)
        b.string(0x0028, 0x1052, vr: "DS", "0")
        b.string(0x0028, 0x1053, vr: "DS", "1")
        b.element(0x7FE0, 0x0010, vr: "OW", DICOMTestBuilder.uint16Pixels([100, 4000]))
        return b.part10(transferSyntax: DICOMTestBuilder.explicitLE)
    }

    @Test func monochrome1KeepsTrueValuesAndInvertsDisplay() throws {
        let (image, info) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME1"))
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 100)
        #expect(volume.voxel(x: 1, y: 0, z: 0) == 4000)
        #expect(info.rescaleSlope == 1 && image.header.sclSlope == 1)
        #expect(image.header.invertsDisplay)

        let bounds = MIQIntensityWindowBounds(low: 100, high: 4000)
        let options = RenderingOptions(lowerPercentile: 0, upperPercentile: 100)
        let inverted = volume.slice(plane: .axial, index: 0, maxDimension: 2, options: options, windowBounds: bounds)
        let (plainImage, _) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME2"))
        #expect(!plainImage.header.invertsDisplay)
        let plain = MIQVolume(image: plainImage).slice(plane: .axial, index: 0, maxDimension: 2, options: options, windowBounds: bounds)
        #expect(Set(plain.pixels) == [0, 255])
        #expect(inverted.pixels == plain.pixels.map { 255 - $0 })
        // Percentile (auto) windowing is inverted the same way.
        let autoInverted = volume.slice(plane: .axial, index: 0, maxDimension: 2, options: options)
        let autoPlain = MIQVolume(image: plainImage).slice(plane: .axial, index: 0, maxDimension: 2, options: options)
        #expect(autoInverted.pixels == autoPlain.pixels.map { 255 - $0 })
    }

    @Test func enhancedMultiFrameUsesPerFrameRescale() throws {
        func frameItem(_ z: Double, slope: String) -> Data {
            var pos = DICOMTestBuilder(); pos.string(0x0020, 0x0032, vr: "DS", "0\\0\\\(z)")
            var tr = DICOMTestBuilder(); tr.string(0x0028, 0x1052, vr: "DS", "0"); tr.string(0x0028, 0x1053, vr: "DS", slope)
            var fg = DICOMTestBuilder()
            fg.sequence(0x0020, 0x9113, items: [pos.bytes])
            fg.sequence(0x0028, 0x9145, items: [tr.bytes])
            return fg.bytes
        }
        func file(slopes: [String]) -> Data {
            var orient = DICOMTestBuilder(); orient.string(0x0020, 0x0037, vr: "DS", "1\\0\\0\\0\\1\\0")
            var shared = DICOMTestBuilder(); shared.sequence(0x0020, 0x9116, items: [orient.bytes])
            var b = DICOMTestBuilder()
            b.string(0x0028, 0x0004, vr: "CS", "MONOCHROME2")
            b.string(0x0028, 0x0008, vr: "IS", "2")
            b.us(0x0028, 0x0010, 1); b.us(0x0028, 0x0011, 1); b.us(0x0028, 0x0100, 8)
            b.sequence(0x5200, 0x9229, items: [shared.bytes])
            b.sequence(0x5200, 0x9230, items: [frameItem(0, slope: slopes[0]), frameItem(2, slope: slopes[1])])
            b.element(0x7FE0, 0x0010, vr: "OB", Data([5, 5]))
            return b.part10(transferSyntax: DICOMTestBuilder.explicitLE)
        }

        let (image, _) = try MIQParser().decodeDicom(file(slopes: ["1", "10"]))
        let volume = MIQVolume(image: image)
        #expect(image.header.datatype == .float32)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 5)
        #expect(volume.voxel(x: 0, y: 0, z: 1) == 50)

        // Uniform per-frame rescale keeps the zero-copy integer path.
        let (uniform, _) = try MIQParser().decodeDicom(file(slopes: ["10", "10"]))
        #expect(uniform.header.datatype == .uint8)
        #expect(MIQVolume(image: uniform).voxel(x: 0, y: 0, z: 1) == 50)
    }

    // MARK: - CT detection

    @Test func looksLikeCTFollowsDicomModality() throws {
        // Values 100/4000 with identity rescale: the heuristic alone says "not CT".
        let (ct, _) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME2", modality: "CT"))
        #expect(ct.header.modality == "CT")
        #expect(WindowPreset.looksLikeCT(header: ct.header, sampleMin: 100))
        // An MR that bottoms out at -1024 would fool the heuristic; the modality wins.
        let (mr, _) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME2", modality: "MR"))
        #expect(!WindowPreset.looksLikeCT(header: mr.header, sampleMin: -1024))
        let (pt, _) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME2", modality: "PT"))
        #expect(!WindowPreset.looksLikeCT(header: pt.header, sampleMin: -1024))
        // No modality: heuristic as before.
        let (none, _) = try MIQParser().decodeDicom(Self.monochrome("MONOCHROME2"))
        #expect(none.header.modality == nil)
        #expect(WindowPreset.looksLikeCT(header: none.header, sampleMin: -1024))
    }

    // MARK: - Label table colour scale

    @Test func labelTableColourScaleIsDecidedPerTable() {
        let xml = """
        <LabelTable>
        <Label Key="1" Red="200" Green="100" Blue="0"><![CDATA[bright]]></Label>
        <Label Key="2" Red="1" Green="0" Blue="1"><![CDATA[dark]]></Label>
        </LabelTable>
        """
        let table = SegmentationLut.parseLabelTableXML(xml)
        #expect(table[2]?.packedRGB == SegmentationLut.pack(1, 0, 1))
        #expect(table[1]?.packedRGB == SegmentationLut.pack(200, 100, 0))

        let unit = SegmentationLut.parseLabelTableXML("""
        <Label Key="3" Red="1" Green="0.5" Blue="0">a</Label>
        <Label Key="4" Red="0" Green="0" Blue="1">b</Label>
        """)
        #expect(unit[3]?.packedRGB == SegmentationLut.pack(255, 128, 0))
        #expect(unit[4]?.packedRGB == SegmentationLut.pack(0, 0, 255))
    }
}
