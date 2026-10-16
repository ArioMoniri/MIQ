import Foundation
import Testing
@testable import MIQCore

struct PreviewPanelSupportTests {
    // MARK: Display mode badge / forced L/R labels

    @Test func badgeLabels() {
        #expect(ViewOrientation.stored.badgeLabel == "As stored")
        #expect(ViewOrientation.neurological.badgeLabel == "Neurological")
        #expect(ViewOrientation.radiological.badgeLabel == "Radiological")
        #expect(ViewOrientation.stored.requiresLeftRightLabels)
        #expect(!ViewOrientation.neurological.requiresLeftRightLabels)
        #expect(!ViewOrientation.radiological.requiresLeftRightLabels)
    }

    @Test func unknownOrientationFallsBackToStoredBadge() {
        #expect(ViewOrientation.neurological.effective(orientationKnown: false) == .stored)
        #expect(ViewOrientation.radiological.effective(orientationKnown: true) == .radiological)
    }

    @Test func leftRightOnlyKeepsJustPatientLeftRight() {
        let axial = SliceOrientationLabels(leading: "R", trailing: "L", top: "A", bottom: "P")
        let kept = axial.leftRightOnly()
        #expect(kept.leading == "R" && kept.trailing == "L")
        #expect(kept.top.isEmpty && kept.bottom.isEmpty)

        // Stored order can put L/R on the vertical edges.
        let odd = SliceOrientationLabels(leading: "A", trailing: "P", top: "L", bottom: "R")
        let oddKept = odd.leftRightOnly()
        #expect(oddKept.leading.isEmpty && oddKept.trailing.isEmpty)
        #expect(oddKept.top == "L" && oddKept.bottom == "R")

        let sagittal = SliceOrientationLabels(leading: "P", trailing: "A", top: "S", bottom: "I")
        let none = sagittal.leftRightOnly()
        #expect(Self.allBlank(none))

        let unknown = SliceOrientationLabels.unknown.leftRightOnly()
        #expect(unknown.isUnknown)
        #expect(Self.allBlank(unknown))
    }

    // MARK: Crosshair position

    @Test func positionUsesSformAffineAndUnit() throws {
        let volume = ModalityFixtures.floatVolume(
            width: 4, height: 4, depth: 4,
            geometry: .srow([[2, 0, 0, -10], [0, 2, 0, 5], [0, 0, 3, 0]]),
            values: [Float](repeating: 1, count: 64)
        )
        let header = volume.image.header
        #expect(header.positionAffine != nil)
        let text = MIQMetadata.voxelPositionText(cursor: MIQVolumeCursor(x: 1, y: 2, z: 3), header: header)
        #expect(text == "1, 2, 3  (-8.0, 9.0, 9.0 mm)")
    }

