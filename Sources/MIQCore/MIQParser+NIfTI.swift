import Foundation

extension MIQParser {
    /// - Parameter compressed: Whether the file was gzipped. Only the NIfTI-2 format
    ///   label depends on it: `MIQFileKind.displayName` says "NIfTI-1", and the header
    ///   version is only known here while the compression is only known to the caller.
    func parseNifti(_ data: Data, compressed: Bool = false) throws -> MIQImage {
        let header = try parseNiftiHeader(from: data, compressed: compressed)
        guard data.count >= header.voxOffset else {
            throw MIQError.truncatedData
        }
        // Volume 0 must actually be present: the offset check above only proves the
        // payload *starts* inside the buffer. Subtraction (not `voxOffset + volumeBytes`)
        // so a header whose dims product lands near `Int.max` cannot trap; the offset is
        // non-negative and `<= count` by the guard above. `validateDimensionExtent` already
        // bounded the full dims product, of which `volumeBytes` is a factor.
        let volumeBytes = header.width * header.height * header.depth * header.datatype.bytesPerVoxel
        guard data.count - header.voxOffset >= volumeBytes else {
            throw MIQError.truncatedData
        }
        return MIQImage(header: header, storage: data, payloadOffset: header.voxOffset)
    }

    func parseNiftiHeader(from data: Data, compressed: Bool = false) throws -> MIQHeader {
        guard data.count >= 4 else { throw MIQError.truncatedData }

        let headerSizeLE = MIQBinaryReader.int32(data, 0, littleEndian: true)
        let headerSizeBE = MIQBinaryReader.int32(data, 0, littleEndian: false)

        var header: MIQHeader
        if headerSizeLE == 348 || headerSizeBE == 348 {
            header = try parseNifti1Header(from: data, littleEndian: headerSizeLE == 348)
            header.acquisition = niftiAcquisition(from: data, layout: .nifti1, header: header)
        } else if headerSizeLE == 540 || headerSizeBE == 540 {
            header = try parseNifti2Header(from: data, littleEndian: headerSizeLE == 540, compressed: compressed)
            header.acquisition = niftiAcquisition(from: data, layout: .nifti2, header: header)
        } else {
            throw MIQError.invalidHeaderSize(headerSizeLE)
        }
        try validateDimensionExtent(header.dimensions, bytesPerVoxel: header.datatype.bytesPerVoxel)
        return header
    }

    // MARK: - NIfTI-1 (348-byte header)

    private func parseNifti1Header(from data: Data, littleEndian: Bool) throws -> MIQHeader {
        guard data.count >= 348 else { throw MIQError.truncatedData }

        let dim = MIQBinaryReader.int16Array(data, 40, count: 8, littleEndian: littleEndian)
        let dimensions = try parseDimensions(dim.map { Int($0) })

        let datatype = try readAndValidateDatatype(data: data, at: 70, bitpixAt: 72, littleEndian: littleEndian)

        let pixdim = MIQBinaryReader.float32Array(data, 76, count: 8, littleEndian: littleEndian)
        let voxOffset = MIQBinaryReader.safeInt(MIQBinaryReader.float32(data, 108, littleEndian: littleEndian))
        let (sclSlope, sclInter) = normalizedScaling(
            slope: MIQBinaryReader.float32(data, 112, littleEndian: littleEndian),
            inter: MIQBinaryReader.float32(data, 116, littleEndian: littleEndian)
        )
        let qformCode = Int(MIQBinaryReader.int16(data, 252, littleEndian: littleEndian))
        let sformCode = Int(MIQBinaryReader.int16(data, 254, littleEndian: littleEndian))
        let quaternB = MIQBinaryReader.float32(data, 256, littleEndian: littleEndian)
        let quaternC = MIQBinaryReader.float32(data, 260, littleEndian: littleEndian)
        let quaternD = MIQBinaryReader.float32(data, 264, littleEndian: littleEndian)
        let srowX = MIQBinaryReader.float32Array(data, 280, count: 4, littleEndian: littleEndian)
        let srowY = MIQBinaryReader.float32Array(data, 296, count: 4, littleEndian: littleEndian)
        let srowZ = MIQBinaryReader.float32Array(data, 312, count: 4, littleEndian: littleEndian)

        let orientationFrame = niftiOrientationFrame(
            sform: SformFields(code: sformCode, rowX: srowX, rowY: srowY, rowZ: srowZ),
            qform: QformFields(code: qformCode, quaternB: quaternB, quaternC: quaternC, quaternD: quaternD, qfac: pixdim[safe: 0] ?? 1)
        )

        return MIQHeader(
            littleEndian: littleEndian,
            dimensions: dimensions,
            pixdim: Array(pixdim.prefix(4)),
            datatype: datatype,
            voxOffset: max(352, voxOffset),
            sclSlope: sclSlope,
            sclInter: sclInter,
            qformCode: qformCode,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            orientationFrame: orientationFrame
        )
    }

