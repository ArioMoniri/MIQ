import AppIntents
import Foundation
import MIQCore
import UniformTypeIdentifiers

/// Shared plumbing for MIQ's App Intents: the file types they accept, scoped access
/// to the `IntentFile` the system hands over, user-facing errors and PNG encoding
/// (via MIQCore `PNGEncoder`).
///
/// Every intent is read-only and offline: it reads the given file, never writes
/// next to it, never touches the network, and returns its result to the caller.
enum MIQIntentSupport {
    /// The volume types an intent accepts — the same list the thumbnail extension's
    /// `QLSupportedContentTypes` claims. The `org.*` identifiers are the ones the
    /// app's Info.plist imports (`UTImportedTypeDeclarations`); `gov.nih.nifti-1` is
    /// the identifier some other neuroimaging apps declare for `.nii`. `.gzip` is
    /// included because macOS commonly resolves `.nii.gz` / `.mif.gz` to the generic
    /// gzip type rather than the narrow MIQ one (see `MIQThumbnailProvider`);
    /// unrelated archives are rejected in `perform()` via `MIQFileKind`.
    static let supportedContentTypes: [UTType] = [
        UTType(importedAs: "org.nifti.nii"),
        UTType(importedAs: "gov.nih.nifti-1"),
        UTType(importedAs: "org.nifti.nii-gz"),
        UTType(importedAs: "org.freesurfer.mgh"),
        UTType(importedAs: "org.freesurfer.mgz"),
        UTType(importedAs: "org.mrtrix.mif"),
        UTType(importedAs: "org.mrtrix.mif-gz"),
        UTType(importedAs: "org.teem.nrrd"),
        UTType(importedAs: "org.teem.nhdr"),
        UTType(importedAs: "org.mrtrix.mih"),
        UTType(importedAs: "org.itk.metaimage"),
        UTType(importedAs: "org.itk.metaimage-header"),
        .gzip,
    ]

    /// Runs `body` with a local file URL for `file`, off the caller's actor.
    ///
    /// The parse/render in `body` runs on a detached task
    /// (`withCancellableDetachedWork`), so `perform()` never decodes a volume
    /// inline, and a cancelled shortcut run stops the decode at its next chunk.
    ///
    /// A file-backed `IntentFile` (the usual case from Shortcuts or Finder) is used
    /// in place under its security scope — never copied, so a large volume is not
    /// duplicated. A data-backed one is written to a private temporary directory
    /// under its original filename (the extension is what `MIQFileKind` keys on)
    /// and removed afterwards. A data-backed detached header (`.nhdr`, `.mhd`,
    /// `.mih`) arrives without the data file it points to, so when `body` fails on
    /// one the error says exactly that instead of a confusing parse failure.
    static func withLocalFile<T: Sendable>(
        _ file: IntentFile,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        if let url = file.fileURL {
            guard MIQFileKind(url: url) != nil else { throw MIQIntentError.unsupportedFile(url.lastPathComponent) }
            return try await withCancellableDetachedWork(priority: .userInitiated) {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return try body(url)
            }
        }

        let name = (file.filename as NSString).lastPathComponent
        let filename = name.isEmpty ? "volume" : name
        guard let kind = MIQFileKind(url: URL(fileURLWithPath: filename)) else {
            throw MIQIntentError.unsupportedFile(filename)
        }
        let data = file.data
        return try await withCancellableDetachedWork(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MIQIntent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            do {
                return try body(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch where kind.isDetachedHeader {
                // Header-only work (Get Volume Info) succeeds above; reaching here
                // means the payload was needed and its data file isn't available.
                throw MIQIntentError.detachedDataUnavailable(filename)
            }
        }
    }

    /// The display name of `file` without its (possibly double) volume extension,
    /// e.g. `sub-01_T1w.nii.gz` → `sub-01_T1w`. Used to name rendered outputs.
    static func baseName(of file: IntentFile) -> String {
        let name = file.fileURL?.lastPathComponent ?? (file.filename as NSString).lastPathComponent
        let lower = name.lowercased()
        for kind in MIQFileKind.allCases {
            for suffix in kind.pathSuffixes where lower.hasSuffix(suffix) {
                let base = String(name.dropLast(suffix.count))
                return base.isEmpty ? "volume" : base
            }
        }
        return name.isEmpty ? "volume" : (name as NSString).deletingPathExtension
    }

    /// Encodes a rendered slice as PNG with MIQCore's `PNGEncoder` — the same
    /// encoder the `miq` CLI uses, so both produce identical files: grayscale
    /// slices as 8-bit gray, colour (RGB / segmentation) slices as 8-bit RGB.
    static func pngData(from slice: SliceImage) throws -> Data {
        do {
            return try PNGEncoder.encode(slice)
        } catch {
            throw MIQIntentError.renderFailed
        }
    }
}

/// Errors surfaced to the Shortcuts / Spotlight user. Messages name only the
/// file's name, never header contents.
enum MIQIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unsupportedFile(String)
    /// A detached header (`.nhdr`, `.mhd`, `.mih`) handed over as data, without
    /// the separate data file it references.
    case detachedDataUnavailable(String)
    case renderFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unsupportedFile(let name):
            return "\(name) is not a supported volume. MIQ reads .nii, .nii.gz, .mgh, .mgz, .mif, .mif.gz, .mih, .nrrd, .nhdr, .mha and .mhd files."
        case .detachedDataUnavailable(let name):
            return "\(name) is a detached header: its image data is in a separate file that wasn’t passed to the shortcut. Pass the header as a file from Finder, with its data file next to it, or use a single-file format such as .nii.gz, .nrrd or .mha."
        case .renderFailed:
            return "MIQ could not render an image from this volume."
        }
    }
}
