import Foundation
import Testing
import MIQCore
@testable import miq

/// Regressions from the end-to-end run on realistic phantoms: stale format lists,
/// DICOM folders, CT window presets and direction-encoded colour for vector fields.
struct CLIFormatPresetDECTests {
    // MARK: - Fixtures (generated in-test)

    private static func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("miq-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Little-endian NIfTI-1 with an int16 (`datatype` 4) or float32 (16) payload.
    private static func writeNifti(
        to url: URL, dims: [Int], int16: [Int16]? = nil, float32: [Float]? = nil,
        intercept: Float = 0, intentCode: Int16 = 0
    ) throws {
        var bytes = [UInt8](repeating: 0, count: 352)
        func put<T: FixedWidthInteger>(_ v: T, _ at: Int) {
            withUnsafeBytes(of: v.littleEndian) { for (i, b) in $0.enumerated() { bytes[at + i] = b } }
        }
        func putF(_ v: Float, _ at: Int) { put(v.bitPattern, at) }
        put(Int32(348), 0)
        put(Int16(dims.count), 40)
        for (i, d) in dims.enumerated() { put(Int16(d), 42 + i * 2) }
        put(intentCode, 68)
        put(Int16(int16 != nil ? 4 : 16), 70)
        put(Int16(int16 != nil ? 16 : 32), 72)
        for i in 0..<4 { putF(1, 76 + i * 4) }
        putF(352, 108)
        putF(1, 112)
        putF(intercept, 116)
        bytes.replaceSubrange(344..<348, with: Array("n+1\0".utf8))
        var payload = [UInt8]()
        for v in int16 ?? [] { withUnsafeBytes(of: v.littleEndian) { payload += $0 } }
        for v in float32 ?? [] { withUnsafeBytes(of: v.bitPattern.littleEndian) { payload += $0 } }
        try Data(bytes + payload).write(to: url)
    }

    /// Explicit-VR little-endian Part-10 CT slice, 8×8 int16, intercept −1024.
    private static func dicomSlice(z: Double, value: Int16, seriesUID: String) -> Data {
        var body = Data()
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func element(_ g: UInt16, _ e: UInt16, _ vr: String, _ value: [UInt8], into data: inout Data) {
            data.append(contentsOf: le16(g) + le16(e) + Array(vr.utf8))
            if ["OB", "OW"].contains(vr) {
                data.append(contentsOf: [0, 0] + le32(UInt32(value.count)))
            } else {
                data.append(contentsOf: le16(UInt16(value.count)))
            }
            data.append(contentsOf: value)
        }
        func text(_ g: UInt16, _ e: UInt16, _ vr: String, _ s: String, into data: inout Data) {
            var v = Array(s.utf8)
            if v.count % 2 == 1 { v.append(vr == "UI" ? 0 : 0x20) }
            element(g, e, vr, v, into: &data)
        }
        text(0x0008, 0x0060, "CS", "CT", into: &body)
        text(0x0018, 0x0050, "DS", "2", into: &body)
        text(0x0020, 0x000E, "UI", seriesUID, into: &body)
        text(0x0020, 0x0032, "DS", "0\\0\\\(z)", into: &body)
        text(0x0020, 0x0037, "DS", "1\\0\\0\\0\\1\\0", into: &body)
        element(0x0028, 0x0002, "US", le16(1), into: &body)
        text(0x0028, 0x0004, "CS", "MONOCHROME2", into: &body)
        element(0x0028, 0x0010, "US", le16(8), into: &body)
        element(0x0028, 0x0011, "US", le16(8), into: &body)
        text(0x0028, 0x0030, "DS", "1\\1", into: &body)
        element(0x0028, 0x0100, "US", le16(16), into: &body)
        element(0x0028, 0x0101, "US", le16(16), into: &body)
        element(0x0028, 0x0102, "US", le16(15), into: &body)
        element(0x0028, 0x0103, "US", le16(1), into: &body)
        text(0x0028, 0x1052, "DS", "-1024", into: &body)
        text(0x0028, 0x1053, "DS", "1", into: &body)
        element(0x7FE0, 0x0010, "OW", (0..<64).flatMap { _ in le16(UInt16(bitPattern: value)) }, into: &body)

        var meta = Data()
        element(0x0002, 0x0001, "OB", [0, 1], into: &meta)
        text(0x0002, 0x0002, "UI", "1.2.840.10008.5.1.4.1.1.2", into: &meta)
        text(0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1", into: &meta)
        return Data(count: 128) + Data("DICM".utf8) + meta + body
    }

    private static func pixel(_ image: SliceImage, _ x: Int, _ y: Int) -> [UInt8] {
        switch image {
        case .grayscale(let g):
            let v = g.pixels[y * g.width + x]
            return [v, v, v]
        case .rgb(let c):
            let i = (y * c.width + x) * 3
            return Array(c.pixels[i..<(i + 3)])
        }
    }

    // MARK: - Help and errors list every MIQFileKind

    @Test
    func helpAndErrorsDeriveFormatsFromFileKind() throws {
        let overview = Usage.text(for: nil)
        for suffix in MIQFileKind.allCases.flatMap(\.pathSuffixes) {
            #expect(overview.contains(suffix), "help is missing \(suffix)")
        }
        for family in ["DICOM", "OME-Zarr", "MetaImage", "MRtrix MIH", "NRRD"] {
            #expect(overview.contains(family), "help is missing \(family)")
        }
        #expect(Usage.text(for: "render").contains("--preset"))
        #expect(Usage.text(for: "mosaic").contains("--dec"))

        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("volume.xyz")
        try Data("x".utf8).write(to: bogus)
        do {
            _ = try VolumeLoader.load(path: bogus.path, needsAllVolumes: false)
            Issue.record("expected an unsupported-type error")
        } catch let error as CommandError {
            for suffix in [".mha", ".mhd", ".nhdr", ".mih", ".zarr", ".dcm"] {
                #expect(error.message.contains(suffix), "\(error.message)")
            }
        }
    }

    // MARK: - DICOM folders

    @Test
    func dicomFolderIsAssembledIntoOneVolume() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Extensionless, written out of order; the values identify each slice.
        for (name, z, value) in [("IM0002", 2.0, Int16(1064)), ("IM0001", 0.0, Int16(1024)), ("IM0003", 4.0, Int16(1124))] {
            try Self.dicomSlice(z: z, value: value, seriesUID: "2.25.1001").write(to: dir.appendingPathComponent(name))
        }
        try Data("readme".utf8).write(to: dir.appendingPathComponent("README.txt"))

        let (url, image, kind) = try VolumeLoader.load(path: dir.path, needsAllVolumes: false)
        #expect(kind == .dicom)
        #expect(url.lastPathComponent == dir.lastPathComponent)
        #expect(image.header.dimensions.prefix(3) == [8, 8, 3])
        let volume = MIQVolume(image: image)
        #expect(volume.voxel(x: 0, y: 0, z: 0) == 0)
        #expect(volume.voxel(x: 0, y: 0, z: 1) == 40)
        #expect(volume.voxel(x: 0, y: 0, z: 2) == 100)

        let report = InfoReport(url: url, image: image, kind: kind)
        #expect(report.dimensions.prefix(3) == [8, 8, 3])
        #expect(MIQTool.run(["info", dir.path]) == 0)

        var render = RenderCommand(path: dir.path, output: "-", plane: .coronal)
        render.settings.maxSize = 32
        #expect(throws: Never.self) { try SliceRenderer.render(render) }
        #expect(throws: Never.self) { try SliceRenderer.mosaic(MosaicCommand(path: dir.path, output: "-")) }
    }

    @Test
    func folderWithoutDICOMIsAnError() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        #expect(throws: CommandError.self) { try VolumeLoader.load(path: dir.path, needsAllVolumes: false) }
        #expect(MIQTool.run(["info", dir.path]) == 1)
    }

