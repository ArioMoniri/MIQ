import Foundation

/// The allowlisted values found in one dataset (the top level, or one sequence item).
/// Holds only byte *ranges* into the file; nothing outside `DICOMAllowlist` is recorded.
struct DICOMDataset: Sendable {
    /// 0-based byte range (relative to `Data.startIndex`) of each allowlisted value.
    var values: [DICOMTag: Range<Int>] = [:]
    /// Items of each allowlisted sequence (`DICOMAllowlist.sequences`).
    var sequences: [DICOMTag: [DICOMDataset]] = [:]

    /// First item of `sequence`, if present.
    func item(_ sequence: DICOMTag) -> DICOMDataset? {
        sequences[sequence]?.first
    }
}

/// A Part-10 file read up to (not including) its Pixel Data value.
struct DICOMParsedFile: Sendable {
    let data: Data
    let transferSyntax: DICOMTransferSyntax
    let dataset: DICOMDataset
    /// 0-based byte range of the native Pixel Data value, clipped to the file
    /// length (a truncated file yields a short range; callers size-check it). `nil`
    /// when the file has no (7FE0,0010) element.
    let pixelData: Range<Int>?
}

/// Bounded, non-trapping reader for DICOM Part-10 data sets.
///
/// Parses group 0002 as explicit VR little endian, then the main data set in the
/// transfer syntax it names (implicit or explicit VR little endian). Every length is
/// checked against its enclosing extent before use, sequence nesting is capped, and
/// the number of elements visited is budgeted, so truncated or crafted input throws
/// `MIQError` rather than trapping or looping. Reading stops at the top-level Pixel
/// Data element, whose bytes are only located, never touched — on a memory-mapped
/// file the payload's pages stay unread until a slice is rendered.
struct DICOMReader {
    /// Offset of the `DICM` marker in a Part-10 file (after the 128-byte preamble).
    static let preambleLength = 128
    static let undefinedLength: UInt32 = 0xFFFF_FFFF
    /// Sequence nesting cap. Real files nest functional groups 2–3 deep; anything
    /// beyond this is either a crafted file or irrelevant to a preview.
    static let maxDepth = 12
    /// Total elements + items visited per file before the reader gives up.
    static let maxElements = 2_000_000

    private let data: Data
    private let base: Int
    private let count: Int
    private var remainingElements = DICOMReader.maxElements

    init(data: Data) {
        self.data = data
        self.base = data.startIndex
        self.count = data.count
    }

    // MARK: - Detection

    /// `true` when `data` has the Part-10 `DICM` marker at offset 128.
    static func hasPart10Marker(_ data: Data) -> Bool {
        let start = data.startIndex + preambleLength
        guard data.count >= preambleLength + 4 else { return false }
        return data[start] == 0x44 && data[start + 1] == 0x49
            && data[start + 2] == 0x43 && data[start + 3] == 0x4D // "DICM"
    }

    /// Conservative check for a preamble-less data set: the very first element must be
    /// in group 0002 or 0008 and carry a valid two-letter explicit VR. Implicit-VR
    /// files without a preamble are too ambiguous to sniff and are not accepted.
    static func looksLikeExplicitDatasetWithoutPreamble(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let b = data.startIndex
        let group = UInt16(data[b]) | UInt16(data[b + 1]) << 8
        guard group == 0x0002 || group == 0x0008 else { return false }
        return knownVRs.contains(vrCode(data[b + 4], data[b + 5]))
    }

    // MARK: - File

