import Foundation

/// Direction-encoded colour (DEC) rendering for diffusion vector fields such as
/// a tensor fit's principal eigenvector (FSL `dtifit` `*_V1`, MRtrix `tensor2metric -vector`).
///
/// Convention: R = |left–right|, G = |anterior–posterior|, B = |superior–inferior|
/// component of the vector **in world space**, each multiplied by FA (when given)
/// and by `gain`, clamped to [0, 1]. Vectors are assumed stored in the image's
/// voxel-axis frame (FSL's convention) and are rotated into world space by the
/// affine's direction cosines (voxel scaling removed), so an oblique or permuted
/// acquisition still shows anatomical colours. Pass `.world` for fields already
/// in world/scanner coordinates.
///
/// Note on FSL: `dtifit` writes vectors in FSL's radiological voxel convention,
/// which for a neurological-orientation (det > 0) image flips the x component.
/// `.voxel` undoes that flip before rotating. Taking |component| afterwards does
/// *not* make the flip harmless: for an oblique affine the rotation mixes x into
/// the other world axes, so an unflipped vector lands on the wrong colour (for an
/// axis-aligned affine the two agree).
public enum DiffusionColor {
    public enum VectorFrame: Sendable, Hashable {
        /// Components along the image's storage axes (i, j, k) in FSL's convention —
        /// x negated when the affine's determinant is positive — un-flipped, then
        /// rotated by the affine.
        case voxel
        /// Components already in world RAS axes.
        case world
    }

    /// NIfTI `intent_code` for a vector field (`NIFTI_INTENT_VECTOR`).
    public static let vectorIntentCode = 1007

    /// True for file names following the principal-eigenvector conventions
    /// (`dti_V1.nii.gz`, `sub-01_V1.nii`, `…V1…`). Case-sensitive on `V1`, so
    /// unrelated lowercase "v1" (e.g. a version tag) doesn't match.
    public static func isVectorFieldName(_ fileName: String) -> Bool {
        let stem = SiblingFiles.stripImageExtension(fileName)
        return stem.contains("V1")
    }

    /// The three vector components of `volume` as a volume whose volumes 0, 1, 2
    /// are the x, y, z components, or `nil` when it doesn't hold a 3-vector field:
    ///
    /// - NIfTI 5D with `dim[5] == 3` and a single timepoint (`dim[4] == 1`): the
    ///   components are the 5th axis, which in canonical layout sits exactly where
    ///   volumes 0…2 would. Returned as a view with `dim[4] = 3` over the same
    ///   storage (no copy). Requires the whole payload, so a `.nii.gz` must be
    ///   parsed with `fullyDecompress: true`; a truncated payload returns `nil`.
    /// - 4D with exactly 3 volumes and a name matching `isVectorFieldName`
    ///   (pass `fileName`), or with intent code 1007.
    public static func vectorComponents(of volume: MIQVolume, fileName: String? = nil) -> MIQVolume? {
        let header = volume.image.header
        let w = volume.width, h = volume.height, d = volume.depth
        let bytesPerComponent = w * h * d * header.datatype.bytesPerVoxel
        guard header.datatype != .rgb24, header.datatype != .rgba32, bytesPerComponent > 0 else { return nil }

        if volume.componentCount == 3, volume.volumes == 1 {
            guard volume.image.payloadElementStrides == nil,
                  volume.image.payloadCount >= bytesPerComponent * 3 else { return nil }
            var dims = header.dimensions
            dims[3] = 3
            dims[4] = 1
            let reshaped = MIQHeader(
                littleEndian: header.littleEndian, dimensions: dims, pixdim: header.pixdim,
                datatype: header.datatype, voxOffset: header.voxOffset,
                sclSlope: header.sclSlope, sclInter: header.sclInter,
                qformCode: header.qformCode, sformCode: header.sformCode,
                srowX: header.srowX, srowY: header.srowY, srowZ: header.srowZ,
                formatLabel: header.formatLabel, datatypeLabel: header.datatypeLabel,
                orientationFrame: header.orientationFrame
            )
            return MIQVolume(image: MIQImage(
                header: reshaped, storage: volume.image.storage,
                payloadOffset: volume.image.payloadOffset, payloadElementStrides: nil
            ))
        }
        if volume.volumes == 3, volume.componentCount == 1 {
            let named = fileName.map(isVectorFieldName) ?? false
            guard named || volume.niftiIntentCode == vectorIntentCode else { return nil }
            guard volume.containsAllVolumes else { return nil }
            return volume
        }
        return nil
    }

