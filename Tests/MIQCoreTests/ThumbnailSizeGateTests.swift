import Testing
@testable import MIQCore

/// `MIQFileKind.declinesThumbnail` keeps Finder from fully decompressing one
/// large file per icon, without costing thumbnails that are cheap to render.
struct ThumbnailSizeGateTests {
    private static let threshold = 100

    @Test func boundedNiftiNeverDeclines() {
        for kind in [MIQFileKind.nii, .niiGz] {
            for isLocal in [true, false] {
                #expect(!kind.declinesThumbnail(fileSizeBytes: 1_000, isLocal: isLocal, thresholdBytes: Self.threshold))
            }
        }
    }

    @Test func largeFullReadKindsDecline() {
        for kind in [MIQFileKind.mgz, .mifGz, .nrrd] {
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: true, thresholdBytes: Self.threshold))
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func atOrBelowThresholdRenders() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(fileSizeBytes: Self.threshold, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func largeUncompressedMghMifDeclineOnlyOnNetwork() {
        for kind in [MIQFileKind.mgh, .mif] {
            // Memory-mapped locally: only the centre slice's pages are read.
            #expect(!kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: true, thresholdBytes: Self.threshold))
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func unknownSizeNeverDeclines() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(fileSizeBytes: nil, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    // MARK: - Decoded-size budget

    private static let budget = 1_000

    @Test func overBudgetDeclinesWhenPayloadIsMaterialized() {
        // Compressed kinds, NRRD, and anything on a network volume inflate or read
        // the payload into RAM — including canonical NIfTI's volume 0.
        for kind in MIQFileKind.allCases {
            for isLocal in [true, false] where kind.isCompressed || kind == .nrrd || !isLocal {
                #expect(kind.declinesThumbnail(
                    fileSizeBytes: 10, isLocal: isLocal, thresholdBytes: Self.threshold,
                    estimatedDecompressedBytes: Self.budget + 1, decompressedBudgetBytes: Self.budget
                ), "\(kind) local=\(isLocal)")
            }
        }
    }

    @Test func overBudgetLocalUncompressedStillRenders() {
        // Memory-mapped: only the centre slice's pages are touched.
        for kind in [MIQFileKind.nii, .mgh, .mif] {
            #expect(!kind.declinesThumbnail(
                fileSizeBytes: 10, isLocal: true, thresholdBytes: Self.threshold,
                estimatedDecompressedBytes: Self.budget * 1_000, decompressedBudgetBytes: Self.budget
            ))
        }
    }

    @Test func atOrUnderBudgetFallsBackToSizeGate() {
        for kind in MIQFileKind.allCases {
            for isLocal in [true, false] {
                let sizeOnly = kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: isLocal, thresholdBytes: Self.threshold)
                let withEstimate = kind.declinesThumbnail(
                    fileSizeBytes: Self.threshold + 1, isLocal: isLocal, thresholdBytes: Self.threshold,
                    estimatedDecompressedBytes: Self.budget, decompressedBudgetBytes: Self.budget
                )
                #expect(sizeOnly == withEstimate, "\(kind) local=\(isLocal)")
            }
        }
    }

    @Test func unknownEstimateKeepsSizeOnlyBehaviour() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(
                fileSizeBytes: 10, isLocal: false, thresholdBytes: Self.threshold,
                estimatedDecompressedBytes: nil, decompressedBudgetBytes: Self.budget
            ))
        }
    }

    @Test func defaultBudgetIsTheThumbnailConstant() {
        let big = MIQPayloadSizeEstimate.thumbnailDecompressedBudgetBytes + 1
        #expect(MIQFileKind.mgz.declinesThumbnail(fileSizeBytes: 10, isLocal: true, thresholdBytes: Self.threshold, estimatedDecompressedBytes: big))
        #expect(!MIQFileKind.mgz.declinesThumbnail(fileSizeBytes: 10, isLocal: true, thresholdBytes: Self.threshold, estimatedDecompressedBytes: big - 1))
    }
}
