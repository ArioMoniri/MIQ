import Foundation

/// The pure, platform-independent half of the app's opt-in "Describe file"
/// feature: what the language model is told, which header facts it may see,
/// and what of its answer is allowed back onto the screen.
///
/// ## Regulatory rationale
///
/// MIQ is intended as a file viewer, not a medical device. This is the
/// project's own reading, not legal advice, and it is not an FDA determination.
/// Under the FD&C Act, whether software is a device depends on its *intended
/// use* (the device definition in section 201(h), 21 U.S.C. 321(h)). The
/// clinical decision support (CDS) carve-out in section 520(o)(1)(E),
/// 21 U.S.C. 360j(o)(1)(E), does not cover software "intended to acquire,
/// process, or analyze a medical image", and FDA's guidance "Clinical Decision
/// Support Software" (fda.gov/regulatory-information/search-fda-guidance-documents/clinical-decision-support-software;
/// check the current revision) explains how FDA applies those criteria. A
/// model-written caption therefore seems safest when it stays strictly
/// technical: it describes the file's properties and offers no findings,
/// diagnoses or treatment suggestions. This type enforces that in code rather
/// than relying on the prompt alone:
///
/// - **Input allowlist.** Only the structural header facts in `CaptionField`
///   reach the model — never the file name, path, NIfTI `descrip` / `aux_file`,
///   NRRD comments or key/value pairs, sidecar JSON, or any other free text that
///   could carry PHI or a clinician's notes, and values are character-filtered so
///   a hostile header cannot smuggle prose through an allowed field.
/// - **Instructions.** `systemInstructions` restricts the model to a single
///   sentence about modality guess, dimensions, resolution and coverage, and
///   forbids findings and diagnosis.
/// - **Output filter.** `filterOutput(_:metadata:)` rejects any answer that uses
///   diagnostic or clinical vocabulary (or mentions a patient) and substitutes a
///   deterministic caption built from the header alone, so a model that ignores
///   its instructions still cannot put an interpretation on screen.
///
/// The UI additionally carries a permanent "Generated on-device. Not a medical
/// interpretation." label, and the feature is OFF by default and app-only — the
/// Quick Look and thumbnail extensions never link it.
public enum CaptionPrompt {

    /// The header facts a caption may be built from, in prompt order. Anything
    /// not listed here is dropped by `allowlisted(_:)` before a prompt exists.
    public enum CaptionField: String, CaseIterable, Sendable {
        case format
        case dimensions
        case spacing
        case orientation
        case datatype
        case volumes
        case scaling
        /// Physical extent per axis (dimension × spacing), e.g. "256 × 256 × 180 mm".
        case coverage

        /// Human-readable label used in the prompt.
        var label: String {
            switch self {
            case .format:      return "Format"
            case .dimensions:  return "Dimensions (voxels)"
            case .spacing:     return "Voxel spacing"
            case .orientation: return "Storage orientation"
            case .datatype:    return "Datatype"
            case .volumes:     return "Volumes (4th dimension)"
            case .scaling:     return "Intensity scaling"
            case .coverage:    return "Field of view"
            }
        }
    }

    /// Longest caption that is shown; longer model output is cut at a word
    /// boundary and ends with an ellipsis.
    public static let maximumCaptionLength = 200

    /// Longest metadata value passed to the model. Real values are short
    /// ("1.00 × 1.00 × 1.00 mm"); anything longer is not a structural fact.
    static let maximumValueLength = 48

    /// The system prompt / instructions shared by every engine.
    public static let systemInstructions = """
        You write a one-sentence technical description of a medical imaging file \
        for a file browser. Use only the header facts provided. Describe the \
        likely acquisition type or modality (as a guess, e.g. "likely a T1-weighted \
        MRI" or "likely a CT", or "a label/segmentation map"), the matrix \
        dimensions, the voxel resolution, and the anatomical coverage or field of \
        view. Never describe clinical findings, anatomy that looks normal or \
        abnormal, disease, pathology, or diagnosis, and never mention a patient. \
        If an image is attached, use it only to judge the acquisition type and \
        coverage. Output exactly one plain sentence of at most 30 words, with no \
        preamble, lists, quotes or markdown.
        """

    // MARK: - Input

