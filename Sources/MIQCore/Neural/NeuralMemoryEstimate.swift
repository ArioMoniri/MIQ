import Foundation

/// Rough upper bound on the memory a `NeuralMaskEngine.run` needs, so a caller can
/// refuse a volume up front with a clear message instead of letting the process
/// be killed for running out of memory halfway through.
///
/// The estimate counts the large buffers only, each at full size even when the
/// engine would crop the grid (the crop is unknown before conforming):
/// - the source as `Float` (`NeuralInputVolume`) plus the `UInt8` labels and a
///   `Float` probability the mapping back to the source grid may hold;
/// - the conformed `gridSize³` grid, twice (resampled + normalised copy);
/// - two activation tensors of `gridSize³ × widest layer` floats (a convolution's
///   input and output), plus 25 % for im2col scratch and allocator slack.
/// It is deliberately pessimistic: a volume it accepts fits comfortably.
public enum NeuralMemoryEstimate {
    /// Peak bytes for a source of `sourceVoxelCount` voxels on a `gridSize³` model
    /// grid whose widest layer has `maxChannels` channels.
    public static func peakBytes(sourceVoxelCount: Int, gridSize: Int, maxChannels: Int) -> Int {
        let source = Double(max(0, sourceVoxelCount)) * (4 + 1 + 4)
        let grid = pow(Double(max(1, gridSize)), 3)
        let conformed = grid * 4 * 2
        let activations = grid * Double(max(1, maxChannels)) * 4 * 2 * 1.25
        let total = source + conformed + activations
        return total >= Double(Int.max) ? Int.max : Int(total)
    }

    /// Peak bytes for running `model` with `options` on `sourceVoxelCount` voxels.
    public static func peakBytes(sourceVoxelCount: Int, model: NeuralModel, options: NeuralRunOptions) -> Int {
        peakBytes(sourceVoxelCount: sourceVoxelCount, gridSize: options.gridSize, maxChannels: model.maxChannels)
    }

    /// A conservative default budget: half the machine's physical memory, capped
    /// at 8 GiB (the app also holds the parsed source volume and the previews).
    public static var defaultBudget: Int {
        let half = ProcessInfo.processInfo.physicalMemory / 2
        let cap: UInt64 = 8 << 30
        return Int(min(half, cap))
    }

    /// `nil` when the run fits in `budget`; otherwise a display-ready reason.
    public static func refusalReason(
        sourceVoxelCount: Int,
        model: NeuralModel,
        options: NeuralRunOptions,
        budget: Int = NeuralMemoryEstimate.defaultBudget
    ) -> String? {
        let need = peakBytes(sourceVoxelCount: sourceVoxelCount, model: model, options: options)
        guard need > budget else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return "This volume needs about \(formatter.string(fromByteCount: Int64(need))) of memory for the brain mask, "
            + "more than the \(formatter.string(fromByteCount: Int64(budget))) MIQ allows. "
            + "Try a coarser grid or a smaller volume."
    }
}

extension NeuralModel {
    /// The widest activation in the network (its largest `outChannels`, or the input
    /// channel count when larger).
    public var maxChannels: Int {
        layers.reduce(inputChannels) { widest, layer in
            if case .conv3D(let conv) = layer { return max(widest, conv.outChannels, conv.inChannels) }
            return widest
        }
    }
}