    // MARK: - CT presets

    @Test
    func parsesPresetsAndDECFlags() throws {
        func settings(_ extra: [String]) throws -> RenderSettings {
            guard case .render(let r) = try ArgumentParser.parse(["render", "a.nii", "-o", "x.png"] + extra) else {
                Issue.record("expected render"); return RenderSettings()
            }
            return r.settings
        }
        #expect(try settings(["--preset", "brain"]).preset == .brain)
        #expect(try settings(["--preset=soft-tissue"]).preset == .softTissue)
        #expect(try settings(["--preset", "Soft_Tissue"]).preset == .softTissue)
        #expect(try settings(["--preset", "AUTO"]).preset == .auto)
        #expect(try settings([]).preset == nil)
        #expect(try settings(["--dec"]).dec == true)
        #expect(try settings(["--no-dec"]).dec == false)
        #expect(try settings([]).dec == nil)
        #expect(ArgumentParser.presetNames == ["brain", "subdural", "stroke", "bone", "lung", "soft-tissue", "auto"])
        for bad in [
            ["--preset", "liver"], ["--preset"], ["--preset", "brain", "--window", "0,100"],
            ["--dec=yes"], ["--dec", "--window", "0,1"], ["--dec", "--preset", "bone"],
        ] {
            #expect(throws: UsageError.self, "\(bad)") { try settings(bad) }
        }
        guard case .mosaic(let m) = try ArgumentParser.parse(["mosaic", "a.nii", "-o", "-", "--preset", "lung", "--no-dec"]) else {
            Issue.record("expected mosaic"); return
        }
        #expect(m.settings.preset == .lung && m.settings.dec == false)
    }

    @Test
    func presetsWindowHounsfieldUnitsAndAutoDetectsCT() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 16³ CT: air (stored 0 → −1024 HU) with a 40 HU cube in the middle.
        let n = 16
        var stored = [Int16](repeating: 0, count: n * n * n)
        for z in 4..<12 { for y in 4..<12 { for x in 4..<12 { stored[(z * n + y) * n + x] = 1064 } } }
        let ct = dir.appendingPathComponent("ct.nii")
        try Self.writeNifti(to: ct, dims: [n, n, n], int16: stored, intercept: -1024)

