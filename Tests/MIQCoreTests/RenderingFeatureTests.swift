import Foundation
import Testing
@testable import MIQCore

/// Builds in-memory float32 / int16 volumes for the rendering-feature tests,
/// with arbitrary values, scaling and storage strides.
private enum SyntheticVolume {
    static func header(
        dims: [Int],
        datatype: MIQDatatype,
        slope: Float = 1,
        inter: Float = 0,
        pixdim: [Float] = [1, 1, 1, 1]
    ) -> MIQHeader {
        MIQHeader(
            littleEndian: true,
            dimensions: dims,
            pixdim: pixdim,
            datatype: datatype,
            voxOffset: 0,
            sclSlope: slope,
            sclInter: inter,
            qformCode: 0,
            sformCode: 0,
            srowX: [1, 0, 0, 0],
            srowY: [0, 1, 0, 0],
            srowZ: [0, 0, 1, 0]
        )
    }

    /// Payload layout overrides for `float32`.
    struct PayloadLayout {
        /// Element strides of a MIF-style permuted layout; `nil` = canonical x-fastest.
        var strides: [Int]?
        /// Volumes actually stored in the payload; `nil` = all of them.
        var payloadVolumes: Int?
    }

    /// Float32 volume; `value(x, y, z, t)` fills it. With `layout.strides`, the payload
    /// is laid out with those element strides (a MIF-style permuted layout).
    static func float32(
        _ w: Int, _ h: Int, _ d: Int, volumes: Int = 1,
        pixdim: [Float] = [1, 1, 1, 1],
        layout: PayloadLayout = PayloadLayout(),
        _ value: (Int, Int, Int, Int) -> Float
    ) -> MIQVolume {
        let strides = layout.strides
        let payloadVolumes = layout.payloadVolumes
        let header = header(dims: volumes > 1 ? [w, h, d, volumes] : [w, h, d], datatype: .float32, pixdim: pixdim)
        let stored = payloadVolumes ?? volumes
        var floats = [Float](repeating: 0, count: w * h * d * stored)
        for t in 0..<stored {
            for z in 0..<d {
                for y in 0..<h {
                    for x in 0..<w {
                        let index: Int
                        if let s = strides {
                            index = x * s[0] + y * s[1] + z * s[2] + t * s[3]
                        } else {
                            index = ((t * d + z) * h + y) * w + x
                        }
                        floats[index] = value(x, y, z, t)
                    }
                }
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0, payloadElementStrides: strides))
    }

    static func int16(
        _ w: Int, _ h: Int, _ d: Int, slope: Float = 1, inter: Float = 0,
        _ value: (Int, Int, Int) -> Int16
    ) -> MIQVolume {
        let header = header(dims: [w, h, d], datatype: .int16, slope: slope, inter: inter)
        var raw = [Int16](repeating: 0, count: w * h * d)
        for z in 0..<d { for y in 0..<h { for x in 0..<w { raw[(z * h + y) * w + x] = value(x, y, z) } } }
        let data = raw.withUnsafeBufferPointer { Data(buffer: $0) }
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }
}

private func options(_ orientation: ViewOrientation = .stored) -> RenderingOptions {
    RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: orientation)
}

private func sameBits(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
}

// MARK: - Window presets

struct WindowPresetTests {

    @Test func presetValuesMatchRadiopaedia() {
        let expected: [WindowPreset: (Float, Float)] = [
            .brain: (80, 40), .subdural: (200, 75), .stroke: (40, 40),
            .bone: (1800, 400), .lung: (1500, -600), .softTissue: (400, 40),
        ]
        for preset in WindowPreset.fixedPresets {
            let (w, l) = expected[preset]!
            #expect(preset.width == w && preset.level == l, "\(preset)")
            let bounds = preset.bounds!
            #expect(bounds.low == l - w / 2 && bounds.high == l + w / 2, "\(preset)")
            #expect(bounds.width == w && bounds.level == l, "\(preset)")
        }
        #expect(WindowPreset.auto.bounds == nil)
        #expect(WindowPreset.fixedPresets.count == WindowPreset.allCases.count - 1)
        #expect(WindowPreset.brain.bounds == MIQIntensityWindowBounds(low: 0, high: 80))
        #expect(WindowPreset.lung.bounds == MIQIntensityWindowBounds(low: -1350, high: 150))
    }

