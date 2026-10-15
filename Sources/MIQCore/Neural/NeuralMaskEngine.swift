import Foundation

/// How a model's inputs are prepared and its outputs interpreted.
public struct NeuralModelProfile: Sendable, Hashable {
    public var normalization: NeuralNormalization
    /// Crop to voxels above `cropThreshold · max` (0 → any voxel > 0) before inference.
    public var cropThreshold: Float
    /// Padding around the crop box, in millimetres (converted to grid voxels).
    public var cropPaddingMM: Double
    /// Classes that make up "brain" for a binary mask; nil → multi-label output
    /// (argmax labels mapped back with nearest-neighbour).
    public var foregroundClasses: Set<Int>?
    /// Keep only the largest 6-connected foreground component (binary masks only).
    public var keepLargestComponent: Bool

    public init(
        normalization: NeuralNormalization,
        cropThreshold: Float,
        cropPaddingMM: Double,
        foregroundClasses: Set<Int>?,
        keepLargestComponent: Bool
    ) {
        self.normalization = normalization
        self.cropThreshold = cropThreshold
        self.cropPaddingMM = cropPaddingMM
        self.foregroundClasses = foregroundClasses
        self.keepLargestComponent = keepLargestComponent
    }

    /// brainchop "omnimodal Skull Strip" (MindGrab, `Models/mindgrab`): 2 classes,
    /// class 1 = brain. Settings mirror brainchop-parameters.js (min-max normalisation,
    /// autoThreshold 0.5, cropPadding 20) plus brainchop's connected-component cleanup.
    public static let mindgrab = NeuralModelProfile(
        normalization: .minMax, cropThreshold: 0.5, cropPaddingMM: 20,
        foregroundClasses: [1], keepLargestComponent: true
    )

    /// brainchop "Brain Mask (FAST)" (`Models/model5_gw_ae`): 3 tissue classes
    /// (background / grey / white); any non-background class counts as brain.
    public static let brainMaskFast = NeuralModelProfile(
        normalization: .minMax, cropThreshold: 0, cropPaddingMM: 17,
        foregroundClasses: [1, 2], keepLargestComponent: true
    )

    /// Multi-label parcellation output with the given normalisation.
    public static func parcellation(normalization: NeuralNormalization = .quantile(lower: 0.02, upper: 0.98)) -> NeuralModelProfile {
        NeuralModelProfile(normalization: normalization, cropThreshold: 0, cropPaddingMM: 0,
                           foregroundClasses: nil, keepLargestComponent: false)
    }
}

/// Run-time knobs (speed/accuracy trade-offs).
public struct NeuralRunOptions: Sendable, Hashable {
    /// Model-grid spacing in mm. brainchop models are trained at 1 mm on a 256³ grid;
    /// 2 mm (128³) is ~8× cheaper but halves the effective resolution and doubles the
    /// physical reach of every dilation, so edges get blockier and the mask can bleed
    /// or erode by a voxel or two. Use 2 mm for a preview, 1 mm for a final mask.
    public var gridSpacing: Double
    /// Edge length of the cubic model field of view in mm (256 mm = FreeSurfer conform).
    public var fieldOfView: Double
    public var maxThreads: Int
    public var backend: NeuralConvBackend
    /// When the grid is coarser than the model's native 1 mm, divide every dilation by
    /// the spacing ratio (rounded, minimum 1) so the receptive field keeps its physical
    /// size. Measured on a 1 mm T1 with MindGrab this markedly improves 2 mm masks
    /// (see Models/README.md); turn off to run the network verbatim.
    public var adaptDilationToSpacing: Bool

    public init(
        gridSpacing: Double = 2,
        fieldOfView: Double = 256,
        maxThreads: Int = ProcessInfo.processInfo.activeProcessorCount,
        backend: NeuralConvBackend = .platformDefault,
        adaptDilationToSpacing: Bool = true
    ) {
        self.gridSpacing = gridSpacing
        self.fieldOfView = fieldOfView
        self.maxThreads = maxThreads
        self.backend = backend
        self.adaptDilationToSpacing = adaptDilationToSpacing
    }

    /// Factor applied to dilations (1 at native resolution).
    var dilationScale: Double {
        adaptDilationToSpacing && gridSpacing > 1 ? 1 / gridSpacing : 1
    }

    /// Edge length of the model grid in voxels.
    public var gridSize: Int { max(8, Int((fieldOfView / max(gridSpacing, 0.1)).rounded())) }
}

/// Wall-clock breakdown of a run, in seconds.
public struct NeuralRunTimings: Sendable, Hashable {
    public var conform: Double = 0
    public var inference: Double = 0
    public var postprocess: Double = 0
    public var total: Double { conform + inference + postprocess }
}

