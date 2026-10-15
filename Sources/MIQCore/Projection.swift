import Foundation

/// Intensity projection through a volume along a plane's slice axis.
public enum ProjectionMode: String, CaseIterable, Sendable {
    /// Maximum intensity projection: the brightest finite voxel along each ray
    /// (vessels on angiography, bone, contrast).
    case mip
    /// Minimum intensity projection: the darkest finite voxel along each ray
    /// (airways, emphysema on lung CT).
    case minip

    /// Short English menu title.
    public var displayName: String {
        switch self {
        case .mip: return "MIP"
        case .minip: return "MinIP"
        }
    }
}

extension MIQVolume {
    /// Projects timepoint `volumeIndex` through its full extent perpendicular to
    /// `plane`, producing the same `SliceImage` a regular `slice(plane:…)` call
    /// does — same pixel grid, orientation, flips, reorientation mode
    /// (`options.orientation`), physical-spacing resample and `maxDimension` cap —
    /// so it drops into the existing windowing and RGBA/CGImage pipeline as is.
    ///
    /// * Values are *scaled* (slope/intercept applied, as `voxel()` returns them),
    ///   so a `WindowPreset` or a shared window's bounds apply unchanged.
    /// * Non-finite voxels (NaN, ±Inf) are ignored; a ray with no finite voxel
    ///   renders black.
    /// * `windowBounds` `nil` derives a percentile window from the projection
    ///   itself (`options.lowerPercentile/upperPercentile`). Pass the slice window
    ///   instead to keep brightness comparable with the regular slices — though a
    ///   MIP is brighter than any one slice by construction, so its own window
    ///   usually reads better.
    /// * `maxSamplesAlongAxis` caps how many positions along the projection axis
    ///   are visited (evenly spaced, both ends included) for a quicker *approximate*
    ///   projection of a large volume; `nil` (default) visits every voxel, which
    ///   is exact. The in-plane resolution is always full before the resample.
    /// * Segmentation colouring is not applied (a max over label IDs is not a
    ///   meaningful label), and RGB datatypes return `nil`.
    ///
    /// Cost is one pass over the timepoint's voxels, read in storage order —
    /// comparable to a whole-volume window scan, far more than a single slice, so
    /// callers should render it off the main thread and cache it per
    /// (plane, mode, t, orientation).
    public func projection(
        plane: SlicePlane,
        mode: ProjectionMode,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds? = nil,
        maxSamplesAlongAxis: Int? = nil
    ) -> SliceImage? {
        renderProjection(
            plane: plane,
            mode: mode,
            volumeIndex: volumeIndex,
            maxDimension: maxDimension,
            options: options,
            windowBounds: windowBounds,
            maxSamplesAlongAxis: maxSamplesAlongAxis
        )
    }
}