    // MARK: - NIfTI-2 (540-byte header)
    // Field types are widened relative to NIfTI-1: dim→int64, pixdim→float64,
    // vox_offset→int64, scl_slope/inter→float64, srow→float64, form_codes→int32.

    private func parseNifti2Header(from data: Data, littleEndian: Bool, compressed: Bool) throws -> MIQHeader {
        guard data.count >= 540 else { throw MIQError.truncatedData }

        let dim = MIQBinaryReader.int64Array(data, 16, count: 8, littleEndian: littleEndian)
        let dimensions = try parseDimensions(dim.map { Int($0) })

        let datatype = try readAndValidateDatatype(data: data, at: 12, bitpixAt: 14, littleEndian: littleEndian)

        let pixdim = MIQBinaryReader.float64Array(data, 104, count: 4, littleEndian: littleEndian).map { Float($0) }
        let voxOffset = Int(MIQBinaryReader.int64(data, 168, littleEndian: littleEndian))
        let (sclSlope, sclInter) = normalizedScaling(
            slope: Float(MIQBinaryReader.float64(data, 176, littleEndian: littleEndian)),
            inter: Float(MIQBinaryReader.float64(data, 184, littleEndian: littleEndian))
        )
        let qformCode = Int(MIQBinaryReader.int32(data, 344, littleEndian: littleEndian))
        let sformCode = Int(MIQBinaryReader.int32(data, 348, littleEndian: littleEndian))
        let quaternB = Float(MIQBinaryReader.float64(data, 352, littleEndian: littleEndian))
        let quaternC = Float(MIQBinaryReader.float64(data, 360, littleEndian: littleEndian))
        let quaternD = Float(MIQBinaryReader.float64(data, 368, littleEndian: littleEndian))
        let srowX = MIQBinaryReader.float64Array(data, 400, count: 4, littleEndian: littleEndian).map { Float($0) }
        let srowY = MIQBinaryReader.float64Array(data, 432, count: 4, littleEndian: littleEndian).map { Float($0) }
        let srowZ = MIQBinaryReader.float64Array(data, 464, count: 4, littleEndian: littleEndian).map { Float($0) }

        let orientationFrame = niftiOrientationFrame(
            sform: SformFields(code: sformCode, rowX: srowX, rowY: srowY, rowZ: srowZ),
            qform: QformFields(code: qformCode, quaternB: quaternB, quaternC: quaternC, quaternD: quaternD, qfac: pixdim[safe: 0] ?? 1)
        )

        return MIQHeader(
            littleEndian: littleEndian,
            dimensions: dimensions,
            pixdim: Array(pixdim),
            datatype: datatype,
            voxOffset: max(544, voxOffset),
            sclSlope: sclSlope,
            sclInter: sclInter,
            qformCode: qformCode,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            formatLabel: compressed ? "Compressed NIfTI-2" : "NIfTI-2",
            orientationFrame: orientationFrame
        )
    }

    // MARK: - Shared helpers

    private struct SformFields {
        let code: Int
        let rowX: [Float]
        let rowY: [Float]
        let rowZ: [Float]
    }

    private struct QformFields {
        let code: Int
        let quaternB: Float
        let quaternC: Float
        let quaternD: Float
        let qfac: Float
    }

