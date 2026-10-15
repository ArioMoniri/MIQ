import Foundation
import Testing
@testable import MIQCore

/// `CoreUIText`: the template matcher, the safe formatter, and the Quick Look
/// extension's `Preview.xcstrings`, which must translate every phrase and
/// template MIQCore lists (de, tr) with matching placeholders.
struct CoreUITextTests {
    // MARK: Matching and substitution

    @Test func matchExtractsArgumentsLazily() {
        #expect(CoreUIText.match(template: "%@ slice %@ of %@", text: "Axial slice 45 of 90") == ["Axial", "45", "90"])
        #expect(CoreUIText.match(template: "%@ (%@, heuristic)", text: "Typical (6 metrics, heuristic)") == ["Typical", "6 metrics"])
        #expect(CoreUIText.match(template: "%@ (heuristic)", text: "Typical (6 metrics, heuristic)") == nil)
        #expect(CoreUIText.match(template: "oblique %@", text: "oblique ") == nil)
        #expect(CoreUIText.match(template: "oblique %@", text: "Oblique 3°") == nil)
        #expect(CoreUIText.match(template: "no placeholder", text: "no placeholder") == nil)
    }

    @Test func substituteHandlesSequentialPositionalAndMalformed() {
        #expect(CoreUIText.substitute(format: "%@ von %@", arguments: ["1", "2"]) == "1 von 2")
        #expect(CoreUIText.substitute(format: "%2$@ / %1$@", arguments: ["a", "b"]) == "b / a")
        #expect(CoreUIText.substitute(format: "100%% %@", arguments: ["x"]) == "100% x")
        // Missing arguments and foreign specifiers never crash.
        #expect(CoreUIText.substitute(format: "%@ %@ %d %", arguments: ["x"]) == "x  %d %")
        #expect(CoreUIText.substitute(format: "%3$@", arguments: ["x"]) == "")
    }

    @Test func localizeFallsBackToEnglish() {
        let lookup: (String) -> String? = { ["Axial": "Aksiyel", "%@ slice %@ of %@": "%1$@ kesit %2$@ / %3$@"][$0] }
        #expect(CoreUIText.localize("Axial slice 3 of 9", lookup: lookup) == "Aksiyel kesit 3 / 9")
        // Unknown text, and a matching template with no translation, stay English.
        #expect(CoreUIText.localize("Something else", lookup: lookup) == "Something else")
        #expect(CoreUIText.localize("Volume 2 of 5", lookup: lookup) == "Volume 2 of 5")
        // Parts are translated independently; unknown parts are kept.
        #expect(CoreUIText.localize("MIP · Axial", lookup: lookup) == "MIP · Aksiyel")
        #expect(CoreUIText.localize("", lookup: lookup) == "")
    }