    /// Keeps only allowlisted fields whose values pass the character filter,
    /// in `CaptionField` order. Keys are matched case-insensitively against the
    /// field raw values; unknown keys (file names, `descrip`, sidecar keys, …)
    /// are discarded.
    public static func allowlisted(_ metadata: [String: String]) -> [(field: CaptionField, value: String)] {
        var byField: [CaptionField: String] = [:]
        for (key, rawValue) in metadata {
            guard let field = CaptionField(rawValue: key.lowercased()),
                  let value = sanitizedValue(rawValue) else { continue }
            byField[field] = value
        }
        return CaptionField.allCases.compactMap { field in
            byField[field].map { (field: field, value: $0) }
        }
    }

    /// The user-turn prompt: the allowlisted facts as a labelled list.
    public static func userPrompt(metadata: [String: String]) -> String {
        let facts = allowlisted(metadata)
        var lines = ["Header facts:"]
        if facts.isEmpty {
            lines.append("- (none available)")
        } else {
            lines += facts.map { "- \($0.field.label): \($0.value)" }
        }
        lines.append("")
        lines.append("Write the one-sentence technical description now.")
        return lines.joined(separator: "\n")
    }

    /// Builds the caption metadata dictionary from a parsed header. This is the
    /// supported way to feed `userPrompt(metadata:)`: it reads only structural
    /// fields, so nothing free-text can leak in by construction.
    /// - Parameters:
    ///   - format: The display format label ("NIfTI-1", "MGZ", …). Pass the
    ///     kind's `displayName`, never the file name.
    ///   - orientation: Storage orientation code ("RAS", …), if resolved.
    public static func metadata(header: MIQHeader, format: String?, orientation: String?) -> [String: String] {
        let summary = MIQMetadata(header: header, orientation: orientation)
        var result: [String: String] = [
            CaptionField.dimensions.rawValue: summary.dimensions,
            CaptionField.spacing.rawValue: summary.spacing,
            CaptionField.datatype.rawValue: summary.datatype,
            CaptionField.volumes.rawValue: "\(summary.volumes)",
        ]
        if let format { result[CaptionField.format.rawValue] = format }
        if let orientation { result[CaptionField.orientation.rawValue] = orientation }
        if let scaling = summary.asDisplayLines().first(where: { $0.field == .scaling }) {
            result[CaptionField.scaling.rawValue] = scaling.value
        }
        let extents = [header.width, header.height, header.depth].enumerated().map { axis, count -> Float in
            Float(count) * abs(header.pixdim[safe: axis + 1] ?? 1)
        }
        if extents.allSatisfy({ $0.isFinite && $0 > 0 }) {
            result[CaptionField.coverage.rawValue] = extents
                .map { String(format: "%.0f", $0) }
                .joined(separator: " \u{00D7} ") + " mm"
        }
        return result
    }

