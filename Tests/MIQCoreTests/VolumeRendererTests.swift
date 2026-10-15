import Foundation
import Testing
@testable import MIQCore

/// CPU reference ray caster (`VolumeRenderer`, backend `.cpu`). Geometry
/// convention under test (see `VolumeRenderCamera`): the anterior view
/// (azimuth 0) shows the patient's right on the screen's LEFT and superior at
/// the TOP; azimuth 180 (posterior) shows right on the screen's right.
struct VolumeRendererTests {

    // MARK: - Helpers

    private static var cpu: VolumeRenderOptions {
        var o = VolumeRenderOptions()
        o.backend = .cpu
        return o
    }

    /// Float32 MIQVolume with storage dims `dims`, spacing, optional frame, and
    /// a value per storage voxel.
    private static func makeVolume(
        dims: (Int, Int, Int),
        spacing: (Float, Float, Float) = (1, 1, 1),
        frame: OrientationFrame? = nil,
        value: (Int, Int, Int) -> Float
    ) -> MIQVolume {
        var data = Data(capacity: dims.0 * dims.1 * dims.2 * 4)
        for z in 0..<dims.2 {
            for y in 0..<dims.1 {
                for x in 0..<dims.0 {
                    var bits = value(x, y, z).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                }
            }
        }
        let header = MIQHeader(
            littleEndian: true,
            dimensions: [dims.0, dims.1, dims.2, 1],
            pixdim: [1, spacing.0, spacing.1, spacing.2],
            datatype: .float32,
            voxOffset: 0,
            sclSlope: 0,
            sclInter: 0,
            qformCode: 0,
            sformCode: 0,
            srowX: [], srowY: [], srowZ: [],
            orientationFrame: frame
        )
        return MIQVolume(image: MIQImage(header: header, storage: data, payloadOffset: 0))
    }