    mutating func read() throws -> DICOMParsedFile {
        var offset: Int
        let hasMarker = Self.hasPart10Marker(data)
        if hasMarker {
            offset = Self.preambleLength + 4
        } else if Self.looksLikeExplicitDatasetWithoutPreamble(data) {
            offset = 0
        } else {
            throw MIQError.malformedFile("not a DICOM Part-10 file (no DICM marker)")
        }

        // File meta information: group 0002, always explicit VR little endian.
        var meta = DICOMDataset()
        while offset + 8 <= count, u16(offset) == 0x0002 {
            let header = try readHeader(at: offset, explicit: true, end: count)
            offset = try consume(header, explicit: true, end: count, depth: 0, into: &meta)
        }

        let syntax: DICOMTransferSyntax
        if let range = meta.values[.transferSyntaxUID] {
            syntax = try DICOMTransferSyntax.resolve(uid: asciiValue(range))
        } else if offset + 8 <= count, Self.knownVRs.contains(Self.vrCode(byte(offset + 4), byte(offset + 5))) {
            // No (or no TS in the) meta group: sniff the first data-set element.
            syntax = .explicitVRLittleEndian
        } else if hasMarker {
            syntax = .implicitVRLittleEndian
        } else {
            throw MIQError.malformedFile("DICOM transfer syntax could not be determined")
        }

        var dataset = DICOMDataset()
        dataset.values.merge(meta.values) { current, _ in current }
        var pixelData: Range<Int>?
        let explicit = syntax.isExplicitVR
        while offset < count {
            // Trailing bytes too short to hold an element header are padding.
            guard count - offset >= 8 else { break }
            let header = try readHeader(at: offset, explicit: explicit, end: count)
            if header.tag == .pixelData {
                guard header.length != Self.undefinedLength else {
                    // Encapsulated (fragmented) pixel data: only legal for compressed syntaxes.
                    throw MIQError.unsupportedFeature("Compressed DICOM (encapsulated pixel data) isn't supported yet")
                }
                let end = Swift.min(count, header.valueOffset + Int(header.length))
                pixelData = header.valueOffset..<Swift.max(header.valueOffset, end)
                break
            }
            offset = try consume(header, explicit: explicit, end: count, depth: 0, into: &dataset)
        }

        return DICOMParsedFile(data: data, transferSyntax: syntax, dataset: dataset, pixelData: pixelData)
    }

    // MARK: - Elements

    private struct ElementHeader {
        let tag: DICOMTag
        /// Two-letter VR packed big-endian into 16 bits; 0 when implicit / item tag.
        let vr: UInt16
        let length: UInt32
        let valueOffset: Int
    }

    private mutating func readHeader(at p: Int, explicit: Bool, end: Int) throws -> ElementHeader {
        guard p >= 0, end - p >= 8 else { throw MIQError.truncatedData }
        remainingElements -= 1
        guard remainingElements > 0 else {
            throw MIQError.malformedFile("DICOM data set has too many elements")
        }
        let tag = DICOMTag(u16(p), u16(p + 2))
        // Item and delimiter tags never carry a VR, in either syntax.
        if tag.group == 0xFFFE || !explicit {
            return ElementHeader(tag: tag, vr: 0, length: u32(p + 4), valueOffset: p + 8)
        }
        let vr = Self.vrCode(byte(p + 4), byte(p + 5))
        guard Self.knownVRs.contains(vr) else {
            throw MIQError.malformedFile("invalid DICOM value representation at \(tag)")
        }
        if Self.longVRs.contains(vr) {
            guard end - p >= 12 else { throw MIQError.truncatedData }
            return ElementHeader(tag: tag, vr: vr, length: u32(p + 8), valueOffset: p + 12)
        }
        return ElementHeader(tag: tag, vr: vr, length: UInt32(u16(p + 6)), valueOffset: p + 8)
    }

