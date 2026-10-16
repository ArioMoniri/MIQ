import Foundation
import Testing
@testable import MIQCore

struct DiffusionColorTests {
    /// 3×1×1 field: voxel 0 = +x, voxel 1 = -y, voxel 2 = +z (component-major layout).
    static let axisVectors: [Float] = [
        1, 0, 0,   // x components of voxels 0, 1, 2
        0, -1, 0,  // y
        0, 0, 1,   // z
    ]

    @Test func fiveDimensionalNiftiVectorFieldIsDetected() throws {
        let data = ModalityFixtures.niftiBytes(
            dims: [3, 1, 1, 1, 3], pixdim: [1, 1, 1, 1], intentCode: 1007,
            sform: .init(code: 1, srow: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]), values: Self.axisVectors
        )
        let vol = try ModalityFixtures.niftiVolume(data)
        #expect(vol.componentCount == 3)
        #expect(vol.niftiIntentCode == DiffusionColor.vectorIntentCode)
        let comps = try #require(DiffusionColor.vectorComponents(of: vol))
        #expect(comps.volumes == 3)
        #expect(DiffusionColor.color(components: comps, x: 0, y: 0, z: 0) == (255, 0, 0))
        #expect(DiffusionColor.color(components: comps, x: 1, y: 0, z: 0) == (0, 255, 0))
        #expect(DiffusionColor.color(components: comps, x: 2, y: 0, z: 0) == (0, 0, 255))
    }

    @Test func truncatedFiveDimensionalPayloadIsRejected() throws {
        let data = ModalityFixtures.niftiBytes(
            dims: [3, 1, 1, 1, 3], values: Self.axisVectors
        )
        // Keep header + first component only, as a volume-0-capped .nii.gz load would.
        let vol = try ModalityFixtures.niftiVolume(data.prefix(352 + 12))
        #expect(DiffusionColor.vectorComponents(of: vol) == nil)
    }

    /// Storage x runs along world A/P and storage y along world R/L (a 90° rotation
    /// about S, with 2 mm voxels): voxel-frame +x must turn green, ±y red.
    @Test func rotatedAffineGivesAnatomicalColours() throws {
        let srow: [[Float]] = [[0, -2, 0, 0], [2, 0, 0, 0], [0, 0, 2, 0]]
        let vol = ModalityFixtures.floatVolume(
            width: 3, height: 1, depth: 1, volumes: 3, geometry: .init(spacing: [2, 2, 2], srow: srow), values: Self.axisVectors
        )
        let comps = try #require(DiffusionColor.vectorComponents(of: vol, fileName: "dti_V1.nii.gz"))
        #expect(DiffusionColor.color(components: comps, x: 0, y: 0, z: 0) == (0, 255, 0))
        #expect(DiffusionColor.color(components: comps, x: 1, y: 0, z: 0) == (255, 0, 0))
        #expect(DiffusionColor.color(components: comps, x: 2, y: 0, z: 0) == (0, 0, 255))
        // World-frame vectors skip the rotation.
        #expect(DiffusionColor.color(components: comps, x: 0, y: 0, z: 0, frame: .world) == (255, 0, 0))
    }

    @Test func obliqueVectorSplitsAcrossChannels() throws {
        // 45° in-plane rotation: voxel +x → world (√½, √½, 0).
        let c = Float(0.5).squareRoot()
        let srow: [[Float]] = [[c, -c, 0, 0], [c, c, 0, 0], [0, 0, 1, 0]]
        let vol = ModalityFixtures.floatVolume(width: 1, height: 1, depth: 1, volumes: 3, geometry: .srow(srow), values: [1, 0, 0])
        let comps = try #require(DiffusionColor.vectorComponents(of: vol, fileName: "sub-01_V1.nii"))
        let rgb = DiffusionColor.color(components: comps, x: 0, y: 0, z: 0)
        #expect(rgb.r == 180 && rgb.g == 180 && rgb.b == 0)
    }

    @Test func faModulatesBrightness() throws {
        let vol = ModalityFixtures.floatVolume(width: 3, height: 1, depth: 1, volumes: 3, values: Self.axisVectors)
        let comps = try #require(DiffusionColor.vectorComponents(of: vol, fileName: "dti_V1.nii.gz"))
        let fa = ModalityFixtures.floatVolume(width: 3, height: 1, depth: 1, values: [0.5, 0, 2])
        #expect(DiffusionColor.color(components: comps, x: 0, y: 0, z: 0, fa: fa) == (128, 0, 0))
        #expect(DiffusionColor.color(components: comps, x: 1, y: 0, z: 0, fa: fa) == (0, 0, 0))
        #expect(DiffusionColor.color(components: comps, x: 2, y: 0, z: 0, fa: fa) == (0, 0, 255))
    }

    @Test func fourDimensionalNeedsNameOrIntent() {
        let vol = ModalityFixtures.floatVolume(width: 3, height: 1, depth: 1, volumes: 3, values: Self.axisVectors)
        #expect(DiffusionColor.vectorComponents(of: vol, fileName: "bold.nii.gz") == nil)
        #expect(DiffusionColor.vectorComponents(of: vol) == nil)
        #expect(DiffusionColor.vectorComponents(of: vol, fileName: "dti_V1.nii.gz") != nil)
        #expect(DiffusionColor.isVectorFieldName("dti_V1.nii.gz"))
        #expect(!DiffusionColor.isVectorFieldName("sub-01_T1w_v1.nii.gz"))
    }

    @Test func decSliceMatchesGrayscaleSliceSize() throws {
        let n = 4
        var values = [Float](repeating: 0, count: n * n * n * 3)
        for i in 0..<(n * n * n) { values[i] = 1 }  // every voxel +x
        let vol = ModalityFixtures.floatVolume(width: n, height: n, depth: n, volumes: 3, geometry: .spacing([1, 1, 2]), values: values)
        let comps = try #require(DiffusionColor.vectorComponents(of: vol, fileName: "dti_V1.nii.gz"))
        let options = RenderingOptions(lowerPercentile: 0, upperPercentile: 100)
        for plane in SlicePlane.allCases {
            let gray = comps.slice(plane: plane, index: 1, maxDimension: 16, options: options)
            let dec = try #require(DiffusionColor.slice(components: comps, plane: plane, index: 1, maxDimension: 16, options: options))
            #expect(dec.width == gray.width && dec.height == gray.height)
            guard case .rgb(let img) = dec else { Issue.record("expected RGB"); continue }
            #expect(img.pixels[0] == 255 && img.pixels[1] == 0 && img.pixels[2] == 0)
        }
    }
}

private func == (lhs: (r: UInt8, g: UInt8, b: UInt8), rhs: (UInt8, UInt8, UInt8)) -> Bool {
    lhs.r == rhs.0 && lhs.g == rhs.1 && lhs.b == rhs.2
}
