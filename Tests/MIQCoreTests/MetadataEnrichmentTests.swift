import Foundation
import Testing
@testable import MIQCore

/// Byte patching for the synthetic headers built by `TestMIQFactory`.
private enum Patch {
    static func put<T: FixedWidthInteger>(_ value: T, _ data: inout Data, at offset: Int, bigEndian: Bool = false) {
        let v = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: v) { data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }

    static func put(_ value: Float, _ data: inout Data, at offset: Int, bigEndian: Bool = false) {
        put(value.bitPattern, &data, at: offset, bigEndian: bigEndian)
    }

    static func put(_ value: Double, _ data: inout Data, at offset: Int) {
        put(value.bitPattern, &data, at: offset)
    }

    static func put(text: String, _ data: inout Data, at offset: Int, length: Int) {
        var bytes = Array(text.utf8.prefix(length))
        bytes += [UInt8](repeating: 0, count: length - bytes.count)
        data.replaceSubrange(offset..<(offset + length), with: bytes)
    }

    /// Re-lays a factory NIfTI-1 file (348-byte header, payload at 352) with the
    /// given extensions between header and payload, padding each to 16 bytes.
    static func nifti1(_ nii: Data, extensions: [(ecode: Int32, content: Data)]) -> Data {
        var out = Data(nii.prefix(348))
        out.append(contentsOf: [1, 0, 0, 0]) // extender: extensions follow
        for ext in extensions {
            let padded = (ext.content.count + 8 + 15) / 16 * 16
            var record = Data(count: 8)
            put(Int32(padded), &record, at: 0)
            put(ext.ecode, &record, at: 4)
            record.append(ext.content)
            record.append(Data(count: padded - record.count))
            out.append(record)
        }
        put(Float(out.count), &out, at: 108)
        out.append(nii.dropFirst(352))
        return out
    }
}

// MARK: - NIfTI header fields

struct NiftiAcquisitionFieldTests {
    @Test
    func parsesUnitsTRAndIntent() throws {
        var data = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16, pixdim: [1, 2, 2, 3], volumes: 3)
        // pixdim[4] = 2500 ms; xyzt_units = mm (2) | ms (16).
        Patch.put(Float(2500), &data, at: 92)
        data[123] = 2 | 16
        Patch.put(Int16(3), &data, at: 68)       // NIFTI_INTENT_TTEST
        Patch.put(Float(25), &data, at: 56)      // dof
        Patch.put(text: "spmT", &data, at: 328, length: 16)

        let header = try MIQParser().parseNifti(data).header
        #expect(header.acquisition.spatialUnit == .millimeter)
        #expect(header.acquisition.temporalUnit == .millisecond)
        #expect(header.acquisition.repetitionTime == 2.5)
        #expect(header.acquisition.intentCode == 3)
        #expect(header.acquisition.intentName == "spmT")