    /// 3×3 matrix taking stored vectors to world for `volume`. For `.voxel` this is
    /// the affine's direction cosines with the first column negated when
    /// det(affine) > 0, which undoes FSL's radiological x flip in the same step.
    static func rotation(for volume: MIQVolume, frame: VectorFrame) -> [[Float]] {
        switch frame {
        case .world:
            return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        case .voxel:
            let affine = volume.voxelToWorld
            let flipX: Double = affine.determinant > 0 ? -1 : 1
            return affine.directionCosines.map { row in
                [Float(row[0] * flipX), Float(row[1]), Float(row[2])]
            }
        }
    }

    /// DEC colour of one vector already rotated to world space.
    @inline(__always)
    static func color(world v: (Float, Float, Float), fa: Float, gain: Float) -> (UInt8, UInt8, UInt8) {
        let k = (fa.isFinite ? max(0, fa) : 0) * gain
        @inline(__always) func u8(_ c: Float) -> UInt8 {
            guard c.isFinite else { return 0 }
            return UInt8(min(255, max(0, (abs(c) * k * 255).rounded())))
        }
        return (u8(v.0), u8(v.1), u8(v.2))
    }

    /// DEC colour of the voxel at storage index (x, y, z). `components` must come
    /// from `vectorComponents(of:)`; `fa`, when given, must share its grid.
    public static func color(
        components: MIQVolume,
        x: Int, y: Int, z: Int,
        fa: MIQVolume? = nil,
        frame: VectorFrame = .voxel,
        gain: Float = 1
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r = rotation(for: components, frame: frame)
        let v = (components.voxel(x: x, y: y, z: z, t: 0),
                 components.voxel(x: x, y: y, z: z, t: 1),
                 components.voxel(x: x, y: y, z: z, t: 2))
        let world = rotate(r, v)
        let f = fa?.voxel(x: x, y: y, z: z) ?? 1
        let c = color(world: world, fa: f, gain: gain)
        return (c.0, c.1, c.2)
    }

    @inline(__always)
    static func rotate(_ r: [[Float]], _ v: (Float, Float, Float)) -> (Float, Float, Float) {
        (r[0][0] * v.0 + r[0][1] * v.1 + r[0][2] * v.2,
         r[1][0] * v.0 + r[1][1] * v.1 + r[1][2] * v.2,
         r[2][0] * v.0 + r[2][1] * v.1 + r[2][2] * v.2)
    }

    /// DEC-coloured display slice, laid out exactly like `components.slice(plane:index:…)`
    /// (same orientation plan and pixel-spacing resampling). `fa` must be on the
    /// same grid as `components` (resample it with `OverlayResampler` first if
    /// not); FA slices with a different size are ignored. `nil` when
    /// `components` isn't a 3-volume field.
    public static func slice(
        components: MIQVolume,
        plane: SlicePlane,
        index: Int,
        fa: MIQVolume? = nil,
        frame: VectorFrame = .voxel,
        gain: Float = 1,
        maxDimension: Int = 512,
        options: RenderingOptions
    ) -> SliceImage? {
        guard components.volumes >= 3,
              let cx = components.displaySliceValues(plane: plane, index: index, volumeIndex: 0, options: options),
              let cy = components.displaySliceValues(plane: plane, index: index, volumeIndex: 1, options: options),
              let cz = components.displaySliceValues(plane: plane, index: index, volumeIndex: 2, options: options)
        else { return nil }
        var faValues: [Float]?
        if let fa, fa.width == components.width, fa.height == components.height, fa.depth == components.depth,
           let s = fa.displaySliceValues(plane: plane, index: index, options: options), s.values.count == cx.values.count {
            faValues = s.values
        }
        let r = rotation(for: components, frame: frame)
        let n = cx.values.count
        var rgb = [UInt8](repeating: 0, count: n * 3)
        for i in 0..<n {
            let world = rotate(r, (cx.values[i], cy.values[i], cz.values[i]))
            let c = color(world: world, fa: faValues?[i] ?? 1, gain: gain)
            rgb[i * 3] = c.0
            rgb[i * 3 + 1] = c.1
            rgb[i * 3 + 2] = c.2
        }

        // Mirror MIQVolume.finalize's pixel-spacing resample so the DEC slice has the
        // same on-screen size and aspect as the grayscale slice of this plane.
        let geometry = components.sliceGeometry(for: plane, options: options)
        let pixdim = components.image.header.pixdim
        func spacing(_ axis: Int) -> Float { sanitizedSpacing(pixdim[safe: axis + 1] ?? 1) }
        let maxExtent = max(
            Float(components.width) * spacing(0),
            Float(components.height) * spacing(1),
            Float(components.depth) * spacing(2)
        )
        let image = RGBImage(width: cx.width, height: cx.height, pixels: rgb)
        return .rgb(image.resampledForPixelSpacing(
            pixelSpacingX: spacing(geometry.horizontalAxis),
            pixelSpacingY: spacing(geometry.verticalAxis),
            maxPhysicalExtent: maxExtent,
            maxDimension: maxDimension
        ))
    }
}
