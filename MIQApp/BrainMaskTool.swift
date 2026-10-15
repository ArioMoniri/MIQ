import AppKit
import CoreGraphics
import MIQCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scene and menu command

/// "Tools → Brain Mask…": an app-only window that runs a bundled brainchop MeshNet
/// (MIT) on a volume the user picks, previews the mask outline and saves it as a
/// BIDS-style NIfTI. Never part of the Quick Look extension: a run takes seconds
/// and hundreds of megabytes, far beyond a preview's latency and memory budget.
enum BrainMaskTool {
    static let windowID = "brain-mask"
    static var disclaimer: String {
        String(localized: "Brain mask for data preparation/QC only. Not a medical device; not for diagnosis.")
    }
}

/// The tool's window. Added to `MIQApp.body` next to the main `WindowGroup`.
struct BrainMaskWindowScene: Scene {
    var body: some Scene {
        Window("Brain Mask", id: BrainMaskTool.windowID) {
            BrainMaskToolView()
        }
        .defaultSize(width: 720, height: 760)
        // Never opened for a file handed over by Finder; see
        // `AppDelegate.application(_:open:)`. Without this, SwiftUI would pick
        // this scene for the event once the main WindowGroup opts out.
        .handlesExternalEvents(matching: [])
    }
}

/// The "Tools" menu holding the "Brain Mask…" item. Added to `MIQApp`'s `.commands`.
struct BrainMaskCommands: Commands {
    var body: some Commands {
        CommandMenu("Tools") {
            BrainMaskMenuItem()
        }
    }
}

private struct BrainMaskMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Brain Mask…") {
            openWindow(id: BrainMaskTool.windowID)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}

// MARK: - Model choice

enum BrainMaskModelChoice: String, CaseIterable, Identifiable, Sendable {
    case fast
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return String(localized: "Fast", comment: "Brain mask model choice")
        case .accurate: return String(localized: "Accurate", comment: "Brain mask model choice")
        }
    }

    var detail: String {
        switch self {
        case .fast: return String(localized: "brainchop model5 (grey + white matter, no CSF). About 2 s.")
        case .accurate: return String(localized: "MindGrab skull stripping, any modality. About 10–20 s.")
        }
    }

    /// Folder-reference name under the app's Resources (copied from `Models/`).
    var resourceFolder: String {
        switch self {
        case .fast: return "model5_gw_ae"
        case .accurate: return "mindgrab"
        }
    }

    var profile: NeuralModelProfile {
        switch self {
        case .fast: return .brainMaskFast
        case .accurate: return .mindgrab
        }
    }

    /// Short model tag for the NIfTI `descrip` field.
    var tag: String {
        switch self {
        case .fast: return "brainchop model5_gw_ae"
        case .accurate: return "brainchop mindgrab"
        }
    }
}

// MARK: - Pipeline (runs off the main actor)

struct BrainMaskSource: Sendable {
    let url: URL
    let volume: MIQVolume
    let summary: String
}

struct BrainMaskPreview: Sendable, Identifiable {
    let plane: SlicePlane
    let bitmap: RGBABitmap
    var id: String { plane.rawValue }
}

struct BrainMaskResult: Sendable {
    let sourceURL: URL
    let labels: [UInt8]
    let width: Int
    let height: Int
    let depth: Int
    let geometry: NiftiGeometry
    let foregroundVoxels: Int
    /// Mask volume in millilitres, or `nil` when the voxel size is unknown.
    let volumeML: Double?
    let timings: NeuralRunTimings
    let wallSeconds: Double
    let gridSpacing: Double
    let model: BrainMaskModelChoice
    /// Slices windowed like the Quick Look preview (percentiles of the whole
    /// slice), with the mask outline.
    let previews: [BrainMaskPreview]
    /// The same slices windowed from the voxels inside the predicted mask only
    /// ("Window display to brain"); `nil` for an empty mask.
    let brainWindowedPreviews: [BrainMaskPreview]?
}