    @Test func widthLevelLabel() {
        #expect(WindowPreset.brain.bounds!.widthLevelLabel == "W 80 / L 40")
        #expect(WindowPreset.lung.bounds!.widthLevelLabel == "W 1500 / L -600")
        #expect(MIQIntensityWindowBounds(low: 12.5, high: 250.25).widthLevelLabel == "W 238 / L 131")
        #expect(MIQIntensityWindowBounds(low: 0.1, high: 0.6).widthLevelLabel == "W 0.5 / L 0.35")
        #expect(MIQIntensityWindowBounds(low: -1, high: 1).widthLevelLabel == "W 2 / L 0")
        #expect(MIQIntensityWindowBounds(low: 1e-10, high: 2.1e-9).widthLevelLabel == "W 2e-09 / L 1.1e-09")
        #expect(MIQIntensityWindowBounds.formatWindowValue(.nan) == "–")
        #expect(MIQIntensityWindowBounds.formatWindowValue(-0.0) == "0")
        #expect(MIQIntensityWindowBounds.formatWindowValue(-2.25) == "-2.2" || MIQIntensityWindowBounds.formatWindowValue(-2.25) == "-2.3")
        #expect(MIQIntensityWindowBounds.formatWindowValue(3e20) == "3e+20")
    }

    @Test func looksLikeCTFromMinimumOrIntercept() {
        // Signed HU storage with air in the field of view.
        let signed = SyntheticVolume.header(dims: [4, 4, 4], datatype: .int16)
        #expect(WindowPreset.looksLikeCT(header: signed, sampleMin: -1024))
        #expect(WindowPreset.looksLikeCT(header: signed, sampleMin: -1000))
        #expect(WindowPreset.looksLikeCT(header: signed, sampleMin: -1074))
        #expect(!WindowPreset.looksLikeCT(header: signed, sampleMin: -1075))
        #expect(!WindowPreset.looksLikeCT(header: signed, sampleMin: 0))
        #expect(!WindowPreset.looksLikeCT(header: signed, sampleMin: nil))
        #expect(!WindowPreset.looksLikeCT(header: signed, sampleMin: .nan))
        // Documented miss: -2048 / -3024 padding.
        #expect(!WindowPreset.looksLikeCT(header: signed, sampleMin: -3024))

        // Unsigned storage with the DICOM rescale intercept.
        let unsigned = SyntheticVolume.header(dims: [4, 4, 4], datatype: .uint16, slope: 1, inter: -1024)
        #expect(WindowPreset.looksLikeCT(header: unsigned, sampleMin: nil))
        let unsetSlope = SyntheticVolume.header(dims: [4, 4, 4], datatype: .uint16, slope: 0, inter: -1024)
        #expect(WindowPreset.looksLikeCT(header: unsetSlope, sampleMin: nil))
        let scaled = SyntheticVolume.header(dims: [4, 4, 4], datatype: .uint16, slope: 2.5, inter: -1024)
        #expect(!WindowPreset.looksLikeCT(header: scaled, sampleMin: nil))

        // Float data is never classified, whatever its minimum.
        let float = SyntheticVolume.header(dims: [4, 4, 4], datatype: .float32, inter: -1024)
        #expect(!WindowPreset.looksLikeCT(header: float, sampleMin: -1024))
        let rgb = SyntheticVolume.header(dims: [4, 4, 4], datatype: .rgb24)
        #expect(!WindowPreset.looksLikeCT(header: rgb, sampleMin: -1024))
    }

    @Test func presetBoundsRenderThroughSlicePipeline() {
        // Stored int16 HU; brain window [0, 80] maps 0 → black, 40 → mid, 80+ → white.
        let volume = SyntheticVolume.int16(3, 1, 1) { x, _, _ in [0, 40, 200][x] }
        let image = volume.slice(plane: .axial, index: 0, maxDimension: 3, options: options(), windowBounds: WindowPreset.brain.bounds)
        #expect(image.pixels == [0, 128, 255])
    }
}

// MARK: - Shared 4D window

struct SharedVolumeWindowTests {