    @Test func positionCursorIsStoredIndexInEveryDisplayMode() throws {
        // LAS-stored volume: the reoriented modes flip x for display, but the
        // cursor the canvas produces still addresses the stored voxel.
        let volume = ModalityFixtures.floatVolume(
            width: 4, height: 3, depth: 2,
            geometry: .srow([[-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
            values: [Float](repeating: 1, count: 24)
        )
        for mode in ViewOrientation.allCases {
            let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: mode)
            let cursor = volume.cursor(
                for: .axial,
                sliceIndex: 1,
                normalizedPoint: MIQNormalizedPoint(x: 0.1, y: 0.5),
                options: options
            )
            let point = volume.normalizedPoint(for: .axial, cursor: cursor, options: options)
            let roundTrip = volume.cursor(for: .axial, sliceIndex: 1, normalizedPoint: point, options: options)
            #expect(roundTrip == cursor)
            let text = MIQMetadata.voxelPositionText(cursor: cursor, header: volume.image.header)
            // World x = -i for this affine.
            #expect(text.hasPrefix("\(cursor.x), \(cursor.y), \(cursor.z)  (\(cursor.x == 0 ? "0.0" : "-\(cursor.x).0"),"))
        }
    }

    @Test func positionWithoutAffineShowsIndicesOnly() throws {
        // qform-only NIfTI: srow rows are not the affine.
        let data = ModalityFixtures.niftiBytes(
            dims: [2, 2, 2], qform: .init(code: 1, quatern: (0, 0, 0)),
            values: [Float](repeating: 0, count: 8)
        )
        let volume = try ModalityFixtures.niftiVolume(data)
        #expect(volume.image.header.orientationDiagnostics.transformSource == .qform)
        #expect(volume.image.header.positionAffine == nil)
        #expect(MIQMetadata.voxelPositionText(cursor: MIQVolumeCursor(x: 1, y: 0, z: 1), header: volume.image.header) == "1, 0, 1")
    }

    @Test func positionRespectsSpatialUnit() throws {
        var bytes = ModalityFixtures.niftiBytes(
            dims: [2, 2, 2], sform: .init(code: 1, srow: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]),
            values: [Float](repeating: 0, count: 8)
        )
        bytes[123] = 3  // xyzt_units: micron
        let volume = try ModalityFixtures.niftiVolume(bytes)
        let text = MIQMetadata.voxelPositionText(cursor: MIQVolumeCursor(x: 1, y: 1, z: 0), header: volume.image.header)
        #expect(text == "1, 1, 0  (1.0, 1.0, 0.0 \u{00B5}m)")
    }

    // MARK: Warnings

    @Test func normalizedWarningStripsSignAndNewlines() {
        #expect(MIQMetadata.normalizedWarning("\u{26A0} TR mismatch") == "TR mismatch")
        #expect(MIQMetadata.normalizedWarning("\u{26A0}\u{FE0E} a\nb") == "a b")
        #expect(MIQMetadata.normalizedWarning("plain") == "plain")
    }

    @Test func panelWarningsCombineOrientationAndSidecar() throws {
        let data = ModalityFixtures.niftiBytes(dims: [2, 2, 2, 12], values: [Float](repeating: 0, count: 96))
        let volume = try ModalityFixtures.niftiVolume(data)
        var sidecar = SidecarMetadata()
        sidecar.bValues = [0, 1000]
        let warnings = MIQMetadata.panelWarnings(header: volume.image.header, sidecar: sidecar)
        // No sform/qform → orientation caution first, then the .bval count mismatch.
        #expect(warnings.count == 2)
        #expect(warnings[0].contains("no anatomical orientation"))
        #expect(warnings[1].hasPrefix(".bval has 2 entries"))
        #expect(!warnings.contains { $0.hasPrefix("\u{26A0}") })
    }

    @Test func sidecarRowCanOmitWarnings() throws {
        let data = ModalityFixtures.niftiBytes(dims: [2, 2, 2, 3], values: [Float](repeating: 0, count: 24))
        let header = try ModalityFixtures.niftiVolume(data).image.header
        var sidecar = SidecarMetadata()
        sidecar.taskName = "rest"
        sidecar.bValues = [0]
        let inRow = MIQMetadata(header: header, sidecar: sidecar).sidecarSummary
        let separate = MIQMetadata(header: header, sidecar: sidecar, sidecarWarningsInRow: false).sidecarSummary
        #expect(inRow?.contains(".bval") == true)
        #expect(separate == "task rest")
    }

    // MARK: Summaries

    @Test func qcGating() {
        let scalar = ModalityFixtures.floatVolume(width: 2, height: 2, depth: 2, values: [Float](repeating: 1, count: 8))
        #expect(PreviewDataSummaries.shouldRunQC(header: scalar.image.header))
        let rgb = MIQHeader(
            littleEndian: true, dimensions: [2, 2, 2, 1], pixdim: [1, 1, 1, 1], datatype: .rgb24,
            voxOffset: 0, sclSlope: 1, sclInter: 0, qformCode: 0, sformCode: 0,
            srowX: [], srowY: [], srowZ: []
        )
        #expect(!PreviewDataSummaries.shouldRunQC(header: rgb))
        let huge4D = MIQHeader(
            littleEndian: true, dimensions: [256, 256, 256, 100], pixdim: [1, 1, 1, 1], datatype: .float32,
            voxOffset: 0, sclSlope: 1, sclInter: 0, qformCode: 0, sformCode: 0,
            srowX: [], srowY: [], srowZ: []
        )
        #expect(!PreviewDataSummaries.shouldRunQC(header: huge4D))
    }

    @Test func temporalGatingAndEntry() throws {
        let short = TemporalStatsTests.series(volumes: 9)
        #expect(!PreviewDataSummaries.shouldRunTemporalSummary(volume: short, isLabelMap: false))
        let series = TemporalStatsTests.series(volumes: 20, spike: 7)
        #expect(PreviewDataSummaries.shouldRunTemporalSummary(volume: series, isLabelMap: false))
        #expect(!PreviewDataSummaries.shouldRunTemporalSummary(volume: series, isLabelMap: true))

        let summary = try #require(TemporalStats.summary(for: series))
        let entry = try #require(PreviewDataSummaries.temporalEntry(summary))
        #expect(entry.label == "tSNR (median)")
        #expect(entry.field == nil)
        #expect(entry.value.hasSuffix("\u{00B7} 1 spike frame"))
    }

    @Test func windowModeText() {
        #expect(PreviewDataSummaries.windowModeText(perVolume: true) == "per volume")
        #expect(PreviewDataSummaries.windowModeText(perVolume: false) == "shared")
    }

    // MARK: Status texts

    @Test func unsupportedFeatureShownVerbatim() {
        let reason = "Compressed DICOM (JPEG 2000) isn't supported yet"
        #expect(PreviewStatusText.failureMessage(for: MIQError.unsupportedFeature(reason)) == reason)
        #expect(PreviewStatusText.failureMessage(for: MIQError.truncatedData) == "Preview failed: File appears truncated.")
    }

    @Test func deferredWordingDistinguishesICloud() {
        let cloud = PreviewStatusText.deferredMessage(name: "a.nii", sizeText: "2 GB", isDataless: true)
        let network = PreviewStatusText.deferredMessage(name: "a.nii", sizeText: "2 GB", isDataless: false)
        #expect(cloud.contains("in iCloud (not downloaded)"))
        #expect(!cloud.contains("network volume"))
        #expect(network.contains("on a network volume"))
    }

    private static func allBlank(_ labels: SliceOrientationLabels) -> Bool {
        [labels.leading, labels.trailing, labels.top, labels.bottom].allSatisfy { $0.isEmpty }
    }

    @Test func configDefaultsForSummaries() {
        #expect(MIQConfig.Defaults.qcPanelEnabled)
        #expect(MIQConfig.Defaults.temporalSummaryEnabled)
    }
}
