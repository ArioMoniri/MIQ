import Foundation
import zlib

/// ITK MetaImage (MetaIO): `.mha` (header + payload in one file,
/// `ElementDataFile = LOCAL`) and `.mhd` (text header naming a separate payload
/// file). The common output of ITK, ITK-SNAP, 3D Slicer and SimpleITK.
///
/// The header is `Key = Value` lines; `ElementDataFile` is always the last one,
/// and for `LOCAL` the payload starts on the byte after its newline. Fields read:
///
/// - `NDims` (2–4), `DimSize`, `ElementSpacing` (falls back to `ElementSize`)
/// - `ElementType`: `MET_CHAR/UCHAR/SHORT/USHORT/INT/UINT/LONG/ULONG/
///   LONG_LONG/ULONG_LONG/FLOAT/DOUBLE` (`MET_LONG` is 4 bytes in MetaIO)
/// - `ElementNumberOfChannels`: 1, or 3/4 with `MET_UCHAR` (shown as RGB/RGBA);
///   anything else is rejected
/// - `ElementByteOrderMSB` / `BinaryDataByteOrderMSB`: big-endian payload
/// - `CompressedData` (zlib stream, optionally bounded by `CompressedDataSize`)
/// - `HeaderSize`: bytes to skip at the start of each detached data file; `-1`
///   means the payload is the file's last bytes (uncompressed only)
/// - `Offset` / `Position` / `Origin` and `TransformMatrix` / `Rotation` /
///   `Orientation`: the voxel→world mapping in ITK's **LPS** world, converted to
///   RAS exactly as NRRD's `space: left-posterior-superior` is. Row *i* of the
///   matrix is image axis *i*'s direction (ITK's `MetaImageIO` convention).
///
/// Orientation is claimed only when a transform matrix is present: without one
/// the labels read "?" (ITK would silently assume identity-LPS, but the file
/// itself says nothing). `AnatomicalOrientation` is deliberately ignored — ITK's
/// own reader ignores it too, and writers disagree on whether its letters name
/// where each axis points *from* or *to*.
///
/// `ElementDataFile` may also be `LIST [subdim]` (names on the following lines)
/// or a printf pattern (`slice%03d.raw 1 40 1`); files resolve next to the header
/// under the rules of `resolveDetachedDataFile`.
extension MIQParser {

    private struct MetaImageHeader {
        let dims: [Int]
        let spacing: [Float]
        let datatype: MIQDatatype
        let littleEndian: Bool
        let compressed: Bool
        let compressedDataSize: Int?
        let headerSize: Int
        let origin: [Float]?
        /// Row-major NDims×NDims direction matrix (row = image axis), if present.
        let transform: [Float]?
        /// `nil` for `LOCAL` (payload follows the header in the same file).
        let dataFiles: DetachedFileList?
        /// Byte offset just past the `ElementDataFile` line.
        let headerLength: Int
    }

    // MARK: - Entry points

    /// - Parameter headerURL: The header's location, needed for a detached
    ///   `ElementDataFile` (always for `.mhd`); with `nil` that is rejected.
    func parseMetaImage(_ data: Data, headerURL: URL? = nil) throws -> MIQImage {
        let meta = try parseMetaImageHeader(data)
        let header = try buildMetaImageMIQHeader(meta)
        let payloadBytes = meta.dims.reduce(meta.datatype.bytesPerVoxel, *)
        guard payloadBytes > 0 else { throw MIQError.invalidDimensions }

        let storage: Data
        let payloadOffset: Int
        if let files = meta.dataFiles {
            guard let headerURL else {
                throw MIQError.unsupportedFeature(
                    "MetaImage detached header needs its data file, which can only be resolved next to the header file"
                )
            }
            (storage, payloadOffset) = try loadMetaImageDetachedPayload(meta, files: files, headerURL: headerURL)
        } else if meta.compressed {
            var end = data.endIndex
            if let size = meta.compressedDataSize, size > 0, size <= data.count - meta.headerLength {
                end = data.startIndex + meta.headerLength + size
            }
            let compressed = data[(data.startIndex + meta.headerLength)..<end]
            storage = try inflateMetaImage(Data(compressed), expectedBytes: payloadBytes)
            payloadOffset = 0
        } else {
            storage = data
            payloadOffset = meta.headerLength
        }
        guard storage.count - payloadOffset >= payloadBytes else { throw MIQError.truncatedData }

        return MIQImage(header: header, storage: storage, payloadOffset: payloadOffset, payloadElementStrides: nil)
    }