    @Test func sampleIndicesAreEvenlySpaced() {
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 0) == [])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 5, maxSamples: 0) == [])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 1) == [0])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 5) == [0, 1, 2, 3, 4])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 8) == Array(0..<8))
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 100, maxSamples: 1) == [0])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 100, maxSamples: 2) == [0, 99])
        #expect(MIQVolume.sharedWindowSampleIndices(volumeCount: 15, maxSamples: 8) == [0, 2, 4, 6, 8, 10, 12, 14])
        for n in 1...300 {
            for m in 1...12 {
                let idx = MIQVolume.sharedWindowSampleIndices(volumeCount: n, maxSamples: m)
                #expect(idx.count == min(n, m))
                #expect(idx.first == 0)
                if m >= 2 { #expect(idx.last == n - 1) }
                #expect(zip(idx, idx.dropFirst()).allSatisfy { $0 < $1 }, "n \(n) m \(m)")
            }
        }
    }

    @Test func threeDimensionalMatchesFixedCenterWindow() {
        let volume = SyntheticVolume.float32(9, 7, 5) { x, y, z, _ in Float(x * 3 + y * 5 + z * 7) }
        let shared = volume.sharedVolumeWindow(options: options())
        #expect(shared != nil)
        #expect(shared == volume.fixedCenterWindow(volumeIndex: 0, options: options()))
    }

    @Test func poolsAcrossTimepoints() {
        // Each timepoint t holds values in [100t, 100t + 50); per-volume windows sit
        // inside their own band, the shared one spans the series.
        let volume = SyntheticVolume.float32(8, 8, 8, volumes: 20) { x, y, z, t in
            Float(100 * t) + Float((x + y * 2 + z * 3) % 50)
        }
        let first = volume.fixedCenterWindow(volumeIndex: 0, options: options())!
        let last = volume.fixedCenterWindow(volumeIndex: 19, options: options())!
        let shared = volume.sharedVolumeWindow(options: options())!
        #expect(first.high < 100)
        #expect(last.low >= 1900)
        #expect(shared.low < 200)
        #expect(shared.high > 1800)
        // One sampled volume degenerates to that volume's own window.
        #expect(volume.sharedVolumeWindow(maxSampledVolumes: 1, options: options()) == first)
    }

    @Test func cappedPayloadOnlySamplesLoadedVolumes() {
        // Header says 10 timepoints; only 2 are in the payload (volume-0-style cap).
        let volume = SyntheticVolume.float32(6, 6, 6, volumes: 10, layout: .init(payloadVolumes: 2)) { x, y, z, t in
            Float(1000 + 10 * t + x + y + z)
        }
        #expect(volume.loadedVolumeCount == 2)
        let shared = volume.sharedVolumeWindow(options: options())!
        // Zeros from never-loaded volumes would have dragged `low` to 0.
        #expect(shared.low >= 1000)
    }

    @Test func rgbHasNoSharedWindow() {
        let header = SyntheticVolume.header(dims: [2, 2, 2], datatype: .rgb24)
        let volume = MIQVolume(image: MIQImage(header: header, storage: Data(count: 24), payloadOffset: 0))
        #expect(volume.sharedVolumeWindow(options: options()) == nil)
    }
}

// MARK: - Projection

struct ProjectionTests {

    private static let orientations: [ViewOrientation] = [.stored, .neurological, .radiological]

    /// Every voxel of slice `k` along `axis` is the extreme of its ray, so the
    /// projection must equal that regular slice exactly — pixel layout included.
    @Test func projectionMatchesTheExtremeSliceInEveryPlaneAndOrientation() throws {
        let (w, h, d) = (7, 5, 4)
        for mode in ProjectionMode.allCases {
            for axis in 0..<3 {
                let k = [w, h, d][axis] / 2 + (axis == 0 ? 1 : 0)
                let volume = SyntheticVolume.float32(w, h, d, pixdim: [1, 1, 1.5, 2]) { x, y, z, _ in
                    let c = [x, y, z]
                    let base = Float(x * 13 + y * 7 + z * 3) // distinct per voxel
                    if c[axis] == k { return mode == .mip ? base + 1000 : base - 1000 }
                    return base
                }
                for orientation in Self.orientations {
                    let opts = options(orientation)
                    for plane in SlicePlane.allCases {
                        let geometry = volume.sliceGeometry(for: plane, options: opts)
                        guard geometry.sliceAxis == axis else { continue }
                        let projected = try #require(volume.projectedValues(plane: plane, mode: mode, options: opts))
                        let slice = try #require(volume.sliceValues(plane: plane, index: k, options: opts))
                        #expect(sameBits(projected, slice), "\(mode) axis \(axis) \(plane) \(orientation)")

                        // And the rendered image is pixel-identical to the slice
                        // rendered with the same window.
                        let bounds = MIQIntensityWindowBounds(low: -1000, high: 1200)
                        let image = try #require(volume.projection(plane: plane, mode: mode, options: opts, windowBounds: bounds))
                        let regular = volume.slice(plane: plane, index: k, options: opts, windowBounds: bounds)
                        #expect(image.width == regular.width && image.height == regular.height)
                        #expect(image.pixels == regular.pixels, "\(mode) \(plane) \(orientation) image")
                    }
                }
            }
        }
    }

