import Foundation
import zlib

// MARK: - Geometry

/// The spatial part of a NIfTI-1 header: voxel sizes, qform and sform, units.
///
/// `NiftiWriter` stamps this onto every file it writes, so a derived volume (for
/// example a brain mask) lines up with its source in any NIfTI tool. Build it with
/// `init(volume:)` to copy a parsed volume's geometry, or `init(affine:code:)` for
/// a bare voxel → world transform.
public struct NiftiGeometry: Sendable, Equatable {
    /// `pixdim[0...3]`: qfac (±1), then the voxel size along i, j, k.
    public var pixdim: [Float]
    public var qformCode: Int
    /// Quaternion parameters b, c, d (a is implied).
    public var quatern: [Float]
    /// qform translation x, y, z.
    public var qoffset: [Float]
    public var sformCode: Int
    public var srowX: [Float]
    public var srowY: [Float]
    public var srowZ: [Float]
    /// Spatial unit written to `xyzt_units` (the temporal bits are left 0).
    public var spatialUnit: MIQSpatialUnit

    public init(
        pixdim: [Float] = [1, 1, 1, 1],
        qformCode: Int = 0,
        quatern: [Float] = [0, 0, 0],
        qoffset: [Float] = [0, 0, 0],
        sformCode: Int = 0,
        srowX: [Float] = [0, 0, 0, 0],
        srowY: [Float] = [0, 0, 0, 0],
        srowZ: [Float] = [0, 0, 0, 0],
        spatialUnit: MIQSpatialUnit = .millimeter
    ) {
        func padded(_ v: [Float], _ n: Int, _ fill: Float) -> [Float] {
            (0..<n).map { v[safe: $0] ?? fill }
        }
        self.pixdim = padded(pixdim, 4, 1)
        self.qformCode = qformCode
        self.quatern = padded(quatern, 3, 0)
        self.qoffset = padded(qoffset, 3, 0)
        self.sformCode = sformCode
        self.srowX = padded(srowX, 4, 0)
        self.srowY = padded(srowY, 4, 0)
        self.srowZ = padded(srowZ, 4, 0)
        self.spatialUnit = spatialUnit
    }

    /// Writes `affine` as the sform and as an equivalent qform (both with `code`;
    /// 1 = scanner anatomical, 2 = aligned). Voxel sizes are the column norms. A
    /// shear the quaternion cannot express survives in the sform only.
    public init(affine: VoxelAffine, code: Int = 1, spatialUnit: MIQSpatialUnit = .millimeter) {
        let q = Self.quaternion(from: affine)
        let m = affine.rows
        self.init(
            pixdim: [q.qfac, q.spacing[0], q.spacing[1], q.spacing[2]],
            qformCode: code,
            quatern: [q.b, q.c, q.d],
            qoffset: [Float(m[0][3]), Float(m[1][3]), Float(m[2][3])],
            sformCode: code,
            srowX: m[0].map { Float($0) },
            srowY: m[1].map { Float($0) },
            srowZ: m[2].map { Float($0) },
            spatialUnit: spatialUnit
        )
    }

    /// The geometry of a parsed volume, for writing data on its voxel grid.
    ///
    /// - **NIfTI-1/2 sources** are copied field for field: pixdim (qfac and the
    ///   three voxel sizes), qform code, quaternion and offsets (re-read from the
    ///   raw header), sform code and rows, and the spatial unit. NIfTI-2's float64
    ///   values are narrowed to float32.
    /// - **Other formats** (MGH, NRRD, MIF, …) write `volume.voxelToWorld` as both
    ///   sform and qform with code 1; with no orientation at all, only the voxel
    ///   sizes are written (both codes 0).
    ///   See `MIQVolume.voxelToWorld` for where each format's origin comes from.
    public init(volume: MIQVolume) {
        let header = volume.image.header
        let spacing = (1...3).map { sanitizedSpacing(header.pixdim[safe: $0] ?? 1) }
        if let raw = NIfTIRawFields(image: volume.image) {
            self.init(
                pixdim: [Float(raw.qfac)] + spacing,
                qformCode: raw.qformCode,
                quatern: [Float(raw.quaternB), Float(raw.quaternC), Float(raw.quaternD)],
                qoffset: [Float(raw.qoffset.0), Float(raw.qoffset.1), Float(raw.qoffset.2)],
                sformCode: header.sformCode,
                srowX: header.srowX,
                srowY: header.srowY,
                srowZ: header.srowZ,
                spatialUnit: header.acquisition.spatialUnit ?? .millimeter
            )
            return
        }
        guard header.orientationFrame != nil else {
            // No orientation: keep the voxel sizes, claim nothing about world space.
            self.init(pixdim: [1] + spacing)
            return
        }
        self.init(affine: volume.voxelToWorld, code: 1)
    }

