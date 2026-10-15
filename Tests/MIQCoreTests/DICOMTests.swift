import Foundation
import Testing
@testable import MIQCore

// MARK: - Synthetic DICOM writer

/// Builds DICOM data sets byte by byte, so tests need no fixture files.
struct DICOMTestBuilder {
    static let explicitLE = "1.2.840.10008.1.2.1"
    static let implicitLE = "1.2.840.10008.1.2"

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV"]

    let explicit: Bool
    private(set) var bytes = Data()

    init(explicit: Bool = true) { self.explicit = explicit }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    /// Raw element. `length` overrides the encoded length (e.g. 0xFFFFFFFF).
    mutating func element(_ group: UInt16, _ elem: UInt16, vr: String, _ value: Data, length: UInt32? = nil) {
        bytes.append(Self.le16(group))
        bytes.append(Self.le16(elem))
        let len = length ?? UInt32(value.count)
        if explicit {
            bytes.append(contentsOf: Array(vr.utf8))
            if Self.longVRs.contains(vr) {
                bytes.append(contentsOf: [0, 0])
                bytes.append(Self.le32(len))
            } else {
                bytes.append(Self.le16(UInt16(len)))
            }
        } else {
            bytes.append(Self.le32(len))
        }
        bytes.append(value)
    }

    mutating func string(_ group: UInt16, _ elem: UInt16, vr: String, _ text: String) {
        var value = Data(text.utf8)
        if value.count % 2 == 1 { value.append(vr == "UI" ? 0 : 0x20) }
        element(group, elem, vr: vr, value)
    }

    mutating func us(_ group: UInt16, _ elem: UInt16, _ v: UInt16) {
        element(group, elem, vr: "US", Self.le16(v))
    }

    /// Sequence of pre-encoded item data sets.
    mutating func sequence(_ group: UInt16, _ elem: UInt16, items: [Data], undefinedLength: Bool = true, vr: String = "SQ") {
        var body = Data()
        for item in items {
            body.append(Self.le16(0xFFFE)); body.append(Self.le16(0xE000))
            if undefinedLength {
                body.append(Self.le32(0xFFFF_FFFF))
                body.append(item)
                body.append(Self.le16(0xFFFE)); body.append(Self.le16(0xE00D)); body.append(Self.le32(0))
            } else {
                body.append(Self.le32(UInt32(item.count)))
                body.append(item)
            }
        }
        if undefinedLength {
            body.append(Self.le16(0xFFFE)); body.append(Self.le16(0xE0DD)); body.append(Self.le32(0))
            element(group, elem, vr: vr, body, length: 0xFFFF_FFFF)
        } else {
            element(group, elem, vr: vr, body)
        }
    }

    /// Wraps the data set in a Part-10 file (preamble, DICM, group 0002).
    func part10(transferSyntax: String, preamble: Bool = true) -> Data {
        var file = Data()
        if preamble {
            file.append(Data(count: 128))
            file.append(contentsOf: Array("DICM".utf8))
        }
        var meta = DICOMTestBuilder(explicit: true)
        meta.element(0x0002, 0x0001, vr: "OB", Data([0, 1]))
        meta.string(0x0002, 0x0002, vr: "UI", "1.2.840.10008.5.1.4.1.1.2")
        meta.string(0x0002, 0x0010, vr: "UI", transferSyntax)
        file.append(meta.bytes)
        file.append(bytes)
        return file
    }

    static func int16Pixels(_ values: [Int16]) -> Data {
        var d = Data()
        for v in values { d.append(le16(UInt16(bitPattern: v))) }
        return d
    }

    static func uint16Pixels(_ values: [UInt16]) -> Data {
        var d = Data()
        for v in values { d.append(le16(v)) }
        return d
    }
}

// MARK: - Tests

