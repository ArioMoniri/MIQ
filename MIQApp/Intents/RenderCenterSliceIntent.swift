import AppIntents
import Foundation
import MIQCore
import UniformTypeIdentifiers

/// The three orthogonal planes, as an App Intents enum (maps 1:1 onto `SlicePlane`).
@available(macOS 15.0, *)
enum IntentSlicePlane: String, AppEnum {
    case axial
    case coronal
    case sagittal

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Slice Plane"
    static let caseDisplayRepresentations: [IntentSlicePlane: DisplayRepresentation] = [
        .axial: "Axial",
        .coronal: "Coronal",
        .sagittal: "Sagittal",
    ]

    var slicePlane: SlicePlane {
        switch self {
        case .axial: return .axial
        case .coronal: return .coronal
        case .sagittal: return .sagittal
        }
    }
}

/// "Render Center Slice": renders the centre slice of volume 0 in the chosen plane
/// and returns it as a PNG file.
///
/// Uses the same MIQCore pipeline and the same Settings (intensity window
/// percentiles, image orientation, segmentation colouring) as the Quick Look
/// preview, so the image matches what the user sees there — without labels,
/// crosshair or metadata overlay. Read-only and offline; the PNG is returned to
/// the caller, never written next to the source file.
@available(macOS 15.0, *)
struct RenderCenterSliceIntent: AppIntent {
    static let title: LocalizedStringResource = "Render Center Slice"
    static let description = IntentDescription(
        "Renders the centre slice of a medical volume (NIfTI, MGH/MGZ, MRtrix MIF or NRRD) in the chosen plane and returns it as a PNG image.",
        categoryName: "Medical Images"
    )

    @Parameter(title: "Volume", description: "A NIfTI, MGH/MGZ, MIF or NRRD file.", supportedContentTypes: MIQIntentSupport.supportedContentTypes)
    var file: IntentFile

    @Parameter(title: "Plane", default: .axial)
    var plane: IntentSlicePlane

    static var parameterSummary: some ParameterSummary {
        Summary("Render the \(\.$plane) centre slice of \(\.$file)")
    }

    /// Longest side of the rendered PNG, in pixels. Matches the preview's render
    /// budget; volumes are rarely larger than this per slice, so more would only
    /// upscale (nearest-neighbour) without adding detail.
    private static let maxDimension = 512

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let plane = self.plane.slicePlane
        let png = try MIQIntentSupport.withLocalFile(file) { url -> Data in
            let image = try MIQParser().parse(url: url)
            let volume = MIQVolume(image: image)
            let options = RenderingOptions(
                lowerPercentile: MIQConfig.windowLowerPercentile,
                upperPercentile: MIQConfig.windowUpperPercentile,
                orientation: MIQConfig.imageOrientation,
                segmentationColoring: MIQConfig.segmentationColoring
            )
            // With a segmentation LUT active it replaces percentile windowing,
            // exactly as in the thumbnail renderer.
            let lut = volume.buildSegmentationLut(options: options)
            let slice = volume.centerSlice(
                plane: plane,
                volumeIndex: 0,
                maxDimension: Self.maxDimension,
                options: options,
                windowBounds: nil,
                lut: lut
            )
            guard let bitmap = slice.rgbaBitmap(), let data = MIQIntentSupport.pngData(from: bitmap) else {
                throw MIQIntentError.renderFailed
            }
            return data
        }
        let filename = "\(MIQIntentSupport.baseName(of: file))_\(self.plane.rawValue).png"
        return .result(value: IntentFile(data: png, filename: filename, type: .png))
    }
}
