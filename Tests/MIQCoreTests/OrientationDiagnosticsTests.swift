import Foundation
import Testing
@testable import MIQCore

/// `OrientationDiagnostics`: transform provenance, obliquity, and NIfTI qform/sform
/// conflicts, as surfaced to the metadata panel.
struct OrientationDiagnosticsTests {

    private static let deg = Float.pi / 180

    /// sform rows rotating voxel axes by `degrees` about world z, with `spacing`.
    private static func rotatedZRows(_ degrees: Float, spacing: Float = 1) -> (x: [Float], y: [Float], z: [Float]) {
        let c = cos(degrees * deg) * spacing
        let s = sin(degrees * deg) * spacing
        return ([c, -s, 0, 0], [s, c, 0, 0], [0, 0, spacing, 0])
    }

    private static func nifti(
        sformCode: Int16,
        srow: (x: [Float], y: [Float], z: [Float]) = ([0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]),
        qformCode: Int16 = 0,
        quaternion: (b: Float, c: Float, d: Float) = (0, 0, 0),
        qfac: Float = 1
    ) throws -> MIQImage {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: sformCode, srowX: srow.x, srowY: srow.y, srowZ: srow.z,
            qformCode: qformCode,
            quaternB: quaternion.b, quaternC: quaternion.c, quaternD: quaternion.d,
            qfac: qfac
        )
        return try MIQParser().parseNifti(data)
    }

    // MARK: - Obliquity

    @Test
    func axisAlignedSformHasZeroObliquity() throws {
        let image = try Self.nifti(sformCode: 1, srow: ([2, 0, 0, 0], [0, 2, 0, 0], [0, 0, 2, 0]))
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .sform)
        #expect(diag.axisCodes == "RAS")
        #expect(diag.obliquityDegrees == 0)
        #expect(diag.isOblique == false)
        #expect(diag.qformSformConflict == nil)
        #expect(diag.warning == nil)
        #expect(diag.displaySummary == "RAS · sform")
    }

    @Test
    func sformRotated23DegreesAboutZReportsObliquity() throws {
        let image = try Self.nifti(sformCode: 1, srow: Self.rotatedZRows(23, spacing: 1.5))
        let diag = image.header.orientationDiagnostics
        let obliquity = try #require(diag.obliquityDegrees)
        #expect(abs(obliquity - 23) < 0.01)
        #expect(diag.isOblique)
        #expect(diag.displaySummary == "RAS · oblique 23° · sform")
    }

    @Test
    func qformRotated23DegreesAboutZReportsObliquity() throws {
        // Rotation by θ about z: quaternion (a, 0, 0, sin(θ/2)).
        let image = try Self.nifti(sformCode: 0, qformCode: 1, quaternion: (0, 0, sin(23 * Self.deg / 2)))
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .qform)
        let obliquity = try #require(diag.obliquityDegrees)
        #expect(abs(obliquity - 23) < 0.01)
        #expect(diag.displaySummary == "RAS · oblique 23° · qform")
    }

    @Test
    func obliquityIsInvariantUnderAxisFlipsAndPermutation() {
        let rows: [[Float]] = [[0, -1, 0], [cos(10 * Self.deg), 0, -sin(10 * Self.deg)], [sin(10 * Self.deg), 0, cos(10 * Self.deg)]]
        let obliquity = OrientationDiagnostics.obliquityDegrees(rows: rows)
        #expect(obliquity.map { abs($0 - 10) < 0.01 } == true)
    }

    @Test
    func degenerateMatrixHasNoObliquity() {
        #expect(OrientationDiagnostics.obliquityDegrees(rows: [[1, 0, 0], [0, 1, 0], [0, 0, 0]]) == nil)
    }

    @Test
    func tinyTiltSummarisesAsUnderOneDegree() {
        let diag = OrientationDiagnostics(transformSource: .sform, axisCodes: "RAS", obliquityDegrees: 0.2)
        #expect(diag.displaySummary == "RAS · oblique <1° · sform")
    }

    // MARK: - qform / sform conflicts

    @Test
    func oppositeHandednessIsFlagged() throws {
        // sform says LAS (x mirrored); qform says RAS. One is a mirror of the other.
        let image = try Self.nifti(
            sformCode: 1, srow: ([-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]),
            qformCode: 1
        )
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .sform)
        #expect(diag.axisCodes == "LAS")
        #expect(diag.qformSformConflict == .handedness)
        #expect(diag.warning == "qform and sform disagree on left/right — other tools may show this image flipped")
    }

    @Test
    func qfacReflectionAgainstRightHandedSformIsHandedness() throws {
        // qfac = -1 reflects the k axis (RAI); sform is RAS.
        let image = try Self.nifti(
            sformCode: 1, srow: ([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]),
            qformCode: 1, qfac: -1
        )
        #expect(image.header.orientationDiagnostics.qformSformConflict == .handedness)
    }

    @Test
    func swappedAxesWithSameHandednessAreAxisCodeConflict() throws {
        // sform: voxel i → A, j → R, k → I (det +1, like the identity qform).
        let image = try Self.nifti(
            sformCode: 1, srow: ([0, 1, 0, 0], [1, 0, 0, 0], [0, 0, -1, 0]),
            qformCode: 1
        )
        let diag = image.header.orientationDiagnostics
        #expect(diag.axisCodes == "ARI")
        #expect(diag.qformSformConflict == .axisCodes)
        #expect(diag.qformAxisCodes == "RAS")
        #expect(diag.warning == "qform (RAS) and sform (ARI) disagree — other tools may orient this image differently")
    }

    @Test
    func smallRotationDifferenceIsMinor() throws {
        let image = try Self.nifti(sformCode: 1, srow: Self.rotatedZRows(2), qformCode: 1)
        let diag = image.header.orientationDiagnostics
        #expect(diag.qformSformConflict == .minor)
        #expect(diag.warning == nil)
    }

    @Test
    func matchingQformAndSformHaveNoConflict() throws {
        // Same rotation, sform additionally carrying 2 mm spacing (normalised away).
        let image = try Self.nifti(
            sformCode: 1, srow: Self.rotatedZRows(23, spacing: 2),
            qformCode: 1, quaternion: (0, 0, sin(23 * Self.deg / 2))
        )
        #expect(image.header.orientationDiagnostics.qformSformConflict == nil)
    }

    @Test
    func conflictOnlyCheckedWhenBothCodesSet() throws {
        let image = try Self.nifti(sformCode: 1, srow: ([-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]), qformCode: 0)
        #expect(image.header.orientationDiagnostics.qformSformConflict == nil)
    }

    @Test
    func niftiWithoutTransformsIsUnknown() throws {
        let image = try Self.nifti(sformCode: 0, qformCode: 0)
        let diag = image.header.orientationDiagnostics
        #expect(diag == .unknown)
        #expect(diag.displaySummary == "Unknown · no transform")
        #expect(diag.warning != nil)
    }

    // MARK: - MIF

    @Test
    func mifWithoutTransformReportsDefault() throws {
        let image = try MIQParser().parseMif(TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8))
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .mifDefault)
        #expect(diag.axisCodes == "RAS")
        #expect(diag.obliquityDegrees == 0)
        #expect(diag.displaySummary == "RAS · MIF default")
    }

    @Test
    func mifWithObliqueTransformAndReversedLayout() throws {
        let rows = Self.rotatedZRows(23)
        let data = TestMIQFactory.makeMif(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            layout: [0, -1, 2],
            transform: [rows.x, rows.y, rows.z]
        )
        let image = try MIQParser().parseMif(data)
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .mifTransform)
        #expect(diag.axisCodes == MIQVolume(image: image).storageOrientationLabel())
        #expect(diag.obliquityDegrees.map { abs($0 - 23) < 0.01 } == true)
    }

    // MARK: - Fallback derivation

    @Test
    func headerWithoutExplicitDiagnosticsDerivesFromFrame() {
        let rows = Self.rotatedZRows(23)
        let frame = OrientationFrame.from(srowX: rows.x, srowY: rows.y, srowZ: rows.z, source: .mghDirectionCosines)
        let header = MIQHeader(
            littleEndian: false, dimensions: [2, 2, 2, 1], pixdim: [1, 1, 1, 1], datatype: .uint8,
            voxOffset: 0, sclSlope: 0, sclInter: 0, qformCode: 0, sformCode: 1,
            srowX: rows.x, srowY: rows.y, srowZ: rows.z, orientationFrame: frame
        )
        #expect(header.orientationDiagnostics.transformSource == .mghVox2ras)
        #expect(header.orientationDiagnostics.obliquityDegrees.map { abs($0 - 23) < 0.01 } == true)
    }
}

