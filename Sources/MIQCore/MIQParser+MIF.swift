import Foundation

extension MIQParser {
    /// Stand-in for an absent `transform:` field — image axes are then R/A/S as stored.
    /// Composed with the layout, this reproduces MRtrix's own default for the field.
    fileprivate static let identityMifTransform: [[Float]] = [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0]
    ]

    private struct MifHeader {
        let dim: [Int]
        let vox: [Float]
        let layout: [MIFLayoutComponent]
        let datatype: MIQDatatype
        let littleEndian: Bool
        /// MRtrix `bit`: one voxel per bit on disk, expanded to one `uint8` per voxel at parse time.
        let bitPacked: Bool
        let dataFile: String
        let dataOffset: Int
        let scale: Float
        let offset: Float
        /// The voxel→scanner affine's three rows, when the (optional) `transform:` field
        /// is present and well-formed. `nil` means an identity affine, per the MIF spec.
        let transform: [[Float]]?
        /// Display-only fields (`dw_scheme`, `command_history`), carried through
        /// to `MIQHeader.acquisition`.
        var acquisition = MIQAcquisitionInfo()
    }

    /// - Parameter headerURL: The header's location, passed only for `.mih`. A
    ///   `file: <name> <offset>` other than `.` then names a payload file resolved
    ///   next to the header (see `resolveDetachedDataFile`), read from `<offset>`.
    ///   With `nil` (`.mif`, single-file by definition) an external file is rejected.
    func parseMif(_ data: Data, headerURL: URL? = nil) throws -> MIQImage {
        let (mifHeader, embeddedDataOffset) = try parseMifHeader(from: data)
        guard mifHeader.dataFile == "." else {
            guard let headerURL else {
                throw MIQError.malformedFile("MIF references an external data file; only embedded payloads are supported")
            }
            let url = try resolveDetachedDataFile(mifHeader.dataFile, relativeTo: headerURL)
            let payload = try readDetachedDataFile(url, name: mifHeader.dataFile)
            return try buildMifImage(data: payload, dataOffset: mifHeader.dataOffset, header: mifHeader)
        }
        let dataOffset = mifHeader.dataOffset > 0 ? mifHeader.dataOffset : embeddedDataOffset
        return try buildMifImage(data: data, dataOffset: dataOffset, header: mifHeader)
    }

    /// Header-only parse for `parseHeaderOnly(url:maxBytes:)`: no payload is read or validated, and
    /// an external `file:` reference is not rejected (only the size estimate is
    /// wanted).
    func parseMifHeaderOnly(from data: Data) throws -> MIQHeader {
        let (mifHeader, embeddedDataOffset) = try parseMifHeader(from: data)
        let dataOffset = mifHeader.dataOffset > 0 || mifHeader.dataFile != "."
            ? mifHeader.dataOffset
            : embeddedDataOffset
        return try buildMifMIQHeader(dataOffset: dataOffset, header: mifHeader).header
    }

    // MARK: - Header lines

    private func parseMifHeader(from data: Data) throws -> (MifHeader, Int) {
        let (lines, embeddedDataOffset) = try parseMifHeaderLines(from: data)
        var mifHeader = try parseMifHeaderFields(lines: lines)
        mifHeader.acquisition = parseMifAcquisition(lines: lines)
        return (mifHeader, embeddedDataOffset)
    }

    // MARK: - Acquisition & provenance (dw_scheme, command_history)

    /// Display-only fields from the header's key-value lines:
    /// - `dw_scheme`: one `gx,gy,gz,b` line per volume (MRtrix writes the key
    ///   repeatedly); the 4th column is the b-value. A row with fewer than four
    ///   numbers invalidates the scheme rather than mis-assigning b-values.
    /// - `command_history`: one entry per processing step; the last is kept.
    func parseMifAcquisition(lines: [String]) -> MIQAcquisitionInfo {
        var info = MIQAcquisitionInfo()
        var bValues: [Double] = []
        var schemeValid = true
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let key = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "dw_scheme":
                let numbers = value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { Double($0) }
                if numbers.count >= 4, let b = numbers[3], numbers.allSatisfy({ $0 != nil }) {
                    bValues.append(b)
                } else {
                    schemeValid = false
                }
            case "command_history":
                if !value.isEmpty { info.lastCommand = value }
            default:
                continue
            }
        }
        if schemeValid, !bValues.isEmpty { info.bValues = bValues }
        return info
    }

    private func parseMifHeaderLines(from data: Data) throws -> ([String], Int) {
        // Match END only when preceded by a newline so values like "LEGEND" don't trigger a false hit.
        guard let markerRange = data.range(of: Data("\nEND".utf8)) else {
            throw MIQError.malformedFile("MIF header is missing the END marker")
        }

        var payloadStart = markerRange.upperBound
        if payloadStart < data.endIndex, data[payloadStart] == 0x0D {
            payloadStart += 1
        }
        if payloadStart < data.endIndex, data[payloadStart] == 0x0A {
            payloadStart += 1
        }

        // The leading newline belongs to the previous line; stop the header text there.
        let headerData = data[data.startIndex..<markerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        return (lines, payloadStart)
    }

    private func parseMifHeaderFields(lines: [String]) throws -> MifHeader {
        guard let first = lines.first, first.lowercased() == "mrtrix image" else {
            throw MIQError.malformedFile("MIF header does not start with 'mrtrix image'")
        }

        var keyValues: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<sep].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespacesAndNewlines)
            keyValues[key, default: []].append(String(value))
        }

        guard let dimString = keyValues["dim"]?.last,
              let voxString = keyValues["vox"]?.last,
              let layoutString = keyValues["layout"]?.last,
              let datatypeString = keyValues["datatype"]?.last,
              let fileString = keyValues["file"]?.last else {
            throw MIQError.malformedFile("MIF header is missing one or more required fields (dim, vox, layout, datatype, file)")
        }

        let dim = try parseMifIntList(dimString)
        let vox = try parseMifFloatList(voxString)
        let layout = try parseMifLayoutList(layoutString)
        guard dim.count == vox.count, dim.count == layout.count else {
            throw MIQError.invalidDimensions
        }
        guard dim.count >= 3, dim.count <= 4, dim.allSatisfy({ $0 > 0 }) else {
            throw MIQError.invalidDimensions
        }

        let spec = try parseMifDatatype(datatypeString)
        // `bytesPerVoxel` here is the *unpacked* size (1 for `bit`), which is what
        // bounds the buffer this parser hands downstream.
        try validateDimensionExtent(dim, bytesPerVoxel: spec.datatype.bytesPerVoxel)
        let (dataFile, dataOffset) = try parseMifFileSpec(fileString)

        let transform = keyValues["transform"].flatMap(parseMifTransform)

        let scalingValues = keyValues["scaling"]?.last.flatMap { try? parseMifFloatList($0) }
        // MIF spells the pair `offset,scale` — note the argument order. Normalised
        // like NIfTI's: the field is free text, so `Float("nan")` parses.
        let (scale, offset) = normalizedScaling(
            slope: scalingValues?[safe: 1] ?? 1,
            inter: scalingValues?[safe: 0] ?? 0
        )

        return MifHeader(
            dim: dim,
            vox: vox,
            layout: layout,
            datatype: spec.datatype,
            littleEndian: spec.littleEndian,
            bitPacked: spec.bitPacked,
            dataFile: dataFile,
            dataOffset: dataOffset,
            scale: scale,
            offset: offset,
            transform: transform
        )
    }

    // MARK: - Image construction

    private struct MifImageDescriptor {
        let header: MIQHeader
        let strides4: [Int]
    }

    private func buildMifMIQHeader(dataOffset: Int, header: MifHeader) throws -> MifImageDescriptor {
        let axisLayout = try MIFAxisLayout(dim: header.dim, layout: header.layout)
        let rawStrides = axisLayout.rawStrides

        // Sort the 3 spatial axes (0,1,2) by abs(layout) to get storage rank order.
        // This determines which axis varies fastest in memory → shown as logical x.
        // The time axis (index 3, if present) is excluded from permutation.
        let spatialAxes = [0, 1, 2].sorted { header.layout[$0].order < header.layout[$1].order }

        let dim0 = header.dim[spatialAxes[0]]
        let dim1 = header.dim[spatialAxes[1]]
        let dim2 = header.dim[spatialAxes[2]]
        let volumes = header.dim[safe: 3] ?? 1

        let pixX = abs(header.vox[safe: spatialAxes[0]] ?? 1)
        let pixY = abs(header.vox[safe: spatialAxes[1]] ?? 1)
        let pixZ = abs(header.vox[safe: spatialAxes[2]] ?? 1)

        // Render in storage traversal order: axis sign controls labels/orientation,
        // while sampling walks payload in increasing element index order.
        // This preserves "as stored" appearance for mirrored layouts (e.g. RAS vs LAS).
        let defaultVolStride = dim0 * dim1 * dim2
        let tStride = abs(rawStrides[safe: 3] ?? defaultVolStride)
        let strides4 = [
            abs(rawStrides[spatialAxes[0]]),
            abs(rawStrides[spatialAxes[1]]),
            abs(rawStrides[spatialAxes[2]]),
            tStride
        ]

        // MIF is the one format that states anatomy and disk layout separately. The
        // transform's columns give each *image* axis its anatomical direction; `layout`
        // then says in what order and direction those axes are stored. The field is
        // optional — absent means an identity affine, i.e. image axes already R/A/S.
        let transform = header.transform ?? MIQParser.identityMifTransform
        let imageFrame = OrientationFrame.from(
            srowX: transform[0],
            srowY: transform[1],
            srowZ: transform[2],
            source: .mifLayout
        )
        // A degenerate transform leaves both frames nil rather than fabricating a label
        // from axis indices: the resolver then shows "?" instead of a wrong anatomical claim.
        let storageFrame = imageFrame.map {
            MIFAxisLayout.storageFrame(imageFrame: $0, spatialAxes: spatialAxes, layout: header.layout)
        }
        // Obliquity reads the transform itself (layout only permutes/flips axes, which
        // leaves it unchanged). An absent field is still labelled RAS, as MRtrix does,
        // but reported as `.mifDefault` so the panel does not imply the file said so.
        let orientationDiagnostics = OrientationDiagnostics.make(
            frame: storageFrame,
            source: header.transform == nil ? .mifDefault : .mifTransform,
            rows: transform
        )

        let worldRows = storageFrame == nil ? nil : Self.mifVoxelToWorldRows(
            transform: transform, header: header, spatialAxes: spatialAxes
        )

        var miqHeader = MIQHeader(
            littleEndian: header.littleEndian,
            dimensions: [dim0, dim1, dim2, volumes],
            pixdim: [1.0, pixX, pixY, pixZ],
            datatype: header.datatype,
            voxOffset: dataOffset,
            sclSlope: header.scale,
            sclInter: header.offset,
            qformCode: 0,
            sformCode: 0,
            srowX: worldRows?[0] ?? [],
            srowY: worldRows?[1] ?? [],
            srowZ: worldRows?[2] ?? [],
            datatypeLabel: header.bitPacked ? "bit" : nil,
            orientationFrame: storageFrame,
            orientationDiagnostics: orientationDiagnostics
        )

        miqHeader.acquisition = header.acquisition

        return MifImageDescriptor(
            header: miqHeader,
            strides4: strides4
        )
    }

    /// The voxel→scanner affine (three rows of four, mm) in MIQ's *logical* voxel
    /// order — the storage order `buildMifMIQHeader` renders in — so `srowX/Y/Z`
    /// mean the same as a NIfTI sform: `world = srow · (i, j, k, 1)`.
    ///
    /// MRtrix's `transform:` maps image-axis positions *in mm* to scanner space
    /// (its 3×3 block is a pure rotation; voxel sizes come from `vox:`). Logical
    /// axis `n` is image axis `spatialAxes[n]` walked in increasing element order,
    /// which for a reversed (`-`) layout entry runs from the axis's last image index
    /// down to its first. So column `n` is `R[:, a] · |vox[a]|`, negated when `a` is
    /// reversed, and every reversed axis moves the origin to its far end,
    /// `R[:, a] · |vox[a]| · (dim[a] − 1)`.
    ///
    /// Stored with `sformCode` 0 (MIF has no such code); `MIQVolume.voxelToWorld`
    /// reads these rows for `.mifLayout` frames. Display orientation still comes
    /// from `orientationFrame`, which this composition agrees with by construction.
    private static func mifVoxelToWorldRows(
        transform: [[Float]], header: MifHeader, spatialAxes: [Int]
    ) -> [[Float]]? {
        // `parseMifTransform` accepts rows of three (no translation): origin 0 then.
        guard transform.count >= 3, transform.allSatisfy({ $0.count >= 3 }) else { return nil }
        var rows = transform.prefix(3).map { [0, 0, 0, $0[safe: 3] ?? 0] as [Float] }
        for (column, axis) in spatialAxes.enumerated() {
            let spacing = sanitizedSpacing(header.vox[safe: axis] ?? 1)
            let reversed = header.layout[axis].reversed
            for r in 0..<3 {
                let step = transform[r][axis] * spacing
                rows[r][column] = reversed ? -step : step
                if reversed {
                    rows[r][3] += step * Float(header.dim[axis] - 1)
                }
            }
        }
        guard rows.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return nil }
        return rows
    }

    private func buildMifImage(data: Data, dataOffset: Int, header: MifHeader) throws -> MIQImage {
        let elementCount = header.dim.reduce(1, *)
        let bytesPerVoxel = header.datatype.bytesPerVoxel
        // A `bit` payload occupies ceil(n/8) bytes on disk, not one byte per voxel.
        // Written as division rather than `(elementCount + 7) / 8`: `validateDimensionExtent`
        // permits a dims product of exactly `Int.max`, where the `+ 7` would trap.
        let payloadBytes = header.bitPacked
            ? elementCount / 8 + (elementCount % 8 == 0 ? 0 : 1)
            : elementCount * bytesPerVoxel

        guard elementCount > 0, payloadBytes > 0 else {
            throw MIQError.invalidDimensions
        }
        // `dataOffset` comes from the free-text `file:` field, so it can be any
        // Int64 the file cares to spell out (`file: . 9223372036854775807`).
        // `validateDimensionExtent` bounds `payloadBytes` but not the offset, so
        // the sum needs a checked add — a plain `+` traps and crashes the extension.
        let (payloadEnd, overflow) = dataOffset.addingReportingOverflow(payloadBytes)
        guard dataOffset >= 0, !overflow, data.count >= payloadEnd else {
            throw MIQError.truncatedData
        }

        let descriptor = try buildMifMIQHeader(dataOffset: dataOffset, header: header)

        if header.bitPacked {
            // The unpacked buffer holds the payload alone, in the same element order,
            // so the layout-derived strides carry over unchanged and the offset is 0.
            // `descriptor.header.voxOffset` still reports the offset *in the file*.
            return MIQImage(
                header: descriptor.header,
                storage: unpackMifBits(data, offset: dataOffset, voxelCount: elementCount),
                payloadOffset: 0,
                payloadElementStrides: descriptor.strides4
            )
        }

        return MIQImage(
            header: descriptor.header,
            storage: data,
            payloadOffset: dataOffset,
            payloadElementStrides: descriptor.strides4
        )
    }

    /// Expands an MRtrix `bit` payload to one `uint8` (0 or 1) per voxel.
    ///
    /// Bits run MSB-first within each byte — voxel *i* is bit `0x80 >> (i % 8)` of byte
    /// `i / 8` — matching MRtrix3's `BITMASK (0x01U << 7)` in `core/fetch_store.cpp`.
    ///
    /// Every downstream reader (`prepareSlice`, `voxel()`, the segmentation scans) addresses
    /// voxels as `elementIndex * bytesPerVoxel`, so a sub-byte datatype has no place in that
    /// model. Expanding once here — rather than threading bit addressing through the hot
    /// decode loop for one rare datatype — is the deliberate exception to the payload-offset
    /// convention: this is the only MIF path that copies instead of slicing the mapped file in
    /// place. A mask costs 8× its packed size (a 120×120×78 example: 141 KB → 1.1 MB), which is
    /// immaterial next to the slice render it feeds, and `bit` only ever appears on masks.
    private func unpackMifBits(_ data: Data, offset: Int, voxelCount: Int) -> Data {
        var unpacked = Data(count: voxelCount)
        unpacked.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                var voxel = 0
                var byteIndex = offset
                while voxel + 8 <= voxelCount {
                    let packed = src.loadUnaligned(fromByteOffset: byteIndex, as: UInt8.self)
                    dst[voxel] = (packed >> 7) & 1
                    dst[voxel + 1] = (packed >> 6) & 1
                    dst[voxel + 2] = (packed >> 5) & 1
                    dst[voxel + 3] = (packed >> 4) & 1
                    dst[voxel + 4] = (packed >> 3) & 1
                    dst[voxel + 5] = (packed >> 2) & 1
                    dst[voxel + 6] = (packed >> 1) & 1
                    dst[voxel + 7] = packed & 1
                    voxel += 8
                    byteIndex += 1
                }
                if voxel < voxelCount {
                    let packed = src.loadUnaligned(fromByteOffset: byteIndex, as: UInt8.self)
                    var bit = 7
                    while voxel < voxelCount {
                        dst[voxel] = (packed >> UInt8(bit)) & 1
                        voxel += 1
                        bit -= 1
                    }
                }
            }
        }
        return unpacked
    }

    // MARK: - Field parsers

    private func parseMifDatatype(
        _ value: String
    ) throws -> (datatype: MIQDatatype, littleEndian: Bool, bitPacked: Bool) {
        let lowered = value.lowercased()
        let isLittleEndian = !lowered.hasSuffix("be")

        // MRtrix writes a bare "Bit" — no byte order to speak of — so this is an exact
        // match, not the `hasPrefix` the sized types use to absorb their LE/BE suffix.
        // Presented as `uint8` because the payload is expanded to one byte per voxel
        // (see `unpackMifBits`).
        if lowered == "bit" { return (.uint8, true, true) }
        if lowered.hasPrefix("uint8") { return (.uint8, true, false) }
        if lowered.hasPrefix("int8") { return (.int8, true, false) }
        if lowered.hasPrefix("uint16") { return (.uint16, isLittleEndian, false) }
        if lowered.hasPrefix("int16") { return (.int16, isLittleEndian, false) }
        if lowered.hasPrefix("uint32") { return (.uint32, isLittleEndian, false) }
        if lowered.hasPrefix("int32") { return (.int32, isLittleEndian, false) }
        if lowered.hasPrefix("float32") { return (.float32, isLittleEndian, false) }
        if lowered.hasPrefix("float64") { return (.float64, isLittleEndian, false) }
        if lowered.hasPrefix("uint64") { return (.uint64, isLittleEndian, false) }
        if lowered.hasPrefix("int64") { return (.int64, isLittleEndian, false) }

        throw MIQError.malformedFile("unrecognised MIF datatype '\(value)'")
    }

    private func parseMifFileSpec(_ value: String) throws -> (String, Int) {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard let filePart = parts.first else {
            throw MIQError.malformedFile("MIF 'file' field is empty")
        }

        let file = String(filePart)
        let offset = Int(parts[safe: 1] ?? "0") ?? 0
        return (file, max(0, offset))
    }

    private func parseMifIntList(_ value: String) throws -> [Int] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = items.compactMap(Int.init)
        guard parsed.count == items.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("MIF integer list is empty or contains a non-integer value: '\(value)'")
        }
        return parsed
    }

    private func parseMifLayoutList(_ value: String) throws -> [MIFLayoutComponent] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !items.isEmpty else {
            throw MIQError.malformedFile("MIF layout list is empty")
        }

        var parsed: [MIFLayoutComponent] = []
        parsed.reserveCapacity(items.count)

        for item in items {
            guard !item.isEmpty else {
                throw MIQError.malformedFile("MIF layout list contains an empty entry")
            }

            var reversed = false
            var digits = item
            if let first = item.first {
                if first == "-" {
                    reversed = true
                    digits = String(item.dropFirst())
                } else if first == "+" {
                    digits = String(item.dropFirst())
                }
            }

            guard let order = Int(digits), order >= 0 else {
                throw MIQError.malformedFile("MIF layout entry '\(item)' is not a signed non-negative integer")
            }
            parsed.append(MIFLayoutComponent(order: order, reversed: reversed))
        }

        return parsed
    }

    /// The three rows of the voxel→scanner affine. `transform:` is optional in the MIF
    /// spec, and MRtrix writes one line per row; anything absent, short, or malformed is
    /// treated as absent so the caller falls back to the identity affine.
    private func parseMifTransform(_ values: [String]) -> [[Float]]? {
        guard values.count >= 3 else { return nil }
        var rows: [[Float]] = []
        rows.reserveCapacity(3)
        for value in values.prefix(3) {
            guard let row = try? parseMifFloatList(value), row.count >= 3 else { return nil }
            rows.append(row)
        }
        return rows
    }

    private func parseMifFloatList(_ value: String) throws -> [Float] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = items.compactMap(Float.init)
        guard parsed.count == items.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("MIF float list is empty or contains a non-numeric value: '\(value)'")
        }
        return parsed
    }
}