        var command = RenderCommand(path: ct.path, output: "-")
        command.settings.maxSize = 16
        command.settings.preset = .brain
        let brain = try SliceRenderer.renderSlice(command)
        // Brain window W80/L40: 40 HU is mid-grey, air black.
        #expect(abs(Int(Self.pixel(brain, 8, 8)[0]) - 128) <= 2)
        #expect(Self.pixel(brain, 0, 0)[0] == 0)

        command.settings.preset = .bone
        let bone = try SliceRenderer.renderSlice(command)
        // Bone W1800/L400: 40 HU sits at (40 + 500) / 1800 ≈ 30 %.
        #expect(abs(Int(Self.pixel(bone, 8, 8)[0]) - 76) <= 3)

        command.settings.preset = .auto
        #expect(try SliceRenderer.renderSlice(command).pixels == brain.pixels, "auto picks the brain window for CT")

        // Not CT (float, no air): auto keeps the percentile window.
        let mr = dir.appendingPathComponent("t1.nii")
        try Self.writeNifti(to: mr, dims: [n, n, n], float32: (0..<(n * n * n)).map { Float($0 % 97) })
        var mrCommand = RenderCommand(path: mr.path, output: "-")
        mrCommand.settings.maxSize = 16
        let plain = try SliceRenderer.renderSlice(mrCommand)
        mrCommand.settings.preset = .auto
        #expect(try SliceRenderer.renderSlice(mrCommand).pixels == plain.pixels)
    }

    // MARK: - Direction-encoded colour

    @Test
    func vectorFieldRendersDirectionEncodedColour() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 8
        let count = n * n * n
        // Volume 0..2 = x, y, z components: a pure left–right vector everywhere.
        let values = [Float](repeating: 1, count: count) + [Float](repeating: 0, count: count * 2)
        let v1 = dir.appendingPathComponent("dti_V1.nii")
        try Self.writeNifti(to: v1, dims: [n, n, n, 3], float32: values)

        var command = RenderCommand(path: v1.path, output: "-")
        command.settings.maxSize = 16
        let dec = try SliceRenderer.renderSlice(command)
        guard case .rgb = dec else { Issue.record("expected an RGB slice"); return }
        #expect(Self.pixel(dec, 8, 8) == [255, 0, 0])

        command.settings.dec = false
        command.settings.segmentation = .off   // components of 0/1 would look like labels
        guard case .grayscale = try SliceRenderer.renderSlice(command) else {
            Issue.record("--no-dec renders a grayscale component"); return
        }
        command.settings.dec = nil
        command.settings.window = .fixed(low: 0, high: 1)
        guard case .grayscale = try SliceRenderer.renderSlice(command) else {
            Issue.record("an explicit window asks for scalar display"); return
        }

        var mosaic = MosaicCommand(path: v1.path, output: "-")
        mosaic.settings.maxSize = 16
        let canvas = try SliceRenderer.mosaicCanvas(mosaic)
        // Center of the axial (bottom-left) tile is red.
        let side = canvas.width
        let i = ((16 + Mosaic.gap + 8) * side + 8) * 3
        #expect(Array(canvas.pixels[i..<(i + 3)]) == [255, 0, 0])

        // --dec on a scalar file is an error.
        let scalar = dir.appendingPathComponent("t1.nii")
        try Self.writeNifti(to: scalar, dims: [n, n, n], float32: [Float](repeating: 1, count: count))
        var forced = RenderCommand(path: scalar.path, output: "-")
        forced.settings.dec = true
        #expect(throws: CommandError.self) { try SliceRenderer.render(forced) }
    }

    // MARK: - MIF orientation

    @Test
    func mifInfoNamesStorageAndMRtrixImageAxes() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // `file: . <offset>` points just past the header: iterate to a fixed point.
        var offset = 0
        var header = ""
        repeat {
            let previous = offset
            header = "mrtrix image\ndim: 4,3,2\nvox: 1,1,1\nlayout: -0,+1,+2\ndatatype: UInt8\n"
                + "transform: 1,0,0,0\ntransform: 0,1,0,0\ntransform: 0,0,1,0\nfile: . \(offset)\nEND\n"
            offset = header.utf8.count
            if offset == previous { break }
        } while true
        var data = Data(header.utf8)
        data.append(Data((0..<24).map { UInt8($0) }))
        let url = dir.appendingPathComponent("t1.mif")
        try data.write(to: url)

        let (_, image, kind) = try VolumeLoader.load(path: url.path, needsAllVolumes: false)
        let report = InfoReport(url: url, image: image, kind: kind)
        #expect(report.orientation == "LAS")
        #expect(report.imageOrientation == "RAS")
        #expect(report.text().contains("LAS · MRtrix image axes RAS · MIF transform"))
    }
}
