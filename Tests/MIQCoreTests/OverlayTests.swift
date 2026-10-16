import Foundation
import Testing
@testable import MIQCore

struct OverlayTests {

    // MARK: Affine

    @Test func affineInverseRoundTrips() throws {
        let a = VoxelAffine(rows: [[0, -2, 0, 10], [1.5, 0, 0, -3], [0, 0, 3, 7]])
        let inv = try #require(a.inverse())
        let p = a.apply(4, 5, 6)
        let back = inv.apply(p.x, p.y, p.z)
        #expect(abs(back.x - 4) < 1e-9 && abs(back.y - 5) < 1e-9 && abs(back.z - 6) < 1e-9)
        let composed = inv.concatenating(a)
        let q = composed.apply(1, 2, 3)
        #expect(abs(q.x - 1) < 1e-9 && abs(q.y - 2) < 1e-9 && abs(q.z - 3) < 1e-9)
        #expect(VoxelAffine(rows: [[1, 0, 0, 0], [1, 0, 0, 0], [0, 0, 1, 0]]).inverse() == nil)
    }

    @Test func niftiSformIsUsedWhenPresent() throws {
        let srow: [[Float]] = [[-2, 0, 0, 90], [0, 2, 0, -126], [0, 0, 2, -72]]
        let data = ModalityFixtures.niftiBytes(
            dims: [2, 2, 2], pixdim: [1, 2, 2, 2], sform: .init(code: 1, srow: srow), values: [Float](repeating: 0, count: 8)
        )
        let vol = try ModalityFixtures.niftiVolume(data)
        let w = vol.voxelToWorld.apply(1, 1, 1)
        #expect(w.x == 88 && w.y == -124 && w.z == -70)
    }

    /// qform-only NIfTI: MIQHeader has no quaternion offsets, so they are re-read
    /// from the raw header. Quaternion (0, 0, 1) = 180° about z → x and y flip.
    @Test func niftiQformIsReadFromRawHeader() throws {
        let data = ModalityFixtures.niftiBytes(
            dims: [2, 2, 2], pixdim: [1, 3, 3, 3],
            qform: .init(code: 1, quatern: (0, 0, 1), qoffset: (10, 20, 30)), values: [Float](repeating: 0, count: 8)
        )
        let vol = try ModalityFixtures.niftiVolume(data)
        let w = vol.voxelToWorld.apply(1, 1, 1)
        #expect(abs(w.x - 7) < 1e-6 && abs(w.y - 17) < 1e-6 && abs(w.z - 33) < 1e-6)
    }

    @Test func derivedVolumeKeepsGridAndAffine() throws {
        let srow: [[Float]] = [[0, -2, 0, 5], [2, 0, 0, -1], [0, 0, 2, 3]]
        let ref = ModalityFixtures.floatVolume(width: 3, height: 2, depth: 2, geometry: .init(spacing: [2, 2, 2], srow: srow), values: (0..<12).map(Float.init))
        let derived = try #require(MIQVolume.derivedVolume(values: (0..<12).map { Float($0) * 10 }, onGridOf: ref))
        #expect(derived.voxelToWorld == ref.voxelToWorld)
        #expect(derived.voxel(x: 2, y: 1, z: 1) == 110)
        #expect(MIQVolume.derivedVolume(values: [1, 2], onGridOf: ref) == nil)
    }

    // MARK: Resampling

    @Test func identicalGridsResampleExactly() throws {
        let values = (0..<27).map { Float($0) }
        let a = ModalityFixtures.floatVolume(width: 3, height: 3, depth: 3, values: values)
        let near = try #require(OverlayResampler.resample(a, ontoGridOf: a, interpolation: .nearest))
        let tri = try #require(OverlayResampler.resample(a, ontoGridOf: a, interpolation: .trilinear))
        #expect(near == values)
        #expect(tri == values)
    }