        let metadata = MIQMetadata(header: header)
        #expect(metadata.repetitionTime == "2.5 s")
        #expect(metadata.intent == "t-statistic (dof 25)")
        let lines = metadata.asDisplayLines()
        #expect(lines.contains { $0.field == .repetitionTime && $0.label == "TR" && $0.value == "2.5 s" })
        #expect(lines.contains { $0.field == .intent && $0.value == "t-statistic (dof 25)" })
        // intent_name is free text: only in the (default-off) description row.
        #expect(lines.contains { $0.field == .description && $0.value.contains("spmT") })
        #expect(!lines.contains { $0.field == .intent && $0.value.contains("spmT") })
    }

    @Test
    func trNeedsATimeAxisAndATimeUnit() throws {
        // 3D file: pixdim[4] is meaningless.
        var threeD = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        Patch.put(Float(2), &threeD, at: 92)
        threeD[123] = 2 | 8
        #expect(try MIQParser().parseNifti(threeD).header.acquisition.repetitionTime == nil)

        // 4D, unknown temporal unit: no guess.
        var unknownUnit = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16, volumes: 2)
        Patch.put(Float(2), &unknownUnit, at: 92)
        unknownUnit[123] = 2
        #expect(try MIQParser().parseNifti(unknownUnit).header.acquisition.repetitionTime == nil)

        // 4D, Hz (spectral): not a TR.
        var hertz = unknownUnit
        hertz[123] = 2 | 32
        #expect(try MIQParser().parseNifti(hertz).header.acquisition.repetitionTime == nil)

        // 4D, seconds, sub-second TR renders in ms.
        var seconds = unknownUnit
        Patch.put(Float(0.8), &seconds, at: 92)
        seconds[123] = 2 | 8
        let header = try MIQParser().parseNifti(seconds).header
        #expect(abs((header.acquisition.repetitionTime ?? 0) - 0.8) < 1e-6)
        #expect(MIQMetadata(header: header).repetitionTime == "800 ms")
    }

    @Test
    func spacingUsesTheHeaderSpatialUnit() throws {
        let sep = " \u{00D7} "
        var data = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16, pixdim: [1, 0.5, 0.5, 1])
        #expect(MIQMetadata(header: try MIQParser().parseNifti(data).header).spacing == "0.50\(sep)0.50\(sep)1.00 mm")
        data[123] = 3 // micron
        #expect(MIQMetadata(header: try MIQParser().parseNifti(data).header).spacing == "0.50\(sep)0.50\(sep)1.00 \u{00B5}m")
        data[123] = 2 // mm
        #expect(MIQMetadata(header: try MIQParser().parseNifti(data).header).spacing.hasSuffix(" mm"))

        var meters = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16, pixdim: [1, 0.001, 0.001, 0.0015])
        meters[123] = 1
        #expect(MIQMetadata(header: try MIQParser().parseNifti(meters).header).spacing == "0.001\(sep)0.001\(sep)0.0015 m")
    }

    @Test
    func descripIsTrimmedAndNulSafe() throws {
        var data = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        // Trailing garbage after the NUL must not leak into the text.
        var descrip = Array("  FSL5.0 \u{07}bell ".utf8) + [0] + Array("SECRET".utf8)
        descrip += [UInt8](repeating: 0x41, count: 80 - descrip.count)
        data.replaceSubrange(148..<228, with: descrip)
        let header = try MIQParser().parseNifti(data).header
        #expect(header.acquisition.descrip == "FSL5.0  bell")
        #expect(MIQMetadata(header: header).asDisplayLines().contains { $0.field == .description && $0.value == "FSL5.0  bell" })

        // A full 80 bytes with no terminator is still bounded to 80.
        var full = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        full.replaceSubrange(148..<228, with: [UInt8](repeating: 0x42, count: 80))
        #expect(try MIQParser().parseNifti(full).header.acquisition.descrip?.count == 80)

        // Empty descrip: no row at all.
        let empty = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        #expect(!MIQMetadata(header: try MIQParser().parseNifti(empty).header).asDisplayLines().contains { $0.field == .description })
    }

    @Test
    func intentNamesForCommonCodes() {
        var info = MIQAcquisitionInfo()
        #expect(info.intentDisplayName == nil)
        for (code, name) in [(1002, "Label"), (1003, "NeuroNames label"), (1007, "Vector"),
                             (1006, "Displacement vector"), (2003, "RGB vector"), (2005, "Shape"),
                             (5, "z-score"), (2, "Correlation")] {
            info.intentCode = code
            #expect(info.intentDisplayName == name)
        }
        info.intentCode = 4
        info.intentParameters = [3, 120, 0]
        #expect(info.intentDisplayName == "F-statistic (dof 3, 120)")
        info.intentCode = 9999
        #expect(info.intentDisplayName == "intent 9999")
    }

    @Test
    func listsNifti1Extensions() throws {
        let base = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        let data = Patch.nifti1(base, extensions: [
            (ecode: 6, content: Data("a comment".utf8)),
            (ecode: 4, content: Data(repeating: 0x20, count: 40)),
        ])
        let image = try MIQParser().parseNifti(data)
        #expect(image.header.acquisition.extensions == [
            MIQHeaderExtension(ecode: 6, size: 32),
            MIQHeaderExtension(ecode: 4, size: 48),
        ])
        // Voxels still decode from the moved payload.
        #expect(image.header.voxOffset == 352 + 32 + 48)
        let provenance = MIQMetadata(header: image.header).provenance
        #expect(provenance == "extensions: comment (32 B), AFNI (48 B)")
    }

    @Test
    func extensionChainStopsAtMalformedRecords() throws {
        let base = TestMIQFactory.makeNii(width: 4, height: 4, depth: 2, datatype: .int16)
        var data = Patch.nifti1(base, extensions: [(ecode: 6, content: Data("x".utf8))])
        Patch.put(Int32(4096), &data, at: 352) // esize runs past vox_offset
        #expect(try MIQParser().parseNifti(data).header.acquisition.extensions.isEmpty)

        // Extender flag clear: bytes after the header are ignored.
        var noFlag = Patch.nifti1(base, extensions: [(ecode: 6, content: Data("x".utf8))])
        noFlag[348] = 0
        #expect(try MIQParser().parseNifti(noFlag).header.acquisition.extensions.isEmpty)
    }

    @Test
    func parsesNifti2Fields() throws {
        var data = TestMIQFactory.makeNii2(width: 4, height: 4, depth: 2, datatype: .float32, pixdim: [1, 1, 1, 1])
        // Make it 4D: ndim 4, dim[4] = 2, and duplicate the payload.
        let payload = data.dropFirst(544)
        Patch.put(Int64(4), &data, at: 16)
        Patch.put(Int64(2), &data, at: 48)
        data.append(payload)
        Patch.put(Double(1.5), &data, at: 136)       // pixdim[4]
        Patch.put(Int32(2 | 8), &data, at: 500)      // mm + s
        Patch.put(Int32(1002), &data, at: 504)       // label
        Patch.put(text: "nifti2 descrip", &data, at: 240, length: 80)
        // One extension: extender at 540, record at 544, payload moved after it.
        var withExt = Data(data.prefix(540))
        withExt.append(contentsOf: [1, 0, 0, 0])
        var record = Data(count: 16)
        Patch.put(Int32(16), &record, at: 0)
        Patch.put(Int32(2), &record, at: 4)
        withExt.append(record)
        Patch.put(Int64(withExt.count), &withExt, at: 168)
        withExt.append(data.dropFirst(544))

        let header = try MIQParser().parseNifti(withExt).header
        #expect(header.acquisition.repetitionTime == 1.5)
        #expect(header.acquisition.spatialUnit == .millimeter)
        #expect(header.acquisition.intentDisplayName == "Label")
        #expect(header.acquisition.descrip == "nifti2 descrip")
        #expect(header.acquisition.extensions == [MIQHeaderExtension(ecode: 2, size: 16)])
    }
}