/// NRRD must not invent an anatomical orientation: without an anatomical `space` *and*
/// `space directions`, the frame is nil and labels read "?" (as for a NIfTI with both
/// form codes 0). Spacing is still honoured.
struct NrrdOrientationSafetyTests {

    private static func nrrd(space: String?, directions: String?, spacings: String? = nil, extra: [String] = []) -> Data {
        var lines = ["NRRD0004", "type: uint8", "dimension: 3", "sizes: 4 3 2"]
        if let space { lines.append("space: \(space)") }
        if let directions { lines.append("space directions: \(directions)") }
        if let spacings { lines.append("spacings: \(spacings)") }
        lines += extra
        lines += ["endian: little", "encoding: raw"]
        let header = lines.joined(separator: "\n") + "\n\n"
        return Data(header.utf8) + Data(repeating: 1, count: 4 * 3 * 2)
    }

    private static func expectUnknown(_ image: MIQImage, spacing: [Float]) {
        #expect(image.header.orientationFrame == nil)
        #expect(image.header.sformCode == 0)
        #expect(image.header.orientationDiagnostics == .unknown)
        let volume = MIQVolume(image: image)
        #expect(volume.storageOrientationLabel() == nil)
        for plane in [SlicePlane.axial, .coronal, .sagittal] {
            #expect(volume.displayOrientation(for: plane, options: RenderingOptions(lowerPercentile: 1, upperPercentile: 99)).isUnknown)
        }
        #expect(Array(image.header.pixdim[1...3]) == spacing)
    }

