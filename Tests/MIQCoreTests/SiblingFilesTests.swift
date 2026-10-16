import Foundation
import Testing
@testable import MIQCore

struct SiblingFilesTests {

    @Test func extensionStripping() {
        #expect(SiblingFiles.stripImageExtension("sub-01_T1w.nii.gz") == "sub-01_T1w")
        #expect(SiblingFiles.stripImageExtension("aseg.mgz") == "aseg")
        #expect(SiblingFiles.stripImageExtension("dwi.mif.gz") == "dwi")
        #expect(SiblingFiles.stripImageExtension("notes.txt") == "notes.txt")
    }

    @Test func bidsOverlaysRequireSameSubjectAndSession() {
        let listing = [
            "sub-01_ses-1_T1w.nii.gz",
            "sub-01_ses-1_T1w.json",
            "sub-01_ses-1_desc-aseg_dseg.nii.gz",
            "sub-01_ses-1_desc-brain_mask.nii.gz",
            "sub-01_ses-1_label-GM_probseg.nii.gz",
            "sub-01_ses-2_desc-aseg_dseg.nii.gz",
            "sub-02_ses-1_desc-aseg_dseg.nii.gz",
            "sub-01_desc-aseg_dseg.nii.gz",
            "sub-01_ses-1_desc-preproc_T2w.nii.gz",
        ]
        let found = SiblingFiles.overlayCandidates(for: "sub-01_ses-1_T1w.nii.gz", in: listing)
        #expect(found.map(\.fileName) == [
            "sub-01_ses-1_desc-aseg_dseg.nii.gz",
            "sub-01_ses-1_desc-brain_mask.nii.gz",
            "sub-01_ses-1_label-GM_probseg.nii.gz",
        ])
        #expect(found.map(\.role) == [.segmentation, .mask, .probabilisticSegmentation])
    }

    @Test func bidsCompatibleEntitiesMustAgreeWhenBothPresent() {
        let listing = [
            "sub-01_acq-mprage_run-1_T1w.nii.gz",
            "sub-01_acq-mprage_run-1_space-T1w_desc-aseg_dseg.nii.gz",
            "sub-01_acq-mprage_run-2_desc-aseg_dseg.nii.gz",
            "sub-01_acq-other_desc-aseg_dseg.nii.gz",
            "sub-01_desc-aseg_dseg.nii.gz",
        ]
        let found = SiblingFiles.overlayCandidates(for: "sub-01_acq-mprage_run-1_T1w.nii.gz", in: listing).map(\.fileName)
        #expect(found == [
            "sub-01_acq-mprage_run-1_space-T1w_desc-aseg_dseg.nii.gz",
            "sub-01_desc-aseg_dseg.nii.gz",
        ])
    }

    @Test func bidsInverseFindsAnatomicalPreferringT1w() {
        let listing = [
            "sub-01_ses-1_T2w.nii.gz",
            "sub-01_ses-1_T1w.nii.gz",
            "sub-01_ses-2_T1w.nii.gz",
            "sub-01_ses-1_desc-brain_mask.nii.gz",
            "sub-01_ses-1_desc-aseg_dseg.nii.gz",
        ]
        let seg = "sub-01_ses-1_desc-aseg_dseg.nii.gz"
        #expect(SiblingFiles.looksLikeSegmentation(seg))
        let found = SiblingFiles.anatomicalCandidates(forSegmentation: seg, in: listing).map(\.fileName)
        #expect(found == ["sub-01_ses-1_T1w.nii.gz", "sub-01_ses-1_T2w.nii.gz"])
        // The direction-detecting entry point picks the inverse search too.
        #expect(SiblingFiles.candidates(for: seg, in: listing).first?.fileName == "sub-01_ses-1_T1w.nii.gz")
    }

    @Test func freeSurferMriDirectory() {
        let listing = ["T1.mgz", "brain.mgz", "orig.mgz", "aseg.mgz", "aparc+aseg.mgz", "wmparc.mgz", "norm.mgz", "transforms"]
        let overlays = SiblingFiles.overlayCandidates(for: "T1.mgz", in: listing).map(\.fileName)
        #expect(overlays == ["aparc+aseg.mgz", "aseg.mgz", "wmparc.mgz"])
        let fromBrain = SiblingFiles.overlayCandidates(for: "brain.mgz", in: listing).map(\.fileName)
        #expect(fromBrain.first == "aparc+aseg.mgz")
        let anat = SiblingFiles.candidates(for: "aseg.mgz", in: listing).map(\.fileName)
        #expect(anat == ["T1.mgz", "brain.mgz", "norm.mgz", "orig.mgz"])
    }

    @Test func fslAndPlainPrefixConventions() {
        let listing = ["T1.nii.gz", "T1_brain.nii.gz", "T1_brain_mask.nii.gz", "T1_brain_seg.nii.gz", "T1_brain_pve_1.nii.gz", "T1_other.nii.gz"]
        let fromBrain = SiblingFiles.overlayCandidates(for: "T1_brain.nii.gz", in: listing)
        #expect(fromBrain.map(\.fileName) == ["T1_brain_seg.nii.gz", "T1_brain_mask.nii.gz", "T1_brain_pve_1.nii.gz"])
        let anat = SiblingFiles.anatomicalCandidates(forSegmentation: "T1_brain_mask.nii.gz", in: listing).map(\.fileName)
        #expect(anat == ["T1_brain.nii.gz", "T1.nii.gz"])
    }

    @Test func totalSegmentatorOutputs() {
        let listing = ["ct.nii.gz", "segmentations", "segmentations.nii.gz", "ct_seg", "report.pdf"]
        let found = SiblingFiles.overlayCandidates(for: "ct.nii.gz", in: listing)
        #expect(Set(found.map(\.fileName)) == ["segmentations", "segmentations.nii.gz", "ct_seg"])
        #expect(found.allSatisfy { $0.role == .segmentationDirectory })
    }

    @Test func faForVectorField() {
        let listing = ["dti_V1.nii.gz", "dti_FA.nii.gz", "dti_MD.nii.gz", "dti_V2.nii.gz"]
        let fa = SiblingFiles.fractionalAnisotropyCandidates(forVectorField: "dti_V1.nii.gz", in: listing)
        #expect(fa.map(\.fileName) == ["dti_FA.nii.gz"])
        let all = SiblingFiles.candidates(for: "dti_V1.nii.gz", in: listing)
        #expect(all.contains { $0.role == .fractionalAnisotropy })
    }

    @Test func neverReturnsSelfOrNonImages() {
        let listing = ["sub-01_T1w.nii.gz", "sub-01_dseg.tsv", "sub-01_dseg.nii.gz"]
        let found = SiblingFiles.overlayCandidates(for: "sub-01_T1w.nii.gz", in: listing).map(\.fileName)
        #expect(found == ["sub-01_dseg.nii.gz"])
        #expect(!SiblingFiles.looksLikeSegmentation("sub-01_T1w.nii.gz"))
    }

    @Test func listingFailureIsNil() {
        #expect(SiblingFiles.listing(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) == nil)
    }
}
