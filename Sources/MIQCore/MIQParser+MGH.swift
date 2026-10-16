import Foundation

extension MIQParser {
    private enum MghType: Int32 {
        case uchar = 0
        case int = 1
        case float = 3
        case short = 4

        var datatype: MIQDatatype {
            switch self {
            case .uchar: return .uint8
            case .int: return .int32
            case .float: return .float32
            case .short: return .int16
            }
        }
    }

    func parseMgh(_ data: Data) throws -> MIQImage {
        let header = try parseMghHeader(from: data)

        let voxelCount = header.width * header.height * header.depth * max(1, header.volumes)
        let payloadBytes = voxelCount * header.datatype.bytesPerVoxel
        guard payloadBytes > 0 else {
            throw MIQError.invalidDimensions
        }
        // Subtraction form: `voxOffset + payloadBytes` traps when the validated dims
        // product lands on `Int.max`. The offset is the 284-byte header constant, already
        // covered by the length check in `parseMghHeader`.
        guard data.count - header.voxOffset >= payloadBytes else {
            throw MIQError.truncatedData
        }

        return MIQImage(header: header, storage: data, payloadOffset: header.voxOffset)
    }

    func parseMghHeader(from data: Data) throws -> MIQHeader {
        let mghHeaderSize = 284
        guard data.count >= mghHeaderSize else {
            throw MIQError.truncatedData
        }

        let version = MIQBinaryReader.int32(data, 0, littleEndian: false)
        guard version == 1 else {
            throw MIQError.unsupportedFormatVersion(version)
        }

        let width = Int(MIQBinaryReader.int32(data, 4, littleEndian: false))
        let height = Int(MIQBinaryReader.int32(data, 8, littleEndian: false))
        let depth = Int(MIQBinaryReader.int32(data, 12, littleEndian: false))
        let frames = Int(MIQBinaryReader.int32(data, 16, littleEndian: false))
        let typeRaw = MIQBinaryReader.int32(data, 20, littleEndian: false)

        guard width > 0, height > 0, depth > 0, frames > 0 else {
            throw MIQError.invalidDimensions
        }

        guard let mghType = MghType(rawValue: typeRaw) else {
            throw MIQError.unsupportedDatatype(typeRaw)
        }

        try validateDimensionExtent([width, height, depth, frames], bytesPerVoxel: mghType.datatype.bytesPerVoxel)

        let goodRAS = MIQBinaryReader.int16(data, 28, littleEndian: false)
        let pixdim: [Float]
        let srowX: [Float]
        let srowY: [Float]
        let srowZ: [Float]
        let sformCode: Int

        if goodRAS != 0 {
            let sx = sanitizedSpacing(MIQBinaryReader.float32(data, 30, littleEndian: false))
            let sy = sanitizedSpacing(MIQBinaryReader.float32(data, 34, littleEndian: false))
            let sz = sanitizedSpacing(MIQBinaryReader.float32(data, 38, littleEndian: false))
            pixdim = [1.0, sx, sy, sz]

            let xr = MIQBinaryReader.float32(data, 42, littleEndian: false)
            let xa = MIQBinaryReader.float32(data, 46, littleEndian: false)
            let xs = MIQBinaryReader.float32(data, 50, littleEndian: false)
            let yr = MIQBinaryReader.float32(data, 54, littleEndian: false)
            let ya = MIQBinaryReader.float32(data, 58, littleEndian: false)
            let ys = MIQBinaryReader.float32(data, 62, littleEndian: false)
            let zr = MIQBinaryReader.float32(data, 66, littleEndian: false)
            let za = MIQBinaryReader.float32(data, 70, littleEndian: false)
            let zs = MIQBinaryReader.float32(data, 74, littleEndian: false)

            // Rows keep the unit direction cosines (spacing lives in pixdim, as
            // consumers of `.mghDirectionCosines` expect); the fourth column is the
            // world position of voxel (0,0,0). FreeSurfer's vox2ras puts `c_ras` at
            // the voxel *centre* index dim/2: P0 = c_ras − Mdc · diag(spacing) · dim/2.
            let cr = MIQBinaryReader.float32(data, 78, littleEndian: false)
            let ca = MIQBinaryReader.float32(data, 82, littleEndian: false)
            let cs = MIQBinaryReader.float32(data, 86, littleEndian: false)
            let half = [Float(width) / 2 * sx, Float(height) / 2 * sy, Float(depth) / 2 * sz]
            func origin(_ c: Float, _ row: (Float, Float, Float)) -> Float {
                let p = c - (row.0 * half[0] + row.1 * half[1] + row.2 * half[2])
                return p.isFinite ? p : 0
            }
            srowX = [xr, yr, zr, origin(cr, (xr, yr, zr))]
            srowY = [xa, ya, za, origin(ca, (xa, ya, za))]
            srowZ = [xs, ys, zs, origin(cs, (xs, ys, zs))]
            sformCode = 1
        } else {
            pixdim = [1.0, 1.0, 1.0, 1.0]
            srowX = [1, 0, 0, 0]
            srowY = [0, 1, 0, 0]
            srowZ = [0, 0, 1, 0]
            sformCode = 0
        }

        let orientationFrame: OrientationFrame? = sformCode > 0
            ? OrientationFrame.from(srowX: srowX, srowY: srowY, srowZ: srowZ, source: .mghDirectionCosines)
            : nil

        var header = MIQHeader(
            littleEndian: false,
            dimensions: [width, height, depth, frames],
            pixdim: pixdim,
            datatype: mghType.datatype,
            voxOffset: mghHeaderSize,
            sclSlope: 0,
            sclInter: 0,
            qformCode: 0,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            orientationFrame: orientationFrame
        )
        // Product bounded by `validateDimensionExtent` above; the add is checked
        // because that bound is `Int.max` itself.
        let payloadBytes = width * height * depth * frames * mghType.datatype.bytesPerVoxel
        let (payloadEnd, overflow) = mghHeaderSize.addingReportingOverflow(payloadBytes)
        if !overflow {
            header.acquisition = mghScanParameters(from: data, payloadEnd: payloadEnd)
        }
        return header
    }

    // MARK: - Acquisition & provenance (optional tail)

    /// The optional scan-parameter tail FreeSurfer writes straight after the
    /// payload: big-endian float32 TR (ms), flip angle (radians), TE (ms), TI (ms)
    /// (then FoV and tags, unread). Absent in many files, so read only when all
    /// four floats are inside the buffer; zero or non-finite values mean "not
    /// recorded" (FreeSurfer's writers zero-fill the tail) and are left out.
    ///
    /// Cost: none extra. Both `.mgh` (mapped) and `.mgz` (always fully
    /// decompressed — MGH volume 0 is never budget-capped, see
    /// `niftiVolumeZeroBudget`) already hold the whole file here. A buffer cut
    /// short (header-only probes) just yields no tail.
    private func mghScanParameters(from data: Data, payloadEnd: Int) -> MIQAcquisitionInfo {
        var info = MIQAcquisitionInfo()
        guard payloadEnd > 0, data.count - payloadEnd >= 16 else { return info }
        func value(_ index: Int) -> Double? {
            let v = Double(MIQBinaryReader.float32(data, payloadEnd + index * 4, littleEndian: false))
            return v.isFinite && v > 0 ? v : nil
        }
        info.repetitionTime = value(0).map { $0 / 1000 }
        info.flipAngle = value(1).map { $0 * 180 / .pi }
        info.echoTime = value(2).map { $0 / 1000 }
        info.inversionTime = value(3).map { $0 / 1000 }
        return info
    }
}