/// Segmentation result on the *source* voxel grid (x fastest, then y, then z).
public struct NeuralLabelVolume: Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    /// Per-voxel label: 0/1 for a binary mask, argmax class otherwise.
    public let labels: [UInt8]
    public let classCount: Int
    public let isBinaryMask: Bool
    /// Model grid actually used (edge voxels, mm) and the cropped extent inferred on.
    public let gridSize: Int
    public let gridSpacing: Double
    public let inferredExtent: [Int]
    public let timings: NeuralRunTimings

    public var foregroundVoxelCount: Int { labels.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } }
}

/// On-device brain extraction / parcellation with a brainchop MeshNet model.
///
/// Pure Swift (portable to Linux), multi-threaded, with an Accelerate GEMM path on
/// Apple platforms. Typical use:
/// ```swift
/// let engine = try NeuralMaskEngine.load(modelURL: modelJSON, profile: .mindgrab)
/// let input = try NeuralInputVolume(volume: miqVolume)
/// let mask = try await engine.run(volume: input)          // 2 mm preview
/// ```
public struct NeuralMaskEngine: Sendable {
    public let model: NeuralModel
    public let profile: NeuralModelProfile

    public init(model: NeuralModel, profile: NeuralModelProfile) {
        self.model = model
        self.profile = profile
    }

    /// Loads a tfjs layers-model (`…/model.json` + shards next to it).
    public static func load(modelURL: URL, profile: NeuralModelProfile) throws -> NeuralMaskEngine {
        NeuralMaskEngine(model: try NeuralModel.load(modelURL: modelURL), profile: profile)
    }