    /// Characters a structural header value can legitimately contain: letters
    /// and digits (format and datatype names), whitespace, the multiplication
    /// sign and simple arithmetic / unit punctuation.
    private static let allowedValueScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: " .,+-_()/:\u{00D7}")
        return set
    }()

    /// Collapses whitespace, then rejects values that are too long or contain
    /// characters outside `allowedValueScalars`, or read like prose (a value
    /// with more than six words is not a header fact).
    static func sanitizedValue(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maximumValueLength,
              collapsed.unicodeScalars.allSatisfy({ allowedValueScalars.contains($0) }),
              !containsBlockedTerm(collapsed) else { return nil }
        let words = collapsed.split(separator: " ").filter { $0.contains(where: \.isLetter) }
        guard words.count <= 6 else { return nil }
        return collapsed
    }

    // MARK: - Output

    /// Result of filtering a model response.
    public struct FilteredCaption: Sendable, Equatable {
        /// What the UI shows.
        public let text: String
        /// `true` when the model's text was rejected and `text` is the
        /// deterministic fallback.
        public let usedFallback: Bool
    }

    /// Stems matched against the start of each lowercased word ("diagnos"
    /// catches diagnosis/diagnostic, "abnormal" catches abnormality).
    static let blockedStems: [String] = [
        "diagnos", "tumor", "tumour", "lesion", "abnormal", "malignan", "benign",
        "infarct", "hemorrhag", "haemorrhag", "bleed", "patholog", "cancer",
        "carcinom", "metasta", "neoplas", "glioma", "oncolog", "stroke", "ischemi",
        "ischaemi", "fracture", "nodule", "cyst", "edema", "oedema", "atroph",
        "aneurysm", "stenos", "occlusion", "hematoma", "haematoma", "inflamm",
        "unremarkable", "finding", "suspicious", "disease", "patient",
        "prognos", "symptom", "clinical", "biopsy",
    ]

    /// Multi-word phrases matched anywhere in the lowercased, whitespace-
    /// collapsed text.
    static let blockedPhrases: [String] = [
        "normal study", "normal scan", "normal exam", "within normal", "appears normal",
        "looks normal", "no evidence", "consistent with", "suggestive of",
        "concerning for", "mass effect", "year-old", "year old", "years old",
    ]

    /// `true` if `text` contains a blocked stem at the start of any word, or a
    /// blocked phrase anywhere.
    public static func containsBlockedTerm(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if blockedPhrases.contains(where: { collapsed.contains($0) }) { return true }
        let words = lowered.split(whereSeparator: { !$0.isLetter })
        return words.contains { word in blockedStems.contains { word.hasPrefix($0) } }
    }

    /// Normalises raw model output into at most one sentence of at most
    /// `maximumCaptionLength` characters, or replaces it with
    /// `fallbackCaption(metadata:)` when it is empty or uses blocked vocabulary.
    /// The blocked-term check runs on the *whole* raw response, not just the
    /// kept sentence, so an interpretation in a trailing sentence still rejects.
    public static func filterOutput(_ raw: String, metadata: [String: String]) -> FilteredCaption {
        let fallback = FilteredCaption(text: fallbackCaption(metadata: metadata), usedFallback: true)
        guard !containsBlockedTerm(raw) else { return fallback }

        // First non-empty line, minus markdown / list / quote decoration.
        let decoration = CharacterSet(charactersIn: "*#>`\"'\u{201C}\u{201D}\u{2018}\u{2019}-\u{2022} ")
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: decoration.union(.whitespaces)) })
            .first(where: { !$0.isEmpty }) else { return fallback }
        var text = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        // Drop a leading "Description:" / "Caption:" label if the model added one.
        for prefix in ["description:", "caption:", "summary:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: decoration)
        }

        text = firstSentence(of: text)
        guard text.contains(where: \.isLetter) else { return fallback }
        return FilteredCaption(text: truncated(text), usedFallback: false)
    }

    /// The text up to and including the first sentence-ending period, question
    /// or exclamation mark followed by a space — decimal points ("1.25 mm")
    /// don't end a sentence because no space follows them.
    static func firstSentence(of text: String) -> String {
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == " ", let previous, ".!?".contains(previous) {
                return String(text[..<index])
            }
            previous = character
        }
        return text
    }

    /// Cuts at the last space that keeps the result (with "…") within the cap.
    static func truncated(_ text: String) -> String {
        guard text.count > maximumCaptionLength else { return text }
        let hardLimit = text.index(text.startIndex, offsetBy: maximumCaptionLength - 1)
        var cut = text[..<hardLimit]
        if let space = cut.lastIndex(of: " ") { cut = cut[..<space] }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "\u{2026}"
    }

    /// Deterministic, model-free caption from the allowlisted facts, e.g.
    /// "NIfTI-1 volume, 256 × 256 × 180 voxels at 1.00 × 1.00 × 1.00 mm,
    /// float32, 1 volume." Used whenever model output is rejected.
    public static func fallbackCaption(metadata: [String: String]) -> String {
        let facts = Dictionary(allowlisted(metadata).map { ($0.field, $0.value) }, uniquingKeysWith: { a, _ in a })
        var parts: [String] = []
        var head = "\(facts[.format] ?? "Imaging") volume"
        if let dimensions = facts[.dimensions] { head += ", \(dimensions) voxels" }
        if let spacing = facts[.spacing] { head += " at \(spacing)" }
        parts.append(head)
        if let coverage = facts[.coverage] { parts.append("field of view \(coverage)") }
        if let datatype = facts[.datatype] { parts.append(datatype) }
        if let volumes = facts[.volumes], let count = Int(volumes) {
            parts.append(count == 1 ? "1 volume" : "\(count) volumes")
        }
        return truncated(parts.joined(separator: ", ") + ".")
    }
}
