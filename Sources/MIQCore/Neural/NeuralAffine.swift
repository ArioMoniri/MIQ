import Foundation

/// A 3×4 affine transform (row-major, implicit `[0 0 0 1]` bottom row) used by the
/// neural-mask pipeline to move between voxel grids and world (RAS millimetre) space.
///
/// Kept deliberately tiny and `Double`-precision: it is evaluated once per output
/// row, never per voxel, so precision costs nothing and avoids drift across 256³ grids.
public struct NeuralAffine: Sendable, Hashable {
    /// Row-major 3×4 entries: `[r00 r01 r02 t0, r10 r11 r12 t1, r20 r21 r22 t2]`.
    public var entries: [Double]

    public init(entries: [Double]) {
        precondition(entries.count == 12, "NeuralAffine needs 12 entries")
        self.entries = entries
    }

    /// Builds an affine from three rows of four values (`srow_x/y/z`-style).
    public init(rowX: [Double], rowY: [Double], rowZ: [Double]) {
        func padded(_ row: [Double]) -> [Double] {
            (0..<4).map { row.indices.contains($0) ? row[$0] : 0 }
        }
        self.entries = padded(rowX) + padded(rowY) + padded(rowZ)
    }

    public static let identity = NeuralAffine(entries: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])

    /// Scaling-only affine (axis-aligned voxel grid with the given spacings).
    public static func scaling(_ sx: Double, _ sy: Double, _ sz: Double) -> NeuralAffine {
        NeuralAffine(entries: [sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0])
    }

    @inline(__always)
    public func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let m = entries
        return (
            m[0] * x + m[1] * y + m[2] * z + m[3],
            m[4] * x + m[5] * y + m[6] * z + m[7],
            m[8] * x + m[9] * y + m[10] * z + m[11]
        )
    }

    /// Column `axis` of the linear part (the world step for one voxel along that axis).
    public func column(_ axis: Int) -> (Double, Double, Double) {
        (entries[axis], entries[4 + axis], entries[8 + axis])
    }

    /// `self ∘ other`: first applies `other`, then `self`.
    public func concatenating(_ other: NeuralAffine) -> NeuralAffine {
        let a = entries, b = other.entries
        var out = [Double](repeating: 0, count: 12)
        for r in 0..<3 {
            for c in 0..<4 {
                var v = 0.0
                for k in 0..<3 { v += a[r * 4 + k] * b[k * 4 + c] }
                if c == 3 { v += a[r * 4 + 3] }
                out[r * 4 + c] = v
            }
        }
        return NeuralAffine(entries: out)
    }

    /// Inverse transform, or nil when the linear part is singular or non-finite.
    public func inverted() -> NeuralAffine? {
        let m = entries
        let a = m[0], b = m[1], c = m[2]
        let d = m[4], e = m[5], f = m[6]
        let g = m[8], h = m[9], i = m[10]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let r = [
            (e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv,
        ]
        let tx = m[3], ty = m[7], tz = m[11]
        return NeuralAffine(entries: [
            r[0], r[1], r[2], -(r[0] * tx + r[1] * ty + r[2] * tz),
            r[3], r[4], r[5], -(r[3] * tx + r[4] * ty + r[5] * tz),
            r[6], r[7], r[8], -(r[6] * tx + r[7] * ty + r[8] * tz),
        ])
    }
}
