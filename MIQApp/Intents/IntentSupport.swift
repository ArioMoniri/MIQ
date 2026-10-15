import AppIntents
import CoreGraphics
import Foundation
import ImageIO
import MIQCore
import UniformTypeIdentifiers

/// Shared plumbing for MIQ's App Intents: the file types they accept, scoped access
/// to the `IntentFile` the system hands over, user-facing errors and PNG encoding.
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

    /// Runs `body` with a local file URL for `file`.
    ///
    /// A file-backed `IntentFile` (the usual case from Shortcuts or Finder) is used
    /// in place under its security scope — never copied, so a large volume is not
    /// duplicated. A data-backed one is written to a private temporary directory
    /// under its original filename (the extension is what `MIQFileKind` keys on)
    /// and removed afterwards.
    static func withLocalFile<T>(_ file: IntentFile, _ body: (URL) throws -> T) throws -> T {
        if let url = file.fileURL {
            guard MIQFileKind(url: url) != nil else { throw MIQIntentError.unsupportedFile(url.lastPathComponent) }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return try body(url)
        }

        let name = (file.filename as NSString).lastPathComponent
        let filename = name.isEmpty ? "volume" : name
        guard MIQFileKind(url: URL(fileURLWithPath: filename)) != nil else {
            throw MIQIntentError.unsupportedFile(filename)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MIQIntent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(filename)
        try file.data.write(to: url, options: .atomic)
        return try body(url)
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

    /// Encodes an RGBA slice bitmap as an opaque sRGB PNG with ImageIO. The bitmap's
    /// alpha is always 255, so it is skipped rather than written as a channel.
    static func pngData(from bitmap: RGBABitmap) -> Data? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: bitmap.pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bitmap.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Errors surfaced to the Shortcuts / Spotlight user. Messages name only the
/// file's name, never header contents.
enum MIQIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unsupportedFile(String)
    case renderFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unsupportedFile(let name):
            return "\(name) is not a supported volume. MIQ reads .nii, .nii.gz, .mgh, .mgz, .mif, .mif.gz, .mih, .nrrd, .nhdr, .mha and .mhd files."
        case .renderFailed:
            return "MIQ could not render an image from this volume."
        }
    }
}