enum BrainMaskError: LocalizedError {
    case unsupportedFile
    case noDICOMSeries(String)
    case unsupportedVolume(String)
    case modelMissing(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return String(localized: "MIQ can’t read this file. Choose a NIfTI, MGH/MGZ, MRtrix MIF or NRRD volume.")
        case .noDICOMSeries(let folder):
            return String(localized: "No DICOM series found in “\(folder)”. Choose a folder that directly holds the single-frame DICOM files of one series.")
        case .unsupportedVolume(let reason): return reason
        case .modelMissing(let name):
            return String(localized: "The \(name) model is missing from the app bundle. Reinstall MIQ.")
        case .tooLarge(let reason): return reason
        }
    }
}

/// Stateless work, all callable from a detached task.
enum BrainMaskPipeline {
    /// Same overlay colour family as the system red, opaque.
    private static let outlineColor: (UInt8, UInt8, UInt8) = (255, 69, 58)

    static func load(url: URL) throws -> BrainMaskSource {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let image: MIQImage
        var seriesNote: String?
        if MIQFileKind(url: url) != nil {
            image = try MIQParser().parse(url: url)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            // A folder of DICOM slices: the user-selected folder's grant
            // covers the files inside it, and the assembler copies the pixels
            // out, so nothing is read after the grant is released.
            guard let series = DICOMSeriesAssembler().assembleLargestSeries(inFolder: url) else {
                throw BrainMaskError.noDICOMSeries(url.lastPathComponent)
            }
            image = series.image
            seriesNote = String(localized: "DICOM series of \(series.sliceCount) files")
        } else {
            throw BrainMaskError.unsupportedFile
        }
        // Cancelled while the last chunk decoded: drop the volume now rather
        // than building the source for a load nobody will show.
        try Task.checkCancellation()
        let volume = MIQVolume(image: image)
        let header = image.header
        if header.datatype == .rgb24 || header.datatype == .rgba32 {
            throw BrainMaskError.unsupportedVolume(String(localized: "Colour (RGB) images aren’t supported. Choose a grey-scale structural scan."))
        }
        guard min(volume.width, volume.height, volume.depth) >= 8 else {
            throw BrainMaskError.unsupportedVolume(String(localized: "The brain mask needs a 3-D volume with at least 8 voxels along each axis."))
        }
        let spacing = (1...3).map { $0 < header.pixdim.count ? abs(header.pixdim[$0]) : 1 }
        let spacingText = spacing.map { String(format: "%.3g", $0) }.joined(separator: " × ")
        var summary = String(localized: "\(volume.width) × \(volume.height) × \(volume.depth) voxels · \(spacingText) mm")
        if volume.volumes > 1 {
            summary += " · " + String(localized: "first of \(volume.volumes) volumes")
        }
        if let seriesNote {
            summary += " · " + seriesNote
        }
        return BrainMaskSource(url: url, volume: volume, summary: summary)
    }

    static func modelURL(for choice: BrainMaskModelChoice) -> URL? {
        Bundle.main.url(forResource: "model", withExtension: "json", subdirectory: choice.resourceFolder)
    }