// MARK: - MGH tail

struct MghScanParameterTests {
    @Test
    func readsOptionalTail() throws {
        var data = TestMIQFactory.makeMgh(width: 2, height: 2, depth: 2, frames: 1, datatype: .uint8)
        var tail = Data(count: 20)
        Patch.put(Float(2300), &tail, at: 0, bigEndian: true)              // TR ms
        Patch.put(Float(9 * Float.pi / 180), &tail, at: 4, bigEndian: true) // flip rad
        Patch.put(Float(2.98), &tail, at: 8, bigEndian: true)              // TE ms
        Patch.put(Float(900), &tail, at: 12, bigEndian: true)              // TI ms
        data.append(tail)

        let header = try MIQParser().parseMgh(data).header
        let acq = header.acquisition
        #expect(abs((acq.repetitionTime ?? 0) - 2.3) < 1e-6)
        #expect(abs((acq.flipAngle ?? 0) - 9) < 1e-4)
        #expect(abs((acq.echoTime ?? 0) - 0.00298) < 1e-7)
        #expect(abs((acq.inversionTime ?? 0) - 0.9) < 1e-6)
        #expect(MIQMetadata(header: header).repetitionTime == "2.3 s (TE 2.98 ms, TI 900 ms, flip 9\u{00B0})")
    }

    @Test
    func absentOrZeroTailYieldsNothing() throws {
        let bare = TestMIQFactory.makeMgh(width: 2, height: 2, depth: 2, frames: 1, datatype: .uint8)
        #expect(try MIQParser().parseMgh(bare).header.acquisition.repetitionTime == nil)
        #expect(MIQMetadata(header: try MIQParser().parseMgh(bare).header).repetitionTime == nil)

        var zeros = bare
        zeros.append(Data(count: 16))
        let acq = try MIQParser().parseMgh(zeros).header.acquisition
        #expect(acq.repetitionTime == nil && acq.flipAngle == nil && acq.echoTime == nil && acq.inversionTime == nil)

        // A partial tail (fewer than four floats) is ignored.
        var partial = bare
        partial.append(Data(count: 8))
        #expect(try MIQParser().parseMgh(partial).header.acquisition.repetitionTime == nil)
    }
}

// MARK: - MIF dw_scheme / command_history