    /// File names in the deferred-preview text are never split, matched or
    /// translated: not at the first " is ", not on " · ", not as a phrase.
    @Test func deferredMessageKeepsFileNamesIntact() {
        let template = PreviewStatusText.deferredTemplate(isDataless: false)
        let lookup: (String) -> String? = {
            [template: "%1$@ ist %2$@ groß (Netzwerk).", "Unknown": "Unbekannt", "MIP": "MIP-de"][$0]
        }
        for name in ["This is a scan.nii.gz", "a · b.nii", "Unknown", "MIP · Unknown is x.nii"] {
            // Structured: what the extension calls.
            #expect(CoreUIText.localize(template: template, arguments: [name, "2 GB"], lookup: lookup)
                == "\(name) ist 2 GB groß (Netzwerk).")
            // Composed English still round-trips with the name intact.
            let english = PreviewStatusText.deferredMessage(name: name, sizeText: "2 GB", isDataless: false)
            #expect(CoreUIText.localize(english, lookup: lookup) == "\(name) ist 2 GB groß (Netzwerk).")
        }
        #expect(CoreUIText.match(template: template, text: PreviewStatusText.deferredMessage(
            name: "This is a scan.nii.gz", sizeText: "2 GB", isDataless: false), anchorLast: true)
            == ["This is a scan.nii.gz", "2 GB"])
        // No catalog entry: English template, name intact.
        #expect(CoreUIText.localize(template: template, arguments: ["a · b.nii", "1 GB"]) { _ in nil }
            == PreviewStatusText.deferredMessage(name: "a · b.nii", sizeText: "1 GB", isDataless: false))
    }

    // MARK: Templates cover what MIQCore produces

    /// A lookup that knows every catalogued key and returns it unchanged, but
    /// records which templates were used.
    final class RecordingLookup: @unchecked Sendable {
        var used: Set<String> = []
        let keys = Set(CoreUIText.phrases).union(CoreUIText.templates)
        func callAsFunction(_ key: String) -> String? {
            guard keys.contains(key) else { return nil }
            used.insert(key)
            return key
        }
    }

    @Test func templatesMatchProducedEnglish() {
        let header = OrientationDiagnostics(
            transformSource: .sform, axisCodes: "RAS", obliquityDegrees: 23,
            qformSformConflict: .axisCodes, qformAxisCodes: "LAS"
        )
        let produced: [String] = [
            PreviewStatusText.failureMessage(for: MIQError.malformedFile("bad dim")),
            PreviewStatusText.failureMessage(for: MIQError.invalidHeaderSize(12)),
            PreviewStatusText.deferredMessage(name: "a.nii.gz", sizeText: "2 GB", isDataless: true),
            PreviewStatusText.deferredMessage(name: "a.nii.gz", sizeText: "2 GB", isDataless: false),
            MIQPayloadSizeEstimate.tooLargeFor4DMessage(bytes: 5_000_000_000),
            PreviewAccessibility.sliceLabel(plane: .axial, sliceIndex: 44, sliceCount: 90, window: "W 80 / L 40"),
            PreviewAccessibility.sliceLabel(plane: .coronal, sliceIndex: 0, sliceCount: 10, window: nil),
            PreviewAccessibility.volumeValue(index: 2, count: 20),
            header.warning!,
            header.displaySummary,
            WindowPresetShortcuts.badgeText(preset: .brain, bounds: WindowPreset.brain.bounds!),
            MIQError.unsupportedFeature("x").errorDescription!,
            MIQError.unsupportedDatatype(7).errorDescription!,
            MIQError.unsupportedFormatVersion(3).errorDescription!,
        ]
        let lookup = RecordingLookup()
        for text in produced {
            // Identity translations reproduce the English exactly.
            #expect(CoreUIText.localize(text) { lookup($0) } == text)
        }
        for template in [
            "Preview failed: %@", "Malformed file: %@.", "Invalid NIfTI header size: %@.",
            "Too large for 4D in Quick Look (%@)", "%@ slice %@ of %@, window %@", "%@ slice %@ of %@",
            "Volume %@ of %@", "oblique %@", "Unsupported feature: %@.", "Unsupported datatype code: %@.",
            "Unsupported file format version: %@.",
            "qform (%@) and sform (%@) disagree — other tools may orient this image differently",
        ] {
            #expect(lookup.used.contains(template), "template not matched: \(template)")
        }
        #expect(lookup.used.contains { $0.contains("in iCloud") })
        #expect(lookup.used.contains { $0.contains("network volume") })
    }

    @Test func temporalAndQCValuesMatchTemplates() {
        let lookup = RecordingLookup()
        for text in ["52 · 3 spike frames", "Typical (6 metrics, heuristic)", "Borderline (2 of 6 metrics flagged, heuristic)",
                     "Likely present (heuristic)", "T1w (heuristic)", "TR mismatch: sidecar 2 s, header 3 s",
                     ".bval has 30 entries for 31 volumes"] {
            #expect(CoreUIText.localize(text) { lookup($0) } == text)
        }
        for template in ["%@ spike frames", "%@ (%@, heuristic)", "%@ of %@ metrics flagged", "%@ metrics",
                         "%@ (heuristic)", "TR mismatch: sidecar %@, header %@", ".bval has %@ entries for %@ volumes"] {
            #expect(lookup.used.contains(template), "template not matched: \(template)")
        }
    }

    // MARK: The extension's catalog

    static var catalogURL: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["MIQ_PREVIEW_CATALOG"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("MIQQuickLookExtension/Preview.xcstrings"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// key → language → value.
    static func loadCatalog() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: try #require(catalogURL))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        let strings = try #require(root["strings"] as? [String: Any])
        var result: [String: [String: String]] = [:]
        for (key, raw) in strings {
            let entry = raw as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            var values: [String: String] = [:]
            for (language, unit) in localizations {
                let stringUnit = (unit as? [String: Any])?["stringUnit"] as? [String: Any]
                if stringUnit?["state"] as? String == "translated", let value = stringUnit?["value"] as? String {
                    values[language] = value
                }
            }
            result[key] = values
        }
        return result
    }

    /// Placeholder indices a format uses: `%@` counts sequentially, `%n$@` is n.
    static func placeholders(_ format: String) -> [Int] {
        var result: [Int] = []
        var next = 1
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%", i + 1 < chars.count else { i += 1; continue }
            if chars[i + 1] == "%" { i += 2; continue }
            if chars[i + 1] == "@" { result.append(next); next += 1; i += 2; continue }
            var j = i + 1
            var digits = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@", let n = Int(digits) {
                result.append(n)
                i = j + 2
            } else {
                i += 1
            }
        }
        return result.sorted()
    }

    @Test(.enabled(if: catalogURL != nil, "Preview.xcstrings not found next to the tests"))
    func catalogTranslatesEveryPhraseAndTemplate() throws {
        let catalog = try Self.loadCatalog()
        for phrase in CoreUIText.phrases where !CoreUIText.untranslatedPhrases.contains(phrase) {
            let values = catalog[phrase]
            #expect(values?["de"] != nil && values?["tr"] != nil, "missing de/tr translation for phrase \"\(phrase)\"")
        }
        for template in CoreUIText.templates {
            let values = try #require(catalog[template], "template not in catalog: \(template)")
            let expected = Self.placeholders(template)
            for language in ["de", "tr"] {
                let value = try #require(values[language], "missing \(language) for \(template)")
                #expect(Self.placeholders(value) == expected, "\(language) placeholders differ for \(template)")
            }
        }
    }

    @Test(.enabled(if: catalogURL != nil, "Preview.xcstrings not found next to the tests"))
    func catalogPlaceholdersMatchTheirKeys() throws {
        for (key, values) in try Self.loadCatalog() {
            let expected = Self.placeholders(key)
            for (language, value) in values {
                #expect(Self.placeholders(value) == expected, "\(language) placeholders differ for \(key)")
            }
        }
    }

    @Test(.enabled(if: catalogURL != nil, "Preview.xcstrings not found next to the tests"))
    func germanAndTurkishRenderings() throws {
        let catalog = try Self.loadCatalog()
        func render(_ text: String, _ language: String) -> String {
            CoreUIText.localize(text) { catalog[$0]?[language] }
        }
        let slice = PreviewAccessibility.sliceLabel(plane: .coronal, sliceIndex: 44, sliceCount: 90, window: "W 80 / L 40")
        #expect(render(slice, "de") == "Koronal, Schicht 45 von 90, Fenster W 80 / L 40")
        #expect(render(slice, "tr") == "Koronal kesit 45 / 90, pencere W 80 / L 40")
        #expect(render(ViewOrientation.radiological.badgeLabel, "tr") == "Radyolojik görünüm")
        #expect(render(ViewOrientation.neurological.badgeLabel, "de") == "Neurologisch")
        #expect(render(PreviewAccessibility.planeName(.sagittal), "tr") == "Sagital")
        #expect(render(PreviewAccessibility.planeName(.axial), "tr") == "Aksiyel")
        #expect(render("Borderline (2 of 6 metrics flagged, heuristic)", "de") == "Grenzwertig (2 von 6 Metriken auffällig, heuristisch)")
        #expect(render("Borderline (2 of 6 metrics flagged, heuristic)", "tr") == "Sınırda (6 metrikten 2 tanesi işaretli, sezgisel)")
        #expect(render("RAS · oblique 23° · sform", "de") == "RAS · schräg 23° · sform")
        #expect(render(PreviewStatusText.failureMessage(for: MIQError.truncatedData), "de")
            == "Vorschau fehlgeschlagen: Die Datei scheint abgeschnitten zu sein.")
        // Technical tokens stay as they are.
        #expect(render("W 80 / L 40", "tr") == "W 80 / L 40")
        #expect(render(WindowPresetShortcuts.badgeText(preset: .bone, bounds: WindowPreset.bone.bounds!), "de")
            == "Knochen · \(WindowPreset.bone.bounds!.widthLevelLabel)")
    }
}