    /// Overlay at 2 mm, reference at 1 mm, shared origin: reference voxel i sits at
    /// overlay position i/2.
    @Test func coarseOverlayUpsamples() throws {
        // Overlay value = x index (a ramp along x).
        var ov: [Float] = []
        for _ in 0..<4 { for _ in 0..<4 { for x in 0..<4 { ov.append(Float(x)) } } }
        let overlay = ModalityFixtures.floatVolume(width: 4, height: 4, depth: 4, geometry: .spacing([2, 2, 2]), values: ov)
        let reference = ModalityFixtures.floatVolume(width: 8, height: 8, depth: 8, values: [Float](repeating: 0, count: 512))
        let tri = try #require(OverlayResampler.resample(overlay, ontoGridOf: reference, interpolation: .trilinear))
        let near = try #require(OverlayResampler.resample(overlay, ontoGridOf: reference, interpolation: .nearest))
        func at(_ v: [Float], _ x: Int, _ y: Int, _ z: Int) -> Float { v[(z * 8 + y) * 8 + x] }
        #expect(at(tri, 3, 2, 2) == 1.5)
        #expect(at(tri, 4, 0, 0) == 2)
        #expect(at(near, 2, 2, 2) == 1)
        #expect(at(near, 4, 5, 6) == 2)
        // Reference x = 7 → overlay 3.5: within the half-voxel margin → edge value.
        #expect(at(tri, 7, 0, 0) == 3)
    }

    @Test func translatedOverlayLeavesOutsideValue() throws {
        // Overlay origin shifted +2 mm in x: reference voxel x ↔ overlay x - 2.
        let overlay = ModalityFixtures.floatVolume(
            width: 4, height: 1, depth: 1,
            geometry: .srow([[1, 0, 0, 2], [0, 1, 0, 0], [0, 0, 1, 0]]),
            values: [1, 2, 3, 4]
        )
        let reference = ModalityFixtures.floatVolume(width: 8, height: 1, depth: 1, values: [Float](repeating: 0, count: 8))
        let out = try #require(OverlayResampler.resample(overlay, ontoGridOf: reference, interpolation: .nearest, outsideValue: -1))
        #expect(out == [-1, -1, 1, 2, 3, 4, -1, -1])
    }

    @Test func rotatedOverlayMapsThroughWorld() throws {
        // Overlay storage x runs along world +y; reference is identity.
        let overlay = ModalityFixtures.floatVolume(
            width: 3, height: 1, depth: 1,
            geometry: .srow([[0, 1, 0, 0], [1, 0, 0, 0], [0, 0, 1, 0]]),
            values: [5, 6, 7]
        )
        let reference = ModalityFixtures.floatVolume(width: 1, height: 3, depth: 1, values: [0, 0, 0])
        let out = try #require(OverlayResampler.resample(overlay, ontoGridOf: reference, interpolation: .nearest))
        #expect(out == [5, 6, 7])
    }

    @Test func resampleRespectsCapAndCancellation() {
        let a = ModalityFixtures.floatVolume(width: 4, height: 4, depth: 4, values: [Float](repeating: 1, count: 64))
        #expect(OverlayResampler.resample(a, ontoGridOf: a, interpolation: .nearest, maxVoxels: 10) == nil)
        #expect(OverlayResampler.resample(a, ontoGridOf: a, interpolation: .nearest, isCancelled: { true }) == nil)
    }

    // MARK: Layers & compositing

    @Test func outlineModeKeepsOnlyBoundaries() throws {
        // 7×7 with a 5×5 square of label 1 at (1…5, 1…5).
        var v = [Float](repeating: 0, count: 49)
        for y in 1...5 { for x in 1...5 { v[y * 7 + x] = 1 } }
        let lut = SegmentationLut.freeSurfer
        let filled = try #require(OverlayCompositor.labelLayer(values: v, width: 7, height: 7, lut: lut, outlineOnly: false))
        let outline = try #require(OverlayCompositor.labelLayer(values: v, width: 7, height: 7, lut: lut, outlineOnly: true))
        func alphaCount(_ b: RGBABitmap) -> Int { stride(from: 3, to: b.pixels.count, by: 4).filter { b.pixels[$0] == 255 }.count }
        #expect(alphaCount(filled) == 25)
        #expect(alphaCount(outline) == 16)
        #expect(outline.pixels[(3 * 7 + 3) * 4 + 3] == 0)
        #expect(outline.pixels[(1 * 7 + 3) * 4 + 3] == 255)
    }