struct MifProvenanceTests {
    /// 2×2×2 UInt8 MIF with `extraLines` in its header.
    private static func mif(extraLines: [String]) -> Data {
        let fixed = ["mrtrix image", "dim: 2,2,2", "vox: 1,1,1", "layout: +0,+1,+2", "datatype: UInt8"]
        var offset = 0
        var header = ""
        while true {
            header = (fixed + extraLines + ["file: . \(offset)", "END"]).joined(separator: "\n") + "\n"
            if header.utf8.count == offset { break }
            offset = header.utf8.count
        }
        return Data(header.utf8) + Data(0..<8)
    }

    @Test
    func surfacesBValuesAndLastCommand() throws {
        var lines: [String] = []
        for _ in 0..<2 { lines.append("dw_scheme: 0,0,0,0") }
        for _ in 0..<3 { lines.append("dw_scheme: 0.5,0.5,0.707,995") }
        for _ in 0..<4 { lines.append("dw_scheme: 1,0,0,2010") }
        lines.append("command_history: mrconvert dwi.nii dwi.mif  (version=3.0.4)")
        lines.append("command_history: dwidenoise dwi.mif out.mif  (version=3.0.4)")
        let header = try MIQParser().parseMif(Self.mif(extraLines: lines)).header
        #expect(header.acquisition.bValues?.count == 9)
        #expect(header.acquisition.lastCommand == "dwidenoise dwi.mif out.mif  (version=3.0.4)")
        let metadata = MIQMetadata(header: header)
        #expect(metadata.diffusion == "b=0\u{00D7}2, 1000\u{00D7}3, 2000\u{00D7}4")
        #expect(metadata.provenance == "dwidenoise dwi.mif out.mif  (version=3.0.4)")
    }

    @Test
    func malformedSchemeIsDropped() throws {
        let header = try MIQParser().parseMif(Self.mif(extraLines: ["dw_scheme: 0,0,0,0", "dw_scheme: 1,0,x"])).header
        #expect(header.acquisition.bValues == nil)
        #expect(MIQMetadata(header: header).diffusion == nil)
    }
}

// MARK: - Panel formatting

struct MetadataFormattingTests {
    @Test
    func shellSummaryRoundsToNearest50() {
        let b = Array(repeating: 0.0, count: 7) + Array(repeating: 1005.0, count: 16) + Array(repeating: 990.0, count: 16)
            + Array(repeating: 2000.0, count: 64) + [5]
        #expect(MIQMetadata.diffusionShellSummary(b) == "b=0\u{00D7}8, 1000\u{00D7}32, 2000\u{00D7}64")
        #expect(MIQMetadata.diffusionShellSummary([]) == nil)
        #expect(MIQMetadata.diffusionShellSummary([.nan]) == nil)
    }

    @Test
    func voxelPositionWithAndWithoutAffine() {
        let affine: [[Float]] = [[-2, 0, 0, 90], [0, 2, 0, -126], [0, 0, 2, -72]]
        #expect(MIQMetadata.formatVoxelPosition(ijk: [45, 63, 36], affine: affine) == "45, 63, 36  (0.0, 0.0, 0.0 mm)")
        #expect(MIQMetadata.formatVoxelPosition(ijk: [10, 0, 1], affine: affine) == "10, 0, 1  (70.0, -126.0, -70.0 mm)")
        #expect(MIQMetadata.formatVoxelPosition(ijk: [1, 2, 3], affine: nil) == "1, 2, 3")
        #expect(MIQMetadata.formatVoxelPosition(ijk: [1, 2, 3], affine: [[1, 0, 0]]) == "1, 2, 3")
        #expect(MIQMetadata.formatVoxelPosition(ijk: [1, 2, 3], affine: [[.nan, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]) == "1, 2, 3")
    }

    @Test
    func newFieldsAppendAfterExistingOnesInSavedOrders() {
        // A pre-upgrade saved order decodes to the new default.
        let legacy = "format,dimensions,spacing,orientation,datatype,volumes,scaling,value"
        #expect(MIQConfig.parseMetadataOrder(legacy) == MIQConfig.parseMetadataOrder(MIQConfig.Defaults.metadataOrder))
        #expect(MIQConfig.parseMetadataOrder(MIQConfig.Defaults.metadataOrder) == MetadataField.allCases)
        // A customised legacy order keeps its arrangement, new rows at the end.
        let custom = MIQConfig.parseMetadataOrder("value,format,dimensions,spacing,orientation,datatype,volumes,scaling")
        #expect(Array(custom.prefix(2)) == [.value, .format])
        #expect(Array(custom.suffix(7)) == [.repetitionTime, .intent, .diffusion, .sidecar, .voxelPosition, .description, .provenance])
    }

