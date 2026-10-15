import AppKit
import MIQCore

/// What the preview's metadata panel says and how its text looks: row order and
/// visibility, the reserved Volumes / voxel-value slots, the two-column layout
/// and the disclaimer footer. Shared with the app (like `MIQImageBridge`) so the
/// Settings window's panel preview is the real panel text, not a look-alike.
///
/// Every setting is an input — nothing here reads `MIQConfig` — so the preview
/// passes what it reads from the App Group and Settings passes its live values.
/// Sizing (font size, inset) stays with the caller: the preview scales it with
/// the panel, Settings uses a fixed size.
enum MetadataPanelText {
    // Derived from the resolved metadata font size.
    static let rowSpacingFactor: CGFloat = 0.3
    static let labelGutterFactor: CGFloat = 0.9
    static let disclaimerFontFactor: CGFloat = 0.8
    static let disclaimerFontMin: CGFloat = 6
    static let disclaimerGapFactor: CGFloat = 2

    /// Labels drawn by the preview's overlays rather than by the text, still
    /// measured when sizing the label column.
    static let volumesRowLabel = "Volumes"
    static let valueRowLabel = "Voxel value"
    static let positionRowLabel = MetadataField.voxelPosition.displayLabel
    /// Prefix of every warning line (text presentation selector: a monochrome
    /// glyph that takes the warning colour instead of an emoji).
    static let warningPrefix = "\u{26A0}\u{FE0E} "

    /// One drawn line: label + value, empty for an overlay-drawn row (Volumes,
    /// voxel value, position), value-only for a row that spans the panel (the
    /// debug build stamp, warnings, subheadings).
    struct Row {
        enum Style: Sendable, Equatable {
            case normal
            /// Always-visible caution (orientation, sidecar mismatch): spans
            /// the panel in the system warning colour.
            case warning
            /// Spanning section title ("Data QC").
            case subheading
        }

        let label: String
        let value: String
        var style: Style = .normal
    }

    /// Rows appended after the configurable fields, under an optional
    /// subheading: DICOM technical rows, the Data QC rows. Not subject to the
    /// field toggles — the preview decides whether to produce them at all.
    struct Section: Sendable {
        let title: String?
        let entries: [MetadataEntry]
    }

    struct Layout {
        let rows: [Row]
        /// Line reserved blank for the 4D scrubber, if any.
        let volumesLineIndex: Int?
        /// Line reserved blank for the live voxel-value readout, if any.
        let valueLineIndex: Int?
        /// Line reserved blank for the live crosshair-position readout, if any.
        var positionLineIndex: Int? = nil
    }

