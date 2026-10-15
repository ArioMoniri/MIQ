import Foundation

// MARK: - Camera

/// Orbit camera for the 3D volume preview. Projection is orthographic (the
/// conventional choice for MIP/DVR previews: no perspective distortion, and the
/// whole volume stays framed at every angle).
///
/// ## Convention (patient RAS world, millimetres, volume centred on the origin)
/// - `azimuth == 0, elevation == 0` is the **anterior view**: the camera sits at
///   +A looking toward −A, so the patient's face points at the viewer. Screen up
///   is +S and — as when facing a person — the patient's **right appears on the
///   screen's left** (screen right = +L).
/// - Positive `azimuth` (degrees) orbits the camera about the S axis from +A
///   toward +R: `azimuth == 90` is the right-lateral view (camera at +R, screen
///   right = +A), `180` the posterior view (screen right = +R), `-90`/`270` the
///   left-lateral view.
/// - Positive `elevation` (degrees) raises the camera toward +S (looking down on
///   the vertex); it is clamped to ±89.9° so the up vector stays defined.
/// - `zoom == 1` frames the volume's full bounding-box diagonal across the
///   shorter output side, so no rotation ever clips it; `2` doubles magnification.
public struct VolumeRenderCamera: Sendable, Hashable {
    public var azimuth: Float
    public var elevation: Float
    public var zoom: Float

    public init(azimuth: Float = 0, elevation: Float = 0, zoom: Float = 1) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.zoom = zoom
    }

    public static let anterior = VolumeRenderCamera(azimuth: 0)
    public static let posterior = VolumeRenderCamera(azimuth: 180)
    public static let right = VolumeRenderCamera(azimuth: 90)
    public static let left = VolumeRenderCamera(azimuth: -90)
    public static let superior = VolumeRenderCamera(azimuth: 0, elevation: 89.9)
}

// MARK: - Mode / colour

/// What the ray caster accumulates along each ray.
public enum VolumeRenderMode: Sendable, Hashable, CaseIterable {
    /// Maximum-intensity projection.
    case mip
    /// Minimum-intensity projection (only samples inside the volume box count).
    case minIP
    /// Direct volume rendering: front-to-back alpha compositing through the 1D
    /// transfer function (opacity ramp over the window), optional gradient shading.
    case dvr
    /// Label map: nearest-neighbour label lookup, colour from
    /// `VolumeRenderOptions.labelColor`, high opacity and shading from the
    /// gradient of the foreground occupancy — a surface-like rendering. Requires
    /// a grid built with `asLabels: true`.
    case labels
}

/// Colour ramp applied to the windowed intensity (MIP/MinIP/DVR).
public enum VolumeColormap: String, Sendable, Hashable, CaseIterable {
    case grayscale
    case hot
    case bone

    /// RGB in 0…1 for a normalised intensity `t` in 0…1.
    func rgb(_ t: Float) -> (Float, Float, Float) {
        let t = min(max(t, 0), 1)
        switch self {
        case .grayscale:
            return (t, t, t)
        case .hot:
            return (min(1, t * 3), min(1, max(0, t * 3 - 1)), min(1, max(0, t * 3 - 2)))
        case .bone:
            // Matplotlib-style "bone": grayscale with a blue tint in the mids.
            let r = t < 0.75 ? t * 0.875 : 0.65625 + (t - 0.75) * 1.375
            let g = t < 0.375 ? t * 0.875 : (t < 0.75 ? 0.328125 + (t - 0.375) * 1.208333 : 0.78125 + (t - 0.75) * 0.875)
            let b = t < 0.375 ? t * 1.208333 : 0.453125 + (t - 0.375) * 0.875
            return (min(1, r), min(1, g), min(1, b))
        }
    }
}

/// 8-bit RGBA colour (straight, not premultiplied alpha).
public struct VolumeRenderColor: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = VolumeRenderColor(r: 0, g: 0, b: 0)
    public static let clear = VolumeRenderColor(r: 0, g: 0, b: 0, a: 0)
}

/// Maps an integer label value to its display colour. Return `a == 0` to hide
/// a label. Label 0 is always background and is never passed.
public typealias VolumeLabelColorMap = @Sendable (Int) -> VolumeRenderColor

extension SegmentationLut {
    /// Label colours for `VolumeRenderMode.labels`, matching the 2D slice views
    /// exactly (same palette, fully opaque).
    public var volumeLabelColorMap: VolumeLabelColorMap {
        let lut = self
        return { label in
            let c = lut.lookup(label)
            return VolumeRenderColor(r: c.r, g: c.g, b: c.b, a: 255)
        }
    }
}

// MARK: - Options

/// Which implementation renders a frame. `.automatic` uses Metal when a device
/// is available and its kernel compiled and passed a CPU cross-check, else CPU;
/// any Metal failure at render time silently falls back to CPU.
public enum VolumeRenderBackend: Sendable, Hashable {
    case automatic
    case cpu
    case metal
}

public struct VolumeRenderOptions: Sendable {
    /// Ray sample spacing in units of the grid's smallest voxel spacing.
    /// 1 = one sample per voxel (default); < 1 is finer and slower. DVR opacity is
    /// corrected for the step so the look doesn't change with this setting.
    public var sampleSpacing: Float = 1
    /// Colour ramp for MIP/MinIP/DVR.
    public var colormap: VolumeColormap = .grayscale
    /// DVR opacity per reference step (one voxel) for a sample at or above the
    /// window high; the ramp is linear from 0 at the window low. Lower = more
    /// translucent.
    public var opacityScale: Float = 0.12
    /// Exponent applied to the opacity ramp (`t^gamma`): > 1 suppresses faint
    /// tissue near the window low.
    public var opacityGamma: Float = 1.5
    /// Lambert + headlight specular shading from central-difference gradients
    /// (DVR and labels).
    public var shading: Bool = true
    /// Front-to-back compositing stops once accumulated alpha reaches this.
    public var earlyTerminationAlpha: Float = 0.98
    /// Per-step opacity for label voxels (multiplied by the label colour's alpha).
    public var labelOpacity: Float = 0.85
    /// Label → colour. `nil` uses `SegmentationLut`'s per-label hash palette.
    public var labelColor: VolumeLabelColorMap? = nil
    /// Colour behind the volume (alpha ignored; output is opaque RGBA).
    public var background: VolumeRenderColor = .black
    public var backend: VolumeRenderBackend = .automatic

    public init() {}
}

public enum VolumeRenderError: Error, Equatable, Sendable {
    /// Output width/height must be in 1…4096.
    case invalidOutputSize
    /// The grid is empty.
    case emptyVolume
    /// `.labels` mode was requested on a grid not built with `asLabels: true`.
    case notALabelGrid
}
