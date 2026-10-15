import Foundation

/// Estimates how many bytes a volume's decoded payload occupies in memory, from
/// its header alone (dimensions × bytes per voxel), so callers can refuse work
/// that would decompress more than an extension can afford *before* doing it.
///
/// The on-disk size is a poor proxy for that cost: a gzipped label map or a
/// mostly-zero 4D series can compress 50–100×, so a 40 MB `.mgz` may inflate to
/// several GB. The header states the true extent up front.
///
/// Apple publishes no memory limit for Quick Look preview or thumbnail
/// extensions; the budgets below are deliberately conservative guesses that
/// cover typical research and clinical data (a 256³ float T1 is 64 MiB, a
/// 96×96×60×100 float DWI series ~211 MiB) while refusing the multi-GB series
/// that would get the extension jetsammed mid-decompress.
public enum MIQPayloadSizeEstimate {
    /// Largest fully decompressed payload the Quick Look preview will expand for
    /// 4D navigation (1.5 GiB). Above it, the preview keeps showing volume 0 and
    /// explains why the other volumes are unavailable. No Apple-documented limit
    /// exists for preview extensions; this leaves headroom for the decode buffers
    /// and slice images that sit next to the payload.
    public static let previewFullDecompressionBudgetBytes = 3 * 512 * 1024 * 1024

    /// Largest decoded payload a Finder thumbnail may materialize (256 MiB).
    /// Lower than the preview's because Finder spawns one thumbnail request per
    /// visible icon, several at a time, in a single extension process.
    public static let thumbnailDecompressedBudgetBytes = 256 * 1024 * 1024

    /// `product(dimensions) × bytesPerVoxel`, or `nil` when the product overflows
    /// `Int` (a crafted header). Non-positive dimensions count as 1, matching how
    /// the parsers pad unused axes.
    public static func bytes(dimensions: [Int], bytesPerVoxel: Int) -> Int? {
        var product = max(1, bytesPerVoxel)
        for dim in dimensions {
            let (next, overflow) = product.multipliedReportingOverflow(by: max(1, dim))
            guard !overflow else { return nil }
            product = next
        }
        return product
    }

    /// Decimal gigabytes with one fraction digit ("2.4 GB"), matching Finder's
    /// own size display.
    public static func gigabytesText(_ bytes: Int) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }

    /// Short status text for a 4D file whose full payload exceeds
    /// `previewFullDecompressionBudgetBytes`.
    public static func tooLargeFor4DMessage(bytes: Int) -> String {
        "Too large for 4D in Quick Look (\(gigabytesText(bytes)))"
    }
}

extension MIQHeader {
    /// Decoded size of the whole payload (every volume, and any axes past the
    /// 4th that the parser kept in `dimensions`). `nil` on overflow. For NRRD and
    /// MIF files with more than four axes this is a lower bound: `MIQHeader`
    /// carries at most four dimensions for those formats.
    public var estimatedPayloadBytes: Int? {
        MIQPayloadSizeEstimate.bytes(dimensions: dimensions, bytesPerVoxel: datatype.bytesPerVoxel)
    }

    /// Decoded size of volume 0 alone (`width × height × depth × bytesPerVoxel`).
    public var estimatedVolumeZeroBytes: Int? {
        MIQPayloadSizeEstimate.bytes(dimensions: [width, height, depth], bytesPerVoxel: datatype.bytesPerVoxel)
    }

    /// Whether fully decompressing this file for 4D navigation would exceed
    /// `budgetBytes`. An unrepresentable (overflowing) extent always exceeds it.
    public func exceedsFullDecompressionBudget(
        _ budgetBytes: Int = MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes
    ) -> Bool {
        guard let bytes = estimatedPayloadBytes else { return true }
        return bytes > budgetBytes
    }
}

extension MIQFileKind {
    /// The decoded bytes a thumbnail of this kind would hold in memory: volume 0
    /// for canonical NIfTI (the parser caps decompression and the network read
    /// there), the whole payload for every other kind (they decompress/read in
    /// full). Feed it to `declinesThumbnail(estimatedDecompressedBytes:)`.
    public func estimatedThumbnailDecodeBytes(header: MIQHeader) -> Int? {
        supportsBoundedNetworkRead ? header.estimatedVolumeZeroBytes : header.estimatedPayloadBytes
    }
}