    @Test
    func phiProneFieldsDefaultOff() {
        for field in MetadataField.allCases {
            #expect(MIQConfig.defaultVisibility(field) == !field.mayContainPHI)
        }
        #expect(MetadataField.description.mayContainPHI && MetadataField.provenance.mayContainPHI)
        #expect(Set(MetadataField.allCases.map(MIQConfig.metadataVisibilityKey)).count == MetadataField.allCases.count)
    }
}

// MARK: - Label names

struct LabelNameTests {
    @Test
    func freeSurferNamesAndFormatting() {
        let lut = SegmentationLut.freeSurfer
        #expect(lut.labelName(17) == "Left-Hippocampus")
        #expect(lut.formatLabel(17) == "17 Left-Hippocampus")
        #expect(lut.labelName(1035) == "ctx-lh-insula")
        #expect(lut.labelName(2001) == "ctx-rh-bankssts")
        #expect(lut.labelName(11175) == "ctx_lh_S_temporal_transverse")
        #expect(lut.labelName(3001) == "wm-lh-bankssts")
        #expect(lut.labelName(5002) == "Right-UnsegmentedWhiteMatter")
        #expect(lut.labelName(987_654) == nil)
        #expect(lut.formatLabel(987_654) == "987654")
        #expect(lut.formatLabelValue(53) == "53 Right-Hippocampus")
        #expect(lut.formatLabelValue(17.5) == nil)
        #expect(lut.formatLabelValue(.nan) == nil)
        #expect(SegmentationLut.freeSurferNamedTable.count > 1500)
    }

    @Test
    func randomAndMaskSchemesHaveNoNames() {
        #expect(SegmentationLut.random(labels: [1, 2, 17]).labelName(17) == nil)
        #expect(SegmentationLut.monochromeWhite.labelName(1) == nil)
        #expect(SegmentationLut.random(labels: [17]).formatLabelValue(17) == nil)
    }

    @Test
    func curatedColoursUnchangedAndLUTFillsTheRest() {
        let lut = SegmentationLut.freeSurfer
        #expect(lut.lookup(28) == (165, 42, 42))   // curated (LUT says 145): curated wins
        #expect(lut.lookup(52) == (13, 48, 255))
        #expect(lut.lookup(6) == (0, 148, 0))      // Left-Cerebellum-Exterior, LUT-only
        // Detection still runs over the curated set only.
        #expect(!SegmentationLut.isFreeSurferLabel(6))
    }
}

// MARK: - Embedded label tables

struct EmbeddedLabelTableTests {
    /// Exactly the document TotalSegmentator's `add_label_map_to_nifti` builds.
    static let totalSegmentatorXML = """
    <?xml version="1.0" encoding="UTF-8"?> <CaretExtension>  <Date><![CDATA[2013-07-14T05:45:09]]></Date>   <VolumeInformation Index="0">   <LabelTable>
    <Label Key="1" Red="0.0" Green="1.0" Blue="0.0" Alpha="1"><![CDATA[spleen]]></Label>
    <Label Key="2" Red="0.0" Green="0.0" Blue="1.0" Alpha="1"><![CDATA[kidney_right]]></Label>
    <Label Key="3" Red="1.0" Green="1.0" Blue="0.0" Alpha="1"><![CDATA[kidney_left]]></Label>

      </LabelTable>  <StudyMetaDataLinkSet>  </StudyMetaDataLinkSet>  <VolumeType><![CDATA[Label]]></VolumeType>   </VolumeInformation></CaretExtension>
    """

    @Test
    func parsesTotalSegmentatorXML() {
        let table = SegmentationLut.parseLabelTableXML(Self.totalSegmentatorXML)
        #expect(table.count == 3)
        #expect(table[1]?.name == "spleen")
        #expect(table[1]?.color.map { [$0.r, $0.g, $0.b] } == [0, 255, 0])
        #expect(table[3]?.name == "kidney_left")
    }