    /// Runs the full pipeline off the cooperative pool. Cancelling the calling task
    /// stops the work at the next row chunk and throws `CancellationError`.
    /// `progress` receives 0…1 (approximate, weighted by convolution cost).
    public func run(
        volume: NeuralInputVolume,
        options: NeuralRunOptions = NeuralRunOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> NeuralLabelVolume {
        try Task.checkCancellation()
        let token = NeuralCancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NeuralLabelVolume, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try self.runSynchronously(volume: volume, options: options, cancellation: token, progress: progress)
                    })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Blocking variant of `run` (call from a background thread).
    public func runSynchronously(
        volume: NeuralInputVolume,
        options: NeuralRunOptions = NeuralRunOptions(),
        cancellation: NeuralCancellationToken? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> NeuralLabelVolume {
        guard model.inputChannels == 1 else {
            throw NeuralModelError.unsupportedConfiguration("only single-channel models are supported")
        }
        var timings = NeuralRunTimings()
        let threads = max(1, options.maxThreads)
        var clock = Date()
        func lap() -> Double { let now = Date(); defer { clock = now }; return now.timeIntervalSince(clock) }

        // 1. Conform: resample into the LIA model grid, normalise, crop.
        let grid = NeuralGrid(size: options.gridSize, spacing: options.gridSpacing, centredOn: volume)
        var conformed = try NeuralConform.resample(volume, onto: grid, maxThreads: threads, cancel: cancellation)
        NeuralConform.normalise(&conformed, mode: profile.normalization)
        let padding = Int((profile.cropPaddingMM / options.gridSpacing).rounded())
        let box = NeuralConform.cropBox(conformed, threshold: profile.cropThreshold, padding: padding)
        let isBinary = profile.foregroundClasses != nil
        guard !box.isEmpty else {
            timings.conform = lap()
            return NeuralLabelVolume(
                width: volume.width, height: volume.height, depth: volume.depth,
                labels: [UInt8](repeating: 0, count: volume.voxels.count),
                classCount: model.outputChannels, isBinaryMask: isBinary,
                gridSize: grid.size, gridSpacing: grid.spacing, inferredExtent: [0, 0, 0], timings: timings
            )
        }
        let cropped = NeuralConform.crop(conformed, to: box)
        conformed = NeuralTensor(depth: 0, height: 0, width: 0, channels: 1, data: [])
        timings.conform = lap()
        try cancellation?.check()

        // 2. Inference.
        var head = try infer(cropped, options: options, cancellation: cancellation, progress: progress)
        timings.inference = lap()

        // 3. Post-process and map back to the source grid.
        if isBinary, var fg = head.foreground {
            if profile.keepLargestComponent {
                let keep = NeuralConform.largestComponent(fg.map { $0 >= 0.5 }, dims: box.extent)
                for i in fg.indices where !keep[i] { fg[i] = min(fg[i], 0.49) }
                head.foreground = fg
            }
        }
        let labels = try mapToSource(head, box: box, grid: grid, volume: volume, binary: isBinary, maxThreads: threads, cancel: cancellation)
        timings.postprocess = lap()
        progress?(1)
        return NeuralLabelVolume(
            width: volume.width, height: volume.height, depth: volume.depth,
            labels: labels, classCount: model.outputChannels, isBinaryMask: isBinary,
            gridSize: grid.size, gridSpacing: grid.spacing, inferredExtent: box.extent, timings: timings
        )
    }

    /// Runs the network on an already-conformed, normalised single-channel tensor
    /// (no resampling or cropping) and returns labels + foreground probability in the
    /// same grid. Useful for callers that do their own conforming, and for testing.
    /// `options.gridSpacing` must state the tensor's spacing (it drives dilation
    /// adaptation); the default here is the models' native 1 mm.
    public func predict(
        conformed input: NeuralTensor,
        options: NeuralRunOptions = NeuralRunOptions(gridSpacing: 1),
        cancellation: NeuralCancellationToken? = nil
    ) throws -> NeuralPrediction {
        guard input.channels == model.inputChannels else {
            throw NeuralModelError.invalidInput("expected \(model.inputChannels) input channel(s), got \(input.channels)")
        }
        return try infer(input, options: options, cancellation: cancellation, progress: nil)
    }

    func infer(
        _ input: NeuralTensor,
        options: NeuralRunOptions,
        cancellation: NeuralCancellationToken?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> NeuralPrediction {
        let layers = model.layers
        // A trailing pointwise conv (+ optional softmax/sigmoid) is fused with the argmax
        // so the full class-score tensor (up to 104 channels) is never materialised.
        var bodyEnd = layers.count
        while bodyEnd > 0, case .activation(let a) = layers[bodyEnd - 1], a == .softmax || a == .sigmoid || a == .linear {
            bodyEnd -= 1
        }
        var fusedHead: NeuralConv3D?
        if bodyEnd > 0, case .conv3D(let last) = layers[bodyEnd - 1], last.isPointwise {
            fusedHead = last
            bodyEnd -= 1
        } else {
            bodyEnd = layers.count
        }
        let x = try forward(input, layers: Array(layers[0..<bodyEnd]), options: options, cancellation: cancellation, progress: progress)
        if let head = fusedHead {
            return try pointwiseHead(head, input: x, maxThreads: options.maxThreads, cancel: cancellation)
        }
        let probabilities: Bool
        if case .activation(let a) = layers.last, a == .softmax || a == .sigmoid { probabilities = true } else { probabilities = false }
        return try neuralHead(scores: x, foregroundClasses: profile.foregroundClasses, alreadyProbabilities: probabilities,
                              maxThreads: options.maxThreads, cancel: cancellation)
    }

    /// Sequentially evaluates `layers`, fusing conv→activation and norm→activation.
    func forward(
        _ input: NeuralTensor,
        layers: [NeuralLayer],
        options: NeuralRunOptions,
        cancellation: NeuralCancellationToken?,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> NeuralTensor {
        let threads = max(1, options.maxThreads)
        let totalCost = Double(max(1, layers.reduce(0) { if case .conv3D(let c) = $1 { return $0 + c.weights.count }; return $0 }))
        var done = 0.0
        var x = input
        var i = 0
        while i < layers.count {
            try cancellation?.check()
            let next: NeuralLayer? = i + 1 < layers.count ? layers[i + 1] : nil
            switch layers[i] {
            case .conv3D(let conv):
                var fused = NeuralActivation.linear
                if case .activation(let a)? = next { fused = a; i += 1 }
                x = try runConv3D(PackedConv3D(conv, dilationScale: options.dilationScale), input: x, fusedActivation: fused, backend: options.backend,
                                  maxThreads: threads, cancel: cancellation)
                done += Double(conv.weights.count)
                progress?(0.95 * done / totalCost)
            case .instanceNorm(let eps):
                var fused = NeuralActivation.linear
                if case .activation(let a)? = next { fused = a; i += 1 }
                try applyInstanceNorm(epsilon: eps, then: fused, to: &x, maxThreads: threads, cancel: cancellation)
            case .activation(let a):
                try applyActivation(a, to: &x, maxThreads: threads, cancel: cancellation)
            case .channelAffine(let scale, let shift):
                try applyChannelAffine(scale: scale, shift: shift, to: &x, maxThreads: threads, cancel: cancellation)
            }
            i += 1
        }
        return x
    }

    private func pointwiseHead(_ conv: NeuralConv3D, input: NeuralTensor, maxThreads: Int, cancel: NeuralCancellationToken?) throws -> NeuralPrediction {
        let cin = conv.inChannels, cout = conv.outChannels
        guard input.channels == cin else {
            throw NeuralModelError.channelMismatch(layer: conv.name, expected: cin, actual: input.channels)
        }
        let voxels = input.voxelCount
        let chunk = 4096
        var labels = [UInt8](repeating: 0, count: voxels)
        let binary = profile.foregroundClasses != nil
        var foreground = [Float](repeating: 0, count: binary ? voxels : 0)
        // Evaluate in blocks so scores never exceed `chunk × cout` floats per block.
        var start = 0
        while start < voxels {
            try cancel?.check()
            let end = min(voxels, start + chunk * max(1, maxThreads) * 16)
            let count = end - start
            var block = [Float](repeating: 0, count: count * cout)
            try input.data.withUnsafeBufferPointer { inBuffer in
                try conv.weights.withUnsafeBufferPointer { wBuffer in
                    try block.withUnsafeMutableBufferPointer { bBuffer in
                        let inBase = inBuffer.baseAddress! + start * cin
                        let w = wBuffer.baseAddress!, out = bBuffer.baseAddress!
                        let bias = conv.bias
                        try NeuralParallel.forEachChunk(count: count, chunk: chunk, maxThreads: maxThreads, cancel: cancel) { range, _ in
                            for v in range {
                                let ip = inBase + v * cin
                                let op = out + v * cout
                                for oc in 0..<cout { op[oc] = bias?[oc] ?? 0 }
                                for ic in 0..<cin {
                                    let value = ip[ic]
                                    let wr = w + ic * cout
                                    for oc in 0..<cout { op[oc] += value * wr[oc] }
                                }
                            }
                        }
                    }
                }
            }
            let scores = NeuralTensor(depth: 1, height: 1, width: count, channels: cout, data: block)
            let part = try neuralHead(scores: scores, foregroundClasses: profile.foregroundClasses, alreadyProbabilities: false,
                                      maxThreads: maxThreads, cancel: cancel)
            for v in 0..<count { labels[start + v] = part.labels[v] }
            if let fg = part.foreground {
                for v in 0..<count { foreground[start + v] = fg[v] }
            }
            start = end
        }
        return NeuralPrediction(labels: labels, foreground: binary ? foreground : nil)
    }

    private func mapToSource(
        _ head: NeuralPrediction,
        box: NeuralCropBox,
        grid: NeuralGrid,
        volume: NeuralInputVolume,
        binary: Bool,
        maxThreads: Int,
        cancel: NeuralCancellationToken?
    ) throws -> [UInt8] {
        guard let worldToGrid = grid.gridToWorld.inverted() else { return [UInt8](repeating: 0, count: volume.voxels.count) }
        let m = worldToGrid.concatenating(volume.voxelToWorld).entries
        let e = box.extent
        let lo = box.lower.map(Double.init)
        let w = volume.width, h = volume.height, d = volume.depth
        var out = [UInt8](repeating: 0, count: w * h * d)
        let fg = head.foreground ?? []
        try out.withUnsafeMutableBufferPointer { outBuffer in
            try fg.withUnsafeBufferPointer { fgBuffer in
                try head.labels.withUnsafeBufferPointer { lBuffer in
                    let dst = outBuffer.baseAddress!
                    let labels = lBuffer.baseAddress!
                    try NeuralParallel.forEachChunk(count: h * d, chunk: 16, maxThreads: maxThreads, cancel: cancel) { range, _ in
                        for row in range {
                            let y = Double(row % h), z = Double(row / h)
                            for xi in 0..<w {
                                let x = Double(xi)
                                let gi = m[0] * x + m[1] * y + m[2] * z + m[3] - lo[0]
                                let gj = m[4] * x + m[5] * y + m[6] * z + m[7] - lo[1]
                                let gk = m[8] * x + m[9] * y + m[10] * z + m[11] - lo[2]
                                var value: UInt8 = 0
                                if binary, let fgBase = fgBuffer.baseAddress {
                                    // Tensor (d, h, w) = grid (i, j, k): k is the fastest axis.
                                    let p = NeuralConform.trilinear(fgBase, e[2], e[1], e[0], gk, gj, gi, outside: 0)
                                    value = p >= 0.5 ? 1 : 0
                                } else {
                                    let ii = Int(gi.rounded()), jj = Int(gj.rounded()), kk = Int(gk.rounded())
                                    if ii >= 0, ii < e[0], jj >= 0, jj < e[1], kk >= 0, kk < e[2] {
                                        value = labels[(ii * e[1] + jj) * e[2] + kk]
                                    }
                                }
                                dst[row * w + xi] = value
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
