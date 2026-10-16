import Foundation
import Testing
@testable import MIQCore

struct NiftiWriterTests {
    private static func tempURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miq-niftiwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func mask(_ w: Int, _ h: Int, _ d: Int) -> [UInt8] {
        (0..<(w * h * d)).map { UInt8(($0 * 7 + $0 / 5) % 3 == 0 ? 1 : 0) }
    }

    private static func expectSameAffine(_ a: VoxelAffine, _ b: VoxelAffine, tolerance: Double = 1e-4) {
        for r in 0..<3 {
            for c in 0..<4 {
                #expect(abs(a.rows[r][c] - b.rows[r][c]) <= tolerance, "affine[\(r)][\(c)]: \(a.rows[r][c]) vs \(b.rows[r][c])")
            }
        }
    }

    // MARK: Round trips through MIQParser

    /// Oblique sform + qform source written as `.nii.gz` and parsed back: same
    /// dims, datatype, both transforms, units and every voxel value.
    @Test func gzipRoundTripCopiesSourceGeometry() throws {
        let (w, h, d) = (5, 4, 3)
        let srow: [[Float]] = [[-1.9, 0.2, 0, 91.5], [0.3, 2.1, -0.1, -126], [0, 0.1, 2.5, -72.25]]
        let source = try ModalityFixtures.niftiVolume(ModalityFixtures.niftiBytes(
            dims: [w, h, d, 2], pixdim: [-1, 1.9, 2.1, 2.5, 0.8],
            qform: .init(code: 1, quatern: (0.1, -0.2, 0.3), qoffset: (11, -22, 33.5)),
            sform: .init(code: 2, srow: srow), values: [Float](repeating: 1, count: w * h * d * 2)
        ))
        let geometry = NiftiGeometry(volume: source)
        let voxels = Self.mask(w, h, d)
        let url = try Self.tempURL("sub-01_desc-brain_mask.nii.gz")
        try NiftiWriter.writeUInt8(voxels, width: w, height: h, depth: d, geometry: geometry, to: url, description: "MIQ test mask")

        let raw = try Data(contentsOf: url)
        #expect(raw.prefix(2) == Data([0x1F, 0x8B]))

        let image = try MIQParser().parse(url: url)
        let header = image.header
        #expect(header.dimensions.prefix(3) == [w, h, d])
        #expect(header.volumes == 1)
        #expect(header.datatype == .uint8)
        #expect(header.sformCode == 2)
        #expect(header.qformCode == 1)
        #expect(header.srowX == srow[0] && header.srowY == srow[1] && header.srowZ == srow[2])
        #expect(Array(header.pixdim.prefix(4)) == [-1, 1.9, 2.1, 2.5])
        #expect(header.acquisition.spatialUnit == source.image.header.acquisition.spatialUnit)

        let written = try #require(NIfTIRawFields(image: image))
        let original = try #require(NIfTIRawFields(image: source.image))
        #expect(written.qformCode == 1)
        #expect(written.quaternB == original.quaternB && written.quaternC == original.quaternC && written.quaternD == original.quaternD)
        #expect(written.qoffset == original.qoffset)
        #expect(written.qfac == -1)

        let parsed = MIQVolume(image: image)
        Self.expectSameAffine(parsed.voxelToWorld, source.voxelToWorld, tolerance: 0)
        var i = 0
        for z in 0..<d { for y in 0..<h { for x in 0..<w {
            #expect(parsed.voxel(x: x, y: y, z: z, t: 0) == Float(voxels[i]))
            i += 1
        } } }
    }

    /// qform-only source (sform code 0): the qform travels, the sform stays unset.
    @Test func uncompressedRoundTripKeepsQformOnlyGeometry() throws {
        let source = try ModalityFixtures.niftiVolume(ModalityFixtures.niftiBytes(
            dims: [3, 3, 2], pixdim: [1, 3, 3, 3],
            qform: .init(code: 1, quatern: (0, 0, 1), qoffset: (10, 20, 30)), values: [Float](repeating: 0, count: 18)
        ))
        let url = try Self.tempURL("mask.nii")
        let voxels = Self.mask(3, 3, 2)
        try NiftiWriter.writeUInt8(voxels, width: 3, height: 3, depth: 2, geometry: NiftiGeometry(volume: source), to: url)
        let raw = try Data(contentsOf: url)
        #expect(raw.count == 352 + voxels.count)
        #expect(raw.prefix(4) == Data([0x5C, 0x01, 0x00, 0x00]))  // sizeof_hdr 348 LE

        let parsed = MIQVolume(image: try MIQParser().parse(url: url))
        #expect(parsed.image.header.sformCode == 0)
        #expect(parsed.image.header.qformCode == 1)
        Self.expectSameAffine(parsed.voxelToWorld, source.voxelToWorld)
        #expect(parsed.decodedValues() == voxels.map(Float.init))
    }

