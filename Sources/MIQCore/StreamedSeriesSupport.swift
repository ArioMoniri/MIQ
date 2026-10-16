import Foundation

/// Which series-wide passes the preview runs for a 4D NIfTI it decodes one
/// volume at a time (`NiftiVolumeReader`, used over the decompression budget),
/// and which it leaves out rather than computing them from missing volumes.
extension PreviewDataSummaries {
    /// Whether the shared 4D window (`MIQVolume.sharedVolumeWindow(volumeCount:…)`)
    /// is computed from ≤ 8 sampled volumes through the reader. Cheap except for
    /// a `.nii.gz` on a network volume, where reaching the last sample means
    /// pulling the whole compressed file over the link; the preview then uses
    /// per-volume windows and says so ("per volume").
    public static func streamedSharedWindowAllowed(compressed: Bool, readsOverNetwork: Bool) -> Bool {
        !(compressed && readsOverNetwork)
    }

    /// Whether the temporal summary runs on a streamed series: the same
    /// content rules as `shouldRunTemporalSummary` (scalar, not a label map, at
    /// least `minimumTemporalVolumes`, at most `maximumTemporalVoxelsPerVolume`
    /// per volume), minus the in-memory and budget conditions — the streamed
    /// pass (`TemporalStats.summary(volumeCount:…volumeAt:)`) holds one volume
    /// at a time. It reads every volume once, so it runs only for a local file;
    /// on a network volume the row is omitted rather than pulling the series.
    public static func shouldRunStreamedTemporalSummary(
        header: MIQHeader,
        isLabelMap: Bool,
        readsOverNetwork: Bool
    ) -> Bool {
        guard !readsOverNetwork, !isLabelMap else { return false }
        guard header.datatype != .rgb24, header.datatype != .rgba32 else { return false }
        guard header.volumes >= minimumTemporalVolumes else { return false }
        let (spatial, overflow) = header.width.multipliedReportingOverflow(by: header.height)
        let (voxels, overflow2) = spatial.multipliedReportingOverflow(by: header.depth)
        return !overflow && !overflow2 && voxels > 0 && voxels <= maximumTemporalVoxelsPerVolume
    }
}
