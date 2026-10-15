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
    /// 3-letter orientation of MIQ's voxel grid (e.g. "RAS"), `null` when
    /// undeterminable. MIQ walks every format's payload in storage order, so for
    /// an MRtrix MIF whose `layout` flips or permutes axes this is the *storage*
    /// orientation ("LAS" for `layout: -0,+1,+2` with an RAS transform) — see
    /// `imageOrientation` for what MRtrix reports.
    let orientation: String?
    /// MRtrix MIF only: orientation of MRtrix's image axes (the `transform:`
    /// alone), which is what `mrinfo`/`mrview` voxel indices refer to; `null` for
    /// other formats. Equals `orientation` when `layout` is `+0,+1,+2`.
    let imageOrientation: String?
    let qformCode: Int
    let sformCode: Int
    let scaling: Scaling
    let display: [DisplayLine]

    /// - Parameter includePHI: Keep rows whose field `mayContainPHI` (free text
    ///   such as NIfTI `descrip` or MIF `command_history`). Off by default, so
    ///   output pasted into a bug report or a script's log carries no free text.
    init(url: URL, image: MIQImage, kind: MIQFileKind, includePHI: Bool = false) {
        let header = image.header
        let volume = MIQVolume(image: image)
        let orientation = volume.storageOrientationLabel()
        // Same row text as the preview panel ("RAS · sform", "LAS · MRtrix image
        // axes RAS · MIF transform"), so the transform source is visible too.
        let metadata = MIQMetadata(header: header, orientation: header.orientationDiagnostics.displaySummary)

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
        imageOrientation = header.orientationDiagnostics.imageAxisCodes
        qformCode = header.qformCode
        sformCode = header.sformCode
        scaling = Scaling(
            slope: header.sclSlope.isFinite ? Double(header.sclSlope) : nil,
            intercept: header.sclInter.isFinite ? Double(header.sclInter) : nil
        )
        display = [DisplayLine(label: "Format", value: format)]
            + metadata.asDisplayLines()
                .filter { includePHI || $0.field?.mayContainPHI != true }
                .map { DisplayLine(label: $0.label, value: $0.value) }
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
    /// Parses `path`: a file `MIQFileKind` recognises by name, an extensionless
    /// DICOM Part-10 file (content sniff), or a folder of DICOM slices (stacked by
    /// `DICOMSeriesAssembler`; the CLI has ordinary file access, unlike the
    /// sandboxed preview). `needsAllVolumes` re-parses a `.nii.gz` in full instead of
    /// the preview's volume-0 cap, which `--volume > 0` and DEC colouring require.
    static func load(path: String, needsAllVolumes: Bool) throws -> (URL, MIQImage, MIQFileKind) {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CommandError("no such file: \(path)")
        }
        if isDirectory.boolValue, MIQFileKind(url: url) != .zarr {
            return try loadDICOMFolder(url)
        }
        guard let kind = MIQFileKind(url: url) ?? MIQFileKind.sniffDICOM(url: url) else {
            throw CommandError("unsupported file type: \(url.lastPathComponent) "
                + "(expected \(Usage.suffixList), a DICOM file or a folder of DICOM slices)")
        }
        return (url, try parse(url, fullyDecompress: needsAllVolumes), kind)
    }

    private static func parse(_ url: URL, fullyDecompress: Bool) throws -> MIQImage {
        do {
            return try MIQParser().parse(url: url, fullyDecompress: fullyDecompress)
        } catch let error as LocalizedError {
            throw CommandError("cannot read \(url.lastPathComponent): \(error.errorDescription ?? "\(error)")")
        } catch {
            throw CommandError("cannot read \(url.lastPathComponent): \(error)")
        }
    }

    /// Stacks the folder's largest DICOM series (most files, the same choice as
    /// the app's Brain Mask tool). A folder with a single DICOM file renders that
    /// file. The returned URL is the folder, so `info` reports the folder name.
    static func loadDICOMFolder(_ folder: URL) throws -> (URL, MIQImage, MIQFileKind) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            throw CommandError("cannot list folder \(folder.lastPathComponent)")
        }
        let dicoms = entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { MIQFileKind.sniffDICOM(url: $0) != nil }
        guard let first = dicoms.first else {
            throw CommandError("\(folder.lastPathComponent) is a folder with no DICOM Part-10 files "
                + "(a folder is read only as a DICOM series; otherwise expected \(Usage.suffixList))")
        }
        if dicoms.count == 1 {
            return (folder, try parse(first, fullyDecompress: true), .dicom)
        }
        let assembler = DICOMSeriesAssembler(maxFiles: max(2048, entries.count))
        guard let series = assembler.assembleLargestSeries(inFolder: folder) else {
            throw CommandError("cannot assemble a volume from the \(dicoms.count) DICOM files in \(folder.lastPathComponent) "
                + "(slices need position/orientation; mixed sizes, several slices at one position, "
                + "or over 1 GiB are not stacked) — pass one file instead")
        }
        return (folder, series.image, .dicom)
    }
}

