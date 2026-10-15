import Foundation

/// One entry of a label table: a display name and, optionally, a colour.
public struct SegmentationLabel: Sendable, Equatable {
    public let name: String
    /// Packed 0xRRGGBB, `nil` when the table gives no colour.
    let packedRGB: UInt32?

    public init(name: String, color: (r: UInt8, g: UInt8, b: UInt8)? = nil) {
        self.name = name
        self.packedRGB = color.map { SegmentationLut.pack($0.r, $0.g, $0.b) }
    }

    init(name: String, packedRGB: UInt32?) {
        self.name = name
        self.packedRGB = packedRGB
    }

    public var color: (r: UInt8, g: UInt8, b: UInt8)? {
        packedRGB.map { (UInt8($0 >> 16), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)) }
    }
}

// MARK: - Label names

extension SegmentationLut {
    /// The anatomical / class name of `label` under this colour scheme: the
    /// FreeSurferColorLUT name for `.freeSurfer`, the file's own name for
    /// `.embedded`, `nil` otherwise (and for labels the table does not list).
    public func labelName(_ label: Int) -> String? {
        switch kind {
        case .freeSurfer: return Self.freeSurferNamedTable[label]?.name
        case .embedded: return embeddedLabels[label]?.name
        case .random, .monochromeWhite: return nil
        }
    }

    /// "17 Left-Hippocampus", or just "17" when the label has no name.
    public func formatLabel(_ label: Int) -> String {
        guard let name = labelName(label) else { return String(label) }
        return "\(label) \(name)"
    }

    /// Voxel-readout text with the label name appended ("17 Left-Hippocampus"),
    /// or `nil` when `value` is not an integral label this scheme names; the
    /// caller then falls back to its plain number formatting.
    public func formatLabelValue(_ value: Float) -> String? {
        guard value.isFinite, value == value.rounded(), abs(value) < 1e9 else { return nil }
        let label = Int(value)
        guard labelName(label) != nil else { return nil }
        return formatLabel(label)
    }

    /// FreeSurferColorLUT name for `label`, whatever the scheme.
    public static func freeSurferLabelName(_ label: Int) -> String? {
        freeSurferNamedTable[label]?.name
    }

    struct FreeSurferEntry: Sendable {
        let rgb: UInt32
        let name: String
    }

    /// The full FreeSurferColorLUT (`FreeSurferColorLUT.swift`), parsed on first
    /// use (~1800 short lines, well under a millisecond). Kept apart from
    /// `freeSurferTable`, which stays the curated set that *detection* is defined
    /// over: widening detection to every LUT id would make far more small-integer
    /// label maps look like FreeSurfer.
    static let freeSurferNamedTable: [Int: FreeSurferEntry] = {
        var table: [Int: FreeSurferEntry] = [:]
        table.reserveCapacity(2048)
        for line in freeSurferColorLUTSource.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4)
            guard fields.count == 5,
                  let id = Int(fields[0]),
                  let r = UInt8(fields[1]), let g = UInt8(fields[2]), let b = UInt8(fields[3]) else { continue }
            table[id] = FreeSurferEntry(rgb: pack(r, g, b), name: String(fields[4]))
        }
        return table
    }()
}

// MARK: - Embedded label tables

extension SegmentationLut {
    /// Upper bound on labels read from one embedded table.
    private static let maxEmbeddedLabels = 65_536

