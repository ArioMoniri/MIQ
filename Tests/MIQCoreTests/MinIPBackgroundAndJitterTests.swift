import Foundation
import Testing
@testable import MIQCore

/// e2e regressions: MinIP of a zero-background MR was all black (the background
/// won every ray), and DVR/label renders showed concentric "wood-grain" rings
/// from every ray sampling at the same phase.
struct MinIPBackgroundAndJitterTests {
    private static var cpu: VolumeRenderOptions {
        var o = VolumeRenderOptions()
        o.backend = .cpu
        return o
    }

    private static func rgb(_ b: RGBABitmap, _ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * b.width + x) * 4
        let p = [UInt8](b.pixels)
        return [p[o], p[o + 1], p[o + 2]]
    }

    /// 32³ at 1 mm, centred sphere r 12 mm of ~100 with an inner r 4 mm "ventricle"
    /// of ~40 (± deterministic noise) in an exactly-zero background.
    static func zeroBackgroundMR() -> MIQVolume {
        var noise = QCPhantom.Noise(state: 3)
        return QCPhantom.image(dims: [32, 32, 32], spacing: 1, datatype: .float32, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x) - 15.5, dy = Float(y) - 15.5, dz = Float(z) - 15.5
            let r = (dx * dx + dy * dy + dz * dz).squareRoot()
            if r > 12 { return 0 }
            return (r < 4 ? 40 : 100) + Float(2 * noise.normal())
        }
    }

    // MARK: - Floor rule

    @Test
    func floorIsAFlatMinimum() {
        #expect(MinIPBackground.floor(of: [Float](repeating: 0, count: 100) + [5, 6, 7]) == 0)
        #expect(MinIPBackground.floor(of: [Float](repeating: -1024, count: 80) + [-1000, 40]) == -1024)
        // A single darkest voxel among many is noise, not a background.
        let noisy = (0..<1000).map { Float($0) }
        #expect(MinIPBackground.floor(of: noisy) == nil)
        // A few darkest voxels in a tiny volume are data, not an extended background.
        #expect(MinIPBackground.floor(of: [0, 1, 2, 3, 4, 5, 6, 7] as [Float]) == nil)
        #expect(MinIPBackground.floor(of: [Float](repeating: 0, count: 64) + [5]) == 0)
        // Constant data: nothing to exclude.
        #expect(MinIPBackground.floor(of: [Float](repeating: 3, count: 10)) == nil)
        #expect(MinIPBackground.floor(of: [Float.nan] + [Float](repeating: 1, count: 70) + [2]) == 1)
    }

    // MARK: - 2D projection

    @Test
    func projectionMinIPIgnoresZeroBackgroundOutsideTheObject() throws {
        let volume = Self.zeroBackgroundMR()
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .stored)
        let values = try #require(volume.projectedValues(plane: .axial, mode: .minip, options: options))
        let w = 32
        // Through the ventricle: its ~40, not the background's 0.
        let center = values[16 * w + 16]
        #expect(center > 30 && center < 50, "\(center)")
        // Through tissue only: ~100.
        let tissue = values[16 * w + 16 + 8]
        #expect(tissue > 90, "\(tissue)")
        // Background-only rays have no sample (NaN renders black).
        #expect(values[0].isNaN)
        // MIP is unaffected.
        let mip = try #require(volume.projectedValues(plane: .axial, mode: .mip, options: options))
        #expect(mip[0] == 0)
    }

    @Test
    func projectionMinIPKeepsEnclosedBackgroundValuedVoxels() throws {
        // Exact-zero insert enclosed by tissue along the ray: real data, kept.
        let volume = QCPhantom.image(dims: [16, 16, 16], spacing: 1, datatype: .float32, frame: QCPhantom.rasFrame) { x, y, z, _ in
            if (6..<10).contains(x), (6..<10).contains(y), (6..<10).contains(z) { return 0 }
            return x < 2 ? 0 : 100   // flat zero slab at the edge makes 0 the floor
        }
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .stored)
        let values = try #require(volume.projectedValues(plane: .axial, mode: .minip, options: options))
        #expect(values[8 * 16 + 8] == 0)
        #expect(values[8 * 16 + 12] == 100)
        // Sagittal rays run along x and start in the zero slab: leading run dropped.
        let sagittal = try #require(volume.projectedValues(plane: .sagittal, mode: .minip, options: options))
        #expect(sagittal.contains(100))
    }

    // MARK: - 3D ray caster

    @Test
    func volumeMinIPOfZeroBackgroundMRShowsTissue() async throws {
        let grid = VolumeRenderGrid(volume: Self.zeroBackgroundMR())
        #expect(grid.minIPBackgroundFloor == 0)
        var options = Self.cpu
        options.background = VolumeRenderColor(r: 0, g: 0, b: 255, a: 255)
        // zoom √3 on the 32 mm cube at 128 px → 0.25 mm/px, volume centre at (64, 64).
        let image = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .minIP, window: MIQIntensityWindowBounds(low: 0, high: 100),
            width: 128, height: 128, options: options
        )
        let ventricle = Self.rgb(image, 64, 64)
        #expect(ventricle[0] == ventricle[2] && ventricle[0] > 70 && ventricle[0] < 140, "\(ventricle)")
        let tissue = Self.rgb(image, 64 + 32, 64)   // 8 mm off-centre: tissue only
        #expect(tissue[0] > 200, "\(tissue)")
        // Rays through the box but outside the head show the background colour.
        #expect(Self.rgb(image, 2, 2) == [0, 0, 255])
    }

    @Test
    func volumeMinIPOfCTKeepsNoisyAirAndDropsPadding() async throws {
        var noise = QCPhantom.Noise(state: 5)
        // Padding −1024 outside an x/z cylinder (r 14); noisy air inside; a body block.
        let ct = QCPhantom.image(dims: [32, 32, 32], spacing: 1, datatype: .float32, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x) - 15.5, dz = Float(z) - 15.5
            if dx * dx + dz * dz > 14 * 14 { return -1024 }
            if (8..<24).contains(x), (8..<24).contains(y), (8..<24).contains(z) { return 40 + Float(5 * noise.normal()) }
            // Scanners clip at the padding value; keep the noisy air above it.
            return max(-1020, -1000 + Float(20 * noise.normal()))
        }
        let grid = VolumeRenderGrid(volume: ct)
        #expect(grid.minIPBackgroundFloor == -1024)
        var options = Self.cpu
        options.background = VolumeRenderColor(r: 0, g: 0, b: 255, a: 255)
        let image = try await VolumeRenderer.render(
            grid: grid, camera: VolumeRenderCamera(zoom: Float(3).squareRoot()),
            mode: .minIP, window: MIQIntensityWindowBounds(low: -1100, high: 100),
            width: 128, height: 128, options: options
        )
        // Anterior rays run along y through air in front of and behind the body:
        // air is real data, so the MinIP is dark grey, not the background colour.
        let centre = Self.rgb(image, 64, 64)
        #expect(centre[0] == centre[2] && centre[0] < 60, "\(centre)")
        // Corner rays only cross padding.
        #expect(Self.rgb(image, 2, 2) == [0, 0, 255])
    }

    @Test
    func minIPMaskFlagIsPackedForMetal() throws {
        let grid = VolumeRenderGrid(volume: Self.zeroBackgroundMR())
        let minip = try VolumeRenderSetup(grid: grid, camera: .anterior, mode: .minIP, window: nil, width: 8, height: 8, options: Self.cpu)
        let mip = try VolumeRenderSetup(grid: grid, camera: .anterior, mode: .mip, window: nil, width: 8, height: 8, options: Self.cpu)
        #expect(VolumeRenderMetalShared.pack(minip)[VolumeRenderMetalShared.Param.minIPMasked.rawValue] == 1)
        #expect(VolumeRenderMetalShared.pack(mip)[VolumeRenderMetalShared.Param.minIPMasked.rawValue] == 0)
    }

    // MARK: - Ray-start jitter

    @Test
    func rayStartJitterIsDeterministicAndDecorrelated() {
        var sum: Double = 0
        var equalNeighbours = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let j = CPUVolumeRayCaster.rayStartJitter(x, y)
                #expect(j >= 0 && j < 1)
                #expect(j == CPUVolumeRayCaster.rayStartJitter(x, y))
                sum += Double(j)
                if j == CPUVolumeRayCaster.rayStartJitter(x + 1, y) { equalNeighbours += 1 }
            }
        }
        #expect(abs(sum / 4096 - 0.5) < 0.03)
        #expect(equalNeighbours == 0)
        // Golden values pin the formula the Metal kernel mirrors.
        #expect(CPUVolumeRayCaster.rayStartJitter(0, 0) == Self.referenceJitter(0, 0))
        #expect(CPUVolumeRayCaster.rayStartJitter(4095, 17) == Self.referenceJitter(4095, 17))
    }

    /// Independent spelling of the hash (UInt64 arithmetic masked to 32 bits).
    static func referenceJitter(_ px: UInt64, _ py: UInt64) -> Float {
        let m: UInt64 = 0xFFFF_FFFF
        var h = (px * 1973 + py * 9277 + 26699) & m
        h ^= h >> 16
        h = (h * 0x7feb_352d) & m
        h ^= h >> 15
        h = (h * 0x846c_a68b) & m
        h ^= h >> 16
        return Float(h >> 8) / 16_777_216
    }

    @Test
    func metalKernelMirrorsTheJitterFormula() {
        let source = VolumeRenderMetalShared.kernelSource
        for token in ["px * 1973u + py * 9277u + 26699u", "h ^= h >> 16;", "h *= 0x7feb352du;", "h ^= h >> 15;",
                      "h *= 0x846ca68bu;", "float(h >> 8) * (1.0 / 16777216.0)", "jitter(gid.x, gid.y)",
                      "P[P_MINMASK]"] {
            #expect(source.contains(token), "kernel lacks \(token)")
        }
    }

    @Test
    func dvrRingsAreBrokenUpButRenderStaysDeterministic() async throws {
        // A smooth spherical ramp: with a fixed half-step start, neighbouring
        // pixels' samples are in phase and the DVR image is a set of smooth
        // concentric bands; jitter decorrelates neighbours.
        let volume = QCPhantom.image(dims: [48, 48, 48], spacing: 1, datatype: .float32, frame: QCPhantom.rasFrame) { x, y, z, _ in
            let dx = Float(x) - 23.5, dy = Float(y) - 23.5, dz = Float(z) - 23.5
            return max(0, 100 - 5 * (dx * dx + dy * dy + dz * dz).squareRoot())
        }
        let grid = VolumeRenderGrid(volume: volume)
        var options = Self.cpu
        options.sampleSpacing = 2   // coarse steps make the banding strong
        let camera = VolumeRenderCamera(azimuth: 30, elevation: 20)
        let a = try await VolumeRenderer.render(grid: grid, camera: camera, mode: .dvr, window: nil, width: 96, height: 96, options: options)
        let b = try await VolumeRenderer.render(grid: grid, camera: camera, mode: .dvr, window: nil, width: 96, height: 96, options: options)
        #expect(a.pixels == b.pixels)
    }
}