    @Test
    func tolerantParsing() {
        let xml = """
        <labeltable><label key='7' red="255" green="128" blue="0">A &amp; B &#x41;</label>
        <Label Key="8">no colour</Label><Label Red="1">missing key</Label><Label Key="9"></Label>
        <Label Key="x">bad key</Label></labeltable>
        """
        let table = SegmentationLut.parseLabelTableXML(xml)
        #expect(table[7]?.name == "A & B A")
        #expect(table[7]?.color.map { [$0.r, $0.g, $0.b] } == [255, 128, 0])
        #expect(table[8]?.name == "no colour")
        #expect(table[8]?.color == nil)
        #expect(table.count == 2)
        #expect(SegmentationLut.parseLabelTableXML("<Label Key=\"1\"").isEmpty)
        #expect(SegmentationLut.parseLabelTableXML("").isEmpty)
    }

    @Test
    func embeddedTableDrivesLutNamesAndColours() throws {
        let base = TestMIQFactory.makeNiiLabels(width: 16, height: 16, depth: 16, datatype: .int16, labels: [0, 1, 2, 3])
        let data = Patch.nifti1(base, extensions: [(ecode: 0, content: Data(Self.totalSegmentatorXML.utf8))])
        let image = try MIQParser().parseNifti(data)
        #expect(image.header.acquisition.embeddedLabels.count == 3)
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let lut = try #require(MIQVolume(image: image).buildSegmentationLut(options: options))
        #expect(lut.kind == .embedded)
        #expect(lut.formatLabel(2) == "2 kidney_right")
        #expect(lut.lookup(1) == (0, 255, 0))
        #expect(lut.lookup(0) == (0, 0, 0))

        // `.random` keeps its promise of the random palette (and so has no names).
        let randomLut = try #require(MIQVolume(image: image).buildSegmentationLut(
            options: RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .random)))
        #expect(randomLut.kind == .random)
        #expect(randomLut.labelName(2) == nil)
    }

    @Test
    func embeddedLabelWithoutColourFallsBackToPalette() {
        let lut = SegmentationLut.embedded([5: SegmentationLabel(name: "liver")], labels: [5, 6])
        #expect(lut.labelName(5) == "liver")
        #expect(lut.labelName(6) == nil)
        let c = lut.lookup(5)
        #expect(!(c.r == 0 && c.g == 0 && c.b == 0))
    }
}

// MARK: - BIDS sidecar

struct SidecarMetadataTests {
    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miq-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func allowlistDropsIdentifyingKeys() throws {
        let json = """
        {"RepetitionTime": 2, "EchoTime": 0.03, "FlipAngle": 90, "MagneticFieldStrength": 3,
         "PhaseEncodingDirection": "j-", "TaskName": "rest", "MRAcquisitionType": "2D",
         "PatientName": "DOE^JANE", "PatientBirthDate": "19700101", "InstitutionName": "General Hospital",
         "SeriesDescription": "jane doe fmri", "AcquisitionDateTime": "2024-01-01T10:00:00",
         "DeviceSerialNumber": "12345", "Manufacturer": "Acme"}
        """
        let sidecar = try #require(SidecarMetadata.parse(jsonData: Data(json.utf8)))
        #expect(sidecar.repetitionTime == 2)
        #expect(sidecar.echoTime == 0.03)
        #expect(sidecar.taskName == "rest")
        let summary = try #require(sidecar.summary())
        #expect(summary == "TR 2 s \u{00B7} TE 30 ms \u{00B7} FA 90\u{00B0} \u{00B7} 3 T \u{00B7} 2D \u{00B7} PE j- \u{00B7} task rest")
        for leaked in ["DOE", "JANE", "1970", "Hospital", "jane", "2024", "12345", "Acme"] {
            #expect(!summary.contains(leaked))
        }
        // Nothing beyond the allowlist is representable: the stored value is the typed fields.
        let mirror = Mirror(reflecting: sidecar).children.compactMap(\.label)
        #expect(mirror.count == SidecarMetadata.allowedKeys.count + 1) // + bValues
    }