    /// Consumes one element's value and returns the offset just past it. Records the
    /// value's range only for allowlisted tags; descends only into allowlisted sequences.
    private mutating func consume(
        _ header: ElementHeader,
        explicit: Bool,
        end: Int,
        depth: Int,
        into dataset: inout DICOMDataset
    ) throws -> Int {
        let tag = header.tag
        if tag.group == 0xFFFE {
            throw MIQError.malformedFile("unexpected DICOM item tag outside a sequence")
        }
        let collect = DICOMAllowlist.sequences.contains(tag)

        if header.length == Self.undefinedLength {
            // Undefined length is only legal for a sequence (SQ; or UN, whose content
            // is then implicit VR LE per PS3.5 §6.2.2) — or encapsulated pixel data,
            // which the caller handles at the top level.
            let itemsExplicit: Bool
            if explicit {
                switch header.vr {
                case Self.vrSQ: itemsExplicit = true
                case Self.vrUN: itemsExplicit = false
                default:
                    throw MIQError.malformedFile("undefined length on a non-sequence DICOM element \(tag)")
                }
            } else {
                itemsExplicit = false
            }
            let (items, next) = try readSequence(
                from: header.valueOffset, end: nil, limit: end,
                explicit: itemsExplicit, depth: depth + 1, collect: collect
            )
            if collect { dataset.sequences[tag] = items }
            return next
        }

        let length = Int(header.length)
        guard end - header.valueOffset >= length else { throw MIQError.truncatedData }
        let valueEnd = header.valueOffset + length

        let isSequence = explicit ? header.vr == Self.vrSQ : collect
        if collect, isSequence {
            let (items, _) = try readSequence(
                from: header.valueOffset, end: valueEnd, limit: valueEnd,
                explicit: explicit, depth: depth + 1, collect: true
            )
            dataset.sequences[tag] = items
        } else if DICOMAllowlist.values[tag] != nil, length <= DICOMAllowlist.maxValueLength {
            dataset.values[tag] = header.valueOffset..<valueEnd
        }
        return valueEnd
    }

    /// Reads a sequence's items. `end == nil` means undefined length (terminated by a
    /// Sequence Delimitation Item); `limit` bounds the search either way.
    private mutating func readSequence(
        from start: Int,
        end: Int?,
        limit: Int,
        explicit: Bool,
        depth: Int,
        collect: Bool
    ) throws -> ([DICOMDataset], Int) {
        guard depth <= Self.maxDepth else {
            throw MIQError.malformedFile("DICOM sequences are nested too deeply")
        }
        var items: [DICOMDataset] = []
        var p = start
        while true {
            if let end, p >= end { return (items, p) }
            guard limit - p >= 8 else { throw MIQError.truncatedData }
            remainingElements -= 1
            guard remainingElements > 0 else {
                throw MIQError.malformedFile("DICOM data set has too many elements")
            }
            let tag = DICOMTag(u16(p), u16(p + 2))
            let length = u32(p + 4)
            switch tag {
            case .sequenceDelimitation:
                return (items, p + 8)
            case .item:
                let itemStart = p + 8
                if length == Self.undefinedLength {
                    let (item, next) = try readDataset(
                        from: itemStart, end: limit, delimited: true,
                        explicit: explicit, depth: depth, collect: collect
                    )
                    if collect { items.append(item) }
                    p = next
                } else {
                    guard limit - itemStart >= Int(length) else { throw MIQError.truncatedData }
                    let itemEnd = itemStart + Int(length)
                    if collect {
                        let (item, _) = try readDataset(
                            from: itemStart, end: itemEnd, delimited: false,
                            explicit: explicit, depth: depth, collect: true
                        )
                        items.append(item)
                    }
                    // A defined-length item we don't need is skipped without parsing.
                    p = itemEnd
                }
            default:
                throw MIQError.malformedFile("unexpected element \(tag) inside a DICOM sequence")
            }
        }
    }

    /// Reads one item's data set. `delimited` items end at an Item Delimitation Item.
    private mutating func readDataset(
        from start: Int,
        end: Int,
        delimited: Bool,
        explicit: Bool,
        depth: Int,
        collect: Bool
    ) throws -> (DICOMDataset, Int) {
        var dataset = DICOMDataset()
        var p = start
        while p < end {
            guard end - p >= 8 else { throw MIQError.truncatedData }
            let tag = DICOMTag(u16(p), u16(p + 2))
            if tag == .itemDelimitation {
                remainingElements -= 1
                return (dataset, p + 8)
            }
            let header = try readHeader(at: p, explicit: explicit, end: end)
            if collect {
                p = try consume(header, explicit: explicit, end: end, depth: depth, into: &dataset)
            } else {
                var discard = DICOMDataset()
                p = try consume(header, explicit: explicit, end: end, depth: depth, into: &discard)
            }
        }
        if delimited { throw MIQError.truncatedData }
        return (dataset, p)
    }