    /// NIfTI-1 `nifti_mat44_to_quatern`: the rotation of `affine`'s normalised
    /// columns as (b, c, d) with `a ≥ 0`, the handedness flag, and the column norms.
    /// Non-orthogonal columns are not re-orthogonalised (the sform keeps them exact).
    static func quaternion(from affine: VoxelAffine) -> (b: Float, c: Float, d: Float, qfac: Float, spacing: [Float]) {
        let m = affine.rows
        var r = [[Double]](repeating: [0, 0, 0], count: 3)
        var spacing = [Double](repeating: 1, count: 3)
        for c in 0..<3 {
            let n = (m[0][c] * m[0][c] + m[1][c] * m[1][c] + m[2][c] * m[2][c]).squareRoot()
            let usable = n.isFinite && n > 0
            spacing[c] = usable ? n : 1
            for row in 0..<3 {
                r[row][c] = usable ? m[row][c] / n : (row == c ? 1 : 0)
            }
        }
        let det = r[0][0] * (r[1][1] * r[2][2] - r[1][2] * r[2][1])
            - r[0][1] * (r[1][0] * r[2][2] - r[1][2] * r[2][0])
            + r[0][2] * (r[1][0] * r[2][1] - r[1][1] * r[2][0])
        var qfac: Double = 1
        if det < 0 {
            qfac = -1
            for row in 0..<3 { r[row][2] = -r[row][2] }
        }
        var a = r[0][0] + r[1][1] + r[2][2] + 1
        var b: Double, c: Double, d: Double
        if a > 0.5 {
            a = 0.5 * a.squareRoot()
            b = 0.25 * (r[2][1] - r[1][2]) / a
            c = 0.25 * (r[0][2] - r[2][0]) / a
            d = 0.25 * (r[1][0] - r[0][1]) / a
        } else {
            let xd = 1 + r[0][0] - (r[1][1] + r[2][2])
            let yd = 1 + r[1][1] - (r[0][0] + r[2][2])
            let zd = 1 + r[2][2] - (r[0][0] + r[1][1])
            if xd > 1 {
                b = 0.5 * xd.squareRoot()
                c = 0.25 * (r[0][1] + r[1][0]) / b
                d = 0.25 * (r[0][2] + r[2][0]) / b
                a = 0.25 * (r[2][1] - r[1][2]) / b
            } else if yd > 1 {
                c = 0.5 * yd.squareRoot()
                b = 0.25 * (r[0][1] + r[1][0]) / c
                d = 0.25 * (r[1][2] + r[2][1]) / c
                a = 0.25 * (r[0][2] - r[2][0]) / c
            } else {
                d = 0.5 * max(0, zd).squareRoot()
                let dd = d == 0 ? 1 : d
                b = 0.25 * (r[0][2] + r[2][0]) / dd
                c = 0.25 * (r[1][2] + r[2][1]) / dd
                a = 0.25 * (r[1][0] - r[0][1]) / dd
            }
            if a < 0 { b = -b; c = -c; d = -d }
        }
        return (Float(b), Float(c), Float(d), Float(qfac), spacing.map { Float($0) })
    }
}

// MARK: - Writer