    @Test func knownExtremesAlongEachAxis() throws {
        // 2×2×2, value = x + 2y + 4z (0…7). Axial (z) MIP picks z=1: x+2y+4.
        let volume = SyntheticVolume.float32(2, 2, 2) { x, y, z, _ in Float(x + 2 * y + 4 * z) }
        let opts = options()
        for plane in SlicePlane.allCases {
            let geometry = volume.sliceGeometry(for: plane, options: opts)
            let mip = try #require(volume.projectedValues(plane: plane, mode: .mip, options: opts))
            let minip = try #require(volume.projectedValues(plane: plane, mode: .minip, options: opts))
            let weight = [1, 2, 4][geometry.sliceAxis]
            let high = try #require(volume.sliceValues(plane: plane, index: 1, options: opts))
            let low = try #require(volume.sliceValues(plane: plane, index: 0, options: opts))
            #expect(mip == high)
            #expect(minip == low)
            #expect(zip(mip, minip).allSatisfy { $0 - $1 == Float(weight) })
        }
    }

    @Test func ignoresNonFiniteVoxels() throws {
        // A 1×1×5 column along z: [NaN, 3, +Inf, -2, -Inf] → MIP 3, MinIP -2.
        let column: [Float] = [.nan, 3, .infinity, -2, -.infinity]
        let volume = SyntheticVolume.float32(1, 1, 5) { _, _, z, _ in column[z] }
        #expect(volume.projectedValues(plane: .axial, mode: .mip, options: options()) == [3])
        #expect(volume.projectedValues(plane: .axial, mode: .minip, options: options()) == [-2])

        // An all-NaN ray stays NaN and renders black.
        let empty = SyntheticVolume.float32(2, 1, 3) { x, _, z, _ in x == 0 ? .nan : Float(z) }
        let values = try #require(empty.projectedValues(plane: .axial, mode: .mip, options: options()))
        #expect(values[0].isNaN && values[1] == 2)
        let image = try #require(empty.projection(plane: .axial, mode: .mip, maxDimension: 3, options: options(), windowBounds: .init(low: 0, high: 2)))
        #expect(image.pixels == [0, 255])
    }

    @Test func appliesScalingAndHonoursTimepoint() throws {
        let scaled = SyntheticVolume.int16(2, 2, 3, slope: 2, inter: -1024) { x, y, z in Int16(x + y + z * 10) }
        let mip = try #require(scaled.projectedValues(plane: .axial, mode: .mip, options: options()))
        let top = try #require(scaled.sliceValues(plane: .axial, index: 2, options: options()))
        #expect(mip == top)
        #expect(mip.contains(Float(20 * 2 - 1024)))

        let series = SyntheticVolume.float32(3, 3, 3, volumes: 4) { x, y, z, t in Float(t * 100 + x + y + z) }
        for t in 0..<4 {
            let p = try #require(series.projectedValues(plane: .coronal, mode: .mip, volumeIndex: t, options: options()))
            #expect(p.min()! >= Float(t * 100))
            #expect(p.max()! == Float(t * 100 + 6))
        }
        // Out-of-range timepoint reads as zeros, like a slice.
        #expect(series.projectedValues(plane: .axial, mode: .mip, volumeIndex: 9, options: options())!.allSatisfy { $0 == 0 })
    }

