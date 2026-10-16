import Foundation

// MARK: - Voxel → world affine

/// A 3×4 voxel-index → world (RAS+, mm) affine, row-major:
/// `world = M · (i, j, k, 1)` with `rows[r] = [m_r0, m_r1, m_r2, t_r]`.
/// Stored in `Double` so composing two affines (overlay ← world ← reference) does
/// not accumulate visible float error across a 256³ grid.
public struct VoxelAffine: Sendable, Hashable {
    public let rows: [[Double]]

    /// `rows` must be three rows of four values; missing entries read as 0.
    public init(rows: [[Double]]) {
        self.rows = (0..<3).map { r in (0..<4).map { c in rows[safe: r]?[safe: c] ?? 0 } }
    }

    public static let identity = VoxelAffine(rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]])

    public func apply(_ i: Double, _ j: Double, _ k: Double) -> (x: Double, y: Double, z: Double) {
        let m = rows
        return (
            m[0][0] * i + m[0][1] * j + m[0][2] * k + m[0][3],
            m[1][0] * i + m[1][1] * j + m[1][2] * k + m[1][3],
            m[2][0] * i + m[2][1] * j + m[2][2] * k + m[2][3]
        )
    }

    /// Determinant of the linear (3×3) part.
    public var determinant: Double {
        let m = rows
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    /// Whether the linear part is invertible and finite.
    public var isInvertible: Bool {
        let d = determinant
        return d.isFinite && abs(d) > 1e-12 && rows.allSatisfy { $0.allSatisfy(\.isFinite) }
    }

    /// World → voxel inverse, or `nil` for a singular affine.
    public func inverse() -> VoxelAffine? {
        guard isInvertible else { return nil }
        let m = rows
        let det = determinant
        var inv = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        inv[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det
        inv[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det
        inv[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det
        inv[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det
        inv[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det
        inv[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det
        inv[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det
        inv[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det
        inv[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det
        for r in 0..<3 {
            inv[r][3] = -(inv[r][0] * m[0][3] + inv[r][1] * m[1][3] + inv[r][2] * m[2][3])
        }
        return VoxelAffine(rows: inv)
    }

    /// `self ∘ other`: apply `other` first, then `self`.
    public func concatenating(_ other: VoxelAffine) -> VoxelAffine {
        let a = rows
        let b = other.rows
        var out = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        for r in 0..<3 {
            for c in 0..<4 {
                var v = a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c]
                if c == 3 { v += a[r][3] }
                out[r][c] = v
            }
        }
        return VoxelAffine(rows: out)
    }

    /// Pure rotation (possibly with reflection) of the linear part: each column
    /// normalised to unit length, i.e. voxel scaling removed. Used to rotate
    /// voxel-frame vectors into world directions. Columns of zero length stay zero.
    public var directionCosines: [[Double]] {
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for c in 0..<3 {
            let n = (rows[0][c] * rows[0][c] + rows[1][c] * rows[1][c] + rows[2][c] * rows[2][c]).squareRoot()
            guard n > 0, n.isFinite else { continue }
            for r in 0..<3 { out[r][c] = rows[r][c] / n }
        }
        return out
    }

    /// Diagonal affine from voxel sizes with zero origin.
    static func diagonal(_ sx: Double, _ sy: Double, _ sz: Double) -> VoxelAffine {
        VoxelAffine(rows: [[sx, 0, 0, 0], [0, sy, 0, 0], [0, 0, sz, 0]])
    }
}

/// NIfTI header fields MIQHeader does not carry (`intent_code`, the qform
/// quaternion and offsets), re-read from the raw header bytes still at the front
/// of `MIQImage.storage` for NIfTI images. `nil` for any other format, or for an
/// image whose storage does not start with a NIfTI-1/2 header (derived volumes).
struct NIfTIRawFields {
    let intentCode: Int
    let qformCode: Int
    let quaternB: Double
    let quaternC: Double
    let quaternD: Double
    let qoffset: (Double, Double, Double)
    let qfac: Double

    init?(image: MIQImage) {
        let data = image.storage
        let le = image.header.littleEndian
        guard data.count >= 4 else { return nil }
        let sizeofHdr = MIQBinaryReader.int32(data, 0, littleEndian: le)
        let qfacRaw = Double(image.header.pixdim[safe: 0] ?? 1)
        qfac = qfacRaw < 0 ? -1 : 1
        if sizeofHdr == 348, data.count >= 348, image.payloadOffset >= 348 {
            intentCode = Int(MIQBinaryReader.int16(data, 68, littleEndian: le))
            qformCode = Int(MIQBinaryReader.int16(data, 252, littleEndian: le))
            quaternB = Double(MIQBinaryReader.float32(data, 256, littleEndian: le))
            quaternC = Double(MIQBinaryReader.float32(data, 260, littleEndian: le))
            quaternD = Double(MIQBinaryReader.float32(data, 264, littleEndian: le))
            qoffset = (
                Double(MIQBinaryReader.float32(data, 268, littleEndian: le)),
                Double(MIQBinaryReader.float32(data, 272, littleEndian: le)),
                Double(MIQBinaryReader.float32(data, 276, littleEndian: le))
            )
        } else if sizeofHdr == 540, data.count >= 540, image.payloadOffset >= 540 {
            intentCode = Int(MIQBinaryReader.int32(data, 504, littleEndian: le))
            qformCode = Int(MIQBinaryReader.int32(data, 344, littleEndian: le))
            quaternB = MIQBinaryReader.float64(data, 352, littleEndian: le)
            quaternC = MIQBinaryReader.float64(data, 360, littleEndian: le)
            quaternD = MIQBinaryReader.float64(data, 368, littleEndian: le)
            qoffset = (
                MIQBinaryReader.float64(data, 376, littleEndian: le),
                MIQBinaryReader.float64(data, 384, littleEndian: le),
                MIQBinaryReader.float64(data, 392, littleEndian: le)
            )
        } else {
            return nil
        }
    }

    /// The qform affine (NIfTI-1 spec method 2), or `nil` when the quaternion is
    /// unusable.
    func qformAffine(pixdim: [Float]) -> VoxelAffine? {
        let b = quaternB
        let c = quaternC
        let d = quaternD
        guard b.isFinite, c.isFinite, d.isFinite else { return nil }
        let a = max(0, 1 - b * b - c * c - d * d).squareRoot()
        let r00 = a * a + b * b - c * c - d * d
        let r01 = 2 * (b * c - a * d)
        let r02 = 2 * (b * d + a * c)
        let r10 = 2 * (b * c + a * d)
        let r11 = a * a + c * c - b * b - d * d
        let r12 = 2 * (c * d - a * b)
        let r20 = 2 * (b * d - a * c)
        let r21 = 2 * (c * d + a * b)
        let r22 = a * a + d * d - b * b - c * c
        let sx = Double(sanitizedSpacing(pixdim[safe: 1] ?? 1))
        let sy = Double(sanitizedSpacing(pixdim[safe: 2] ?? 1))
        let sz = Double(sanitizedSpacing(pixdim[safe: 3] ?? 1)) * qfac
        let affine = VoxelAffine(rows: [
            [r00 * sx, r01 * sy, r02 * sz, qoffset.0],
            [r10 * sx, r11 * sy, r12 * sz, qoffset.1],
            [r20 * sx, r21 * sy, r22 * sz, qoffset.2],
        ])
        return affine.isInvertible ? affine : nil
    }
}

extension MIQVolume {
    /// NIfTI `intent_code` (e.g. 3 = t-test, 5 = z-score, 1007 = vector), read from
    /// the raw header; `nil` for non-NIfTI images and derived volumes.
    public var niftiIntentCode: Int? {
        NIfTIRawFields(image: image)?.intentCode
    }

    /// Size of the 5th NIfTI dimension (`dim[5]`, vector/tensor components); 1 when absent.
    public var componentCount: Int {
        max(1, image.header.dimensions[safe: 4] ?? 1)
    }

    /// Best-effort voxel → world (RAS+, mm) affine, per format:
    ///
    /// - **NIfTI**: sform when `sform_code > 0` and invertible; else qform (re-read
    ///   from the raw header) when `qform_code > 0`; else `diag(pixdim)`.
    /// - **MGH/MGZ**: FreeSurfer's vox2ras — direction cosines × voxel size, with
    ///   the origin the parser derived from `c_ras` (the centre voxel dim/2 maps to
    ///   `c_ras`).
    /// - **NRRD**: the space directions + origin.
    /// - **MIF**: `transform:` composed with `layout:` and `vox:` (rows built by the
    ///   parser, see `mifVoxelToWorldRows`).
    /// - **OME-Zarr** (no NIfTI header): the srow rows the parser built from the
    ///   OME scale + translation (`srowIsUnorientedAffine`), so the origin is
    ///   true even though orientation is unknown.
    /// - **Anything else**: signed axis permutation from `orientationFrame`
    ///   × voxel size, centred on the volume (offset unknown).
    /// - No orientation at all: `diag(pixdim)`, zero origin.
    public var voxelToWorld: VoxelAffine {
        let header = image.header
        let sx = Double(sanitizedSpacing(header.pixdim[safe: 1] ?? 1))
        let sy = Double(sanitizedSpacing(header.pixdim[safe: 2] ?? 1))
        let sz = Double(sanitizedSpacing(header.pixdim[safe: 3] ?? 1))
        let srow: VoxelAffine? = header.srowX.count >= 4 && header.srowY.count >= 4 && header.srowZ.count >= 4
            ? VoxelAffine(rows: [header.srowX, header.srowY, header.srowZ].map { $0.map(Double.init) })
            : nil
        let source = header.orientationFrame?.source

        if source == .mghDirectionCosines, let srow, header.sformCode == 1 {
            let cos = srow.rows
            var rows = [[Double]](repeating: [0, 0, 0, 0], count: 3)
            let scale = [sx, sy, sz]
            for r in 0..<3 {
                for c in 0..<3 { rows[r][c] = cos[r][c] * scale[c] }
                rows[r][3] = cos[r][3]
            }
            return VoxelAffine(rows: rows)
        }
        if let raw = NIfTIRawFields(image: image) {
            if header.sformCode > 0, let srow, srow.isInvertible { return srow }
            if raw.qformCode > 0, let q = raw.qformAffine(pixdim: header.pixdim) { return q }
            return .diagonal(sx, sy, sz)
        }
        if header.sformCode > 0, let srow, srow.isInvertible { return srow }
        if source == .mifLayout, let srow, srow.isInvertible { return srow }
        if header.srowIsUnorientedAffine, let srow, srow.isInvertible { return srow }
        if let axes = header.orientationFrame?.axes, axes.count == 3 {
            var rows = [[Double]](repeating: [0, 0, 0, 0], count: 3)
            let scale = [sx, sy, sz]
            for (c, axis) in axes.enumerated() {
                let r: Int
                switch axis.axis {
                case .rightLeft: r = 0
                case .anteriorPosterior: r = 1
                case .superiorInferior: r = 2
                }
                rows[r][c] = (axis.positive ? 1 : -1) * scale[c]
            }
            return Self.centred(VoxelAffine(rows: rows), width: width, height: height, depth: depth)
        }
        return .diagonal(sx, sy, sz)
    }

    /// Shifts `affine` so the volume centre (dim/2) lands on world 0.
    private static func centred(_ affine: VoxelAffine, width: Int, height: Int, depth: Int) -> VoxelAffine {
        let c = affine.apply(Double(width) / 2, Double(height) / 2, Double(depth) / 2)
        var rows = affine.rows
        rows[0][3] -= c.x
        rows[1][3] -= c.y
        rows[2][3] -= c.z
        return VoxelAffine(rows: rows)
    }

    /// Wraps a canonical (x-fastest) `Float` buffer in a single-volume float32
    /// `MIQVolume` that shares `reference`'s grid: same dimensions, spacing,
    /// orientation frame and — written explicitly as an sform — the same
    /// `voxelToWorld`. Slicing it with the same `RenderingOptions` therefore yields
    /// pixels aligned 1:1 with `reference.slice(…)`. `nil` when `values.count`
    /// doesn't match the reference's spatial size.
    public static func derivedVolume(values: [Float], onGridOf reference: MIQVolume) -> MIQVolume? {
        let w = reference.width
        let h = reference.height
        let d = reference.depth
        guard values.count == w * h * d, !values.isEmpty else { return nil }
        let affine = reference.voxelToWorld
        let header = reference.image.header
        let frame = header.orientationFrame.map { OrientationFrame(axes: $0.axes, source: .sform) }
        let derivedHeader = MIQHeader(
            littleEndian: true,
            dimensions: [w, h, d, 1],
            pixdim: header.pixdim,
            datatype: .float32,
            voxOffset: 0,
            sclSlope: 1,
            sclInter: 0,
            qformCode: 0,
            sformCode: 2,
            srowX: affine.rows[0].map { Float($0) },
            srowY: affine.rows[1].map { Float($0) },
            srowZ: affine.rows[2].map { Float($0) },
            formatLabel: header.formatLabel,
            datatypeLabel: nil,
            orientationFrame: frame
        )
        var data = Data(count: values.count * 4)
        data.withUnsafeMutableBytes { raw in
            for (i, v) in values.enumerated() {
                raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: i * 4, as: UInt32.self)
            }
        }
        return MIQVolume(image: MIQImage(header: derivedHeader, storage: data, payloadOffset: 0))
    }

    /// All voxels of one volume as a canonical x-fastest `Float` buffer (scaling
    /// applied). `nil` when `volumeIndex` is out of range or the cancellation
    /// check fires (checked once per z-plane).
    public func decodedValues(volumeIndex: Int = 0, isCancelled: () -> Bool = { false }) -> [Float]? {
        guard volumeIndex >= 0, volumeIndex < volumes else { return nil }
        var out = [Float](repeating: 0, count: width * height * depth)
        var n = 0
        for z in 0..<depth {
            if isCancelled() { return nil }
            for y in 0..<height {
                for x in 0..<width {
                    out[n] = voxel(x: x, y: y, z: z, t: volumeIndex)
                    n += 1
                }
            }
        }
        return out
    }
}

// MARK: - Resampling

public enum OverlayInterpolation: Sendable, Hashable {
    /// World-space nearest neighbour — for label maps (labels are never blended).
    case nearest
    /// Trilinear — for continuous statistical maps.
    case trilinear
}

public enum OverlayResampler {
    /// Upper bound on reference-grid voxels a resample will fill (≈ 1 GiB of
    /// Float intermediates at the limit across overlay + output).
    public static let defaultMaxVoxels = 128 * 1024 * 1024

    /// Resamples `overlay` (volume `volumeIndex`) into `reference`'s voxel grid via
    /// the two voxel → world affines, returning a canonical x-fastest buffer of
    /// reference size. Reference voxels whose world position falls outside the
    /// overlay (beyond half a voxel past its edge) get `outsideValue`.
    ///
    /// Returns `nil` on a singular overlay affine, an empty or oversize grid, or
    /// cancellation.
    public static func resample(
        _ overlay: MIQVolume,
        volumeIndex: Int = 0,
        ontoGridOf reference: MIQVolume,
        interpolation: OverlayInterpolation,
        outsideValue: Float = 0,
        maxVoxels: Int = defaultMaxVoxels,
        isCancelled: () -> Bool = { false }
    ) -> [Float]? {
        let rw = reference.width
        let rh = reference.height
        let rd = reference.depth
        let (refCount, o1) = rw.multipliedReportingOverflow(by: rh)
        let (refTotal, o2) = refCount.multipliedReportingOverflow(by: rd)
        guard !o1, !o2, refTotal > 0, refTotal <= maxVoxels,
              overlay.width * overlay.height * overlay.depth <= maxVoxels,
              let worldToOverlay = overlay.voxelToWorld.inverse() else { return nil }
        let m = worldToOverlay.concatenating(reference.voxelToWorld).rows
        guard m.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return nil }
        guard let src = overlay.decodedValues(volumeIndex: volumeIndex, isCancelled: isCancelled) else { return nil }

        let ow = overlay.width
        let oh = overlay.height
        let od = overlay.depth
        let owD = Double(ow)
        let ohD = Double(oh)
        let odD = Double(od)
        var out = [Float](repeating: outsideValue, count: refTotal)
        var n = 0
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { dst in
                for k in 0..<rd {
                    if isCancelled() { n = -1; return }
                    let kd = Double(k)
                    for j in 0..<rh {
                        let jd = Double(j)
                        // Row start in overlay voxel space; step by column 0 per i.
                        var px = m[0][1] * jd + m[0][2] * kd + m[0][3]
                        var py = m[1][1] * jd + m[1][2] * kd + m[1][3]
                        var pz = m[2][1] * jd + m[2][2] * kd + m[2][3]
                        for _ in 0..<rw {
                            if px >= -0.5, px <= owD - 0.5, py >= -0.5, py <= ohD - 0.5, pz >= -0.5, pz <= odD - 0.5 {
                                switch interpolation {
                                case .nearest:
                                    let x = min(ow - 1, max(0, Int((px + 0.5).rounded(.down))))
                                    let y = min(oh - 1, max(0, Int((py + 0.5).rounded(.down))))
                                    let z = min(od - 1, max(0, Int((pz + 0.5).rounded(.down))))
                                    dst[n] = s[(z * oh + y) * ow + x]
                                case .trilinear:
                                    dst[n] = trilinear(s, ow, oh, od, px, py, pz)
                                }
                            }
                            n += 1
                            px += m[0][0]
                            py += m[1][0]
                            pz += m[2][0]
                        }
                    }
                }
            }
        }
        return n < 0 ? nil : out
    }

    /// Trilinear sample at a continuous voxel position already known to lie within
    /// half a voxel of the grid; coordinates are clamped to [0, dim-1] so edge
    /// voxels extend by half a voxel. Non-finite neighbours fall back to nearest.
    private static func trilinear(
        _ s: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ d: Int,
        _ px: Double, _ py: Double, _ pz: Double
    ) -> Float {
        let x = min(Double(w - 1), max(0, px))
        let y = min(Double(h - 1), max(0, py))
        let z = min(Double(d - 1), max(0, pz))
        let x0 = Int(x)
        let y0 = Int(y)
        let z0 = Int(z)
        let x1 = min(w - 1, x0 + 1)
        let y1 = min(h - 1, y0 + 1)
        let z1 = min(d - 1, z0 + 1)
        let fx = Float(x - Double(x0))
        let fy = Float(y - Double(y0))
        let fz = Float(z - Double(z0))
        @inline(__always) func at(_ xi: Int, _ yi: Int, _ zi: Int) -> Float { s[(zi * h + yi) * w + xi] }
        let c000 = at(x0, y0, z0)
        let c100 = at(x1, y0, z0)
        let c010 = at(x0, y1, z0)
        let c110 = at(x1, y1, z0)
        let c001 = at(x0, y0, z1)
        let c101 = at(x1, y0, z1)
        let c011 = at(x0, y1, z1)
        let c111 = at(x1, y1, z1)
        let c00 = c000 + (c100 - c000) * fx
        let c10 = c010 + (c110 - c010) * fx
        let c01 = c001 + (c101 - c001) * fx
        let c11 = c011 + (c111 - c011) * fx
        let c0 = c00 + (c10 - c00) * fy
        let c1 = c01 + (c11 - c01) * fy
        let v = c0 + (c1 - c0) * fz
        if v.isFinite { return v }
        let xn = Int(x.rounded())
        let yn = Int(y.rounded())
        let zn = Int(z.rounded())
        return at(xn, yn, zn)
    }

    /// `resample` wrapped as a volume on `reference`'s grid (see
    /// `MIQVolume.derivedVolume`), ready to slice with the anatomical's options.
    public static func resampledVolume(
        _ overlay: MIQVolume,
        volumeIndex: Int = 0,
        ontoGridOf reference: MIQVolume,
        interpolation: OverlayInterpolation,
        maxVoxels: Int = defaultMaxVoxels,
        isCancelled: () -> Bool = { false }
    ) -> MIQVolume? {
        guard let values = resample(
            overlay, volumeIndex: volumeIndex, ontoGridOf: reference,
            interpolation: interpolation, maxVoxels: maxVoxels, isCancelled: isCancelled
        ) else { return nil }
        return MIQVolume.derivedVolume(values: values, onGridOf: reference)
    }
}

// MARK: - Overlay layers and compositing

extension MIQVolume {
    /// Raw scalar values of one display slice — the same plane/index/orientation
    /// plan `slice(plane:index:…)` uses, before windowing or pixel-spacing
    /// resampling — with the slice's native size. `nil` for RGB datatypes.
    public func displaySliceValues(
        plane: SlicePlane,
        index: Int,
        volumeIndex: Int = 0,
        options: RenderingOptions
    ) -> (values: [Float], width: Int, height: Int)? {
        let geometry = sliceGeometry(for: plane, options: options)
        guard let values = sliceValues(plane: plane, index: index, volumeIndex: volumeIndex, options: options),
              values.count == geometry.width * geometry.height else { return nil }
        return (values, geometry.width, geometry.height)
    }

    /// A label LUT for showing this volume as an overlay: the volume's own detected
    /// LUT (FreeSurfer or ranked-random) when detection accepts it, else the
    /// FreeSurfer table, whose fallback hashes any label to a stable colour.
    public func overlayLabelLut(orientation: ViewOrientation = .stored) -> SegmentationLut {
        let options = RenderingOptions(
            lowerPercentile: 0, upperPercentile: 100,
            orientation: orientation, segmentationColoring: .auto
        )
        return buildSegmentationLut(options: options) ?? .freeSurfer
    }
}

/// How an overlay's scalar values become colour.
public enum OverlayStyle: Sendable {
    /// Integer label map coloured through a segmentation LUT; label 0 transparent.
    /// `outlineOnly` draws only voxels on a label boundary.
    case labels(SegmentationLut, outlineOnly: Bool)
    /// Continuous map through a colour map with optional threshold.
    case scalar(ScalarColorMapping)
}

public enum OverlayCompositor {
    /// Nearest-neighbour rescale of a row-major `Float` buffer.
    public static func resizeNearest(_ values: [Float], width: Int, height: Int, toWidth tw: Int, toHeight th: Int) -> [Float] {
        guard tw > 0, th > 0, width > 0, height > 0, values.count == width * height else { return [] }
        if tw == width && th == height { return values }
        var out = [Float](repeating: 0, count: tw * th)
        for ny in 0..<th {
            let sy = min(height - 1, Int(Float(ny) * Float(height) / Float(th)))
            for nx in 0..<tw {
                let sx = min(width - 1, Int(Float(nx) * Float(width) / Float(tw)))
                out[ny * tw + nx] = values[sy * width + sx]
            }
        }
        return out
    }

    /// Colours a label slice. Label 0 (and non-finite) is transparent. With
    /// `outlineOnly`, a labelled pixel is kept only if one of its 4-neighbours has
    /// a different label or lies outside the image, giving 1-pixel boundaries at
    /// the output resolution.
    public static func labelLayer(values: [Float], width: Int, height: Int, lut: SegmentationLut, outlineOnly: Bool) -> RGBABitmap? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let labels = values.map { MIQBinaryReader.safeInt($0.rounded()) }
        var out = [UInt8](repeating: 0, count: labels.count * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let label = labels[i]
                guard label != 0 else { continue }
                if outlineOnly {
                    let boundary = x == 0 || y == 0 || x == width - 1 || y == height - 1
                        || labels[i - 1] != label || labels[i + 1] != label
                        || labels[i - width] != label || labels[i + width] != label
                    guard boundary else { continue }
                }
                let c = lut.lookup(label)
                out[i * 4] = c.r
                out[i * 4 + 1] = c.g
                out[i * 4 + 2] = c.b
                out[i * 4 + 3] = 255
            }
        }
        return RGBABitmap(width: width, height: height, pixels: Data(out))
    }

    /// Builds the overlay layer for one slice at `width`×`height` (the base
    /// bitmap's size). Values are first nearest-neighbour scaled to that size so
    /// outlines stay one display pixel wide.
    public static func layer(values: [Float], width: Int, height: Int, style: OverlayStyle, toWidth tw: Int, toHeight th: Int) -> RGBABitmap? {
        let scaled = resizeNearest(values, width: width, height: height, toWidth: tw, toHeight: th)
        guard !scaled.isEmpty else { return nil }
        switch style {
        case .labels(let lut, let outlineOnly):
            return labelLayer(values: scaled, width: tw, height: th, lut: lut, outlineOnly: outlineOnly)
        case .scalar(let mapping):
            return mapping.rgbaBitmap(values: scaled, width: tw, height: th)
        }
    }

    /// Alpha-blends `overlay` over `base`: out = base·(1-α) + overlay·α with
    /// α = overlayAlpha/255 · `opacity`. An overlay of a different size is
    /// nearest-neighbour scaled to the base. Output is opaque. `nil` on malformed
    /// buffers.
    public static func composite(base: RGBABitmap, overlay: RGBABitmap, opacity: Float = 0.5) -> RGBABitmap? {
        let count = base.width * base.height
        guard base.width > 0, base.height > 0, base.pixels.count == count * 4,
              overlay.width > 0, overlay.height > 0, overlay.pixels.count == overlay.width * overlay.height * 4 else {
            return nil
        }
        var ov = [UInt8](overlay.pixels)
        if overlay.width != base.width || overlay.height != base.height {
            ov = nearestNeighborResample(
                pixels: ov, width: overlay.width, height: overlay.height, channels: 4,
                targetWidth: base.width, targetHeight: base.height
            )
        }
        let k = min(1, max(0, opacity.isFinite ? opacity : 0))
        var out = [UInt8](base.pixels)
        for p in 0..<count {
            let o = p * 4
            let a = Float(ov[o + 3]) / 255 * k
            if a > 0 {
                for c in 0..<3 {
                    let v = Float(out[o + c]) * (1 - a) + Float(ov[o + c]) * a
                    out[o + c] = UInt8(min(255, max(0, v.rounded())))
                }
            }
            out[o + 3] = 255
        }
        return RGBABitmap(width: base.width, height: base.height, pixels: Data(out))
    }

    /// One-call path: the anatomical `base` slice (as rendered by
    /// `anatomical.slice(plane:index:…)`) with `overlay` — already on the
    /// anatomical's grid, e.g. from `OverlayResampler.resampledVolume` — drawn on
    /// top for the same plane/index/options.
    static func compositeSlice(
        base: SliceImage,
        overlay: MIQVolume,
        plane: SlicePlane,
        index: Int,
        options: RenderingOptions,
        style: OverlayStyle,
        opacity: Float = 0.5
    ) -> RGBABitmap? {
        guard let baseBitmap = base.rgbaBitmap(),
              let slice = overlay.displaySliceValues(plane: plane, index: index, options: options),
              let layer = layer(
                values: slice.values, width: slice.width, height: slice.height,
                style: style, toWidth: baseBitmap.width, toHeight: baseBitmap.height
              ) else { return nil }
        return composite(base: baseBitmap, overlay: layer, opacity: opacity)
    }
}