/// Minimal NIfTI-1 writer for single-volume `uint8` data (masks and label maps).
///
/// Writes a 348-byte header, an empty 4-byte extension block and the voxels at
/// `vox_offset` 352, little-endian, `scl_slope` 1. Geometry comes from a
/// `NiftiGeometry`; everything else (intent, TR, description of the source…) is
/// deliberately not carried over, so no free-text header field of the source
/// leaks into the derived file.
public enum NiftiWriter {
    public enum WriteError: Error, LocalizedError, Equatable {
        /// `voxels.count` is not `width × height × depth`, or a dimension is < 1.
        case dimensionMismatch
        /// A dimension exceeds NIfTI-1's int16 limit (32767).
        case dimensionTooLarge
        /// zlib failed while compressing.
        case compressionFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .dimensionMismatch: return "The mask does not match the volume's dimensions."
            case .dimensionTooLarge: return "The volume is too large for a NIfTI-1 file."
            case .compressionFailed(let status): return "Compressing the file failed (zlib status \(status))."
            }
        }
    }

    /// Size of the header plus the empty extension flag.
    static let voxOffset = 352

    /// Encodes `voxels` (x fastest, then y, then z) as uncompressed `.nii` bytes.
    /// - Parameters:
    ///   - description: Written to `descrip` (ASCII, truncated to 79 bytes).
    ///   - calibration: `cal_min`/`cal_max` display range; `0...1` suits a binary mask.
    public static func encodeUInt8(
        _ voxels: [UInt8],
        width: Int, height: Int, depth: Int,
        geometry: NiftiGeometry,
        description: String = "",
        calibration: ClosedRange<Float>? = 0...1
    ) throws -> Data {
        guard width > 0, height > 0, depth > 0, voxels.count == width * height * depth else {
            throw WriteError.dimensionMismatch
        }
        guard max(width, height, depth) <= Int(Int16.max) else { throw WriteError.dimensionTooLarge }

        var h = [UInt8](repeating: 0, count: voxOffset)
        func put<T: FixedWidthInteger>(_ v: T, _ o: Int) {
            withUnsafeBytes(of: v.littleEndian) { for (i, x) in $0.enumerated() { h[o + i] = x } }
        }
        func putF(_ v: Float, _ o: Int) { put((v.isFinite ? v : 0).bitPattern, o) }

        put(Int32(348), 0)                        // sizeof_hdr
        h[38] = UInt8(ascii: "r")                 // regular
        let dims = [3, width, height, depth, 1, 1, 1, 1]
        for (i, d) in dims.enumerated() { put(Int16(d), 40 + i * 2) }
        put(MIQDatatype.uint8.rawValue, 70)       // datatype
        put(Int16(8), 72)                         // bitpix
        let qfac: Float = (geometry.pixdim[safe: 0] ?? 1) < 0 ? -1 : 1
        let pixdim: [Float] = [qfac] + (1...3).map { geometry.pixdim[safe: $0] ?? 1 } + [0, 0, 0, 0]
        for (i, p) in pixdim.enumerated() { putF(p, 76 + i * 4) }
        putF(Float(voxOffset), 108)               // vox_offset
        putF(1, 112)                              // scl_slope
        putF(0, 116)                              // scl_inter
        h[123] = UInt8(truncatingIfNeeded: geometry.spatialUnit.rawValue & 0x07)
        if let calibration {
            putF(calibration.upperBound, 124)     // cal_max
            putF(calibration.lowerBound, 128)     // cal_min
        }
        let descrip = Array(description.unicodeScalars.filter(\.isASCII).map { UInt8($0.value) }.prefix(79))
        for (i, byte) in descrip.enumerated() { h[148 + i] = byte }
        put(Int16(clamping: geometry.qformCode), 252)
        put(Int16(clamping: geometry.sformCode), 254)
        for i in 0..<3 {
            putF(geometry.quatern[safe: i] ?? 0, 256 + i * 4)
            putF(geometry.qoffset[safe: i] ?? 0, 268 + i * 4)
        }
        for c in 0..<4 {
            putF(geometry.srowX[safe: c] ?? 0, 280 + c * 4)
            putF(geometry.srowY[safe: c] ?? 0, 296 + c * 4)
            putF(geometry.srowZ[safe: c] ?? 0, 312 + c * 4)
        }
        h[344] = 0x6E; h[345] = 0x2B; h[346] = 0x31; h[347] = 0  // "n+1\0"
        // Bytes 348…351 stay 0: no extensions.

        var out = Data(capacity: voxOffset + voxels.count)
        out.append(contentsOf: h)
        out.append(contentsOf: voxels)
        return out
    }

    /// Encodes and writes `voxels` to `url`, gzip-compressed when the path ends in
    /// `.gz` (e.g. `sub-01_desc-brain_mask.nii.gz`). Written atomically.
    public static func writeUInt8(
        _ voxels: [UInt8],
        width: Int, height: Int, depth: Int,
        geometry: NiftiGeometry,
        to url: URL,
        description: String = "",
        calibration: ClosedRange<Float>? = 0...1
    ) throws {
        var data = try encodeUInt8(
            voxels, width: width, height: height, depth: depth,
            geometry: geometry, description: description, calibration: calibration
        )
        if url.pathExtension.lowercased() == "gz" {
            data = try gzip(data)
        }
        try data.write(to: url, options: .atomic)
    }

    /// RFC 1952 gzip stream of `data` (zlib deflate with a gzip wrapper).
    public static func gzip(_ data: Data, level: Int32 = 6) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, max(0, min(9, level)), Z_DEFLATED, 16 + MAX_WBITS, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw WriteError.compressionFailed(status) }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var output = [UInt8](repeating: 0, count: max(64, bound))
        status = input.withUnsafeMutableBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                stream.next_in = src.baseAddress
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw WriteError.compressionFailed(status) }
        return Data(output.prefix(Int(stream.total_out)))
    }
}
