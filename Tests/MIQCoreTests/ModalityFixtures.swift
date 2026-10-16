import Foundation
@testable import MIQCore

/// Synthetic volumes for the overlay / colormap / diffusion / temporal suites.
enum ModalityFixtures {
    /// Voxel spacing and sform rows for `floatVolume`.
    struct Geometry {
        var spacing: [Float] = [1, 1, 1]
        /// sform rows; `nil` = `diag(spacing)`, zero origin.
        var srow: [[Float]]?

        static func spacing(_ spacing: [Float]) -> Geometry { Geometry(spacing: spacing) }
        static func srow(_ srow: [[Float]]) -> Geometry { Geometry(srow: srow) }
    }

    /// NIfTI qform fields for `niftiBytes`.
    struct QForm {
        var code: Int16 = 0
        var quatern: (Float, Float, Float) = (0, 0, 0)
        var qoffset: (Float, Float, Float) = (0, 0, 0)
    }

    /// NIfTI sform fields for `niftiBytes`.
    struct SForm {
        var code: Int16 = 0
        var srow: [[Float]] = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]]
    }

    /// Float32 volume built straight from an `MIQHeader`, x-fastest then t then
    /// (5th axis) components. `geometry.srow` rows default to `diag(spacing)`, zero origin.
    static func floatVolume(
        width: Int, height: Int, depth: Int, volumes: Int = 1, components: Int = 1,
        geometry: Geometry = Geometry(),
        values: [Float]
    ) -> MIQVolume {
        let spacing = geometry.spacing
        let rows = geometry.srow ?? [
            [spacing[0], 0, 0, 0],
            [0, spacing[1], 0, 0],
            [0, 0, spacing[2], 0],
        ]
        var dims = [width, height, depth, volumes]
        if components > 1 { dims.append(components) }
        let header = MIQHeader(
            littleEndian: true,
            dimensions: dims,
            pixdim: [1, spacing[0], spacing[1], spacing[2]],
            datatype: .float32,
            voxOffset: 0,
            sclSlope: 1,
            sclInter: 0,
            qformCode: 0,
            sformCode: 1,
            srowX: rows[0], srowY: rows[1], srowZ: rows[2],
            orientationFrame: OrientationFrame.from(srowX: rows[0], srowY: rows[1], srowZ: rows[2], source: .sform)
        )
        precondition(values.count == width * height * depth * volumes * components)
        var data = Data(count: values.count * 4)
        data.withUnsafeMutableBytes { raw in
            for (i, v) in values.enumerated() {
                raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: i * 4, as: UInt32.self)
            }
        }
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }

    /// Minimal little-endian NIfTI-1 (`.nii`) bytes with float32 payload.
    static func niftiBytes(
        dims: [Int],
        pixdim: [Float] = [1, 1, 1, 1],
        intentCode: Int16 = 0,
        qform: QForm = QForm(),
        sform: SForm = SForm(),
        values: [Float]
    ) -> Data {
        let qformCode = qform.code
        let sformCode = sform.code
        let quatern = qform.quatern
        let qoffset = qform.qoffset
        let srow = sform.srow
        var b = [UInt8](repeating: 0, count: 352)
        func put<T: FixedWidthInteger>(_ v: T, _ o: Int) {
            withUnsafeBytes(of: v.littleEndian) { for (i, x) in $0.enumerated() { b[o + i] = x } }
        }
        func putF(_ v: Float, _ o: Int) { put(v.bitPattern, o) }
        put(Int32(348), 0)
        put(Int16(dims.count), 40)
        for (i, d) in dims.enumerated() { put(Int16(d), 42 + i * 2) }
        put(intentCode, 68)
        put(MIQDatatype.float32.rawValue, 70)
        put(Int16(32), 72)
        for (i, p) in pixdim.enumerated() { putF(p, 76 + i * 4) }
        putF(352, 108)
        putF(1, 112)
        put(qformCode, 252)
        put(sformCode, 254)
        putF(quatern.0, 256); putF(quatern.1, 260); putF(quatern.2, 264)
        putF(qoffset.0, 268); putF(qoffset.1, 272); putF(qoffset.2, 276)
        for c in 0..<4 {
            putF(srow[0][c], 280 + c * 4)
            putF(srow[1][c], 296 + c * 4)
            putF(srow[2][c], 312 + c * 4)
        }
        b[344] = 0x6E; b[345] = 0x2B; b[346] = 0x31; b[347] = 0  // "n+1\0"
        var payload = [UInt8](repeating: 0, count: values.count * 4)
        for (i, v) in values.enumerated() {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { for (j, x) in $0.enumerated() { payload[i * 4 + j] = x } }
        }
        return Data(b + payload)
    }

    static func niftiVolume(_ data: Data) throws -> MIQVolume {
        MIQVolume(image: try MIQParser().parseNifti(data))
    }
}
