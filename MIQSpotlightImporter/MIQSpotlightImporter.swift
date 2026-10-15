import Foundation
import MIQCore
#if canImport(CoreServices)
import CoreServices
#endif

/// Spotlight attributes for one volume, derived from its header only.
///
/// Built from `VolumeSummary` — the same header-only summary the App Intents and
/// `miq info` use — so Spotlight, Shortcuts and the CLI always agree. The payload
/// is never read; for gzipped files only enough of the stream to cover the header
/// is inflated. No free-text header field (NIfTI `descrip`, MIF comments, NRRD
/// `content`) is ever indexed: they can hold patient identifiers, and the
/// Spotlight index is persistent and queryable by any process.
///
/// The `org_miq_*` attributes are declared in `schema.xml` (with display names in
/// `en.lproj/schema.strings`); the `kMDItem*` keys are system attributes, written
/// as their literal key strings (identical to the CoreServices constants' values)
/// so this table also compiles where CoreServices does not exist.
enum MIQSpotlightAttributes {
    static let pixelWidth = "kMDItemPixelWidth"
    static let pixelHeight = "kMDItemPixelHeight"
    static let kind = "kMDItemKind"
    static let dimensions = "org_miq_dimensions"
    static let voxelSpacing = "org_miq_voxelSpacing"
    static let spacingUnit = "org_miq_spacingUnit"
    static let datatype = "org_miq_datatype"
    static let volumes = "org_miq_volumes"
    static let orientation = "org_miq_orientation"

    /// Attribute dictionary for `summary`. Optional fields the header does not
    /// provide (orientation, spacing unit) are omitted rather than written empty.
    static func attributes(for summary: VolumeSummary) -> [String: Any] {
        var attributes: [String: Any] = [
            pixelWidth: NSNumber(value: summary.dimensions[safeIndex: 0] ?? 0),
            pixelHeight: NSNumber(value: summary.dimensions[safeIndex: 1] ?? 0),
            kind: summary.format,
            dimensions: summary.dimensions.map { NSNumber(value: $0) },
            voxelSpacing: summary.voxelSpacing.map { NSNumber(value: $0) },
            datatype: summary.datatype,
            volumes: NSNumber(value: summary.volumes),
        ]
        if let unit = summary.spacingUnit { attributes[spacingUnit] = unit }
        if let code = summary.orientation { attributes[orientation] = code }
        return attributes
    }

    /// Reads `url`'s header and returns its attributes, or `nil` when the file is
    /// not a volume MIQ understands (wrong extension — e.g. an unrelated `.gz` routed
    /// here by the generic gzip UTI — or a malformed / truncated header). The
    /// extension check runs first, so a non-volume file costs no I/O at all.
    static func attributes(forFileAt url: URL) -> [String: Any]? {
        guard MIQFileKind(url: url) != nil,
              let summary = try? VolumeSummary.read(contentsOf: url) else {
            return nil
        }
        return attributes(for: summary)
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if canImport(CoreServices)
/// Entry point called by the CFPlugIn glue in `main.c` for both importer
/// interfaces. Must not throw or trap: it runs inside `mdworker`, so every
/// failure is reported as `false` ("nothing imported").
@_cdecl("MIQImporterImportURL")
public func miqImporterImportURL(
    _ attributes: CFMutableDictionary,
    _ contentTypeUTI: CFString,
    _ url: CFURL
) -> DarwinBoolean {
    guard let values = MIQSpotlightAttributes.attributes(forFileAt: url as URL) else {
        return false
    }
    let target = attributes as NSMutableDictionary
    for (key, value) in values {
        target[key] = value
    }
    return true
}
#endif