    private static let ras = OrientationFrame(
        axes: [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true),
        ],
        source: .sform
    )

    /// LPS storage (DICOM-style): +x = L, +y = P, +z = S.
    private static let lps = OrientationFrame(
        axes: [
            StorageAxisOrientation(axis: .rightLeft, positive: false),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: false),
            StorageAxisOrientation(axis: .superiorInferior, positive: true),
        ],
        source: .sform
    )

    private static func luma(_ b: RGBABitmap, _ x: Int, _ y: Int) -> Int {
        let o = (y * b.width + x) * 4
        let p = [UInt8](b.pixels)
        return (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
    }

    /// Bounding box (minX, maxX, minY, maxY), inclusive, of pixels satisfying `pred`.
    private static func bbox(_ b: RGBABitmap, _ pred: (Int) -> Bool) -> (Int, Int, Int, Int)? {
        let p = [UInt8](b.pixels)
        var box: (Int, Int, Int, Int)? = nil
        for y in 0..<b.height {
            for x in 0..<b.width {
                let o = (y * b.width + x) * 4
                let l = (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
                guard pred(l) else { continue }
                if let c = box {
                    box = (min(c.0, x), max(c.1, x), min(c.2, y), max(c.3, y))
                } else {
                    box = (x, x, y, y)
                }
            }
        }
        return box
    }

    /// Centroid x of bright pixels (luma > 127).
    private static func brightCentroidX(_ b: RGBABitmap) -> Double {
        let p = [UInt8](b.pixels)
        var sum = 0.0, n = 0.0
        for y in 0..<b.height {
            for x in 0..<b.width {
                let o = (y * b.width + x) * 4
                if p[o] > 127 { sum += Double(x); n += 1 }
            }
        }
        return n > 0 ? sum / n : -1
    }

    private static func fnv1a(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// 32³ RAS cube phantom: value 100 in x 8..<16, y 12..<20, z 20..<28.
    private static func cubeVolume(inside: Float = 100, outside: Float = 0) -> MIQVolume {
        makeVolume(dims: (32, 32, 32), frame: ras) { x, y, z in
            (8..<16).contains(x) && (12..<20).contains(y) && (20..<28).contains(z) ? inside : outside
        }
    }

    // MARK: - Projection geometry

    @Test
    func cubeMIPFromFrontIsSquareOfExpectedSizeAndPosition() async throws {
        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        #expect(grid.orientationKnown)
        // zoom √3 on a 32 mm cube (diagonal 32√3) at 128 px → exactly 0.25 mm/px.
        let image = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(azimuth: 0, elevation: 0, zoom: Float(3).squareRoot()),
            mode: .mip, window: MIQIntensityWindowBounds(low: 0, high: 100),
            width: 128, height: 128, options: Self.cpu
        )
        #expect(image.width == 128 && image.height == 128)
        #expect(image.pixels.count == 128 * 128 * 4)
        // World x ∈ [−8, 0] (the patient-LEFT half) → screen u = −x ∈ [0, 8] mm
        // → columns 64…95; world z ∈ [4, 12] → rows 16…47.
        let box = try #require(Self.bbox(image) { $0 > 127 })
        #expect(abs(box.0 - 64) <= 1 && abs(box.1 - 95) <= 1, "columns \(box.0)…\(box.1)")
        #expect(abs(box.2 - 16) <= 1 && abs(box.3 - 47) <= 1, "rows \(box.2)…\(box.3)")
        // Square: equal width and height.
        #expect(abs((box.1 - box.0) - (box.3 - box.2)) <= 1)
        #expect(Self.luma(image, 80, 32) == 255)
        #expect(Self.luma(image, 40, 32) == 0)
    }

    @Test
    func minIPShowsDarkCubeInsideBrightVolume() async throws {
        let grid = VolumeRenderGrid(volume: Self.cubeVolume(inside: 0, outside: 100))
        let image = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .minIP, window: MIQIntensityWindowBounds(low: 0, high: 100),
            width: 128, height: 128, options: Self.cpu
        )
        #expect(Self.luma(image, 80, 32) == 0)          // through the dark cube
        #expect(Self.luma(image, 40, 100) == 255)       // bright volume elsewhere
        let dark = try #require(Self.bbox(image) { $0 < 128 })
        // Volume fills the frame at this zoom, so only the cube is dark.
        #expect(abs(dark.0 - 64) <= 1 && abs(dark.1 - 95) <= 1)
        #expect(abs(dark.2 - 16) <= 1 && abs(dark.3 - 47) <= 1)
        // Contrast: MIP of the same phantom is uniformly bright there.
        let mip = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .mip, window: MIQIntensityWindowBounds(low: 0, high: 100),
            width: 128, height: 128, options: Self.cpu
        )
        #expect(Self.luma(mip, 80, 32) == 255)
    }

    @Test
    func raysMissingTheVolumeShowTheBackground() async throws {
        var options = Self.cpu
        options.background = VolumeRenderColor(r: 10, g: 20, b: 30)
        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        let image = try await VolumeRenderer.render(
            grid: grid, mode: .mip, window: nil, width: 64, height: 64, options: options
        )
        // At zoom 1 the frame spans the full box diagonal, so the corner misses the box.
        let p = [UInt8](image.pixels)
        #expect(Array(p[0..<4]) == [10, 20, 30, 255])
    }

    // MARK: - Orientation

    /// A bright blob on the patient's RIGHT (+R), low A, high S.
    private static func rightBlob(frame: OrientationFrame) -> MIQVolume {
        makeVolume(dims: (32, 32, 32), frame: frame) { x, y, z in
            // Convert storage → RAS index for the frame under test.
            let rx = frame == lps ? 31 - x : x
            let ry = frame == lps ? 31 - y : y
            return (24..<30).contains(rx) && (12..<20).contains(ry) && (14..<18).contains(z) ? 100 : 0
        }
    }

    @Test
    func patientRightAppearsOnScreenLeftInAnteriorView() async throws {
        let grid = VolumeRenderGrid(volume: Self.rightBlob(frame: Self.ras))
        let window = MIQIntensityWindowBounds(low: 0, high: 100)
        let anterior = try await VolumeRenderer.render(
            grid: grid, camera: .anterior, mode: .mip, window: window, width: 64, height: 64, options: Self.cpu
        )
        #expect(Self.brightCentroidX(anterior) < 32)
        let posterior = try await VolumeRenderer.render(
            grid: grid, camera: .posterior, mode: .mip, window: window, width: 64, height: 64, options: Self.cpu
        )
        #expect(Self.brightCentroidX(posterior) > 32)
        // Right-lateral view looks straight at the +R face: blob projects near
        // the centre column (A range 12..<20 straddles 0).
        let right = try await VolumeRenderer.render(
            grid: grid, camera: .right, mode: .mip, window: window, width: 64, height: 64, options: Self.cpu
        )
        #expect(abs(Self.brightCentroidX(right) - 31.5) < 3)
    }

    @Test
    func anteriorAppearsOnScreenRightInRightLateralView() async throws {
        let volume = Self.makeVolume(dims: (32, 32, 32), frame: Self.ras) { x, y, z in
            (12..<20).contains(x) && (26..<31).contains(y) && (12..<20).contains(z) ? 100 : 0
        }
        let image = try await VolumeRenderer.render(
            volume: volume, camera: .right, mode: .mip,
            window: MIQIntensityWindowBounds(low: 0, high: 100), width: 64, height: 64, options: Self.cpu
        )
        #expect(Self.brightCentroidX(image) > 32)
    }

    @Test
    func superiorAppearsAtTop() async throws {
        let volume = Self.makeVolume(dims: (32, 32, 32), frame: Self.ras) { x, y, z in
            (12..<20).contains(x) && (12..<20).contains(y) && z >= 26 ? 100 : 0
        }
        let image = try await VolumeRenderer.render(
            volume: volume, mode: .mip,
            window: MIQIntensityWindowBounds(low: 0, high: 100), width: 64, height: 64, options: Self.cpu
        )
        let box = try #require(Self.bbox(image) { $0 > 127 })
        #expect(box.3 < 32)
    }

    @Test
    func lpsAndRasStorageOfTheSameAnatomyRenderIdentically() async throws {
        let window = MIQIntensityWindowBounds(low: 0, high: 100)
        let camera = VolumeRenderCamera(azimuth: 37, elevation: 12, zoom: 1.2)
        let a = try await VolumeRenderer.render(
            volume: Self.rightBlob(frame: Self.ras), camera: camera, mode: .dvr,
            window: window, width: 64, height: 64, options: Self.cpu
        )
        let b = try await VolumeRenderer.render(
            volume: Self.rightBlob(frame: Self.lps), camera: camera, mode: .dvr,
            window: window, width: 64, height: 64, options: Self.cpu
        )
        #expect(a.pixels == b.pixels)
        #expect(Self.brightCentroidX(a) >= 0)
    }

    @Test
    func unknownOrientationTreatsStorageAsRAS() {
        let volume = Self.makeVolume(dims: (4, 4, 4)) { x, _, _ in Float(x) }
        let grid = VolumeRenderGrid(volume: volume)
        #expect(!grid.orientationKnown)
        #expect(grid.storage.values[3] == 3)
    }

    // MARK: - Grid construction

    @Test
    func gridDownsamplesPerAxisPreservingPhysicalExtent() {
        let volume = Self.makeVolume(dims: (200, 50, 10), spacing: (0.5, 1, 3), frame: Self.lps) { x, _, _ in Float(x) }
        let grid = VolumeRenderGrid(volume: volume, maxDimension: 100)
        #expect(grid.dimensions.x == 100 && grid.dimensions.y == 50 && grid.dimensions.z == 10)
        #expect(grid.spacing.x == 1 && grid.spacing.y == 1 && grid.spacing.z == 3)
        // LPS: RAS x index 0 is storage x 199/198 (averaged) — the rightmost voxels.
        #expect(grid.storage.values[0] == 198.5)
        #expect(grid.storage.values[99] == 0.5)
    }

    @Test
    func labelGridCompactsLabelsAndNeverBlends() {
        let volume = Self.makeVolume(dims: (8, 8, 8), frame: Self.ras) { x, _, _ in
            x < 3 ? 0 : (x < 6 ? 17 : 1002)
        }
        let grid = VolumeRenderGrid(volume: volume, maxDimension: 4, asLabels: true)
        #expect(grid.isLabelGrid)
        #expect(grid.labels == [0, 17, 1002])
        let allowed: Set<Float> = [0, 1, 2]
        #expect(grid.storage.values.allSatisfy { allowed.contains($0) })
        #expect(grid.storage.occupancy?.count == grid.voxelCount)
        #expect(grid.suggestedWindow == nil)
    }

    /// The raw-payload reader must reproduce `MIQVolume.voxel` bit for bit:
    /// every supported datatype, both endiannesses, slope/intercept, permuted
    /// strides, an unaligned payload offset and a truncated payload.
    @Test(arguments: [MIQDatatype.uint8, .int8, .int16, .uint16, .int32, .uint32, .float32, .float64, .int64, .rgb24])
    func fastGridReaderMatchesVoxelAccessor(datatype: MIQDatatype) {
        let dims = (9, 7, 5, 2)
        let bpv = datatype.bytesPerVoxel
        let elements = dims.0 * dims.1 * dims.2 * dims.3
        for littleEndian in [true, false] {
            for strided in [false, true] {
                var rng: UInt64 = 0x9E37_79B9 &+ UInt64(bpv)
                var payload = Data((0..<(elements * bpv - 3)).map { _ -> UInt8 in
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    return UInt8(truncatingIfNeeded: rng >> 41)
                })
                payload.insert(contentsOf: [1, 2, 3, 4, 5, 6, 7], at: 0)  // unaligned offset 7
                let header = MIQHeader(
                    littleEndian: littleEndian, dimensions: [dims.0, dims.1, dims.2, dims.3],
                    pixdim: [1, 1, 1, 1], datatype: datatype, voxOffset: 0,
                    sclSlope: datatype == .float32 || datatype == .float64 ? 0 : 0.5, sclInter: -3,
                    qformCode: 0, sformCode: 0, srowX: [], srowY: [], srowZ: [],
                    orientationFrame: Self.lps
                )
                // z-fastest permuted layout when strided.
                let strides: [Int]? = strided ? [dims.2, dims.2 * dims.0, 1, dims.0 * dims.1 * dims.2] : nil
                let volume = MIQVolume(image: MIQImage(header: header, storage: payload, payloadOffset: 7, payloadElementStrides: strides))
                for maxDim in [100, 4] {
                    for asLabels in [false, true] {
                        let fast = VolumeRenderGrid(volume: volume, volumeIndex: 1, maxDimension: maxDim, asLabels: asLabels, useFastReader: true)
                        let slow = VolumeRenderGrid(volume: volume, volumeIndex: 1, maxDimension: maxDim, asLabels: asLabels, useFastReader: false)
                        #expect(fast.storage.values == slow.storage.values, "\(datatype) le=\(littleEndian) strided=\(strided) max=\(maxDim) labels=\(asLabels)")
                        #expect(fast.labels == slow.labels)
                    }
                }
            }
        }
    }

    @Test
    func nonFiniteVoxelsBecomeZero() {
        let volume = Self.makeVolume(dims: (2, 1, 1)) { x, _, _ in x == 0 ? .nan : 5 }
        let grid = VolumeRenderGrid(volume: volume)
        #expect(grid.storage.values == [0, 5])
        #expect(grid.valueRange.min == 0 && grid.valueRange.max == 5)
    }

    // MARK: - DVR

    @Test
    func dvrAccumulatedOpacityIsMonotonicInThickness() async throws {
        var options = Self.cpu
        options.shading = false
        options.opacityScale = 0.1
        var previous = -1
        var values: [Int] = []
        for thickness in [1, 2, 4, 8, 16, 32] {
            // Slab along A (the anterior viewing axis), full extent in R and S.
            let volume = Self.makeVolume(dims: (32, 32, 32), frame: Self.ras) { _, y, _ in
                y < thickness ? 100 : 0
            }
            let image = try await VolumeRenderer.render(
                volume: volume, mode: .dvr, window: MIQIntensityWindowBounds(low: 0, high: 100),
                width: 32, height: 32, options: options
            )
            let center = Self.luma(image, 16, 16)
            #expect(center >= previous, "thickness \(thickness): \(center) < \(previous)")
            previous = center
            values.append(center)
        }
        #expect(values.first! < values.last!)
        #expect(values.last! > 200)   // thick slab approaches opaque white
    }

    @Test
    func dvrIsMonotonicInOpacityScaleAndStepCorrected() async throws {
        let volume = Self.makeVolume(dims: (24, 24, 24), frame: Self.ras) { _, y, _ in y < 6 ? 100 : 0 }
        let grid = VolumeRenderGrid(volume: volume)
        let window = MIQIntensityWindowBounds(low: 0, high: 100)
        var previous = -1
        for scale: Float in [0.01, 0.05, 0.1, 0.3, 1] {
            var options = Self.cpu
            options.shading = false
            options.opacityScale = scale
            let image = try await VolumeRenderer.render(grid: grid, mode: .dvr, window: window, width: 24, height: 24, options: options)
            let c = Self.luma(image, 12, 12)
            #expect(c >= previous)
            previous = c
        }
        // Opacity correction: halving the step leaves the look nearly unchanged.
        var coarse = Self.cpu
        coarse.shading = false
        var fine = coarse
        fine.sampleSpacing = 0.5
        let a = try await VolumeRenderer.render(grid: grid, mode: .dvr, window: window, width: 24, height: 24, options: coarse)
        let b = try await VolumeRenderer.render(grid: grid, mode: .dvr, window: window, width: 24, height: 24, options: fine)
        #expect(abs(Self.luma(a, 12, 12) - Self.luma(b, 12, 12)) <= 12)
    }

    @Test
    func shadingDarkensObliqueSurfacesOnly() async throws {
        // A sphere: centre faces the headlight (bright), the limb is oblique (darker).
        let volume = Self.makeVolume(dims: (32, 32, 32), frame: Self.ras) { x, y, z in
            let dx = Float(x) - 15.5, dy = Float(y) - 15.5, dz = Float(z) - 15.5
            return dx * dx + dy * dy + dz * dz < 100 ? 100 : 0
        }
        var options = Self.cpu
        options.opacityScale = 1
        let image = try await VolumeRenderer.render(
            volume: volume, mode: .dvr, window: MIQIntensityWindowBounds(low: 0, high: 100),
            width: 64, height: 64, options: options
        )
        let centre = Self.luma(image, 32, 32)
        let limb = Self.luma(image, 32 + 10, 32)  // ~0.9 R from the centre
        #expect(centre > limb)
        #expect(limb > 0)
    }

    // MARK: - Labels

    @Test
    func labelModeUsesTheColorMap() async throws {
        let volume = Self.makeVolume(dims: (32, 32, 32), frame: Self.ras) { x, y, z in
            if (8..<16).contains(x) && (12..<20).contains(y) && (20..<28).contains(z) { return 5 }
            if (20..<28).contains(x) && (12..<20).contains(y) && (4..<12).contains(z) { return 9 }
            return 0
        }
        var options = Self.cpu
        options.shading = false
        options.labelOpacity = 1
        options.labelColor = { label in
            label == 5 ? VolumeRenderColor(r: 255, g: 0, b: 0) : VolumeRenderColor(r: 0, g: 0, b: 255, a: 0)
        }
        let grid = VolumeRenderGrid(volume: volume, asLabels: true)
        let image = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .labels, window: nil, width: 128, height: 128, options: options
        )
        let p = [UInt8](image.pixels)
        let o = (32 * 128 + 80) * 4
        #expect(Array(p[o..<o + 4]) == [255, 0, 0, 255])
        // Label 9 has alpha 0 → hidden; its screen location (world x ∈ [4,12] → u ∈ [−12,−4],
        // z ∈ [−12,−4]) shows background.
        let h = (96 * 128 + 32) * 4
        #expect(Array(p[h..<h + 4]) == [0, 0, 0, 255])
        // Shaded default palette also renders (non-black) through the label.
        let shaded = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .labels, window: nil, width: 128, height: 128, options: Self.cpu
        )
        #expect(Self.luma(shaded, 80, 32) > 0)
        #expect(Self.luma(shaded, 32, 96) > 0)
    }

    @Test
    func segmentationLutAdapterMatchesSliceColors() {
        let lut = SegmentationLut.freeSurfer
        let color = lut.volumeLabelColorMap(17)
        let expected = lut.lookup(17)
        #expect(color == VolumeRenderColor(r: expected.r, g: expected.g, b: expected.b, a: 255))
    }

    // MARK: - Errors, cancellation, determinism

    @Test
    func invalidRequestsThrow() async {
        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        await #expect(throws: VolumeRenderError.invalidOutputSize) {
            _ = try await VolumeRenderer.render(grid: grid, mode: .mip, window: nil, width: 0, height: 10, options: Self.cpu)
        }
        await #expect(throws: VolumeRenderError.notALabelGrid) {
            _ = try await VolumeRenderer.render(grid: grid, mode: .labels, window: nil, options: Self.cpu)
        }
    }

    @Test
    func asyncRenderHonoursTaskCancellation() async {
        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        var options = Self.cpu
        options.sampleSpacing = 0.05   // deliberately slow: ~20 samples per voxel
        let task = Task {
            try await VolumeRenderer.render(grid: grid, mode: .dvr, window: nil, width: 1024, height: 1024, options: options)
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test
    func synchronousRenderHonoursCancellationClosure() {
        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        let calls = StopFlag()
        #expect(throws: CancellationError.self) {
            _ = try VolumeRenderer.renderSynchronously(
                grid: grid, mode: .mip, window: nil, width: 256, height: 256, options: Self.cpu,
                isCancelled: { calls.set(); return true }
            )
        }
        #expect(calls.isSet)
    }

    @Test
    func cpuOutputIsDeterministicAcrossRunsAndEntryPoints() async throws {
        let volume = Self.makeVolume(dims: (40, 36, 30), spacing: (1, 1.2, 1.5), frame: Self.lps) { x, y, z in
            let dx = Float(x) - 18, dy = Float(y) - 20, dz = Float(z) - 14
            return max(0, 120 - (dx * dx + dy * dy + dz * dz).squareRoot() * 8) + Float((x * 7 + y * 3 + z) % 11)
        }
        let grid = VolumeRenderGrid(volume: volume)
        let labelGrid = VolumeRenderGrid(volume: volume, asLabels: true)
        let camera = VolumeRenderCamera(azimuth: 41, elevation: -17, zoom: 1.3)
        var hashes: Set<UInt64> = []
        for mode in VolumeRenderMode.allCases {
            let g = mode == .labels ? labelGrid : grid
            let a = try await VolumeRenderer.render(grid: g, camera: camera, mode: mode, window: nil, width: 96, height: 80, options: Self.cpu)
            let b = try await VolumeRenderer.render(grid: g, camera: camera, mode: mode, window: nil, width: 96, height: 80, options: Self.cpu)
            let c = try VolumeRenderer.renderSynchronously(grid: g, camera: camera, mode: mode, window: nil, width: 96, height: 80, options: Self.cpu)
            let h = Self.fnv1a(a.pixels)
            #expect(h == Self.fnv1a(b.pixels), "\(mode)")
            #expect(h == Self.fnv1a(c.pixels), "\(mode)")
            hashes.insert(h)
        }
        // Each mode produces a distinct image (the hash is actually discriminating).
        #expect(hashes.count == VolumeRenderMode.allCases.count)
        // A rebuilt grid renders the same bytes too.
        let again = try await VolumeRenderer.render(
            grid: VolumeRenderGrid(volume: volume), camera: camera, mode: .dvr, window: nil, width: 96, height: 80, options: Self.cpu
        )
        let first = try await VolumeRenderer.render(grid: grid, camera: camera, mode: .dvr, window: nil, width: 96, height: 80, options: Self.cpu)
        #expect(again.pixels == first.pixels)
    }

    // MARK: - Metal mirror bookkeeping (portable parts)

    @Test
    func metalParameterPackingMatchesKernelEnum() throws {
        let source = VolumeRenderMetalShared.kernelSource
        let start = try #require(source.range(of: "enum {"))
        let end = try #require(source.range(of: "};", range: start.upperBound..<source.endIndex))
        let names = source[start.upperBound..<end.lowerBound]
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        #expect(names.count == VolumeRenderMetalShared.Param.allCases.count)
        #expect(names.first == "P_W" && names.last == "P_BGB")

        let grid = VolumeRenderGrid(volume: Self.cubeVolume())
        let setup = try VolumeRenderSetup(
            grid: grid, camera: .right, mode: .dvr, window: nil, width: 20, height: 10, options: Self.cpu
        )
        let packed = VolumeRenderMetalShared.pack(setup)
        #expect(packed.count == names.count)
        #expect(packed[VolumeRenderMetalShared.Param.width.rawValue] == 20)
        #expect(packed[VolumeRenderMetalShared.Param.mode.rawValue] == 2)
        #expect(packed[VolumeRenderMetalShared.Param.dx.rawValue] == setup.dir.0)
        #expect(setup.transfer.count == VolumeRenderSetup.transferTableSize * 4)
    }
}