    @Test
    func noSpaceFieldIsUnknown() throws {
        let image = try MIQParser().parseNrrd(Self.nrrd(space: nil, directions: "(2,0,0) (0,3,0) (0,0,4)"))
        Self.expectUnknown(image, spacing: [2, 3, 4])
    }

    @Test
    func spaceDimensionWithoutSpaceIsUnknown() throws {
        let image = try MIQParser().parseNrrd(
            Self.nrrd(space: nil, directions: "(2,0,0) (0,3,0) (0,0,4)", extra: ["space dimension: 3"])
        )
        Self.expectUnknown(image, spacing: [2, 3, 4])
    }

    @Test(arguments: ["scanner-xyz", "3D-right-handed", "3D-left-handed", "3D-right-handed-time", "bogus"])
    func nonAnatomicalSpaceIsUnknown(space: String) throws {
        let image = try MIQParser().parseNrrd(Self.nrrd(space: space, directions: "(2,0,0) (0,3,0) (0,0,4)"))
        Self.expectUnknown(image, spacing: [2, 3, 4])
    }

    @Test
    func anatomicalSpaceWithoutDirectionsIsUnknown() throws {
        let image = try MIQParser().parseNrrd(Self.nrrd(space: "left-posterior-superior", directions: nil, spacings: "2 3 4"))
        Self.expectUnknown(image, spacing: [2, 3, 4])
    }

    @Test
    func noSpaceNoDirectionsDefaultsSpacingToOne() throws {
        let image = try MIQParser().parseNrrd(Self.nrrd(space: nil, directions: nil))
        Self.expectUnknown(image, spacing: [1, 1, 1])
    }

    @Test(arguments: [
        ("left-posterior-superior", "LPS"),
        ("LPS", "LPS"),
        ("right-anterior-superior", "RAS"),
        ("RAS", "RAS"),
        ("left-anterior-superior", "LAS"),
    ])
    func anatomicalSpaceWithDirectionsIsKnown(space: String, expected: String) throws {
        let image = try MIQParser().parseNrrd(Self.nrrd(space: space, directions: "(2,0,0) (0,3,0) (0,0,4)"))
        #expect(image.header.orientationFrame?.source == .nrrdSpaceDirections)
        #expect(image.header.sformCode == 1)
        #expect(MIQVolume(image: image).storageOrientationLabel() == expected)
        #expect(Array(image.header.pixdim[1...3]) == [2, 3, 4])
        let diag = image.header.orientationDiagnostics
        #expect(diag.transformSource == .nrrdSpace)
        #expect(diag.obliquityDegrees == 0)
        #expect(diag.displaySummary == "\(expected) · NRRD space")
        #expect(diag.warning == nil)
    }

    @Test
    func obliqueNrrdReportsObliquity() throws {
        let c = cos(Float(23) * .pi / 180)
        let s = sin(Float(23) * .pi / 180)
        let image = try MIQParser().parseNrrd(
            Self.nrrd(space: "RAS", directions: "(\(c),\(s),0) (\(-s),\(c),0) (0,0,1)")
        )
        let diag = image.header.orientationDiagnostics
        #expect(diag.obliquityDegrees.map { abs($0 - 23) < 0.01 } == true)
        #expect(diag.displaySummary == "RAS · oblique 23° · NRRD space")
    }
}