// MARK: - Rendering

enum SliceRenderer {
    /// The fixed preset `--preset auto` applies to a volume that looks like CT. MIQ's
    /// audience is mostly neuroimaging, so the brain window is the useful default;
    /// `--preset soft-tissue` etc. cover body CT.
    static let ctAutoPreset: WindowPreset = .brain

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

    /// Whether `volume` holds CT Hounsfield units, decided the way the preview
    /// decides whether to offer presets: `WindowPreset.looksLikeCT` on the header
    /// plus the minimum of the center axial slice of the rendered volume.
    static func looksLikeCT(_ volume: MIQVolume, settings: RenderSettings) -> Bool {
        let header = volume.image.header
        guard header.datatype != .rgb24, header.datatype != .rgba32 else { return false }
        let options = renderingOptions(settings)
        let index = volume.sliceIndex(for: .axial, cursor: volume.centerCursor(), options: options)
        var minimum: Float?
        if let sample = volume.displaySliceValues(plane: .axial, index: index, volumeIndex: settings.volume, options: options) {
            for v in sample.values where v.isFinite { minimum = min(minimum ?? v, v) }
        }
        return WindowPreset.looksLikeCT(header: header, sampleMin: minimum)
    }

    /// `settings` with `--preset` folded into `window`: a fixed preset becomes its
    /// HU bounds; `auto` becomes `ctAutoPreset`'s bounds for CT and stays the
    /// percentile window otherwise.
    static func resolvingPreset(_ settings: RenderSettings, volume: MIQVolume) -> RenderSettings {
        guard let preset = settings.preset else { return settings }
        let chosen: WindowPreset?
        if preset == .auto {
            chosen = looksLikeCT(volume, settings: settings) ? ctAutoPreset : nil
        } else {
            chosen = preset
        }
        var resolved = settings
        if let bounds = chosen?.bounds {
            resolved.window = .fixed(low: bounds.low, high: bounds.high)
        }
        return resolved
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

    /// Whether DEC colouring is wanted at all (before looking at the file):
    /// `--dec`/`--no-dec` decide; otherwise on unless a window or preset asks for
    /// scalar display.
    static func wantsDEC(_ settings: RenderSettings) -> Bool {
        if let explicit = settings.dec { return explicit }
        return settings.preset == nil && settings.window == .auto
    }

    /// Loads the volume to render. When DEC may apply and the first parse doesn't
    /// yield a vector field although the shape fits (a `.nii.gz` parsed with the
    /// preview's volume-0 cap), re-parses in full so `DiffusionColor.vectorComponents`
    /// sees every component.
    static func load(path: String, settings: RenderSettings) throws -> (volume: MIQVolume, fileName: String) {
        let full = settings.volume > 0 || settings.dec == true
        let (url, image, _) = try VolumeLoader.load(path: path, needsAllVolumes: full)
        var volume = MIQVolume(image: image)
        if !full, wantsDEC(settings), volume.volumes == 3 || volume.componentCount == 3,
           DiffusionColor.vectorComponents(of: volume, fileName: url.lastPathComponent) == nil {
            volume = MIQVolume(image: try VolumeLoader.load(path: path, needsAllVolumes: true).1)
        }
        return (volume, url.lastPathComponent)
    }

    /// The vector components to colour, or `nil` for scalar rendering. Throws for
    /// `--dec` on a file that isn't a recognised 3-vector field.
    static func decComponents(_ volume: MIQVolume, fileName: String, settings: RenderSettings) throws -> MIQVolume? {
        guard wantsDEC(settings) else { return nil }
        if let components = DiffusionColor.vectorComponents(of: volume, fileName: fileName) { return components }
        if settings.dec == true {
            throw CommandError("--dec: \(fileName) is not a 3-component vector field "
                + "(expected 3 volumes with 'V1' in the name or NIfTI intent 1007, or a 5D NIfTI with 3 components)")
        }
        return nil
    }

    static func render(_ command: RenderCommand) throws -> Data {
        try PNGEncoder.encode(renderSlice(command))
    }

    /// The slice `render` encodes (DEC RGB, label colours or windowed grayscale).
    static func renderSlice(_ command: RenderCommand) throws -> SliceImage {
        let (volume, fileName) = try load(path: command.path, settings: command.settings)
        try validateVolume(volume, settings: command.settings)
        let settings = resolvingPreset(command.settings, volume: volume)
        let options = renderingOptions(settings)

        let geometry = volume.sliceGeometry(for: command.plane, options: options)
        let extent = [volume.width, volume.height, volume.depth][geometry.sliceAxis]
        let index = command.slice ?? max(0, extent / 2)
        guard index < extent else {
            throw CommandError("--slice \(index) is out of range for the \(command.plane.rawValue) plane (valid: 0–\(extent - 1))")
        }

        if let components = try decComponents(volume, fileName: fileName, settings: settings) {
            guard let slice = DiffusionColor.slice(components: components, plane: command.plane, index: index,
                                                   maxDimension: settings.maxSize, options: options) else {
                throw CommandError("cannot colour \(fileName) by direction")
            }
            return slice
        }

        let (window, lut) = resolveAppearance(volume: volume, settings: settings, options: options)
        return volume.slice(
            plane: command.plane,
            index: index,
            volumeIndex: settings.volume,
            maxDimension: settings.maxSize,
            options: options,
            windowBounds: window,
            lut: lut
        )
    }

    static func mosaic(_ command: MosaicCommand) throws -> Data {
        let canvas = try mosaicCanvas(command)
        return try PNGEncoder.encode(pixels: canvas.pixels, width: canvas.width, height: canvas.height, colorType: .rgb8)
    }

    /// The RGB canvas `mosaic` encodes.
    static func mosaicCanvas(_ command: MosaicCommand) throws -> Mosaic.Canvas {
        let (volume, fileName) = try load(path: command.path, settings: command.settings)
        try validateVolume(volume, settings: command.settings)
        let settings = resolvingPreset(command.settings, volume: volume)
        let options = renderingOptions(settings)
        let components = try decComponents(volume, fileName: fileName, settings: settings)
        let (window, lut): (MIQIntensityWindowBounds?, SegmentationLut?) = components == nil
            ? resolveAppearance(volume: volume, settings: settings, options: options) : (nil, nil)

        func center(_ plane: SlicePlane) -> SliceImage? {
            if let components {
                // Same center index `MIQVolume.centerSlice` uses for this plane.
                let axis = volume.sliceGeometry(for: plane, options: options).sliceAxis
                let index = max(0, [volume.width, volume.height, volume.depth][axis] / 2)
                return DiffusionColor.slice(components: components, plane: plane, index: index,
                                            maxDimension: settings.maxSize, options: options)
            }
            return volume.centerSlice(
                plane: plane,
                volumeIndex: settings.volume,
                maxDimension: settings.maxSize,
                options: options,
                windowBounds: window,
                lut: lut
            )
        }
        return Mosaic.compose(
            topLeft: center(.coronal),
            topRight: center(.sagittal),
            bottomLeft: center(.axial),
            tile: settings.maxSize
        )
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