    /// Resolves the anatomical orientation frame per NIfTI-1 spec rules: prefer
    /// sform when present and non-degenerate; otherwise fall back to qform; otherwise
    /// `nil`. Sform wins when both are valid because the spec treats sform as the
    /// "newer" / preferred transform.
    private func niftiOrientationFrame(sform: SformFields, qform: QformFields) -> OrientationFrame? {
        if sform.code > 0,
           let frame = OrientationFrame.from(srowX: sform.rowX, srowY: sform.rowY, srowZ: sform.rowZ, source: .sform) {
            return frame
        }
        if qform.code > 0,
           let frame = OrientationFrame.fromQuaternion(b: qform.quaternB, c: qform.quaternC, d: qform.quaternD, qfac: qform.qfac) {
            return frame
        }
        return nil
    }

    private func readAndValidateDatatype(data: Data, at datatypeOffset: Int, bitpixAt bitpixOffset: Int, littleEndian: Bool) throws -> MIQDatatype {
        let raw = MIQBinaryReader.int16(data, datatypeOffset, littleEndian: littleEndian)
        guard let datatype = MIQDatatype(rawValue: raw) else { throw MIQError.unsupportedDatatype(Int32(raw)) }
        let bitpix = Int(MIQBinaryReader.int16(data, bitpixOffset, littleEndian: littleEndian))
        if bitpix != datatype.bytesPerVoxel * 8 { throw MIQError.unsupportedDatatype(Int32(raw)) }
        return datatype
    }

    private func parseDimensions(_ dim: [Int]) throws -> [Int] {
        let ndim = dim[0]
        guard ndim >= 1 else { throw MIQError.invalidDimensions }
        var dimensions: [Int] = []
        for idx in 1...max(3, min(7, ndim)) {
            dimensions.append(max(1, dim[idx]))
        }
        while dimensions.count < 4 { dimensions.append(1) }
        return dimensions
    }
}

// MARK: - Acquisition & provenance fields
// Display-only header fields, read after (and independently of) the geometry
// parse above so they can never fail a file: every read is bounds-checked
// against the buffer, and anything malformed is simply left out.

extension MIQParser {
    /// Byte offsets of the display-only fields, per header version.
    struct NiftiAcquisitionLayout {
        let intentParamsOffset: Int
        /// Width of the float fields read here (float32 in NIfTI-1, float64 in NIfTI-2).
        let floatWidth: Int
        let intentCodeOffset: Int
        /// Width of `intent_code` (int16 / int32).
        let intentCodeWidth: Int
        let pixdim4Offset: Int
        let xyztUnitsOffset: Int
        /// Width of `xyzt_units` (char / int32).
        let xyztUnitsWidth: Int
        let descripOffset: Int
        let intentNameOffset: Int
        /// Offset of the 4-byte `extension` flag, = the fixed header size.
        let extenderOffset: Int

        static let nifti1 = NiftiAcquisitionLayout(
            intentParamsOffset: 56, floatWidth: 4,
            intentCodeOffset: 68, intentCodeWidth: 2,
            pixdim4Offset: 92,
            xyztUnitsOffset: 123, xyztUnitsWidth: 1,
            descripOffset: 148, intentNameOffset: 328,
            extenderOffset: 348
        )
        static let nifti2 = NiftiAcquisitionLayout(
            intentParamsOffset: 80, floatWidth: 8,
            intentCodeOffset: 504, intentCodeWidth: 4,
            pixdim4Offset: 136,
            xyztUnitsOffset: 500, xyztUnitsWidth: 4,
            descripOffset: 240, intentNameOffset: 508,
            extenderOffset: 540
        )
    }

    /// Upper bound on the number of extensions walked, so a crafted chain of
    /// tiny extensions cannot turn the header parse into a long loop.
    private static let maxNiftiExtensions = 256
    /// Largest extension whose content is scanned for an embedded label table.
    private static let maxLabelExtensionBytes = 8 * 1024 * 1024