    /// A non-NIfTI source (no raw NIfTI header): `voxelToWorld` is written as both
    /// sform and an equivalent qform.
    @Test func nonNiftiSourceWritesAffineAsSformAndQform() throws {
        let srow: [[Float]] = [[0, 0, -1.5, 40], [2, 0, 0, -30], [0, -1, 0, 12]]  // permuted, flipped, LH
        let source = ModalityFixtures.floatVolume(
            width: 4, height: 3, depth: 2, geometry: .init(spacing: [2, 1, 1.5], srow: srow),
            values: [Float](repeating: 0, count: 24)
        )
        #expect(NIfTIRawFields(image: source.image) == nil)
        let geometry = NiftiGeometry(volume: source)
        #expect(geometry.sformCode == 1 && geometry.qformCode == 1)

        let data = try NiftiWriter.encodeUInt8(Self.mask(4, 3, 2), width: 4, height: 3, depth: 2, geometry: geometry)
        let image = try MIQParser().parseNifti(data)
        let parsed = MIQVolume(image: image)
        Self.expectSameAffine(parsed.voxelToWorld, source.voxelToWorld)

        let raw = try #require(NIfTIRawFields(image: image))
        let q = try #require(raw.qformAffine(pixdim: image.header.pixdim))
        Self.expectSameAffine(q, source.voxelToWorld)
    }

    // MARK: Quaternion

    @Test(arguments: [
        VoxelAffine(rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
        VoxelAffine(rows: [[-2, 0, 0, 5], [0, 2, 0, 6], [0, 0, 2, 7]]),            // LAS (qfac −1)
        VoxelAffine(rows: [[-1, 0, 0, 0], [0, -1, 0, 0], [0, 0, 1, 0]]),           // 180° about z
        VoxelAffine(rows: [[1, 0, 0, 0], [0, -1, 0, 0], [0, 0, -1, 0]]),           // 180° about x
        VoxelAffine(rows: [[-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1, 0]]),           // 180° about y
        VoxelAffine(rows: [[0.866, -0.5, 0, 1], [0.5, 0.866, 0, 2], [0, 0, 1.2, 3]]), // 30° about z
    ])
    func quaternionReproducesRotation(affine: VoxelAffine) throws {
        let g = NiftiGeometry(affine: affine)
        let data = try NiftiWriter.encodeUInt8([0, 1], width: 2, height: 1, depth: 1, geometry: g)
        let image = try MIQParser().parseNifti(data)
        let raw = try #require(NIfTIRawFields(image: image))
        let q = try #require(raw.qformAffine(pixdim: image.header.pixdim))
        Self.expectSameAffine(q, affine, tolerance: 2e-3)
    }

    // MARK: Header details and errors

    @Test func headerFieldsAreMinimalAndDescriptive() throws {
        let data = try NiftiWriter.encodeUInt8(
            [0, 1, 1, 0], width: 2, height: 2, depth: 1,
            geometry: NiftiGeometry(pixdim: [1, 1, 1, 1]),
            description: "MIQ brain mask (mindgrab) \u{00E9}" + String(repeating: "x", count: 100)
        )
        let header = try MIQParser().parseNifti(data).header
        #expect(Array(header.dimensions.prefix(3)) == [2, 2, 1])
        #expect(header.sclSlope == 1)
        let descrip = data[148..<228]
        #expect(descrip.last == 0)                                    // NUL-terminated
        #expect(String(decoding: descrip.prefix(26), as: UTF8.self) == "MIQ brain mask (mindgrab) ")
        #expect(!descrip.contains(0xC3))                              // non-ASCII dropped
        #expect(Array(data[344..<348]) == [0x6E, 0x2B, 0x31, 0])
    }

    @Test func mismatchedOrOversizedDimensionsThrow() {
        #expect(throws: NiftiWriter.WriteError.dimensionMismatch) {
            try NiftiWriter.encodeUInt8([1, 2, 3], width: 2, height: 2, depth: 1, geometry: NiftiGeometry())
        }
        #expect(throws: NiftiWriter.WriteError.dimensionMismatch) {
            try NiftiWriter.encodeUInt8([], width: 0, height: 1, depth: 1, geometry: NiftiGeometry())
        }
        #expect(throws: NiftiWriter.WriteError.dimensionTooLarge) {
            try NiftiWriter.encodeUInt8([UInt8](repeating: 0, count: 40_000), width: 40_000, height: 1, depth: 1, geometry: NiftiGeometry())
        }
    }

    @Test func gzipOutputInflatesBack() throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let compressed = try NiftiWriter.gzip(payload)
        #expect(compressed.prefix(2) == Data([0x1F, 0x8B]))
        #expect(try MIQBinaryReader.gunzip(compressed) == payload)
    }

    // MARK: Memory estimate

    @Test func memoryEstimateScalesWithGridAndRefusesHugeRuns() throws {
        let small = NeuralMemoryEstimate.peakBytes(sourceVoxelCount: 64 * 64 * 64, gridSize: 128, maxChannels: 15)
        let large = NeuralMemoryEstimate.peakBytes(sourceVoxelCount: 64 * 64 * 64, gridSize: 256, maxChannels: 15)
        #expect(small < 1 << 30)
        #expect(large > 7 * small)

        let conv = try NeuralConv3D(name: "c", inChannels: 1, outChannels: 15, kernel: [1, 1, 1], dilation: [1, 1, 1],
                                    weights: [Float](repeating: 0, count: 15), bias: nil)
        let model = try NeuralModel(name: "m", layers: [.conv3D(conv)])
        #expect(model.maxChannels == 15)
        let options = NeuralRunOptions(gridSpacing: 2)
        #expect(NeuralMemoryEstimate.refusalReason(sourceVoxelCount: 1_000_000, model: model, options: options, budget: 4 << 30) == nil)
        let reason = NeuralMemoryEstimate.refusalReason(sourceVoxelCount: 1_000_000_000, model: model, options: options, budget: 4 << 30)
        #expect(reason?.contains("memory") == true)
    }
}
