import Foundation

/// Intensity projection through a volume along a plane's slice axis.
public enum ProjectionMode: String, CaseIterable, Sendable {
    /// Maximum intensity projection: the brightest finite voxel along each ray
    /// (vessels on angiography, bone, contrast).
    case mip
    /// Minimum intensity projection: the darkest finite voxel along each ray
    /// (airways, emphysema on lung CT), ignoring the volume's flat background
    /// (see `MinIPBackground`) so a zero-filled MR is not all black.
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
    /// * MinIP ignores the volume's flat background *outside the object* along
    ///   each ray (`MinIPBackground`): the leading and trailing runs of voxels at
    ///   or below the background floor — zero fill around an MR head, CT padding
    ///   outside the reconstruction circle — so they no longer win every ray.
    ///   Background-valued voxels *between* foreground voxels still count, and a
    ///   ray with only background voxels renders black.
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

    /// `MinIPBackground.floor` of timepoint `volumeIndex`, estimated on an evenly
    /// strided sample of at most `maxSamplesPerAxis`³ voxels (the floor test
    /// needs a fraction, not every voxel; voxels below a missed minimum are
    /// excluded anyway, since MinIP skips everything *at or below* the floor).
    func minIPBackgroundFloor(volumeIndex: Int, maxSamplesPerAxis: Int = 64) -> Float? {
        let dims = [width, height, depth]
        guard dims.allSatisfy({ $0 > 0 }), volumeIndex >= 0, volumeIndex < volumes else { return nil }
        let axes = dims.map { Self.sharedWindowSampleIndices(volumeCount: $0, maxSamples: maxSamplesPerAxis) }
        var sample: [Float] = []
        sample.reserveCapacity(axes[0].count * axes[1].count * axes[2].count)
        for z in axes[2] {
            for y in axes[1] {
                for x in axes[0] {
                    sample.append(voxel(x: x, y: y, z: z, t: volumeIndex))
                }
            }
        }
        return MinIPBackground.floor(of: sample)
    }
}

/// The "flat background" a minimum-intensity projection ignores, shared by the
/// 2D projection (`MIQVolume.projection(mode: .minip)`) and the 3D ray caster
/// (`VolumeRenderMode.minIP`).
///
/// **Floor.** The finite minimum `m` of the data is a background floor when at
/// least `minimumFraction` of the finite values, and at least `minimumCount`
/// of them, equal `m` exactly (a background is an extended region: a handful of
/// darkest voxels in a tiny volume are data). Zero fill
/// around an MR head, skull-stripped data and CT padding outside the field of
/// view (−1024/−2048/−3024) are constant by construction and sit at the
/// minimum; real tissue and real air are noisy, so their minimum is held by a
/// handful of voxels.
///
/// **Outside the object.** Along each ray only the leading and trailing runs of
/// at-or-below-floor samples are dropped — the padding between the volume's
/// edge and the body. A floor-valued region enclosed by foreground along the ray
/// (a synthetic dark insert, a zeroed lesion mask) still projects. Hence:
/// * MR with a zero background: MinIP shows the darkest *tissue* (ventricles,
///   vessels on SWI) instead of a black frame.
/// * CT with padding: the padding is dropped; air inside the field of view is
///   noisy, so it is foreground and airway/lung MinIP is unchanged.
/// * Data without a flat floor (noisy MR background, cropped CT): nothing is
///   dropped — the classic MinIP.
/// A QC head mask would also delimit "outside", but it is optional, computed
/// off-thread and on a different grid; this rule is deterministic, needs only
/// the values, and is identical in the CPU caster and the Metal kernel.
public enum MinIPBackground {
    /// Share of finite values that must sit exactly at the minimum.
    public static let minimumFraction = 0.01
    /// Minimum number of values at the minimum (a 4×4×4 block).
    public static let minimumCount = 64

    /// The background floor of `values`, or `nil` when there is none.
    public static func floor<S: Sequence>(of values: S) -> Float? where S.Element == Float {
        var minimum = Float.infinity
        var atMinimum = 0
        var finite = 0
        for v in values where v.isFinite {
            finite += 1
            if v < minimum {
                minimum = v
                atMinimum = 1
            } else if v == minimum {
                atMinimum += 1
            }
        }
        guard finite > 0, atMinimum >= minimumCount,
              Double(atMinimum) >= minimumFraction * Double(finite) else { return nil }
        // A constant volume has nothing but "background": keep the classic MinIP.
        guard atMinimum < finite else { return nil }
        return minimum
    }
}