    static func run(
        source: BrainMaskSource,
        choice: BrainMaskModelChoice,
        gridSpacing: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> BrainMaskResult {
        let started = Date()
        guard let modelURL = modelURL(for: choice) else { throw BrainMaskError.modelMissing(choice.title) }
        let engine = try NeuralMaskEngine.load(modelURL: modelURL, profile: choice.profile)
        let options = NeuralRunOptions(gridSpacing: gridSpacing)
        let volume = source.volume
        let voxelCount = volume.width * volume.height * volume.depth
        if let reason = NeuralMemoryEstimate.refusalReason(sourceVoxelCount: voxelCount, model: engine.model, options: options) {
            throw BrainMaskError.tooLarge(reason)
        }
        try Task.checkCancellation()
        let input = try NeuralInputVolume(volume: volume)
        try Task.checkCancellation()
        let mask = try await engine.run(volume: input, options: options, progress: progress)
        try Task.checkCancellation()

        let previews = makePreviews(volume: volume, labels: mask.labels, windowBounds: nil)
        try Task.checkCancellation()
        let brainWindowedPreviews = brainWindow(volume: volume, labels: mask.labels).map {
            makePreviews(volume: volume, labels: mask.labels, windowBounds: $0)
        }
        try Task.checkCancellation()
        let count = mask.foregroundVoxelCount
        return BrainMaskResult(
            sourceURL: source.url,
            labels: mask.labels,
            width: mask.width, height: mask.height, depth: mask.depth,
            geometry: NiftiGeometry(volume: volume),
            foregroundVoxels: count,
            volumeML: millilitres(voxels: count, volume: volume),
            timings: mask.timings,
            wallSeconds: Date().timeIntervalSince(started),
            gridSpacing: gridSpacing,
            model: choice,
            previews: previews,
            brainWindowedPreviews: brainWindowedPreviews
        )
    }

    /// Voxel count × voxel volume (|det| of the voxel→world affine, in the file's
    /// spatial unit) in mL.
    static func millilitres(voxels: Int, volume: MIQVolume) -> Double? {
        let det = abs(volume.voxelToWorld.determinant)
        guard det.isFinite, det > 0 else { return nil }
        let mmPerUnit: Double
        switch volume.image.header.acquisition.spatialUnit {
        case .meter: mmPerUnit = 1000
        case .micron: mmPerUnit = 0.001
        default: mmPerUnit = 1
        }
        return Double(voxels) * det * pow(mmPerUnit, 3) / 1000
    }

    /// Upper bound on voxels sampled for the brain window: a 1 mm head has
    /// about 1.5 M brain voxels, so typical masks are read in full.
    static let brainWindowMaxSamples = 2_000_000

    /// Intensity window from the voxels inside the mask only (first volume),
    /// at the preview's default percentiles — so a bright scalp, fat or neck
    /// and the empty background no longer set the grey range. `nil` when the
    /// mask is empty or holds no finite value, or `labels` doesn't match the
    /// grid.
    static func brainWindow(volume: MIQVolume, labels: [UInt8]) -> MIQIntensityWindowBounds? {
        let width = volume.width, height = volume.height
        let count = width * height * volume.depth
        guard count > 0, labels.count == count else { return nil }
        let inside = labels.reduce(into: 0) { if $1 != 0 { $0 += 1 } }
        guard inside > 0 else { return nil }
        // Every n-th mask voxel, so the sample stays bounded on huge grids.
        let step = max(1, (inside + brainWindowMaxSamples - 1) / brainWindowMaxSamples)
        var values: [Float] = []
        values.reserveCapacity(inside / step + 1)
        var seen = 0
        let plane = width * height
        for i in 0..<count where labels[i] != 0 {
            defer { seen += 1 }
            guard seen % step == 0 else { continue }
            let z = i / plane, rest = i - z * plane
            let y = rest / width, x = rest - y * width
            let value = volume.voxel(x: x, y: y, z: z)
            if value.isFinite { values.append(value) }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        func percentile(_ p: Double) -> Float {
            let position = p / 100 * Double(values.count - 1)
            let lower = Int(position.rounded(.down)), upper = min(values.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
        let low = percentile(MIQConfig.Defaults.windowLowerPercentile)
        var high = percentile(MIQConfig.Defaults.windowUpperPercentile)
        if high <= low { high = low + max(abs(low) * 1e-3, 1e-3) }
        return MIQIntensityWindowBounds(low: low, high: high)
    }

    /// Axial, coronal and sagittal slices through the mask's centroid (the volume
    /// centre for an empty mask) with the mask outline drawn on top. A `nil`
    /// window derives one per slice, as the preview does.
    static func makePreviews(volume: MIQVolume, labels: [UInt8],
                             windowBounds: MIQIntensityWindowBounds?) -> [BrainMaskPreview] {
        guard let maskVolume = MIQVolume.derivedVolume(values: labels.map { Float($0) }, onGridOf: volume) else { return [] }
        let options = RenderingOptions(
            lowerPercentile: MIQConfig.Defaults.windowLowerPercentile,
            upperPercentile: MIQConfig.Defaults.windowUpperPercentile,
            orientation: .neurological,
            segmentationColoring: .off
        )
        let cursor = centroid(labels: labels, width: volume.width, height: volume.height, depth: volume.depth)
            ?? volume.centerCursor()
        let lut = maskVolume.overlayLabelLut(orientation: options.orientation)
        return [SlicePlane.axial, .coronal, .sagittal].compactMap { plane in
            let index = volume.sliceIndex(for: plane, cursor: cursor, options: options)
            let base = volume.slice(plane: plane, index: index, maxDimension: 320, options: options,
                                    windowBounds: windowBounds)
            guard let baseBitmap = base.rgbaBitmap() else { return nil }
            guard let slice = maskVolume.displaySliceValues(plane: plane, index: index, options: options),
                  let layer = OverlayCompositor.layer(
                    values: slice.values, width: slice.width, height: slice.height,
                    style: .labels(lut, outlineOnly: true),
                    toWidth: baseBitmap.width, toHeight: baseBitmap.height
                  ),
                  let composite = OverlayCompositor.composite(base: baseBitmap, overlay: recoloured(layer), opacity: 1)
            else {
                return BrainMaskPreview(plane: plane, bitmap: baseBitmap)
            }
            return BrainMaskPreview(plane: plane, bitmap: composite)
        }
    }

    /// Paints every visible overlay pixel in the outline colour (the label LUT's
    /// colour for label 1 is arbitrary and can be hard to see on grey).
    private static func recoloured(_ layer: RGBABitmap) -> RGBABitmap {
        var pixels = [UInt8](layer.pixels)
        var i = 0
        while i + 3 < pixels.count {
            if pixels[i + 3] > 0 {
                pixels[i] = outlineColor.0
                pixels[i + 1] = outlineColor.1
                pixels[i + 2] = outlineColor.2
                pixels[i + 3] = 255
            }
            i += 4
        }
        return RGBABitmap(width: layer.width, height: layer.height, pixels: Data(pixels))
    }

    private static func centroid(labels: [UInt8], width: Int, height: Int, depth: Int) -> MIQVolumeCursor? {
        var sx = 0, sy = 0, sz = 0, n = 0
        var i = 0
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    if labels[i] != 0 { sx += x; sy += y; sz += z; n += 1 }
                    i += 1
                }
            }
        }
        guard n > 0 else { return nil }
        return MIQVolumeCursor(x: sx / n, y: sy / n, z: sz / n)
    }

    /// `<stem>_desc-brain_mask.nii.gz`, the stem being the source name without its
    /// volume extension (`sub-01_T1w.nii.gz` → `sub-01_T1w_desc-brain_mask.nii.gz`).
    static func defaultSaveName(for url: URL) -> String {
        var name = url.lastPathComponent
        let extensions = [".nii.gz", ".mif.gz", ".mgh.gz", ".nii", ".mgz", ".mgh", ".mif", ".nrrd", ".nhdr", ".gz"]
        if let ext = extensions.first(where: { name.lowercased().hasSuffix($0) }) {
            name = String(name.dropLast(ext.count))
        }
        if name.isEmpty { name = "volume" }
        return name + "_desc-brain_mask.nii.gz"
    }

    static func save(_ result: BrainMaskResult, to url: URL) throws {
        let spacing = String(format: "%g", result.gridSpacing)
        try NiftiWriter.writeUInt8(
            result.labels,
            width: result.width, height: result.height, depth: result.depth,
            geometry: result.geometry,
            to: url,
            description: "MIQ brain mask (\(result.model.tag), \(spacing) mm grid)"
        )
    }
}

// MARK: - View model

@MainActor
final class BrainMaskToolModel: ObservableObject {
    @Published private(set) var source: BrainMaskSource?
    @Published var choice: BrainMaskModelChoice = .fast
    @Published var fullResolution = false
    /// Shows `BrainMaskResult.brainWindowedPreviews` instead of `previews`.
    @Published var windowToBrain = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRunning = false
    @Published private(set) var isSaving = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var result: BrainMaskResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private var task: Task<Void, Never>?
    /// Bumped by every load/run/cancel so a late completion of a superseded task
    /// never overwrites newer state.
    private var generation = 0