    @Test
    func wrongTypesAndMalformedJSONAreIgnored() {
        #expect(SidecarMetadata.parse(jsonData: Data("not json".utf8)) == nil)
        #expect(SidecarMetadata.parse(jsonData: Data("[1,2]".utf8)) == nil)
        let sidecar = SidecarMetadata.parse(jsonData: Data(#"{"RepetitionTime": "2", "FlipAngle": true, "EchoTime": -1, "TaskName": 7, "InversionTime": 1}"#.utf8))
        #expect(sidecar?.repetitionTime == nil)
        #expect(sidecar?.flipAngle == nil)
        #expect(sidecar?.echoTime == nil)
        #expect(sidecar?.taskName == nil)
        #expect(sidecar?.inversionTime == 1)
    }

    @Test
    func stemStripsFormatSuffixes() {
        let dir = FileManager.default.temporaryDirectory
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent("sub-01_T1w.nii.gz")) == "sub-01_T1w")
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent("sub-01_dwi.nii")) == "sub-01_dwi")
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent("brain.MGZ")) == "brain")
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent("dwi.mif.gz")) == "dwi")
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent("notes.txt")) == nil)
        #expect(SidecarMetadata.stem(of: dir.appendingPathComponent(".nii")) == nil)
    }

    @Test
    func loadsJsonAndBvalBesideTheImage() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("sub-01_dwi.nii.gz")
        try Data(#"{"RepetitionTime": 3.2, "PatientName": "X"}"#.utf8).write(to: dir.appendingPathComponent("sub-01_dwi.json"))
        try Data("0 0 1000 1000 995\n2000 2005\n".utf8).write(to: dir.appendingPathComponent("sub-01_dwi.bval"))
        let sidecar = try #require(SidecarMetadata.load(forImageAt: image))
        #expect(sidecar.repetitionTime == 3.2)
        #expect(sidecar.bValues == [0, 0, 1000, 1000, 995, 2000, 2005])

        // Diffusion row from the .bval when the header has no scheme.
        let header = try MIQParser().parseNifti(TestMIQFactory.makeNii(width: 2, height: 2, depth: 2, datatype: .uint8))
            .header
        let metadata = MIQMetadata(header: header, sidecar: sidecar)
        #expect(metadata.diffusion == "b=0\u{00D7}2, 1000\u{00D7}3, 2000\u{00D7}2")
        #expect(metadata.sidecarSummary?.hasPrefix("TR 3.2 s") == true)
        #expect(metadata.sidecarSummary?.contains(".bval has 7 entries for 1 volumes") == true)
        #expect(metadata.asDisplayLines().contains { $0.field == .sidecar && $0.label == "BIDS" })
    }

    @Test
    func missingOversizedOrUnreadableSidecarsAreSilent() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SidecarMetadata.load(forImageAt: dir.appendingPathComponent("a.nii")) == nil)

        var big = Data(#"{"RepetitionTime": 2, "pad": ""#.utf8)
        big.append(Data(repeating: 0x61, count: SidecarMetadata.maxFileBytes))
        big.append(Data(#""}"#.utf8))
        try big.write(to: dir.appendingPathComponent("b.json"))
        #expect(SidecarMetadata.load(forImageAt: dir.appendingPathComponent("b.nii")) == nil)

        // A directory where the JSON should be: unreadable, still silent.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("c.json"), withIntermediateDirectories: true)
        #expect(SidecarMetadata.load(forImageAt: dir.appendingPathComponent("c.nii")) == nil)
    }

    @Test
    func trMismatchWarning() throws {
        var data = TestMIQFactory.makeNii(width: 2, height: 2, depth: 2, datatype: .uint8, volumes: 2)
        Patch.put(Float(2.5), &data, at: 92)
        data[123] = 2 | 8
        let header = try MIQParser().parseNifti(data).header

        var sidecar = SidecarMetadata()
        sidecar.repetitionTime = 2.0
        #expect(sidecar.consistencyWarnings(against: header) == ["\u{26A0} TR mismatch: sidecar 2 s, header 2.5 s"])
        sidecar.repetitionTime = 2.51 // within 1 %
        #expect(sidecar.consistencyWarnings(against: header).isEmpty)
        sidecar.repetitionTime = 2.0
        #expect(MIQMetadata(header: header, sidecar: sidecar).sidecarSummary == "TR 2 s \u{00B7} \u{26A0} TR mismatch: sidecar 2 s, header 2.5 s")
    }

    @Test
    func bvalParsing() {
        #expect(SidecarMetadata.parseBval("0 1000\t2000\n") == [0, 1000, 2000])
        #expect(SidecarMetadata.parseBval("0\n1000\n") == [0, 1000])
        #expect(SidecarMetadata.parseBval("0 abc") == nil)
        #expect(SidecarMetadata.parseBval("  \n") == nil)
    }
}
