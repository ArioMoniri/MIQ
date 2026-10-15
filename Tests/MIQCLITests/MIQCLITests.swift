import Foundation
import Testing
import MIQCore
@testable import miq

struct ArgumentParsingTests {
    @Test
    func noArgumentsAndHelpFlagsShowHelp() throws {
        #expect(try ArgumentParser.parse([]) == .help(topic: nil))
        #expect(try ArgumentParser.parse(["--help"]) == .help(topic: nil))
        #expect(try ArgumentParser.parse(["help", "render"]) == .help(topic: "render"))
        #expect(try ArgumentParser.parse(["mosaic", "-h"]) == .help(topic: "mosaic"))
    }

    @Test
    func parsesInfo() throws {
        #expect(try ArgumentParser.parse(["info", "a.nii.gz"]) == .info(InfoCommand(path: "a.nii.gz", json: false)))
        #expect(try ArgumentParser.parse(["info", "--json", "a.nii"]) == .info(InfoCommand(path: "a.nii", json: true)))
        #expect(try ArgumentParser.parse(["info", "a.nii", "--json"]) == .info(InfoCommand(path: "a.nii", json: true)))
        #expect(try ArgumentParser.parse(["info", "--include-phi", "a.nii"]) == .info(InfoCommand(path: "a.nii", includePHI: true)))
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["info", "--include-phi=1", "a.nii"]) }
    }

    @Test
    func parsesRenderWithDefaults() throws {
        let parsed = try ArgumentParser.parse(["render", "x.mgz", "-o", "out.png"])
        #expect(parsed == .render(RenderCommand(path: "x.mgz", output: "out.png")))
        guard case .render(let render) = parsed else { return }
        #expect(render.plane == .axial)
        #expect(render.slice == nil)
        #expect(render.settings == RenderSettings())
    }

    @Test
    func parsesRenderWithEveryOption() throws {
        let parsed = try ArgumentParser.parse([
            "render", "--plane", "Coronal", "--slice=12", "--volume", "3",
            "--window", "-1000,400", "--orientation", "radiological",
            "--segmentation", "off", "--max-size", "300", "--output=o.png", "in.nii",
        ])
        var expected = RenderCommand(path: "in.nii", output: "o.png", plane: .coronal, slice: 12)
        expected.settings = RenderSettings(
            volume: 3,
            window: .fixed(low: -1000, high: 400),
            orientation: .radiological,
            segmentation: .off,
            maxSize: 300
        )
        #expect(parsed == .render(expected))
    }

    @Test
    func doubleDashAllowsDashPrefixedPaths() throws {
        #expect(try ArgumentParser.parse(["info", "--", "-weird.nii"]) == .info(InfoCommand(path: "-weird.nii")))
    }

    @Test
    func mosaicDefaultsToSmallerTiles() throws {
        guard case .mosaic(let mosaic) = try ArgumentParser.parse(["mosaic", "v.mif", "-o", "-"]) else {
            Issue.record("expected mosaic"); return
        }
        #expect(mosaic.output == "-")
        #expect(mosaic.settings.maxSize == 256)
        #expect(mosaic.settings.window == .auto)
    }

    @Test
    func parsesWindowSpecs() throws {
        #expect(try ArgumentParser.parseWindow("auto") == .auto)
        #expect(try ArgumentParser.parseWindow("AUTO") == .auto)
        #expect(try ArgumentParser.parseWindow("0,255") == .fixed(low: 0, high: 255))
        #expect(try ArgumentParser.parseWindow("-0.5, 1.5e3") == .fixed(low: -0.5, high: 1500))
        for bad in ["", "5", "1,2,3", "a,b", "10,5", "3,3", "nan,1", "0,inf"] {
            #expect(throws: UsageError.self, "'\(bad)' must be rejected") { try ArgumentParser.parseWindow(bad) }
        }
    }

    @Test
    func reportsUsageErrors() {
        let cases: [[String]] = [
            ["frobnicate"],
            ["info"],
            ["info", "a.nii", "b.nii"],
            ["info", "--bogus", "a.nii"],
            ["info", "--json=yes", "a.nii"],
            ["render", "a.nii"],                         // no -o
            ["render", "a.nii", "-o"],                   // -o without value
            ["render", "a.nii", "-o", "x.png", "--plane", "oblique"],
            ["render", "a.nii", "-o", "x.png", "--slice", "-1"],
            ["render", "a.nii", "-o", "x.png", "--volume", "two"],
            ["render", "a.nii", "-o", "x.png", "--orientation", "upside-down"],
            ["render", "a.nii", "-o", "x.png", "--segmentation", "freesurfer"],
            ["render", "a.nii", "-o", "x.png", "--max-size", "8"],
            ["mosaic", "a.nii", "-o", "x.png", "--slice", "3"], // render-only flag
        ]
        for args in cases {
            #expect(throws: UsageError.self, "\(args)") { try ArgumentParser.parse(args) }
        }
    }

    @Test
    func usageErrorsCarryTheirSubcommandTopic() {
        do {
            _ = try ArgumentParser.parse(["render", "a.nii", "--plane", "oblique", "-o", "x.png"])
            Issue.record("expected an error")
        } catch let error as UsageError {
            #expect(error.topic == "render")
            #expect(error.message.contains("oblique"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

struct MosaicTests {
    @Test
    func placesSlicesInPreviewQuadrantsCentered() {
        let tile = 4
        let gray = SliceImage.grayscale(GrayscaleImage(width: 2, height: 4, pixels: [UInt8](repeating: 200, count: 8)))
        let colour = SliceImage.rgb(RGBImage(width: 4, height: 2, pixels: Array(repeating: [UInt8]([10, 20, 30]), count: 8).flatMap { $0 }))
        let canvas = Mosaic.compose(topLeft: gray, topRight: colour, bottomLeft: gray, tile: tile)
        let size = tile * 2 + Mosaic.gap
        #expect(canvas.width == size && canvas.height == size)
        #expect(canvas.pixels.count == size * size * 3)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * size + x) * 3
            return Array(canvas.pixels[i..<(i + 3)])
        }
        // Top-left: 2-wide slice centered → columns 1...2 filled, 0 and 3 black.
        #expect(pixel(0, 0) == [0, 0, 0])
        #expect(pixel(1, 0) == [200, 200, 200])
        #expect(pixel(2, 3) == [200, 200, 200])
        #expect(pixel(3, 0) == [0, 0, 0])
        // Top-right: 2-tall colour slice centered vertically → rows 1...2.
        let right = tile + Mosaic.gap
        #expect(pixel(right, 0) == [0, 0, 0])
        #expect(pixel(right, 1) == [10, 20, 30])
        #expect(pixel(right + 3, 2) == [10, 20, 30])
        // Bottom-left filled, bottom-right (metadata quadrant) blank.
        #expect(pixel(1, right) == [200, 200, 200])
        #expect(pixel(right + 1, right + 1) == [0, 0, 0])
    }
}

/// End-to-end over a tiny on-disk NIfTI-1 fixture.
struct CommandExecutionTests {
    /// Minimal little-endian NIfTI-1 (`n+1`) with uint8 voxels `value = index % 251`.
    static func writeNifti(width: Int, height: Int, depth: Int, volumes: Int = 1, pixdim: [Float] = [1, 1, 1], descrip: String? = nil) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 352)
        func put<T: FixedWidthInteger>(_ v: T, _ at: Int) {
            withUnsafeBytes(of: v.littleEndian) { for (i, b) in $0.enumerated() { bytes[at + i] = b } }
        }
        func putF(_ v: Float, _ at: Int) { put(v.bitPattern, at) }
        put(Int32(348), 0)
        put(Int16(volumes > 1 ? 4 : 3), 40)
        put(Int16(width), 42); put(Int16(height), 44); put(Int16(depth), 46); put(Int16(volumes), 48)
        put(Int16(2), 70)   // DT_UINT8
        put(Int16(8), 72)
        putF(1, 76)
        for (i, p) in pixdim.enumerated() { putF(p, 80 + i * 4) }
        putF(352, 108)
        putF(1, 112)
        bytes.replaceSubrange(344..<348, with: Array("n+1\0".utf8))
        if let descrip { bytes.replaceSubrange(148..<(148 + descrip.utf8.count), with: Array(descrip.utf8)) }
        let count = width * height * depth * volumes
        let payload = (0..<count).map { UInt8($0 % 251) }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("miq-cli-\(UUID().uuidString).nii")
        try Data(bytes + payload).write(to: url)
        return url
    }

    private static func pngSize(_ data: Data) -> (Int, Int)? {
        let b = [UInt8](data)
        guard b.count > 24, Array(b[0..<8]) == PNGEncoder.signature else { return nil }
        func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (be(16), be(20))
    }

    @Test
    func infoReportsHeaderFieldsAndJSON() throws {
        let url = try Self.writeNifti(width: 6, height: 5, depth: 4, volumes: 2, pixdim: [0.5, 1, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, image, kind) = try VolumeLoader.load(path: url.path, needsAllVolumes: false)
        let report = InfoReport(url: url, image: image, kind: kind)
        #expect(report.file == url.lastPathComponent)
        #expect(report.dimensions.prefix(4) == [6, 5, 4, 2])
        #expect(report.spacing == [0.5, 1, 2])
        #expect(report.volumes == 2)
        #expect(report.datatype == MIQDatatype.uint8.label)
        #expect(report.display.first?.label == "Format")
        #expect(report.text().contains("Dimensions"))

        let json = try JSONSerialization.jsonObject(with: try report.jsonData()) as? [String: Any]
        #expect(json?["volumes"] as? Int == 2)
        #expect(json?["file"] as? String == url.lastPathComponent)
        #expect((json?["display"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test
    func infoOmitsPHIRowsUnlessIncludePHI() throws {
        let url = try Self.writeNifti(width: 4, height: 4, depth: 2, descrip: "DOE^JOHN 1970-01-01")
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, image, kind) = try VolumeLoader.load(path: url.path, needsAllVolumes: false)

        let redacted = InfoReport(url: url, image: image, kind: kind)
        #expect(!redacted.text().contains("DOE^JOHN"))
        #expect(!String(decoding: try redacted.jsonData(), as: UTF8.self).contains("DOE"))
        #expect(!redacted.display.contains { $0.label == MetadataField.description.displayLabel })

        let full = InfoReport(url: url, image: image, kind: kind, includePHI: true)
        #expect(full.text().contains("DOE^JOHN"))
        #expect(full.display.contains { $0.label == MetadataField.description.displayLabel })
    }

    @Test
    func renderProducesPNGOfSliceSizeAndValidatesRanges() throws {
        let url = try Self.writeNifti(width: 8, height: 6, depth: 4, volumes: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let axial = try SliceRenderer.render(RenderCommand(path: url.path, output: "-", plane: .axial))
        #expect(Self.pngSize(axial).map { [$0.0, $0.1] } == [512, 384])

        var small = RenderCommand(path: url.path, output: "-", plane: .sagittal, slice: 0)
        small.settings.maxSize = 60
        small.settings.volume = 1
        small.settings.window = .fixed(low: 0, high: 100)
        let sagittal = try SliceRenderer.render(small)
        #expect(Self.pngSize(sagittal) != nil)

        var badSlice = RenderCommand(path: url.path, output: "-", plane: .axial, slice: 4)
        #expect(throws: CommandError.self) { try SliceRenderer.render(badSlice) }
        badSlice.slice = nil
        badSlice.settings.volume = 2
        #expect(throws: CommandError.self) { try SliceRenderer.render(badSlice) }
    }

    @Test
    func mosaicIsSquareTwoByTwo() throws {
        let url = try Self.writeNifti(width: 8, height: 6, depth: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try SliceRenderer.mosaic(MosaicCommand(path: url.path, output: "-"))
        let side = 256 * 2 + Mosaic.gap
        #expect(Self.pngSize(png).map { [$0.0, $0.1] } == [side, side])
    }

    @Test
    func runMapsOutcomesToExitStatus() throws {
        #expect(MIQTool.run(["bogus"]) == 2)
        #expect(MIQTool.run(["info", "/nonexistent/file.nii"]) == 1)

        let url = try Self.writeNifti(width: 4, height: 4, depth: 4)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("miq-cli-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: out)
        }
        #expect(MIQTool.run(["render", url.path, "--plane", "coronal", "-o", out.path]) == 0)
        #expect(Self.pngSize(try Data(contentsOf: out)) != nil)
    }
}