    /// Parses a Caret / GIFTI / CIFTI-style label table:
    ///
    ///     <Label Key="1" Red="1" Green="0" Blue="0" Alpha="1"><![CDATA[spleen]]></Label>
    ///
    /// This is what TotalSegmentator writes (`nifti_ext_header.py`,
    /// `add_label_map_to_nifti`: a `CaretExtension` XML document appended as a
    /// NIfTI extension with ecode 0), and the shape of GIFTI label tables and
    /// CIFTI dlabel extensions (ecode 32). A tolerant scanner, not a full XML
    /// parser: attribute names match case-insensitively and in any order,
    /// colours accept 0–1 floats (the GIFTI convention) or 0–255 integers, the
    /// name may be CDATA or entity-escaped text, and malformed entries are
    /// skipped. Missing colours leave `color` nil; empty names drop the entry.
    public static func parseLabelTableXML(_ xml: String) -> [Int: SegmentationLabel] {
        var result: [Int: SegmentationLabel] = [:]
        var cursor = xml.startIndex
        while result.count < maxEmbeddedLabels,
              let open = xml.range(of: "<Label", options: [.caseInsensitive], range: cursor..<xml.endIndex) {
            cursor = open.upperBound
            // `<LabelTable>` shares the prefix; only `<Label` + whitespace opens an entry.
            guard open.upperBound < xml.endIndex, xml[open.upperBound].isWhitespace else { continue }
            guard let tagEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex) else { break }
            let attributeText = xml[open.upperBound..<tagEnd.lowerBound]
            cursor = tagEnd.upperBound

            var name = ""
            if attributeText.last != "/" {
                guard let close = xml.range(of: "</Label", options: [.caseInsensitive], range: tagEnd.upperBound..<xml.endIndex) else { break }
                name = decodeXMLText(xml[tagEnd.upperBound..<close.lowerBound])
                cursor = close.upperBound
            }
            let attributes = parseXMLAttributes(attributeText)
            guard let keyText = attributes["key"],
                  let key = Int(keyText.trimmingCharacters(in: .whitespaces)) else { continue }
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard !trimmed.isEmpty else { continue }

            var packed: UInt32?
            if let r = attributes["red"].flatMap(Double.init),
               let g = attributes["green"].flatMap(Double.init),
               let b = attributes["blue"].flatMap(Double.init),
               [r, g, b].allSatisfy({ $0.isFinite && $0 >= 0 }) {
                let scale: Double = [r, g, b].contains(where: { $0 > 1 }) ? 1 : 255
                func channel(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * scale).rounded()))) }
                packed = pack(channel(r), channel(g), channel(b))
            }
            result[key] = SegmentationLabel(name: trimmed, packedRGB: packed)
        }
        return result
    }

    /// `name="value"` / `name='value'` pairs, names lower-cased.
    private static func parseXMLAttributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            guard let eq = text[index...].firstIndex(of: "=") else { break }
            let name = text[index..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var valueStart = text.index(after: eq)
            while valueStart < text.endIndex, text[valueStart].isWhitespace {
                valueStart = text.index(after: valueStart)
            }
            guard valueStart < text.endIndex else { break }
            let quote = text[valueStart]
            guard quote == "\"" || quote == "'" else { break }
            let contentStart = text.index(after: valueStart)
            guard let close = text[contentStart...].firstIndex(of: quote) else { break }
            attributes[name] = decodeXMLText(text[contentStart..<close])
            index = text.index(after: close)
        }
        return attributes
    }

    /// Unwraps CDATA sections, decodes the five predefined XML entities and
    /// numeric character references, and drops any other markup.
    static func decodeXMLText(_ text: Substring) -> String {
        var output = ""
        var rest = text
        while let first = rest.first {
            if rest.hasPrefix("<![CDATA[") {
                let body = rest.dropFirst(9)
                if let end = body.range(of: "]]>") {
                    output += body[..<end.lowerBound]
                    rest = body[end.upperBound...]
                } else {
                    output += body
                    rest = rest[rest.endIndex...]
                }
            } else if first == "<" {
                // Stray markup inside a name (e.g. a comment): drop the tag.
                if let end = rest.firstIndex(of: ">") {
                    rest = rest[rest.index(after: end)...]
                } else {
                    rest = rest[rest.endIndex...]
                }
            } else if first == "&", let semi = rest.prefix(12).firstIndex(of: ";") {
                let entity = rest[rest.index(after: rest.startIndex)..<semi]
                switch entity {
                case "amp": output += "&"
                case "lt": output += "<"
                case "gt": output += ">"
                case "quot": output += "\""
                case "apos": output += "'"
                default:
                    let value: UInt32?
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                        value = UInt32(entity.dropFirst(2), radix: 16)
                    } else if entity.hasPrefix("#") {
                        value = UInt32(entity.dropFirst())
                    } else {
                        value = nil
                    }
                    if let value, let scalar = Unicode.Scalar(value) {
                        output.unicodeScalars.append(scalar)
                    } else {
                        output += rest[...semi]
                    }
                }
                rest = rest[rest.index(after: semi)...]
            } else {
                output.append(first)
                rest = rest.dropFirst()
            }
        }
        return output
    }
}