    /// Orders and filters `entries` into drawn rows.
    ///
    /// - Parameters:
    ///   - showsValue: whether the live voxel-value line occupies a slot (the
    ///     crosshair is visible and the field enabled); the slot is reserved
    ///     blank for the overlay.
    ///   - staticValueText: instead of a reserved slot, draw the voxel-value row
    ///     as ordinary text with this value (Settings' sample). The preview never
    ///     sets it.
    ///   - showsPosition: whether the live crosshair-position line occupies a
    ///     slot (reserved blank like the value line).
    ///   - warnings: always-visible caution lines, drawn first whatever the
    ///     field toggles say.
    ///   - volumesWindowText: for a 4D file, the window-mode indicator
    ///     ("per volume" / "shared") drawn on its own row right after Volumes.
    ///   - appendix: sections drawn after the configurable rows.
    static func layout(
        entries: [MetadataEntry],
        order: [MetadataField],
        isVisible: (MetadataField) -> Bool,
        isFourD: Bool,
        showsValue: Bool,
        staticValueText: String? = nil,
        showsPosition: Bool = false,
        warnings: [String] = [],
        volumesWindowText: String? = nil,
        appendix: [Section] = []
    ) -> Layout {
        let orderIndex: [MetadataField: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        // The value field carries no header-derived text — inject an entry so it
        // takes its configured order position. In the preview its slot is
        // reserved blank below and the overlay draws both halves, so nothing from
        // here is ever shown (and it never churns the rebuild).
        var entries = entries
        if let staticValueText {
            entries.append(MetadataEntry(field: .value, label: valueRowLabel, value: staticValueText))
        } else if showsValue {
            entries.append(MetadataEntry(field: .value, label: "", value: ""))
        }
        if showsPosition {
            entries.append(MetadataEntry(field: .voxelPosition, label: "", value: ""))
        }
        let sorted = entries.sorted { a, b in
            let ai = a.field.flatMap { orderIndex[$0] } ?? Int.max
            let bi = b.field.flatMap { orderIndex[$0] } ?? Int.max
            return ai < bi
        }

        // The 4D Volumes line and the live Value line are each reserved as an
        // empty line of identical height: the matching overlay draws over exactly
        // that slot, every other line keeps its position. For the Volumes case
        // the live value renders inside the scrubber instead.
        var rows: [Row] = warnings.map { Row(label: "", value: warningPrefix + singleLine($0), style: .warning) }
        var volumesLineIndex: Int?
        var valueLineIndex: Int?
        var positionLineIndex: Int?
        for entry in sorted {
            if let field = entry.field, !isVisible(field) { continue }
            if isFourD, entry.field == .volumes {
                volumesLineIndex = rows.count
                rows.append(Row(label: "", value: ""))
                if let volumesWindowText {
                    rows.append(Row(label: PreviewDataSummaries.windowModeLabel, value: volumesWindowText))
                }
            } else if entry.field == .value, staticValueText == nil {
                valueLineIndex = rows.count
                rows.append(Row(label: "", value: ""))
            } else if entry.field == .voxelPosition {
                positionLineIndex = rows.count
                rows.append(Row(label: "", value: ""))
            } else if entry.field == nil {
                // Not a configurable field (only the debug build stamp): span the
                // panel rather than joining the column, whose width it would
                // otherwise drive — "DEBUG BUILD" is wider than any shipping label,
                // so a Debug build would misrepresent Release geometry.
                rows.append(Row(label: "", value: entry.text))
            } else {
                rows.append(Row(label: singleLine(entry.label), value: singleLine(entry.value)))
            }
        }
        for section in appendix where !section.entries.isEmpty {
            if let title = section.title {
                rows.append(Row(label: "", value: singleLine(title), style: .subheading))
            }
            for entry in section.entries {
                rows.append(Row(label: singleLine(entry.label), value: singleLine(entry.value)))
            }
        }
        return Layout(
            rows: rows,
            volumesLineIndex: volumesLineIndex,
            valueLineIndex: valueLineIndex,
            positionLineIndex: positionLineIndex
        )
    }

    /// One row per line is what the preview's reserved-slot mapping counts on
    /// (`MetadataView.characterIndexForLine`), so no row may carry a line break.
    private static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Plain-text rendering of `rows` for VoiceOver: "Label: value" per row;
    /// a reserved (overlay-drawn) row is replaced by `reserved(index)`, or
    /// skipped when that returns `nil`.
    static func accessibilityText(rows: [Row], reserved: (Int) -> String?) -> String {
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            if row.label.isEmpty, row.value.isEmpty {
                if let text = reserved(index) { lines.append(text) }
            } else if row.label.isEmpty {
                if row.style == .warning {
                    lines.append("Warning: " + row.value.replacingOccurrences(of: warningPrefix, with: ""))
                } else {
                    lines.append(row.value)
                }
            } else {
                lines.append("\(row.label): \(row.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The voxel-value readout's text: integers without a decimal point, other
    /// values to six significant digits.
    static func formatVoxelValue(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "+Inf" }
        if value == value.rounded(), abs(value) < 1e7 {
            return String(Int(value))
        }
        return String(format: "%.6g", Double(value))
    }

    /// As `formatVoxelValue(_:)`, with the label name appended when the active
    /// segmentation LUT names this value ("17 Left-Hippocampus").
    static func formatVoxelValue(_ value: Float, lut: SegmentationLut?) -> String {
        lut?.formatLabelValue(value) ?? formatVoxelValue(value)
    }

    /// Value-column x: widest label plus a gutter. Empty labels are skipped.
    static func labelColumnOrigin(for labels: [String], font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = labels.reduce(CGFloat.zero) { widest, label in
            guard !label.isEmpty else { return widest }
            return max(widest, (label as NSString).size(withAttributes: attributes).width)
        }
        return widest + font.pointSize * labelGutterFactor
    }

    static func attributedString(
        from rows: [Row],
        fontSize: CGFloat,
        labelColumnX: CGFloat,
        showsDisclaimer: Bool
    ) -> NSAttributedString {
        let labelColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        let valueColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        // Breathing room between rows. Trailing (not leading) spacing keeps each
        // line's glyphs at its fragment top, so the scrubber — drawn at its
        // fragment top — still aligns with its neighbours.
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacing = fontSize * rowSpacingFactor
        // Two columns, one tab apart; `headIndent` hangs a wrapped value.
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: labelColumnX)]
        rowStyle.defaultTabInterval = labelColumnX
        rowStyle.headIndent = labelColumnX
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
            .paragraphStyle: rowStyle
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: valueColor,
            .paragraphStyle: rowStyle
        ]
        // Spanning rows (warnings, subheadings) wrap flush left, not under the
        // value column.
        let spanStyle = NSMutableParagraphStyle()
        spanStyle.paragraphSpacing = fontSize * rowSpacingFactor
        let warningAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.systemOrange,
            .paragraphStyle: spanStyle
        ]
        let subheadingAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: labelColor,
            .paragraphStyle: spanStyle
        ]
        let result = NSMutableAttributedString()

        for (index, row) in rows.enumerated() {
            if row.style != .normal {
                result.append(NSAttributedString(
                    string: row.value,
                    attributes: row.style == .warning ? warningAttrs : subheadingAttrs
                ))
            } else if !row.label.isEmpty {
                result.append(NSAttributedString(string: row.label + "\t", attributes: labelAttrs))
            }
            if row.style == .normal, !row.value.isEmpty {
                result.append(NSAttributedString(string: row.value, attributes: valueAttrs))
            }

            if index < rows.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: labelAttrs))
            }
        }

        if showsDisclaimer {
            let disclaimerFont = NSFont.systemFont(ofSize: max(disclaimerFontMin, fontSize * disclaimerFontFactor), weight: .regular)
            let disclaimerColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
            let firstLineStyle = NSMutableParagraphStyle()
            firstLineStyle.paragraphSpacingBefore = fontSize * disclaimerGapFactor
            let firstLineAttrs: [NSAttributedString.Key: Any] = [
                .font: disclaimerFont,
                .foregroundColor: disclaimerColor,
                .paragraphStyle: firstLineStyle
            ]
            let secondLineAttrs: [NSAttributedString.Key: Any] = [
                .font: disclaimerFont,
                .foregroundColor: disclaimerColor
            ]
            result.append(NSAttributedString(string: "\nNot for clinical or diagnostic use.", attributes: firstLineAttrs))
            result.append(NSAttributedString(string: "\nNo warranty expressed or implied.", attributes: secondLineAttrs))
        }

        return result
    }
}