    /// Header-only parse for `probeHeader` / `VolumeSummary`: neither the payload
    /// nor a detached data file is read.
    func parseMetaImageHeaderOnly(from data: Data) throws -> MIQHeader {
        try buildMetaImageMIQHeader(parseMetaImageHeader(data))
    }

    // MARK: - Header

    private func parseMetaImageHeader(_ data: Data) throws -> MetaImageHeader {
        var fields: [String: String] = [:]
        var cursor = data.startIndex
        var dataFileValue: String?
        let limit = Swift.min(data.endIndex, data.startIndex + Self.maxTextHeaderBytes)

        while cursor < limit {
            let lineEnd = data[cursor..<limit].firstIndex(of: 0x0A) ?? limit
            let next = lineEnd < data.endIndex ? lineEnd + 1 : lineEnd
            let line = String(decoding: data[cursor..<lineEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = next
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else {
                throw MIQError.malformedFile("MetaImage header line is not 'Key = Value'")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "elementdatafile" {
                dataFileValue = value
                break
            }
            fields[key] = value
        }
        guard let dataFileValue else {
            throw MIQError.malformedFile("MetaImage header has no ElementDataFile line")
        }
        let headerLength = data.distance(from: data.startIndex, to: cursor)

        if let objectType = fields["objecttype"], objectType.lowercased() != "image" {
            throw MIQError.unsupportedFeature("MetaImage ObjectType '\(objectType)' is not an image")
        }
        guard let ndimsText = fields["ndims"], let ndims = Int(ndimsText) else {
            throw MIQError.malformedFile("MetaImage header is missing NDims")
        }
        guard (2...4).contains(ndims) else {
            throw MIQError.unsupportedFeature("MetaImage with \(ndims) dimensions is not supported (expected 2–4)")
        }
        guard let dims = fields["dimsize"].flatMap(Self.metaInts), dims.count >= ndims,
              dims.prefix(ndims).allSatisfy({ $0 > 0 }) else {
            throw MIQError.invalidDimensions
        }
        let usedDims = Array(dims.prefix(ndims))

        guard let typeText = fields["elementtype"] else {
            throw MIQError.malformedFile("MetaImage header is missing ElementType")
        }
        let channels = try fields["elementnumberofchannels"].map {
            guard let n = Int($0), n >= 1 else {
                throw MIQError.malformedFile("MetaImage ElementNumberOfChannels is not a positive integer")
            }
            return n
        } ?? 1
        let datatype = try metaImageDatatype(typeText, channels: channels)
        try validateDimensionExtent(usedDims, bytesPerVoxel: datatype.bytesPerVoxel)

        let spacing = (fields["elementspacing"] ?? fields["elementsize"]).flatMap(Self.metaFloats) ?? []
        let msb = (fields["elementbyteordermsb"] ?? fields["binarydatabyteordermsb"]).map(Self.metaBool) ?? false
        let compressed = fields["compresseddata"].map(Self.metaBool) ?? false
        let compressedDataSize = fields["compresseddatasize"].flatMap { Int($0) }
        let headerSize = fields["headersize"].flatMap { Int($0) } ?? 0
        guard headerSize >= -1 else { throw MIQError.malformedFile("MetaImage HeaderSize is negative") }
        if headerSize == -1, compressed {
            throw MIQError.malformedFile("MetaImage 'HeaderSize = -1' is only valid for uncompressed data")
        }

        let origin = (fields["offset"] ?? fields["position"] ?? fields["origin"]).flatMap(Self.metaFloats)
        let transform = (fields["transformmatrix"] ?? fields["rotation"] ?? fields["orientation"])
            .flatMap(Self.metaFloats)
            .flatMap { $0.count >= ndims * ndims ? Array($0.prefix(ndims * ndims)) : nil }

        let dataFiles: DetachedFileList?
        let tokens = dataFileValue.split(whereSeparator: { $0.isWhitespace })
        if dataFileValue.lowercased() == "local" {
            dataFiles = nil
        } else if tokens.first == "LIST" {
            // Remaining lines are the file names.
            let rest = String(decoding: data[(data.startIndex + headerLength)...], as: UTF8.self)
            let names = rest.split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !names.isEmpty else {
                throw MIQError.malformedFile("MetaImage 'ElementDataFile = LIST' is not followed by any file names")
            }
            guard names.count <= Self.maxDetachedDataFiles else {
                throw MIQError.unsupportedFeature("MetaImage data file list names more than \(Self.maxDetachedDataFiles) files")
            }
            // MetaIO spells the slab dimension "2D"/"3D"; plain digits are accepted too.
            let subdim = tokens.count > 1 ? Int(tokens[1].uppercased().replacingOccurrences(of: "D", with: "")) : nil
            dataFiles = DetachedFileList(names: names, subdim: subdim)
        } else if let pattern = try parseDetachedFilePattern(dataFileValue) {
            dataFiles = pattern
        } else {
            guard !dataFileValue.isEmpty else {
                throw MIQError.malformedFile("MetaImage ElementDataFile is empty")
            }
            dataFiles = DetachedFileList(names: [dataFileValue], subdim: nil)
        }

        return MetaImageHeader(
            dims: usedDims,
            spacing: spacing,
            datatype: datatype,
            littleEndian: !msb,
            compressed: compressed,
            compressedDataSize: compressedDataSize,
            headerSize: headerSize,
            origin: origin,
            transform: transform,
            dataFiles: dataFiles,
            headerLength: headerLength
        )
    }

    private func metaImageDatatype(_ value: String, channels: Int) throws -> MIQDatatype {
        let scalar: MIQDatatype
        switch value.trimmingCharacters(in: .whitespaces).uppercased() {
        case "MET_CHAR": scalar = .int8
        case "MET_UCHAR": scalar = .uint8
        case "MET_SHORT": scalar = .int16
        case "MET_USHORT": scalar = .uint16
        case "MET_INT", "MET_LONG": scalar = .int32
        case "MET_UINT", "MET_ULONG": scalar = .uint32
        case "MET_LONG_LONG": scalar = .int64
        case "MET_ULONG_LONG": scalar = .uint64
        case "MET_FLOAT": scalar = .float32
        case "MET_DOUBLE": scalar = .float64
        default:
            throw MIQError.unsupportedFeature("MetaImage ElementType '\(value)' is not supported")
        }
        switch (channels, scalar) {
        case (1, _): return scalar
        case (3, .uint8): return .rgb24
        case (4, .uint8): return .rgba32
        default:
            throw MIQError.unsupportedFeature(
                "MetaImage with \(channels) channels per voxel is not supported (only scalar, or 3/4-channel MET_UCHAR colour)"
            )
        }
    }

    // MARK: - Geometry

    private func buildMetaImageMIQHeader(_ meta: MetaImageHeader) throws -> MIQHeader {
        let n = meta.dims.count
        let sx = meta.dims[0]
        let sy = meta.dims[1]
        let sz = n >= 3 ? meta.dims[2] : 1
        let volumes = n == 4 ? meta.dims[3] : 1
        let spacing: [Float] = (0..<3).map { i in i < n ? (meta.spacing[safe: i] ?? 1) : 1 }
        let pix = spacing.map { abs($0) }

        var srowX: [Float] = [pix[0], 0, 0, 0]
        var srowY: [Float] = [0, pix[1], 0, 0]
        var srowZ: [Float] = [0, 0, pix[2], 0]
        var frame: OrientationFrame?

        if let m = meta.transform {
            // Image axis i's LPS direction is row i; a 2D image's third axis is +S.
            func direction(_ i: Int) -> [Float] {
                guard i < n else { return [0, 0, 1] }
                return (0..<3).map { j in j < n ? m[i * n + j] : 0 }
            }
            let dirs = (0..<3).map(direction)
            let o: [Float] = (0..<3).map { j in j < n ? (meta.origin?[safe: j] ?? 0) : 0 }
            // LPS → RAS: negate the x (L→R) and y (P→A) world components.
            let rx = [-dirs[0][0] * spacing[0], -dirs[1][0] * spacing[1], -dirs[2][0] * spacing[2], -o[0]]
            let ry = [-dirs[0][1] * spacing[0], -dirs[1][1] * spacing[1], -dirs[2][1] * spacing[2], -o[1]]
            let rz = [dirs[0][2] * spacing[0], dirs[1][2] * spacing[1], dirs[2][2] * spacing[2], o[2]]
            if let f = OrientationFrame.from(srowX: rx, srowY: ry, srowZ: rz, source: .metaImageTransform) {
                frame = f
                (srowX, srowY, srowZ) = (rx, ry, rz)
            }
        }

        let detached = meta.dataFiles != nil
        let label: String
        switch (meta.compressed, detached) {
        case (false, false): label = "MetaImage"
        case (true, false): label = "Compressed MetaImage"
        case (false, true): label = "MetaImage (detached)"
        case (true, true): label = "Compressed MetaImage (detached)"
        }

        return MIQHeader(
            littleEndian: meta.littleEndian,
            dimensions: [sx, sy, sz, volumes],
            pixdim: [1.0, pix[0], pix[1], pix[2]],
            datatype: meta.datatype,
            voxOffset: detached ? max(0, meta.headerSize) : meta.headerLength,
            sclSlope: 1.0,
            sclInter: 0.0,
            qformCode: 0,
            sformCode: frame != nil ? 1 : 0,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            formatLabel: label,
            orientationFrame: frame
        )
    }

    // MARK: - Payload

    private func loadMetaImageDetachedPayload(
        _ meta: MetaImageHeader,
        files: DetachedFileList,
        headerURL: URL
    ) throws -> (Data, Int) {
        let bytesPerFile = try detachedBytesPerFile(
            sizes: meta.dims,
            subdim: files.subdim,
            fileCount: files.names.count,
            bytesPerElement: meta.datatype.bytesPerVoxel
        )
        var combined = Data()
        if files.names.count > 1 {
            let (total, overflow) = bytesPerFile.multipliedReportingOverflow(by: files.names.count)
            try requireAssemblablePayload(overflow ? nil : total)
            combined.reserveCapacity(total)
        }

        for name in files.names {
            try Task.checkCancellation()
            let url = try resolveDetachedDataFile(name, relativeTo: headerURL)
            let raw = try readDetachedDataFile(url, name: name)
            let buffer: Data
            var offset: Int
            if meta.compressed {
                let skip = Swift.min(meta.headerSize, raw.count)
                var end = raw.endIndex
                if files.names.count == 1, let size = meta.compressedDataSize, size > 0, size <= raw.count - skip {
                    end = raw.startIndex + skip + size
                }
                buffer = try inflateMetaImage(Data(raw[(raw.startIndex + skip)..<end]), expectedBytes: bytesPerFile)
                offset = 0
            } else {
                buffer = raw
                offset = meta.headerSize == -1 ? raw.count - bytesPerFile : meta.headerSize
            }
            guard offset >= 0, offset <= buffer.count, buffer.count - offset >= bytesPerFile else {
                throw MIQError.truncatedData
            }
            if files.names.count == 1 { return (buffer, offset) }
            let start = buffer.startIndex + offset
            combined.append(buffer[start..<(start + bytesPerFile)])
        }
        return (combined, 0)
    }

    /// Inflates a MetaImage `CompressedData` stream (zlib; a gzip wrapper is
    /// accepted too) into exactly `expectedBytes`. Output beyond that is never
    /// produced, so a lying stream can't grow the buffer; a short stream is
    /// `truncatedData`. Polls cancellation between 16 MiB output windows.
    /// `expectedBytes` is header-declared, so it is capped at
    /// `maxAssembledPayloadBytes` before the output buffer is allocated.
    func inflateMetaImage(_ compressed: Data, expectedBytes: Int) throws -> Data {
        guard expectedBytes > 0, !compressed.isEmpty else { throw MIQError.decompressionFailed }
        try requireAssemblablePayload(expectedBytes)
        var stream = z_stream()
        // +32: auto-detect zlib or gzip header.
        guard inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        let outputWindow = 16 << 20
        var output = Data(count: expectedBytes)
        var produced = 0
        var failed = false

        try compressed.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) in
            guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress else { failed = true; return }
            var fed = 0
            try output.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) in
                guard let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else { failed = true; return }
                while produced < expectedBytes {
                    try Task.checkCancellation()
                    if stream.avail_in == 0, fed < inBuf.count {
                        let chunk = Swift.min(inBuf.count - fed, Int(UInt32.max))
                        stream.next_in = UnsafeMutablePointer(mutating: inBase + fed)
                        stream.avail_in = UInt32(chunk)
                        fed += chunk
                    }
                    let window = Swift.min(outputWindow, expectedBytes - produced)
                    stream.next_out = outBase + produced
                    stream.avail_out = UInt32(window)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    produced += window - Int(stream.avail_out)
                    if status == Z_STREAM_END { break }
                    if status == Z_BUF_ERROR, stream.avail_in == 0, fed >= inBuf.count { break }
                    guard status == Z_OK || status == Z_BUF_ERROR else { failed = true; return }
                }
            }
        }
        if failed { throw MIQError.decompressionFailed }
        guard produced == expectedBytes else { throw MIQError.truncatedData }
        return output
    }

    // MARK: - Value parsers

    private static func metaInts(_ value: String) -> [Int]? {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        let parsed = parts.compactMap { Int($0) }
        return parsed.count == parts.count && !parsed.isEmpty ? parsed : nil
    }

    private static func metaFloats(_ value: String) -> [Float]? {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        let parsed = parts.compactMap { Float($0) }
        return parsed.count == parts.count && !parsed.isEmpty ? parsed : nil
    }

    private static func metaBool(_ value: String) -> Bool {
        ["true", "1", "yes"].contains(value.lowercased())
    }
}
