import Foundation

// MIQCore writes its user-facing text (metadata labels, badges, menu titles,
// warnings, QC lines, error descriptions) in English, because it is also built
// with SwiftPM on Linux and for the `miq` CLI, where `String(localized:bundle:)`
// and a processed `.xcstrings` resource are unavailable. The Quick Look
// extension translates that text at its boundary instead: it hands each string
// to `CoreUIText.localize(_:lookup:)` with a lookup into its own string catalog
// (`MIQQuickLookExtension/Preview.xcstrings`), whose keys are the English
// phrases and templates listed here.

/// Translation of MIQCore's English UI text through a caller-supplied catalog.
public enum CoreUIText {
    /// English strings MIQCore shows verbatim, each a catalog key. Technical
    /// tokens that stay the same in every language (MIP, sform, SNR, TR, BIDS…)
    /// are listed too; the catalog test accepts them untranslated
    /// (`untranslatedPhrases`).
    public static var phrases: [String] {
        var list: [String] = []
        list += MetadataField.allCases.map(\.displayLabel)
        list += ViewOrientation.allCases.map(\.badgeLabel)
        list += SlicePlane.allCases.map(PreviewAccessibility.planeName)
        list += PreviewViewMode.allCases.map(\.displayName)
        list += ProjectionMode.allCases.map(\.displayName)
        list += VolumeRenderMode.allCases.map(VolumeRenderModeCycle.displayName)
        list += Colormap.allCases.map(ColormapCycle.displayName)
        list += WindowPreset.allCases.map(\.displayName)
        list += QCLevel.allCases.map(\.displayName)
        list += QCMetricID.allCases.map(\.displayName)
        let sources: [OrientationDiagnostics.TransformSource] = [
            .sform, .qform, .nrrdSpace, .mifTransform, .mifDefault, .mghVox2ras, .metaImage, .none
        ]
        list += sources.map(\.label)
        list += [
            // Orientation summary and warnings (`OrientationDiagnostics`).
            "Unknown",
            "qform and sform disagree on left/right — other tools may show this image flipped",
            "qform and sform disagree — other tools may orient this image differently",
            "Header has no anatomical orientation — labels unknown",
            // Data QC and temporal rows (`QCAnalysis.displayLines`, `PreviewDataSummaries`).
            PreviewDataSummaries.sectionTitle,
            "Likely sequence", "Head mask", "Face", "Likely present", "Likely removed",
            "tSNR (median)", "no spike frames", "1 spike frame",
            PreviewDataSummaries.windowModeLabel,
            PreviewDataSummaries.windowModeText(perVolume: true),
            PreviewDataSummaries.windowModeText(perVolume: false),
            // `MIQError` descriptions without an argument.
            MIQError.invalidDimensions.errorDescription!,
            MIQError.truncatedData.errorDescription!,
            MIQError.decompressionFailed.errorDescription!,
            MIQError.unsupportedFileFormat.errorDescription!,
        ]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Phrases that are the same in every language: modality / method acronyms,
    /// NIfTI vocabulary and colour-map proper names. Never catalogued.
    public static let untranslatedPhrases: Set<String> = [
        "TR", "BIDS", "MIP", "MinIP", "DVR", "3D", "sform", "qform", "vox2ras",
        "SNR", "CNR", "CJV", "EFC", "FBER", "Hot", "Cool", "Winter", "Viridis", "Inferno",
        "Subdural",
    ]

    /// English templates of MIQCore's composed text, each a catalog key. `%@`
    /// marks an argument (a number, a file name, or another phrase, which is
    /// translated in turn). The catalog's translations use `%@` or positional
    /// `%1$@` / `%2$@`. More specific templates come first: the first match wins.
    public static let templates: [String] = [
        // Status and errors (`PreviewStatusText`, `MIQError`, `MIQPayloadSizeEstimate`).
        "Preview failed: %@",
        "Invalid NIfTI header size: %@.",
        "Unsupported file format version: %@.",
        "Unsupported datatype code: %@.",
        "Unsupported feature: %@.",
        "Malformed file: %@.",
        "%@ is %@ in iCloud (not downloaded).\nLoading it now downloads the whole file, which could make Finder unresponsive.",
        "%@ is %@ on a network volume.\nLoading it now could make Finder unresponsive while it transfers.",
        "Too large for 4D in Quick Look (%@)",
        // Accessibility (`PreviewAccessibility`).
        "%@ slice %@ of %@, window %@",
        "%@ slice %@ of %@",
        "Volume %@ of %@",
        // Orientation (`OrientationDiagnostics`) and sidecar warnings.
        "qform (%@) and sform (%@) disagree — other tools may orient this image differently",
        "oblique %@",
        "TR mismatch: sidecar %@, header %@",
        ".bval has %@ entries for %@ volumes",
        // Data QC.
        "%@ (%@, heuristic)",
        "%@ (heuristic)",
        "%@ of %@ metrics flagged",
        "%@ metrics",
        "%@ spike frames",
    ]

    /// Separator MIQCore uses between parts of one value ("RAS · oblique 23° ·
    /// sform", "12.3 · Typical"); each part is translated on its own.
    static let partSeparator = " \u{00B7} "

    /// `text` translated through `lookup`, which returns a catalog key's
    /// translation or `nil` when the catalog has none. Tried in order: the whole
    /// text as a phrase; each `·`-separated part; the first matching template,
    /// with its arguments translated recursively. Anything unmatched comes back
    /// unchanged, so the English is always the fallback.
    public static func localize(_ text: String, lookup: (String) -> String?) -> String {
        localize(text, lookup: lookup, depth: 0)
    }

    private static func localize(_ text: String, lookup: (String) -> String?, depth: Int) -> String {
        guard !text.isEmpty, depth < 4 else { return text }
        if let exact = lookup(text) { return exact }
        if text.contains(partSeparator) {
            return text.components(separatedBy: partSeparator)
                .map { localize($0, lookup: lookup, depth: depth + 1) }
                .joined(separator: partSeparator)
        }
        for template in templates {
            guard let arguments = match(template: template, text: text) else { continue }
            guard let format = lookup(template) else { return text }
            let translated = arguments.map { localize($0, lookup: lookup, depth: depth + 1) }
            return substitute(format: format, arguments: translated)
        }
        return text
    }

    /// The `%@` arguments of `text` under `template`, or `nil` when it does not
    /// match. Each argument is non-empty and ends at the first occurrence of
    /// the literal that follows it.
    static func match(template: String, text: String) -> [String]? {
        let literals = template.components(separatedBy: "%@")
        guard literals.count > 1,
              let first = literals.first, let last = literals.last,
              text.hasPrefix(first), text.hasSuffix(last),
              text.count >= first.count + last.count + literals.count - 1
        else { return nil }
        var rest = Substring(text.dropFirst(first.count).dropLast(last.count))
        var arguments: [String] = []
        for literal in literals.dropFirst().dropLast() {
            // At least one character of argument before the literal.
            guard !rest.isEmpty else { return nil }
            let searchStart = rest.index(after: rest.startIndex)
            guard let range = rest.range(of: literal, range: searchStart..<rest.endIndex) else { return nil }
            arguments.append(String(rest[rest.startIndex..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        guard !rest.isEmpty else { return nil }
        arguments.append(String(rest))
        return arguments
    }

    /// Fills `%@`, `%n$@` and `%%` in a translated template. Any other `%`
    /// sequence is copied literally, and a missing argument becomes empty, so a
    /// malformed translation degrades instead of crashing like `String(format:)`.
    static func substitute(format: String, arguments: [String]) -> String {
        var result = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%", format.index(after: i) < format.endIndex else {
                result.append(c)
                i = format.index(after: i)
                continue
            }
            var j = format.index(after: i)
            if format[j] == "%" {
                result.append("%")
                i = format.index(after: j)
                continue
            }
            if format[j] == "@" {
                if next < arguments.count { result += arguments[next] }
                next += 1
                i = format.index(after: j)
                continue
            }
            var digits = ""
            while j < format.endIndex, let d = format[j].wholeNumberValue, format[j].isASCII {
                digits.append(Character(String(d)))
                j = format.index(after: j)
            }
            if !digits.isEmpty, j < format.endIndex, format[j] == "$",
               format.index(after: j) < format.endIndex, format[format.index(after: j)] == "@",
               let position = Int(digits), position >= 1 {
                if position <= arguments.count { result += arguments[position - 1] }
                i = format.index(j, offsetBy: 2)
                continue
            }
            result.append(c)
            i = format.index(after: i)
        }
        return result
    }
}