    func niftiAcquisition(from data: Data, layout: NiftiAcquisitionLayout, header: MIQHeader) -> MIQAcquisitionInfo {
        var info = MIQAcquisitionInfo()
        let littleEndian = header.littleEndian

        let units: Int
        if layout.xyztUnitsWidth == 1 {
            units = Int(data[data.startIndex + layout.xyztUnitsOffset])
        } else {
            units = Int(MIQBinaryReader.int32(data, layout.xyztUnitsOffset, littleEndian: littleEndian))
        }
        info.spatialUnit = MIQSpatialUnit(rawValue: units & 0x07) ?? .unknown
        info.temporalUnit = MIQTemporalUnit(rawValue: units & 0x38) ?? .unknown

        // pixdim[4] is the time step only along a real time axis; 3D files often
        // leave 0 or 1 there. Spectral units (Hz/ppm/rad/s) and an unknown unit
        // yield no TR rather than a guess.
        let timeStep: Double = layout.floatWidth == 4
            ? Double(MIQBinaryReader.float32(data, layout.pixdim4Offset, littleEndian: littleEndian))
            : MIQBinaryReader.float64(data, layout.pixdim4Offset, littleEndian: littleEndian)
        if (header.dimensions[safe: 3] ?? 1) > 1,
           let unitsPerSecond = info.temporalUnit?.unitsPerSecond,
           timeStep.isFinite, timeStep > 0 {
            info.repetitionTime = timeStep / unitsPerSecond
        }

        info.intentCode = layout.intentCodeWidth == 2
            ? Int(MIQBinaryReader.int16(data, layout.intentCodeOffset, littleEndian: littleEndian))
            : Int(MIQBinaryReader.int32(data, layout.intentCodeOffset, littleEndian: littleEndian))
        info.intentParameters = (0..<3).map { i in
            let offset = layout.intentParamsOffset + i * layout.floatWidth
            return layout.floatWidth == 4
                ? Double(MIQBinaryReader.float32(data, offset, littleEndian: littleEndian))
                : MIQBinaryReader.float64(data, offset, littleEndian: littleEndian)
        }

        info.descrip = niftiText(data, offset: layout.descripOffset, length: 80)
        info.intentName = niftiText(data, offset: layout.intentNameOffset, length: 16)

        let (extensions, labels) = niftiExtensions(
            from: data,
            start: layout.extenderOffset,
            voxOffset: header.voxOffset,
            littleEndian: littleEndian
        )
        info.extensions = extensions
        info.embeddedLabels = labels
        return info
    }

    private func niftiText(_ data: Data, offset: Int, length: Int) -> String? {
        let start = data.startIndex + offset
        guard offset >= 0, data.count >= offset + length else { return nil }
        return MIQAcquisitionInfo.headerText(data[start..<(start + length)])
    }

    /// Walks the extension chain that follows the fixed header: a 4-byte
    /// extender (`extension[0] != 0` means extensions follow), then records of
    /// `esize` (int32, total record size incl. this 8-byte prefix, nominally a
    /// multiple of 16) and `ecode` (int32). The chain ends at `vox_offset` (single
    /// `.nii` file) or the end of the buffer, whichever comes first — the bounded
    /// cold-load prefix always includes everything up to `vox_offset`.
    ///
    /// Any extension whose content holds a `<Label Key=...>` table is parsed into
    /// label names (see `SegmentationLut.parseLabelTableXML`).
    private func niftiExtensions(
        from data: Data,
        start: Int,
        voxOffset: Int,
        littleEndian: Bool
    ) -> ([MIQHeaderExtension], [Int: SegmentationLabel]) {
        guard data.count >= start + 4, data[data.startIndex + start] != 0 else { return ([], [:]) }
        let end = min(voxOffset, data.count)
        var offset = start + 4
        var extensions: [MIQHeaderExtension] = []
        var labels: [Int: SegmentationLabel] = [:]
        while offset + 8 <= end, extensions.count < Self.maxNiftiExtensions {
            let esize = Int(MIQBinaryReader.int32(data, offset, littleEndian: littleEndian))
            let ecode = Int(MIQBinaryReader.int32(data, offset + 4, littleEndian: littleEndian))
            guard esize >= 8, esize <= end - offset else { break }
            extensions.append(MIQHeaderExtension(ecode: ecode, size: esize))
            let contentSize = esize - 8
            if labels.isEmpty, contentSize > 0, contentSize <= Self.maxLabelExtensionBytes {
                let contentStart = data.startIndex + offset + 8
                let content = data[contentStart..<(contentStart + contentSize)]
                if content.range(of: Data("<Label".utf8)) != nil {
                    labels = SegmentationLut.parseLabelTableXML(String(decoding: content, as: UTF8.self))
                }
            }
            offset += esize
        }
        return (extensions, labels)
    }
}
