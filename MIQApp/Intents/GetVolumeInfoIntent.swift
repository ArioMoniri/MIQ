import AppIntents
import Foundation
import MIQCore

/// Output shape for `GetVolumeInfoIntent`: readable lines for a dialog, or JSON a
/// shortcut can feed into "Get Dictionary from Input".
@available(macOS 15.0, *)
enum VolumeInfoOutput: String, AppEnum {
    case text
    case json

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output Format"
    static let caseDisplayRepresentations: [VolumeInfoOutput: DisplayRepresentation] = [
        .text: "Text",
        .json: "JSON",
    ]
}

/// "Get Volume Info": reports a volume's format, dimensions, voxel spacing,
/// datatype, volume count and orientation code.
///
/// Header-only (`VolumeSummary.read(contentsOf:)`): the voxel payload is never
/// read, so it is fast even for multi-GB 4D files. Carries no free-text header
/// fields, so the result is safe to log or share. `@available(macOS 15)` because
/// `@Parameter(…, supportedContentTypes:)` for `IntentFile` is macOS 15+ in the
/// current SDK; on macOS 14 the app simply offers no intents.
@available(macOS 15.0, *)
struct GetVolumeInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Volume Info"
    static let description = IntentDescription(
        "Reads a medical volume's header (NIfTI, MGH/MGZ, MRtrix MIF or NRRD) and returns its format, dimensions, voxel spacing, datatype, number of volumes and orientation. The image data itself is not read.",
        categoryName: "Medical Images"
    )

    @Parameter(title: "Volume", description: "A NIfTI, MGH/MGZ, MIF or NRRD file.", supportedContentTypes: MIQIntentSupport.supportedContentTypes)
    var file: IntentFile

    @Parameter(title: "Output", default: .text)
    var output: VolumeInfoOutput

    static var parameterSummary: some ParameterSummary {
        Summary("Get info for \(\.$file) as \(\.$output)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = try await MIQIntentSupport.withLocalFile(file) { url in
            try VolumeSummary.read(contentsOf: url)
        }
        let value: String
        switch output {
        case .text:
            value = summary.summaryText
        case .json:
            value = String(decoding: try summary.jsonData(prettyPrinted: true), as: UTF8.self)
        }
        // The dialog is always the readable form; the returned value follows `output`.
        return .result(value: value, dialog: "\(summary.summaryText)")
    }
}