    @Test func compositeBlendsByAlphaAndOpacity() throws {
        let base = RGBABitmap(width: 2, height: 1, pixels: Data([100, 100, 100, 255, 100, 100, 100, 255]))
        let overlay = RGBABitmap(width: 2, height: 1, pixels: Data([255, 0, 0, 255, 0, 255, 0, 0]))
        let out = try #require(OverlayCompositor.composite(base: base, overlay: overlay, opacity: 0.5))
        #expect([UInt8](out.pixels) == [178, 50, 50, 255, 100, 100, 100, 255])
        // A smaller overlay is scaled up to the base.
        let tiny = RGBABitmap(width: 1, height: 1, pixels: Data([0, 0, 255, 255]))
        let up = try #require(OverlayCompositor.composite(base: base, overlay: tiny, opacity: 1))
        #expect([UInt8](up.pixels) == [0, 0, 255, 255, 0, 0, 255, 255])
        #expect(OverlayCompositor.composite(base: RGBABitmap(width: 2, height: 2, pixels: Data()), overlay: tiny) == nil)
    }

    @Test func endToEndLabelOverlayOnAnatomicalSlice() throws {
        let n = 4
        let anatomy = ModalityFixtures.floatVolume(
            width: n, height: n, depth: n, values: (0..<(n * n * n)).map { Float($0 % 7) * 10 + 20 }
        )
        // Label 17 in the x < 2 half of a 2 mm overlay grid covering the same FOV.
        var labels = [Float](repeating: 0, count: 8)
        for i in 0..<8 where i % 2 == 0 { labels[i] = 17 }
        // Origin 0.5 mm so the 2 mm voxel boundaries coincide with the 1 mm ones.
        let seg = ModalityFixtures.floatVolume(
            width: 2, height: 2, depth: 2,
            geometry: .init(spacing: [2, 2, 2], srow: [[2, 0, 0, 0.5], [0, 2, 0, 0.5], [0, 0, 2, 0.5]]), values: labels
        )
        let onGrid = try #require(OverlayResampler.resampledVolume(seg, ontoGridOf: anatomy, interpolation: .nearest))
        let options = RenderingOptions(lowerPercentile: 0, upperPercentile: 100)
        let base = anatomy.slice(plane: .axial, index: 1, maxDimension: 8, options: options)
        #expect(seg.overlayLabelLut().lookup(0).r == 0)
        let lut = SegmentationLut.freeSurfer
        let out = try #require(OverlayCompositor.compositeSlice(
            base: base, overlay: onGrid, plane: .axial, index: 1, options: options,
            style: .labels(lut, outlineOnly: false), opacity: 1
        ))
        #expect(out.width == base.width && out.height == base.height)
        // Label 17 (FreeSurfer Left-Hippocampus, 220 216 20) covers half the slice.
        let px = [UInt8](out.pixels)
        let hippo = stride(from: 0, to: px.count, by: 4).filter { px[$0] == 220 && px[$0 + 1] == 216 && px[$0 + 2] == 20 }.count
        #expect(hippo == out.width * out.height / 2)
    }

    @Test func scalarOverlayLayerThresholds() throws {
        let style = OverlayStyle.scalar(.diverging(limit: 4, threshold: 2))
        let layer = try #require(OverlayCompositor.layer(values: [-3, 0, 1, 3], width: 2, height: 2, style: style, toWidth: 4, toHeight: 4))
        #expect(layer.width == 4 && layer.pixels.count == 64)
        #expect(layer.pixels[3] == 255)       // -3 visible (top-left block)
        #expect(layer.pixels[2 * 4 + 3] == 0) // 0 hidden (top-right block)
    }
}
