import Foundation
import MIQCore

/// A failure while running a well-formed command (unreadable file, slice out of
/// range, …); printed as `miq: error: …`, exit status 1.
struct CommandError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - info

/// Header summary for `miq info`. Field names are the stable JSON contract;
/// `display` mirrors the preview's metadata panel (`MIQMetadata.asDisplayLines()`)
/// so any field the panel gains shows up here without a CLI change.
struct InfoReport: Encodable, Equatable {
    struct Scaling: Encodable, Equatable {
        let slope: Double?
        let intercept: Double?
    }

    struct DisplayLine: Encodable, Equatable {
        let label: String
        let value: String
    }

    /// File name only — never the full path, so pasted output does not leak a
    /// directory structure that may itself identify a subject.
    let file: String
    let format: String
    let dimensions: [Int]
    /// Voxel size along x, y, z as stored in the header (`pixdim[1...3]`).
    /// Non-finite values are reported as `null`.
    let spacing: [Double?]
    let datatype: String
    let volumes: Int
    /// 3-letter storage orientation (e.g. "RAS"), `null` when undeterminable.
    let orientation: String?
    let qformCode: Int
    let sformCode: Int
    let scaling: Scaling
    let display: [DisplayLine]

    init(url: URL, image: MIQImage, kind: MIQFileKind) {
        let header = image.header
        let volume = MIQVolume(image: image)
        let orientation = volume.storageOrientationLabel()
        let metadata = MIQMetadata(header: header, orientation: orientation)

        file = url.lastPathComponent
        format = header.formatLabel ?? kind.displayName
        dimensions = header.dimensions
        spacing = (1...3).map { index in
            guard header.pixdim.indices.contains(index), header.pixdim[index].isFinite else { return nil }
            return Double(header.pixdim[index])
        }
        datatype = header.datatypeLabel ?? header.datatype.label
        volumes = header.volumes
        self.orientation = orientation
        qformCode = header.qformCode
        sformCode = header.sformCode
        scaling = Scaling(
            slope: header.sclSlope.isFinite ? Double(header.sclSlope) : nil,
            intercept: header.sclInter.isFinite ? Double(header.sclInter) : nil
        )
        display = [DisplayLine(label: "Format", value: format)]
            + metadata.asDisplayLines().map { DisplayLine(label: $0.label, value: $0.value) }
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    func text() -> String {
        var rows = [DisplayLine(label: "File", value: file)] + display
        rows.append(DisplayLine(label: "qform/sform", value: "\(qformCode) / \(sformCode)"))
        let width = rows.map(\.label.count).max() ?? 0
        return rows.map { row in
            let pad = String(repeating: " ", count: max(0, width - row.label.count))
            return "\(row.label):\(pad) \(row.value)"
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - Loading

enum VolumeLoader {
    /// Parses `path`. `needsAllVolumes` re-parses a `.nii.gz` in full instead of
    /// the preview's volume-0 cap, which `--volume > 0` requires.
    static func load(path: String, needsAllVolumes: Bool) throws -> (URL, MIQImage, MIQFileKind) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CommandError("no such file: \(path)")
        }
        guard let kind = MIQFileKind(url: url) else {
            throw CommandError("unsupported file type: \(url.lastPathComponent) "
                + "(expected .nii, .nii.gz, .mgh, .mgz, .mgh.gz, .mif, .mif.gz, .mih, .nrrd, .nhdr, .mha or .mhd)")
        }
        do {
            let image = try MIQParser().parse(url: url, fullyDecompress: needsAllVolumes)
            return (url, image, kind)
        } catch let error as LocalizedError {
            throw CommandError("cannot read \(url.lastPathComponent): \(error.errorDescription ?? "\(error)")")
        } catch {
            throw CommandError("cannot read \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - Rendering

enum SliceRenderer {
    static func renderingOptions(_ settings: RenderSettings) -> RenderingOptions {
        // An explicit window means "show these intensities", which a label LUT
        // would override — so it implies segmentation colouring off.
        let segmentation: SegmentationColoring
        if case .fixed = settings.window { segmentation = .off } else { segmentation = settings.segmentation }
        return RenderingOptions(
            lowerPercentile: MIQConfig.Defaults.windowLowerPercentile,
            upperPercentile: MIQConfig.Defaults.windowUpperPercentile,
            orientation: settings.orientation,
            segmentationColoring: segmentation
        )
    }

    /// Window + LUT the way the preview resolves them on a cold load: a detected
    /// segmentation LUT replaces windowing; otherwise the center-slice pooled
    /// window (or the explicit bounds) is shared by every rendered plane.
    static func resolveAppearance(
        volume: MIQVolume,
        settings: RenderSettings,
        options: RenderingOptions
    ) -> (MIQIntensityWindowBounds?, SegmentationLut?) {
        switch settings.window {
        case .fixed(let low, let high):
            return (MIQIntensityWindowBounds(low: low, high: high), nil)
        case .auto:
            let lut = options.segmentationColoring == .off ? nil : volume.buildSegmentationLut(options: options)
            if let lut { return (nil, lut) }
            return (volume.fixedCenterWindow(volumeIndex: settings.volume, options: options), nil)
        }
    }

    static func validateVolume(_ volume: MIQVolume, settings: RenderSettings) throws {
        guard settings.volume < volume.volumes else {
            throw CommandError("--volume \(settings.volume) is out of range (file has \(volume.volumes) volume\(volume.volumes == 1 ? "" : "s"); valid: 0–\(volume.volumes - 1))")
        }
    }

    static func render(_ command: RenderCommand) throws -> Data {
        let (_, image, _) = try VolumeLoader.load(path: command.path, needsAllVolumes: command.settings.volume > 0)
        let volume = MIQVolume(image: image)
        try validateVolume(volume, settings: command.settings)
        let options = renderingOptions(command.settings)

        let geometry = volume.sliceGeometry(for: command.plane, options: options)
        let extent = [volume.width, volume.height, volume.depth][geometry.sliceAxis]
        let index = command.slice ?? max(0, extent / 2)
        guard index < extent else {
            throw CommandError("--slice \(index) is out of range for the \(command.plane.rawValue) plane (valid: 0–\(extent - 1))")
        }

        let (window, lut) = resolveAppearance(volume: volume, settings: command.settings, options: options)
        let slice = volume.slice(
            plane: command.plane,
            index: index,
            volumeIndex: command.settings.volume,
            maxDimension: command.settings.maxSize,
            options: options,
            windowBounds: window,
            lut: lut
        )
        return try PNGEncoder.encode(slice)
    }

    static func mosaic(_ command: MosaicCommand) throws -> Data {
        let (_, image, _) = try VolumeLoader.load(path: command.path, needsAllVolumes: command.settings.volume > 0)
        let volume = MIQVolume(image: image)
        try validateVolume(volume, settings: command.settings)
        let options = renderingOptions(command.settings)
        let (window, lut) = resolveAppearance(volume: volume, settings: command.settings, options: options)

        func center(_ plane: SlicePlane) -> SliceImage {
            volume.centerSlice(
                plane: plane,
                volumeIndex: command.settings.volume,
                maxDimension: command.settings.maxSize,
                options: options,
                windowBounds: window,
                lut: lut
            )
        }
        let canvas = Mosaic.compose(
            topLeft: center(.coronal),
            topRight: center(.sagittal),
            bottomLeft: center(.axial),
            tile: command.settings.maxSize
        )
        return try PNGEncoder.encode(pixels: canvas.pixels, width: canvas.width, height: canvas.height, colorType: .rgb8)
    }
}

/// 2×2 tile layout matching the Quick Look preview (coronal | sagittal over
/// axial | metadata). Slices from one volume share a physical scale already
/// (`MIQVolume` resamples every plane against the same largest extent), so each
/// is centered at its native size in a square `tile` cell — no further scaling,
/// which would break that shared scale. The fourth cell stays black.
enum Mosaic {
    struct Canvas: Equatable {
        let width: Int
        let height: Int
        /// Interleaved RGB8.
        let pixels: [UInt8]
    }

    /// Gap between cells, in pixels, matching the preview's thin separators.
    static let gap = 2

    static func compose(topLeft: SliceImage?, topRight: SliceImage?, bottomLeft: SliceImage?, tile: Int) -> Canvas {
        let size = tile * 2 + gap
        var pixels = [UInt8](repeating: 0, count: size * size * 3)
        let cells: [(SliceImage?, Int, Int)] = [
            (topLeft, 0, 0),
            (topRight, tile + gap, 0),
            (bottomLeft, 0, tile + gap),
        ]
        for (image, originX, originY) in cells {
            guard let image else { continue }
            blit(image, into: &pixels, canvasWidth: size, cellX: originX, cellY: originY, cell: tile)
        }
        return Canvas(width: size, height: size, pixels: pixels)
    }

    private static func blit(_ image: SliceImage, into canvas: inout [UInt8], canvasWidth: Int, cellX: Int, cellY: Int, cell: Int) {
        let channels: Int
        switch image {
        case .grayscale: channels = 1
        case .rgb: channels = 3
        }
        let src = image.pixels
        let w = image.width, h = image.height
        guard w > 0, h > 0, src.count == w * h * channels else { return }
        // Center inside the cell; crop defensively if a slice ever exceeds it.
        let offsetX = max(0, (cell - w) / 2)
        let offsetY = max(0, (cell - h) / 2)
        for y in 0..<min(h, cell) {
            let dstRow = ((cellY + offsetY + y) * canvasWidth + cellX + offsetX) * 3
            let srcRow = y * w * channels
            for x in 0..<min(w, cell) {
                let d = dstRow + x * 3
                let s = srcRow + x * channels
                if channels == 1 {
                    canvas[d] = src[s]; canvas[d + 1] = src[s]; canvas[d + 2] = src[s]
                } else {
                    canvas[d] = src[s]; canvas[d + 1] = src[s + 1]; canvas[d + 2] = src[s + 2]
                }
            }
        }
    }
}