    // MARK: - Bytes

    private func byte(_ offset: Int) -> UInt8 { data[base + offset] }

    private func u16(_ offset: Int) -> UInt16 {
        UInt16(data[base + offset]) | UInt16(data[base + offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        UInt32(data[base + offset])
            | UInt32(data[base + offset + 1]) << 8
            | UInt32(data[base + offset + 2]) << 16
            | UInt32(data[base + offset + 3]) << 24
    }

    private func asciiValue(_ range: Range<Int>) -> String {
        DICOMValues.ascii(data, range)
    }

    // MARK: - VRs

    static func vrCode(_ a: UInt8, _ b: UInt8) -> UInt16 { UInt16(a) << 8 | UInt16(b) }
    private static func vr(_ s: StaticString) -> UInt16 {
        s.withUTF8Buffer { vrCode($0[0], $0[1]) }
    }

    static let vrSQ = vr("SQ")
    static let vrUN = vr("UN")

    static let knownVRs: Set<UInt16> = Set([
        "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FL", "FD", "IS", "LO", "LT", "OB", "OD",
        "OF", "OL", "OV", "OW", "PN", "SH", "SL", "SQ", "SS", "ST", "SV", "TM", "UC", "UI",
        "UL", "UN", "UR", "US", "UT", "UV",
    ].map { (s: String) -> UInt16 in
        let u = Array(s.utf8)
        return vrCode(u[0], u[1])
    })

    /// VRs with a 2-byte reserved field and 32-bit length in explicit VR (PS3.5 §7.1.2).
    static let longVRs: Set<UInt16> = Set([
        "OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV",
    ].map { (s: String) -> UInt16 in
        let u = Array(s.utf8)
        return vrCode(u[0], u[1])
    })
}

/// Decoders for allowlisted values. Each refuses a tag that isn't in `DICOMAllowlist`,
/// so no code path can turn a non-allowlisted element into a value.
enum DICOMValues {
    static func ascii(_ data: Data, _ range: Range<Int>) -> String {
        let b = data.startIndex
        let bytes = data[(b + range.lowerBound)..<(b + range.upperBound)]
        let printable = bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }
        return String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func string(_ tag: DICOMTag, in dataset: DICOMDataset?, data: Data) -> String? {
        guard DICOMAllowlist.values[tag] != nil, let range = dataset?.values[tag] else { return nil }
        let value = ascii(data, range)
        return value.isEmpty ? nil : value
    }

    static func uint16(_ tag: DICOMTag, in dataset: DICOMDataset?, data: Data) -> Int? {
        guard DICOMAllowlist.values[tag] == .unsignedShort,
              let range = dataset?.values[tag], range.count >= 2 else { return nil }
        let b = data.startIndex + range.lowerBound
        return Int(UInt16(data[b]) | UInt16(data[b + 1]) << 8)
    }

    static func decimals(_ tag: DICOMTag, in dataset: DICOMDataset?, data: Data) -> [Double]? {
        guard DICOMAllowlist.values[tag] == .decimalString || DICOMAllowlist.values[tag] == .integerString,
              let text = string(tag, in: dataset, data: data) else { return nil }
        let parts = text.split(separator: "\\", omittingEmptySubsequences: false)
        var values: [Double] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                return nil
            }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    static func decimal(_ tag: DICOMTag, in dataset: DICOMDataset?, data: Data) -> Double? {
        decimals(tag, in: dataset, data: data)?.first
    }

    static func integer(_ tag: DICOMTag, in dataset: DICOMDataset?, data: Data) -> Int? {
        guard let value = decimal(tag, in: dataset, data: data),
              value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
        return Int(value)
    }
}
