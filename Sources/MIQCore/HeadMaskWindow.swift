import Foundation

extension MIQVolume {
    /// Whether `windowingHeadMask()` can return a mask at all, from the header
    /// alone: a single scalar 3D volume. 4D series, RGB data and empty extents
    /// keep the ordinary window.
    public var isHeadMaskWindowCandidate: Bool {
        let datatype = image.header.datatype
        return volumes == 1 && datatype != .rgb24 && datatype != .rgba32
            && width > 0 && height > 0 && depth > 0
    }

    /// The coarse `QCHeadMask` to restrict the auto window to (pass it as
    /// `headMask:` to `centerPreview` / `centerInteractiveState` /
    /// `fixedCenterWindow`), or `nil` when the volume is not an anatomical scalar
    /// 3D image: 4D, RGB, a label map / mask, CT (air is real signal at
    /// −1000 HU and presets own its window), or an empty/constant volume.
    ///
    /// Reuses `QCAnalyzer`'s classification and mask (metrics and the face check
    /// are skipped), so it costs one downsampled grid pass plus the morphology —
    /// tens of milliseconds for a 256³ T1. Synchronous and CPU-bound: call it off
    /// the main thread, once per loaded volume. Throws `CancellationError`.
    public func windowingHeadMask(maxGridDimension: Int = QCHeadMask.defaultMaxGridDimension) throws -> QCHeadMask? {
        guard isHeadMaskWindowCandidate else { return nil }
        let summary = try QCAnalyzer.analyze(
            volume: self,
            options: QCOptions(maxGridDimension: maxGridDimension, computeMetrics: false, checkFace: false)
        )
        guard summary.contentKind == .anatomical else { return nil }
        return summary.headMask
    }
}