    @Test func stridedLayoutMatchesCanonical() throws {
        // Same volume stored canonically and z-fastest (MIF-style strides).
        let (w, h, d) = (4, 3, 5)
        let f: (Int, Int, Int, Int) -> Float = { x, y, z, _ in Float((x * 7 + y * 11 + z * 5) % 17) }
        let canonical = SyntheticVolume.float32(w, h, d, f)
        let strided = SyntheticVolume.float32(w, h, d, layout: .init(strides: [d, d * w, 1, w * h * d]), f)
        for mode in ProjectionMode.allCases {
            for plane in SlicePlane.allCases {
                let a = try #require(canonical.projectedValues(plane: plane, mode: mode, options: options()))
                let b = try #require(strided.projectedValues(plane: plane, mode: mode, options: options()))
                #expect(a == b, "\(mode) \(plane)")
            }
        }
    }

    @Test func sampleCapVisitsEvenlySpacedPositions() throws {
        // Value = z along a 10-deep column: a cap of 4 visits z = 0, 3, 6, 9.
        let volume = SyntheticVolume.float32(1, 1, 10) { _, _, z, _ in z == 5 ? 100 : Float(z) }
        #expect(volume.projectedValues(plane: .axial, mode: .mip, options: options()) == [100])
        #expect(volume.projectedValues(plane: .axial, mode: .mip, options: options(), maxSamplesAlongAxis: 4) == [9])
        #expect(volume.projectedValues(plane: .axial, mode: .minip, options: options(), maxSamplesAlongAxis: 4) == [0])
    }

    @Test func outputUsesSlicePipelineResampling() throws {
        // Anisotropic voxels: the projection must be resampled like a regular slice.
        let volume = SyntheticVolume.float32(8, 8, 4, pixdim: [1, 1, 1, 3]) { x, y, z, _ in Float(x + y + z) }
        for plane in SlicePlane.allCases {
            let p = try #require(volume.projection(plane: plane, mode: .mip, maxDimension: 64, options: options()))
            let s = volume.slice(plane: plane, index: 0, maxDimension: 64, options: options())
            #expect(p.width == s.width && p.height == s.height, "\(plane)")
            guard case .grayscale = p else { Issue.record("expected grayscale"); continue }
        }
    }

    @Test func rgbReturnsNil() {
        let header = SyntheticVolume.header(dims: [2, 2, 2], datatype: .rgb24)
        let volume = MIQVolume(image: MIQImage(header: header, storage: Data(count: 24), payloadOffset: 0))
        #expect(volume.projection(plane: .axial, mode: .mip, options: options()) == nil)
    }
}

// MARK: - Gray8 output

struct Gray8BitmapTests {

    @Test func grayscaleProducesSingleChannel() throws {
        let image = GrayscaleImage(width: 3, height: 2, pixels: [0, 7, 128, 255, 1, 2])
        let gray = try #require(image.makeGray8())
        #expect(gray.width == 3 && gray.height == 2)
        #expect(gray.pixels == Data([0, 7, 128, 255, 1, 2]))
        let viaSlice = try #require(SliceImage.grayscale(image).makeGray8())
        #expect(viaSlice.pixels == gray.pixels)
    }

    @Test func matchesRGBARedChannel() throws {
        var seed: UInt32 = 12345
        let pixels = (0..<(64 * 48)).map { _ -> UInt8 in
            seed = seed &* 1_103_515_245 &+ 12345
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
        let slice = SliceImage.grayscale(GrayscaleImage(width: 64, height: 48, pixels: pixels))
        let rgba = try #require(slice.rgbaBitmap())
        let gray = try #require(slice.makeGray8())
        #expect(gray.pixels.count * 4 == rgba.pixels.count)
        let red = stride(from: 0, to: rgba.pixels.count, by: 4).map { rgba.pixels[rgba.pixels.startIndex + $0] }
        #expect(Data(red) == gray.pixels)
    }

    @Test func rejectsRGBAndMismatchedBuffers() {
        #expect(SliceImage.rgb(RGBImage(width: 1, height: 1, pixels: [1, 2, 3])).makeGray8() == nil)
        #expect(GrayscaleImage(width: 2, height: 2, pixels: [1, 2, 3]).makeGray8() == nil)
        #expect(GrayscaleImage(width: 0, height: 0, pixels: []).makeGray8() == nil)
    }
}

// MARK: - Config

struct RenderingConfigTests {
    @Test func defaultsAreConservative() {
        #expect(MIQConfig.Defaults.ctWindowPreset == WindowPreset.auto.rawValue)
        #expect(MIQConfig.Defaults.ctPresetAutoDetect == false)
        #expect(WindowPreset(rawValue: MIQConfig.Defaults.ctWindowPreset) == .auto)
    }
}
