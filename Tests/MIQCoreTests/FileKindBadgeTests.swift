import Foundation
import Testing
@testable import MIQCore

/// `MIQFileKind.badgeLabel` is what Finder prints on the thumbnail badge, so a
/// compressed volume must read as its format rather than as "GZ".
struct FileKindBadgeTests {
    @Test(arguments: [
        ("brain.nii", "NII"),
        ("brain.nii.gz", "NII"),
        ("BRAIN.NII.GZ", "NII"),
        ("orig.mgh", "MGH"),
        ("orig.mgz", "MGZ"),
        ("orig.mgh.gz", "MGZ"),
        ("dwi.mif", "MIF"),
        ("dwi.mif.gz", "MIF"),
        ("atlas.nrrd", "NRRD"),
    ])
    func labelFollowsFormatNotCompression(fileName: String, expected: String) throws {
        let kind = try #require(MIQFileKind(url: URL(fileURLWithPath: "/tmp/\(fileName)")))
        #expect(kind.badgeLabel == expected)
    }

    /// Finder renders the badge in a small fixed slot; keep every label short,
    /// upper-case and distinct from the generic "GZ" archive badge.
    @Test func labelsAreShortUppercaseFormatNames() {
        for kind in MIQFileKind.allCases {
            let label = kind.badgeLabel
            #expect(!label.isEmpty && label.count <= 4)
            #expect(label == label.uppercased())
            #expect(label != "GZ")
        }
    }
}