struct DICOMTests {
    private static func tempURL(_ name: String = "img.dcm", in dir: URL? = nil) -> URL {
        let folder = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("miq-dicom-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    /// 4 columns × 3 rows signed 16-bit axial CT slice with a -1024 rescale intercept.
    private static func ctSlice(
        explicit: Bool = true,
        position: [Double]? = [-100, -120, 50],
        orientation: Bool = true,
        intercept: String = "-1024",
        pixels: [Int16] = [0, 1024, 2048, 3000, 0, 0, 0, 0, 0, 0, 0, 1024],
        seriesUID: String? = nil,
        extra: (inout DICOMTestBuilder) -> Void = { _ in }
    ) -> DICOMTestBuilder {
        var b = DICOMTestBuilder(explicit: explicit)
        b.string(0x0008, 0x0060, vr: "CS", "CT")
        extra(&b)
        b.string(0x0018, 0x0050, vr: "DS", "2.5")
        b.string(0x0018, 0x0060, vr: "DS", "120")
        b.string(0x0018, 0x1210, vr: "SH", "B30f")
        if let seriesUID { b.string(0x0020, 0x000E, vr: "UI", seriesUID) }
        if let position {
            b.string(0x0020, 0x0032, vr: "DS", position.map { String($0) }.joined(separator: "\\"))
        }
        if orientation { b.string(0x0020, 0x0037, vr: "DS", "1\\0\\0\\0\\1\\0") }
        b.us(0x0028, 0x0002, 1)
        b.string(0x0028, 0x0004, vr: "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 3)
        b.us(0x0028, 0x0011, 4)
        b.string(0x0028, 0x0030, vr: "DS", "0.5\\0.7")
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0102, 15)
        b.us(0x0028, 0x0103, 1)
        b.string(0x0028, 0x1052, vr: "DS", intercept)
        b.string(0x0028, 0x1053, vr: "DS", "1")
        b.element(0x7FE0, 0x0010, vr: "OW", DICOMTestBuilder.int16Pixels(pixels))
        return b
    }

    private func decode(_ data: Data) throws -> (image: MIQImage, info: DICOMTechnicalInfo) {
        try MIQParser().decodeDicom(data)
    }

    // MARK: Detection

    @Test func fileKindDetection() throws {
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.dcm")) == .dicom)
        #expect(MIQFileKind(url: URL(fileURLWithPath: "/a/b.DICOM")) == .dicom)
        #expect(MIQFileKind.dicom.displayName == "DICOM")

        let url = Self.tempURL("IM000001") // extensionless, as PACS exports often are
        try Self.ctSlice().part10(transferSyntax: DICOMTestBuilder.explicitLE).write(to: url)
        #expect(MIQFileKind(url: url) == nil)
        #expect(MIQFileKind.sniffDICOM(url: url) == .dicom)
        // parse(url:) falls back to the content sniff for unknown names.
        let image = try MIQParser().parse(url: url)
        #expect(image.header.width == 4)

        let notDicom = Self.tempURL("README")
        try Data(repeating: 0x41, count: 300).write(to: notDicom)
        #expect(MIQFileKind.sniffDICOM(url: notDicom) == nil)
        #expect(throws: MIQError.self) { try MIQParser().parse(url: notDicom) }
    }

    @Test func rejectsFileWithoutMarkerOrExplicitDataset() {
        var garbage = Data(count: 128)
        garbage.append(contentsOf: Array("NOPE".utf8))
        garbage.append(Data(count: 64))
        #expect(throws: MIQError.self) { try decode(garbage) }
    }

    @Test func acceptsExplicitDatasetWithoutPreamble() throws {
        let data = Self.ctSlice().part10(transferSyntax: DICOMTestBuilder.explicitLE, preamble: false)
        let (image, _) = try decode(data)
        #expect(image.header.width == 4 && image.header.height == 3)
    }

    // MARK: Explicit / implicit VR

    @Test func explicitLittleEndianCTRescalesToHounsfield() throws {
        let url = Self.tempURL()
        try Self.ctSlice().part10(transferSyntax: DICOMTestBuilder.explicitLE).write(to: url)
        let image = try MIQParser().parse(url: url)
        let h = image.header

        #expect(h.dimensions == [4, 3, 1, 1])
        #expect(h.datatype == .int16)
        // PixelSpacing is [row, column]: x (columns) = 0.7, y (rows) = 0.5.
        #expect(h.pixdim[1] == 0.7)
        #expect(h.pixdim[2] == 0.5)
        #expect(h.pixdim[3] == 2.5)
        #expect(h.sclSlope == 1 && h.sclInter == -1024)
        #expect(h.formatLabel == "DICOM")

        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == -1024) // air
        #expect(volume.voxel(x: 1, y: 0, z: 0) == 0)     // water
        #expect(volume.voxel(x: 3, y: 0, z: 0) == 1976)
        #expect(volume.voxel(x: 3, y: 2, z: 0) == 0)

        // Axial LPS slice: +column = L, +row = P, normal = S; origin LPS→RAS negates x,y.
        #expect(OrientationResolver(image: image).storageLabel() == "LPS")
        #expect(h.srowX == [-0.7, 0, 0, 100])
        #expect(h.srowY == [0, -0.5, 0, 120])
        #expect(h.srowZ == [0, 0, 2.5, 50])
    }

    @Test func implicitLittleEndian() throws {
        var b = DICOMTestBuilder(explicit: false)
        b.string(0x0020, 0x0032, vr: "DS", "0\\0\\0")
        b.string(0x0020, 0x0037, vr: "DS", "1\\0\\0\\0\\0\\-1") // coronal
        b.us(0x0028, 0x0010, 2)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0103, 0)
        b.element(0x7FE0, 0x0010, vr: "OW", DICOMTestBuilder.uint16Pixels([1, 2, 3, 60000]))
        let (image, info) = try decode(b.part10(transferSyntax: DICOMTestBuilder.implicitLE))
        #expect(image.header.datatype == .uint16)
        #expect(info.transferSyntaxName == "Implicit VR Little Endian")
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 1, y: 1, z: 0) == 60000)
        #expect(volume.voxel(x: 0, y: 1, z: 0) == 3)
        // Coronal: +column = L, +row = I, normal = row × col = (0,1,0) LPS = P.
        #expect(OrientationResolver(image: image).storageLabel() == "LIP")
        #expect(info.pixelSpacing == nil)
        #expect(info.geometryNotes.contains { $0.contains("Pixel spacing missing") })
    }

    // MARK: Multi-frame

    @Test func enhancedMultiFrameUsesPerFramePositions() throws {
        func planePosition(_ z: Double) -> Data {
            var inner = DICOMTestBuilder()
            inner.string(0x0020, 0x0032, vr: "DS", "10\\20\\\(z)")
            var fg = DICOMTestBuilder()
            fg.sequence(0x0020, 0x9113, items: [inner.bytes])
            return fg.bytes
        }
        var orient = DICOMTestBuilder()
        orient.string(0x0020, 0x0037, vr: "DS", "1\\0\\0\\0\\1\\0")
        var measures = DICOMTestBuilder()
        measures.string(0x0028, 0x0030, vr: "DS", "2\\2")
        measures.string(0x0018, 0x0050, vr: "DS", "9")
        var transform = DICOMTestBuilder()
        transform.string(0x0028, 0x1052, vr: "DS", "-10")
        transform.string(0x0028, 0x1053, vr: "DS", "2")
        var shared = DICOMTestBuilder()
        shared.sequence(0x0020, 0x9116, items: [orient.bytes], undefinedLength: false)
        shared.sequence(0x0028, 0x9110, items: [measures.bytes])
        shared.sequence(0x0028, 0x9145, items: [transform.bytes])

        var b = DICOMTestBuilder()
        b.string(0x0008, 0x0060, vr: "CS", "MR")
        b.string(0x0018, 0x0087, vr: "DS", "3")
        b.us(0x0028, 0x0002, 1)
        b.string(0x0028, 0x0004, vr: "CS", "MONOCHROME2")
        b.string(0x0028, 0x0008, vr: "IS", "3")
        b.us(0x0028, 0x0010, 2)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.us(0x0028, 0x0101, 8)
        b.us(0x0028, 0x0103, 0)
        b.sequence(0x5200, 0x9229, items: [shared.bytes])
        b.sequence(0x5200, 0x9230, items: [planePosition(0), planePosition(3), planePosition(6)], undefinedLength: false)
        b.element(0x7FE0, 0x0010, vr: "OB", Data([0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22, 23]))

        let (image, info) = try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE))
        let h = image.header
        #expect(h.dimensions == [2, 2, 3, 1])
        #expect(h.formatLabel == "DICOM (multi-frame)")
        #expect(h.pixdim[1] == 2 && h.pixdim[2] == 2)
        #expect(h.pixdim[3] == 3) // from positions, not the 9 mm SliceThickness
        #expect(h.srowZ == [0, 0, 3, 0])
        #expect(h.srowX[3] == -10 && h.srowY[3] == -20)
        #expect(info.geometryNotes.isEmpty)
        #expect(info.numberOfFrames == 3)
        #expect(info.modality == "MR" && info.magneticFieldStrength == 3)
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 1, y: 1, z: 2) == 23 * 2 - 10)
        #expect(OrientationResolver(image: image).storageLabel() == "LPS")
    }

    @Test func multiFrameWithoutPositionsAssumesSpacingAndSaysSo() throws {
        var b = DICOMTestBuilder()
        b.string(0x0018, 0x0050, vr: "DS", "4")
        b.string(0x0020, 0x0037, vr: "DS", "1\\0\\0\\0\\1\\0")
        b.string(0x0028, 0x0008, vr: "IS", "2")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.element(0x7FE0, 0x0010, vr: "OB", Data([1, 2, 3, 4]))
        let (image, info) = try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE))
        #expect(image.header.depth == 2)
        #expect(image.header.pixdim[3] == 4)
        #expect(image.header.orientationFrame != nil)
        #expect(info.geometryNotes.contains { $0.contains("Frame positions unavailable") })
        #expect(info.displayEntries.contains { $0.label == "Note" })
    }

    @Test func missingOrientationIsUnknown() throws {
        let data = Self.ctSlice(position: nil, orientation: false).part10(transferSyntax: DICOMTestBuilder.explicitLE)
        let (image, info) = try decode(data)
        #expect(image.header.orientationFrame == nil)
        #expect(image.header.sformCode == 0)
        let resolver = OrientationResolver(image: image)
        #expect(resolver.storageLabel() == nil)
        #expect(resolver.displayOrientation(for: .axial).isUnknown)
        #expect(info.geometryNotes.contains { $0.contains("Orientation unknown") })
        // Spacing still honoured without orientation.
        #expect(image.header.pixdim[1] == 0.7)
    }

    // MARK: Unsupported syntaxes

    @Test func compressedTransferSyntaxThrowsClearError() {
        let cases: [(String, String)] = [
            ("1.2.840.10008.1.2.4.90", "JPEG 2000"),
            ("1.2.840.10008.1.2.4.50", "JPEG"),
            ("1.2.840.10008.1.2.4.80", "JPEG-LS"),
            ("1.2.840.10008.1.2.5", "RLE"),
            ("1.2.840.10008.1.2.1.99", "Deflate"),
        ]
        for (uid, name) in cases {
            let data = Self.ctSlice().part10(transferSyntax: uid)
            do {
                _ = try decode(data)
                Issue.record("expected \(name) to be rejected")
            } catch MIQError.unsupportedFeature(let reason) {
                #expect(reason == "Compressed DICOM (\(name)) isn't supported yet")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test func bigEndianIsRejected() {
        let data = Self.ctSlice().part10(transferSyntax: "1.2.840.10008.1.2.2")
        do {
            _ = try decode(data)
            Issue.record("expected big endian to be rejected")
        } catch MIQError.unsupportedFeature(let reason) {
            #expect(reason.contains("Big-endian"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func encapsulatedPixelDataIsRejected() {
        var b = DICOMTestBuilder()
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 1)
        b.us(0x0028, 0x0100, 8)
        b.element(0x7FE0, 0x0010, vr: "OB", Data(), length: 0xFFFF_FFFF)
        #expect(throws: MIQError.self) { try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE)) }
    }

    // MARK: Robustness

    @Test func everyTruncationThrows() throws {
        let full = Self.ctSlice().part10(transferSyntax: DICOMTestBuilder.explicitLE)
        _ = try decode(full)
        for length in 0..<full.count {
            #expect(throws: (any Error).self) { try decode(full.prefix(length)) }
        }
    }

    @Test func garbageNeverTraps() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
        let valid = Self.ctSlice().part10(transferSyntax: DICOMTestBuilder.explicitLE)
        for _ in 0..<300 {
            // Random noise after a valid marker, and random byte flips in a valid file.
            var noise = Data(count: 128)
            noise.append(contentsOf: Array("DICM".utf8))
            noise.append(Data((0..<Int(next()) * 4).map { _ in next() }))
            _ = try? decode(noise)

            var mutated = valid
            for _ in 0..<4 {
                let index = 132 + Int(next()) % (valid.count - 132)
                mutated[index] = next()
            }
            _ = try? decode(mutated)
        }
    }

    @Test func undefinedLengthSequencesAreSkipped() throws {
        // A private nested sequence (undefined lengths throughout), an implicit-VR UN
        // sequence, and a defined-length sequence must all be stepped over.
        var deep = DICOMTestBuilder()
        deep.string(0x0010, 0x0010, vr: "PN", "NESTED^NAME")
        var mid = DICOMTestBuilder()
        mid.sequence(0x0040, 0xA730, items: [deep.bytes, deep.bytes])
        mid.string(0x0008, 0x0100, vr: "SH", "CODE")
        var implicitItem = DICOMTestBuilder(explicit: false)
        implicitItem.string(0x0008, 0x0104, vr: "LO", "meaning")
        let data = Self.ctSlice { b in
            b.sequence(0x0008, 0x1140, items: [mid.bytes, Data()])
            b.sequence(0x0009, 0x1010, items: [implicitItem.bytes], vr: "UN")
            b.sequence(0x0008, 0x1111, items: [mid.bytes], undefinedLength: false)
        }.part10(transferSyntax: DICOMTestBuilder.explicitLE)
        let (image, _) = try decode(data)
        #expect(MIQVolume(image: image).voxel(x: 1, y: 0, z: 0) == 0)
    }

    @Test func excessiveNestingThrows() {
        var item = DICOMTestBuilder()
        item.string(0x0008, 0x0100, vr: "SH", "X")
        var payload = item.bytes
        for _ in 0..<40 {
            var wrap = DICOMTestBuilder()
            wrap.sequence(0x0040, 0xA730, items: [payload])
            payload = wrap.bytes
        }
        let data = Self.ctSlice { b in b.sequence(0x0040, 0xA730, items: [payload]) }
            .part10(transferSyntax: DICOMTestBuilder.explicitLE)
        do {
            _ = try decode(data)
            Issue.record("expected deep nesting to be rejected")
        } catch MIQError.malformedFile(let reason) {
            #expect(reason.contains("nested too deeply"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func sizeSanityRejectsShortPixelData() {
        let data = Self.ctSlice(pixels: [1, 2, 3]).part10(transferSyntax: DICOMTestBuilder.explicitLE)
        #expect(throws: MIQError.self) { try decode(data) }
    }

    @Test func strayHighBitsAreMaskedAndSignExtended() throws {
        var b = DICOMTestBuilder()
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 3)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 12)
        b.us(0x0028, 0x0102, 11)
        b.us(0x0028, 0x0103, 1)
        // 12-bit signed: 0xF800 overlay bit + 0x07FF → 2047; 0x0800 → -2048; 0x0FFF → -1.
        b.element(0x7FE0, 0x0010, vr: "OW", DICOMTestBuilder.uint16Pixels([0xF7FF, 0x0800, 0x0FFF]))
        let (image, info) = try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE))
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 2047)
        #expect(volume.voxel(x: 1, y: 0, z: 0) == -2048)
        #expect(volume.voxel(x: 2, y: 0, z: 0) == -1)
        #expect(info.bitsStored == 12)
        #expect(image.header.datatypeLabel == "int16 (12-bit)")
    }

    @Test func planarRGBIsInterleaved() throws {
        var b = DICOMTestBuilder()
        b.us(0x0028, 0x0002, 3)
        b.string(0x0028, 0x0004, vr: "CS", "RGB")
        b.us(0x0028, 0x0006, 1)
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.element(0x7FE0, 0x0010, vr: "OB", Data([10, 11, 20, 21, 30, 31]))
        let (image, _) = try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE))
        #expect(image.header.datatype == .rgb24)
        #expect(Array(image.storage) == [10, 20, 30, 11, 21, 31])
    }

    @Test func monochrome1IsInverted() throws {
        var b = DICOMTestBuilder()
        b.string(0x0028, 0x0004, vr: "CS", "MONOCHROME1")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.element(0x7FE0, 0x0010, vr: "OB", Data([0, 200]))
        let (image, _) = try decode(b.part10(transferSyntax: DICOMTestBuilder.explicitLE))
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) > volume.voxel(x: 1, y: 0, z: 0))
    }

    // MARK: Privacy

    @Test func identifyingTagsNeverReachOutput() throws {
        let secrets = [
            "DOE^JOHN", "PID-778899", "St Example Hospital", "20240131", "093000",
            "ACC-4242", "Dr^Who", "Head routine", "1.2.826.0.1.3680043.99999.1", "1.2.826.0.1.3680043.77777",
            "Secret Series", "NESTED^SECRET",
        ]
        var nested = DICOMTestBuilder()
        nested.string(0x0010, 0x0010, vr: "PN", "NESTED^SECRET")
        let builder = Self.ctSlice(seriesUID: "1.2.826.0.1.3680043.99999.1") { b in
            b.string(0x0008, 0x0020, vr: "DA", "20240131")        // StudyDate
            b.string(0x0008, 0x0030, vr: "TM", "093000")          // StudyTime
            b.string(0x0008, 0x0050, vr: "SH", "ACC-4242")        // AccessionNumber
            b.string(0x0008, 0x0080, vr: "LO", "St Example Hospital") // InstitutionName
            b.string(0x0008, 0x0090, vr: "PN", "Dr^Who")          // ReferringPhysicianName
            b.string(0x0008, 0x1030, vr: "LO", "Head routine")    // StudyDescription
            b.string(0x0008, 0x103E, vr: "LO", "Secret Series")   // SeriesDescription
            b.sequence(0x0008, 0x1120, items: [nested.bytes])      // ReferencedPatientSequence
            b.string(0x0010, 0x0010, vr: "PN", "DOE^JOHN")        // PatientName
            b.string(0x0010, 0x0020, vr: "LO", "PID-778899")      // PatientID
            b.string(0x0020, 0x000D, vr: "UI", "1.2.826.0.1.3680043.77777") // StudyInstanceUID
        }
        let url = Self.tempURL()
        try builder.part10(transferSyntax: DICOMTestBuilder.explicitLE).write(to: url)

        let (image, info) = try MIQParser().parseDICOM(url: url)
        var reader = DICOMReader(data: try Data(contentsOf: url))
        let descriptor = try DICOMImageDescriptor(file: reader.read())

        var outputs: [String] = []
        outputs += MIQMetadata(header: image.header).asDisplayLines().map(\.text)
        outputs += info.displayEntries.map(\.text)
        outputs.append(String(describing: info))
        outputs.append(String(reflecting: info))
        outputs.append(String(reflecting: image.header))
        outputs.append(image.header.formatLabel ?? "")
        outputs.append(String(describing: descriptor.seriesUID as Any))
        var dumped = ""
        dump(info, to: &dumped)
        dump(image.header, to: &dumped)
        dump(descriptor.seriesUID, to: &dumped)
        outputs.append(dumped)

        // Every recorded value range must be an allowlisted tag.
        #expect(descriptor.file.dataset.values.keys.allSatisfy { DICOMAllowlist.values[$0] != nil })
        #expect(descriptor.file.dataset.values[DICOMTag(0x0010, 0x0010)] == nil)

        let joined = outputs.joined(separator: "\n")
        for secret in secrets {
            #expect(!joined.contains(secret), "leaked \(secret)")
        }
        // The technical allowlist still came through.
        #expect(info.modality == "CT")
        #expect(info.convolutionKernel == "B30f")
        #expect(info.kvp == 120)
    }

    // MARK: Series assembly

    @Test func seriesAssemblerStacksSiblingsByPosition() throws {
        let folder = Self.tempURL("x").deletingLastPathComponent()
        let uid = "1.2.3.4.5.6"
        // Written out of order; values identify each slice.
        for (name, z, value) in [("b.dcm", 10.0, Int16(30)), ("a.dcm", 0.0, Int16(10)), ("c.dcm", 5.0, Int16(20))] {
            let data = Self.ctSlice(position: [0, 0, z], intercept: "0", pixels: Array(repeating: value, count: 12), seriesUID: uid)
                .part10(transferSyntax: DICOMTestBuilder.explicitLE)
            try data.write(to: folder.appendingPathComponent(name))
        }
        // Another series and a non-DICOM file in the same folder are ignored.
        try Self.ctSlice(position: [0, 0, 2.5], seriesUID: "9.9.9").part10(transferSyntax: DICOMTestBuilder.explicitLE)
            .write(to: folder.appendingPathComponent("other.dcm"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let series = try #require(DICOMSeriesAssembler().assembleSeries(containing: folder.appendingPathComponent("b.dcm")))
        #expect(series.sliceCount == 3)
        let h = series.image.header
        #expect(h.dimensions == [4, 3, 3, 1])
        #expect(h.pixdim[3] == 5)
        #expect(h.srowZ[2] == 5 && h.srowZ[3] == 0)
        #expect(h.formatLabel == "DICOM series (3 files)")
        let volume = MIQVolume(image: series.image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 10)
        #expect(volume.voxel(x: 0, y: 0, z: 1) == 20)
        #expect(volume.voxel(x: 0, y: 0, z: 2) == 30)
    }

    @Test func seriesAssemblerMaterialisesDifferingRescale() throws {
        let folder = Self.tempURL("x").deletingLastPathComponent()
        for (name, z, intercept) in [("a.dcm", 0.0, "-1024"), ("b.dcm", 1.0, "-1000")] {
            try Self.ctSlice(position: [0, 0, z], intercept: intercept, pixels: Array(repeating: 1000, count: 12), seriesUID: "7.7")
                .part10(transferSyntax: DICOMTestBuilder.explicitLE)
                .write(to: folder.appendingPathComponent(name))
        }
        let series = try #require(DICOMSeriesAssembler().assembleSeries(containing: folder.appendingPathComponent("a.dcm")))
        #expect(series.image.header.datatype == .float32)
        let volume = MIQVolume(image: series.image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == -24)
        #expect(volume.voxel(x: 0, y: 0, z: 1) == 0)
    }

    @Test func seriesAssemblerIsSilentWithoutSiblings() throws {
        let url = Self.tempURL()
        try Self.ctSlice(seriesUID: "1.1").part10(transferSyntax: DICOMTestBuilder.explicitLE).write(to: url)
        #expect(DICOMSeriesAssembler().assembleSeries(containing: url) == nil)
        #expect(DICOMSeriesAssembler().assembleSeries(containing: URL(fileURLWithPath: "/nonexistent/x.dcm")) == nil)
    }
}
