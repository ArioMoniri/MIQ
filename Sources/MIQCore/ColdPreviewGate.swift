import Foundation

/// Memory gate in front of the Quick Look preview's cold (uncached) parse.
///
/// The cold parse materialises the decoded payload (volume 0 for canonical
/// NIfTI, the whole payload for every other kind) before anything is on screen.
/// A tiny crafted header — say a 1 KB `.mha` claiming 4096³ doubles — would
/// otherwise make the extension try to allocate hundreds of GB and be killed.
/// The gate probes the header only (`MIQParser.probeHeader`, ≤ 64 KB of prefix)
/// and declines files whose decoded size exceeds the budget, so normal files
/// pay one small read and keep the fast path.
public enum MIQColdPreviewGate {
    /// Largest decoded payload the cold preview parse may materialise. Same as
    /// the 4D expansion budget: past it the extension risks being jetsammed.
    public static let budgetBytes = MIQPayloadSizeEstimate.previewFullDecompressionBudgetBytes

    /// The status text shown instead of the preview. `bytes` nil means the
    /// header's extent doesn't even fit in an `Int`.
    public static func tooLargeMessage(bytes: Int?) -> String {
        if let bytes {
            return "Too large to preview in Quick Look (\(MIQPayloadSizeEstimate.gigabytesText(bytes)))"
        }
        return "Too large to preview in Quick Look"
    }

    /// The refusal message for a probed header, or nil when the cold parse may
    /// proceed.
    ///
    /// Uncompressed `.nii` is memory-mapped rather than copied, so a *complete*
    /// file (its size on disk covers `voxOffset` + volume 0) costs address space,
    /// not RAM, and is allowed whatever its size. A header promising more than
    /// the file holds gets no such pass.
    public static func refusalMessage(
        header: MIQHeader,
        kind: MIQFileKind,
        fileSizeBytes: Int?,
        budgetBytes: Int = MIQColdPreviewGate.budgetBytes
    ) -> String? {
        guard let bytes = kind.estimatedThumbnailDecodeBytes(header: header) else {
            return tooLargeMessage(bytes: nil)
        }
        guard bytes > budgetBytes else { return nil }
        if kind == .nii, let fileSizeBytes {
            let (needed, overflow) = max(0, header.voxOffset).addingReportingOverflow(bytes)
            if !overflow, fileSizeBytes >= needed { return nil }
        }
        return tooLargeMessage(bytes: bytes)
    }

    /// Probes `url`'s header and applies `refusalMessage(header:kind:…)`.
    /// Returns nil (proceed) when the header can't be probed — DICOM, Zarr, a
    /// malformed header — so the full parse reports its own error as before.
    public static func refusalMessage(
        url: URL,
        parser: MIQParser = MIQParser(),
        budgetBytes: Int = MIQColdPreviewGate.budgetBytes
    ) -> String? {
        guard let kind = MIQFileKind(url: url),
              let header = try? parser.probeHeader(url: url) else { return nil }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return refusalMessage(header: header, kind: kind, fileSizeBytes: fileSize, budgetBytes: budgetBytes)
    }
}