    func chooseVolume() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Volume")
        panel.message = String(localized: "Choose a structural brain scan to mask, or a folder holding a DICOM series.")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = false
        // A folder is read as a DICOM series (`BrainMaskPipeline.load`).
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MIQIntentSupport.supportedContentTypes + [.folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        cancel()
        generation += 1
        let id = generation
        source = nil
        result = nil
        errorMessage = nil
        statusMessage = nil
        isLoading = true
        // The parse runs detached but follows this task's cancellation
        // (`withCancellableDetachedWork`), so `cancel()` — a new file, the window
        // closing — stops a multi-GB decode at its next chunk instead of finishing
        // it in the background; a cancelled load's partial buffers are dropped
        // with the detached task.
        task = Task {
            let outcome: Result<BrainMaskSource, Error>
            do {
                outcome = .success(try await withCancellableDetachedWork(priority: .userInitiated) {
                    try BrainMaskPipeline.load(url: url)
                })
            } catch {
                outcome = .failure(error)
            }
            guard id == self.generation else { return }
            self.isLoading = false
            switch outcome {
            case .success(let loaded): self.source = loaded
            case .failure(let error) where error is CancellationError:
                self.statusMessage = String(localized: "Cancelled.")
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func run() {
        guard let source, !isRunning, !isLoading else { return }
        generation += 1
        let id = generation
        let choice = self.choice
        let spacing = fullResolution ? 1.0 : 2.0
        result = nil
        errorMessage = nil
        statusMessage = nil
        progress = 0
        isRunning = true
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () async throws -> BrainMaskResult in
                try await BrainMaskPipeline.run(source: source, choice: choice, gridSpacing: spacing) { value in
                    Task { @MainActor in self.updateProgress(value, generation: id) }
                }
            }
            let outcome: Result<BrainMaskResult, Error>
            do {
                let value = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
            guard id == self.generation else { return }
            self.isRunning = false
            switch outcome {
            case .success(let value):
                self.progress = 1
                self.result = value
            case .failure(let error) where error is CancellationError:
                self.statusMessage = String(localized: "Cancelled.")
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateProgress(_ value: Double, generation id: Int) {
        guard id == generation, isRunning, value.isFinite else { return }
        progress = max(progress, min(1, value))
    }

    /// Cancels a running load or inference; the engine stops at its next chunk.
    func cancel() {
        task?.cancel()
        task = nil
        if isRunning || isLoading {
            generation += 1
            isRunning = false
            isLoading = false
            statusMessage = String(localized: "Cancelled.")
        }
    }

    func save() {
        guard let result, !isSaving else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Mask as NIfTI")
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = BrainMaskPipeline.defaultSaveName(for: result.sourceURL)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // No allowedContentTypes: AppKit would append a second extension to the
        // double `.nii.gz` one.
        panel.allowsOtherFileTypes = true
        panel.directoryURL = result.sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try BrainMaskPipeline.save(result, to: url) }
            }.value
            self.isSaving = false
            switch outcome {
            case .success: self.statusMessage = String(localized: "Saved “\(url.lastPathComponent)”.")
            case .failure(let error): self.errorMessage = String(localized: "Couldn’t save the mask: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - View

struct BrainMaskToolView: View {
    @StateObject private var model = BrainMaskToolModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                disclaimer
                sourceSection
                modelSection
                runSection
                if let result = model.result {
                    resultSection(result)
                }
                BrainMaskAcknowledgements()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onDisappear { model.cancel() }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(BrainMaskTool.disclaimer)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private var sourceSection: some View {
        GroupBox("Volume") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let source = model.source {
                        Text(source.url.lastPathComponent)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(source.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("No volume chosen.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Choose Volume…") { model.chooseVolume() }
                    .disabled(model.isRunning || model.isLoading)
            }
            .padding(6)
        }
    }

    private var modelSection: some View {
        GroupBox("Model") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Model", selection: $model.choice) {
                    ForEach(BrainMaskModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Full resolution (1 mm grid; about 8× slower and needs more memory)", isOn: $model.fullResolution)
                    .font(.callout)
            }
            .padding(6)
            .disabled(model.isRunning)
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if model.isRunning {
                    ProgressView(value: model.progress)
                        .frame(maxWidth: .infinity)
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Run") { model.run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.source == nil || model.isLoading)
                    Spacer()
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultSection(_ result: BrainMaskResult) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Self.shownPreviews(result, windowToBrain: model.windowToBrain)) { preview in
                        VStack(spacing: 4) {
                            if let image = Self.cgImage(preview.bitmap) {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: 220)
                                    .background(Color.black)
                            }
                            Text(Self.planeTitle(preview.plane))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Window display to brain", isOn: $model.windowToBrain)
                    .font(.callout)
                    .disabled(result.brainWindowedPreviews == nil)
                    .help("Sets the grey range from the voxels inside the predicted mask, so scalp, fat and background don’t wash out the brain. Display only; the saved mask is the same.")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Mask volume").foregroundStyle(.secondary)
                        Text(Self.volumeText(result))
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text("\(result.model.title) · \(String(format: "%g", result.gridSpacing)) mm grid")
                    }
                    GridRow {
                        Text("Timings").foregroundStyle(.secondary)
                        Text(Self.timingText(result))
                    }
                }
                .font(.callout)
                HStack {
                    Button("Save Mask as NIfTI…") { model.save() }
                        .disabled(model.isSaving)
                    if model.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text(BrainMaskTool.disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private static func shownPreviews(_ result: BrainMaskResult, windowToBrain: Bool) -> [BrainMaskPreview] {
        windowToBrain ? (result.brainWindowedPreviews ?? result.previews) : result.previews
    }

    private static func volumeText(_ result: BrainMaskResult) -> String {
        let voxels = result.foregroundVoxels.formatted()
        guard let ml = result.volumeML else { return String(localized: "\(voxels) voxels") }
        let millilitres = String(format: "%.0f", ml)
        return String(localized: "\(millilitres) mL (\(voxels) voxels)")
    }

    private static func timingText(_ result: BrainMaskResult) -> String {
        let t = result.timings
        // Numbers pre-formatted so the catalogue key carries only `%@`s.
        let seconds = { (value: Double) in String(format: "%.1f", value) }
        let total = seconds(result.wallSeconds), conform = seconds(t.conform)
        let inference = seconds(t.inference), postprocess = seconds(t.postprocess)
        return String(localized: "\(total) s total · conform \(conform) s · inference \(inference) s · post-process \(postprocess) s")
    }

    private static func planeTitle(_ plane: SlicePlane) -> String {
        switch plane {
        case .axial: return String(localized: "Axial")
        case .coronal: return String(localized: "Coronal")
        case .sagittal: return String(localized: "Sagittal")
        }
    }

    private static func cgImage(_ bitmap: RGBABitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: bitmap.pixels as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

// MARK: - Acknowledgements

/// MIT notice for the bundled brainchop weights (required by their licence).
private struct BrainMaskAcknowledgements: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Acknowledgements", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("""
                    The brain masks are computed on this Mac with MeshNet models from brainchop \
                    (github.com/neuroneural/brainchop): MindGrab (“Accurate”) and model5_gw_ae (“Fast”). \
                    MindGrab: Fani et al., “MindGrab for BrainChop: Fast and Accurate Skull Stripping \
                    for Command Line and Browser”, arXiv:2506.11860 (2025).
                    """)
                Text(Self.licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }

    /// The bundled `LICENSE-brainchop`, or the MIT notice itself if it is missing.
    private static let licenseText: String = {
        if let url = Bundle.main.url(forResource: "LICENSE-brainchop", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
            MIT License

            Copyright (c) 2021 neuroneural/brainchop

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software \
            and associated documentation files (the "Software"), to deal in the Software without restriction, \
            including without limitation the rights to use, copy, modify, merge, publish, distribute, \
            sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or \
            substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING \
            BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
            NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, \
            DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """
    }()
}
