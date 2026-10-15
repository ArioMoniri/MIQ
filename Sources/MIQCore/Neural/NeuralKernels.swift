import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Dense channels-last 3-D activation tensor: element `(d, h, w, c)` lives at
/// `((d · height + h) · width + w) · channels + c`. Channels-last keeps one voxel's
/// feature vector contiguous, which is what the convolution micro-kernel and the
/// im2col/GEMM path both want.
public struct NeuralTensor: Sendable {
    public let depth: Int
    public let height: Int
    public let width: Int
    public let channels: Int
    public var data: [Float]

    public init(depth: Int, height: Int, width: Int, channels: Int, data: [Float]) {
        precondition(data.count == depth * height * width * channels, "NeuralTensor size mismatch")
        self.depth = depth
        self.height = height
        self.width = width
        self.channels = channels
        self.data = data
    }

    public init(depth: Int, height: Int, width: Int, channels: Int, repeating value: Float = 0) {
        self.init(depth: depth, height: height, width: width, channels: channels,
                  data: [Float](repeating: value, count: depth * height * width * channels))
    }

    public var voxelCount: Int { depth * height * width }

    @inline(__always)
    public func index(_ d: Int, _ h: Int, _ w: Int, _ c: Int = 0) -> Int {
        ((d * height + h) * width + w) * channels + c
    }
}

/// Convolution implementation strategy.
public enum NeuralConvBackend: Sendable, Hashable {
    /// Portable SIMD micro-kernel (8-wide output-channel blocks). Default on Linux.
    case simd
    /// Per-row im2col followed by a GEMM. Uses `vDSP_mmul` when Accelerate is
    /// available (Apple platforms, the default there), else a portable GEMM loop
    /// that exists mainly so the im2col indexing is exercised by the Linux tests.
    case im2colGEMM

    public static var platformDefault: NeuralConvBackend {
        #if canImport(Accelerate)
        return .im2colGEMM
        #else
        return .simd
        #endif
    }
}

/// Thread-safe cancellation flag polled by the worker loops (Swift `Task`
/// cancellation is not visible from Dispatch worker threads).
public final class NeuralCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Lock-protected chunk dispenser so a bounded number of workers can share a row range.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    let total: Int
    let chunk: Int

    init(total: Int, chunk: Int) {
        self.total = total
        self.chunk = max(1, chunk)
    }

    func take() -> Range<Int>? {
        lock.lock(); defer { lock.unlock() }
        guard next < total else { return nil }
        let start = next
        next = min(total, next + chunk)
        return start..<next
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

enum NeuralParallel {
    /// Runs `body` over `0..<count` in chunks on up to `maxThreads` workers, stopping
    /// early (and throwing `CancellationError`) once `cancel` fires.
    static func forEachChunk(
        count: Int,
        chunk: Int,
        maxThreads: Int,
        cancel: NeuralCancellationToken?,
        _ body: (Range<Int>, Int) -> Void
    ) throws {
        guard count > 0 else { return }
        let workers = max(1, min(maxThreads, ProcessInfo.processInfo.activeProcessorCount, (count + chunk - 1) / max(1, chunk)))
        let counter = ChunkCounter(total: count, chunk: chunk)
        if workers == 1 {
            while let range = counter.take() {
                if cancel?.isCancelled == true { break }
                body(range, 0)
            }
        } else {
            // Workers only touch disjoint output ranges through raw pointers owned by the
            // caller for the duration of this call, so the unchecked box is sound.
            withoutActuallyEscaping(body) { escapable in
                let box = UncheckedSendableBox(value: escapable)
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    while let range = counter.take() {
                        if cancel?.isCancelled == true { return }
                        box.value(range, worker)
                    }
                }
            }
        }
        try cancel?.check()
    }
}

// MARK: - Activations

@inline(__always)
func neuralActivate(_ x: Float, _ kind: NeuralActivation) -> Float {
    switch kind {
    case .linear, .softmax: return x
    case .relu: return max(0, x)
    case .elu: return x > 0 ? x : Foundation.expm1(x)
    case .gelu: return 0.5 * x * (1 + Foundation.erf(x * 0.70710678118654752))
    case .geluTanh:
        let inner: Float = 0.7978845608028654 * (x + 0.044715 * x * x * x)
        return 0.5 * x * (1 + Foundation.tanh(inner))
    case .sigmoid: return 1 / (1 + Foundation.exp(-x))
    case .tanh: return Foundation.tanh(x)
    }
}

func applyActivation(_ kind: NeuralActivation, to tensor: inout NeuralTensor, maxThreads: Int, cancel: NeuralCancellationToken?) throws {
    guard kind != .linear else { return }
    if kind == .softmax {
        try applySoftmax(to: &tensor, maxThreads: maxThreads, cancel: cancel)
        return
    }
    let count = tensor.data.count
    try tensor.data.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        try NeuralParallel.forEachChunk(count: count, chunk: 1 << 16, maxThreads: maxThreads, cancel: cancel) { range, _ in
            for i in range { base[i] = neuralActivate(base[i], kind) }
        }
    }
}

func applySoftmax(to tensor: inout NeuralTensor, maxThreads: Int, cancel: NeuralCancellationToken?) throws {
    let channels = tensor.channels
    let voxels = tensor.voxelCount
    try tensor.data.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        try NeuralParallel.forEachChunk(count: voxels, chunk: 4096, maxThreads: maxThreads, cancel: cancel) { range, _ in
            for v in range {
                let p = base + v * channels
                var m = -Float.infinity
                for c in 0..<channels { m = max(m, p[c]) }
                var sum: Float = 0
                for c in 0..<channels { p[c] = Foundation.exp(p[c] - m); sum += p[c] }
                let inv = 1 / sum
                for c in 0..<channels { p[c] *= inv }
            }
        }
    }
}

func applyChannelAffine(scale: [Float], shift: [Float], to tensor: inout NeuralTensor, maxThreads: Int, cancel: NeuralCancellationToken?) throws {
    let channels = tensor.channels
    let voxels = tensor.voxelCount
    try scale.withUnsafeBufferPointer { sp in
        try shift.withUnsafeBufferPointer { tp in
            try tensor.data.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                let s = sp.baseAddress!, t = tp.baseAddress!
                try NeuralParallel.forEachChunk(count: voxels, chunk: 8192, maxThreads: maxThreads, cancel: cancel) { range, _ in
                    for v in range {
                        let p = base + v * channels
                        for c in 0..<channels { p[c] = p[c] * s[c] + t[c] }
                    }
                }
            }
        }
    }
}

/// Per-channel normalisation over all voxels, optionally fused with the following
/// activation. Statistics accumulate in `Double` (population variance, like
/// `tf.moments`) so 16M-voxel sums stay accurate.
func applyInstanceNorm(
    epsilon: Float,
    then activation: NeuralActivation,
    to tensor: inout NeuralTensor,
    maxThreads: Int,
    cancel: NeuralCancellationToken?
) throws {
    let channels = tensor.channels
    let voxels = tensor.voxelCount
    guard voxels > 0 else { return }
    let lock = NSLock()
    var sums = [Double](repeating: 0, count: channels)
    var squares = [Double](repeating: 0, count: channels)
    try tensor.data.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        try NeuralParallel.forEachChunk(count: voxels, chunk: 16384, maxThreads: maxThreads, cancel: cancel) { range, _ in
            var localSum = [Double](repeating: 0, count: channels)
            var localSq = [Double](repeating: 0, count: channels)
            for v in range {
                let p = base + v * channels
                for c in 0..<channels {
                    let x = Double(p[c])
                    localSum[c] += x
                    localSq[c] += x * x
                }
            }
            lock.lock()
            for c in 0..<channels { sums[c] += localSum[c]; squares[c] += localSq[c] }
            lock.unlock()
        }
        var mean = [Float](repeating: 0, count: channels)
        var invStd = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            let m = sums[c] / Double(voxels)
            let variance = max(0, squares[c] / Double(voxels) - m * m)
            mean[c] = Float(m)
            invStd[c] = Float(1 / (variance + Double(epsilon)).squareRoot())
        }
        let fused = activation == .softmax ? NeuralActivation.linear : activation
        try mean.withUnsafeBufferPointer { mp in
            try invStd.withUnsafeBufferPointer { ip in
                let mBase = mp.baseAddress!, iBase = ip.baseAddress!
                try NeuralParallel.forEachChunk(count: voxels, chunk: 16384, maxThreads: maxThreads, cancel: cancel) { range, _ in
                    for v in range {
                        let p = base + v * channels
                        for c in 0..<channels {
                            p[c] = neuralActivate((p[c] - mBase[c]) * iBase[c], fused)
                        }
                    }
                }
            }
        }
    }
    if activation == .softmax {
        try applySoftmax(to: &tensor, maxThreads: maxThreads, cancel: cancel)
    }
}

// MARK: - Convolution

/// A convolution pre-packed for the SIMD micro-kernel: output channels padded to
/// 8-lane blocks, taps flattened to `(dd, dh, dw)` voxel offsets (dilation applied).
struct PackedConv3D {
    let conv: NeuralConv3D
    let groups: Int
    let taps: [(dd: Int, dh: Int, dw: Int)]
    /// `[tap][inChannel][group]` SIMD blocks.
    let packedWeights: [SIMD8<Float>]
    let packedBias: [SIMD8<Float>]

    /// `dilationScale` < 1 shrinks dilations (rounded, minimum 1) so a network trained
    /// at fine spacing keeps roughly the same *physical* receptive field on a coarser grid.
    init(_ conv: NeuralConv3D, dilationScale: Double = 1) {
        self.conv = conv
        let dilation = conv.dilation.map { max(1, Int((Double($0) * dilationScale).rounded())) }
        let groups = (conv.outChannels + 7) / 8
        self.groups = groups
        var taps: [(Int, Int, Int)] = []
        let cd = conv.kernel[0] / 2, ch = conv.kernel[1] / 2, cw = conv.kernel[2] / 2
        for kd in 0..<conv.kernel[0] {
            for kh in 0..<conv.kernel[1] {
                for kw in 0..<conv.kernel[2] {
                    taps.append(((kd - cd) * dilation[0], (kh - ch) * dilation[1], (kw - cw) * dilation[2]))
                }
            }
        }
        self.taps = taps
        let cin = conv.inChannels, cout = conv.outChannels
        var packed = [SIMD8<Float>](repeating: .zero, count: taps.count * cin * groups)
        for t in 0..<taps.count {
            for ic in 0..<cin {
                for oc in 0..<cout {
                    packed[(t * cin + ic) * groups + oc / 8][oc % 8] = conv.weights[(t * cin + ic) * cout + oc]
                }
            }
        }
        self.packedWeights = packed
        var bias = [SIMD8<Float>](repeating: .zero, count: groups)
        if let b = conv.bias {
            for oc in 0..<cout { bias[oc / 8][oc % 8] = b[oc] }
        }
        self.packedBias = bias
    }
}

/// Runs one 3-D convolution (`same` zero padding), optionally fusing an activation
/// into the store. Parallel over output rows `(d, h)`.
func runConv3D(
    _ packed: PackedConv3D,
    input: NeuralTensor,
    fusedActivation: NeuralActivation = .linear,
    backend: NeuralConvBackend,
    maxThreads: Int,
    cancel: NeuralCancellationToken?
) throws -> NeuralTensor {
    let conv = packed.conv
    guard input.channels == conv.inChannels else {
        throw NeuralModelError.channelMismatch(layer: conv.name, expected: conv.inChannels, actual: input.channels)
    }
    var output = NeuralTensor(depth: input.depth, height: input.height, width: input.width, channels: conv.outChannels)
    let activation = fusedActivation == .softmax ? NeuralActivation.linear : fusedActivation
    switch backend {
    case .simd:
        try convSIMD(packed, input: input, output: &output, activation: activation, maxThreads: maxThreads, cancel: cancel)
    case .im2colGEMM:
        try convIm2col(packed, input: input, output: &output, activation: activation, maxThreads: maxThreads, cancel: cancel)
    }
    if fusedActivation == .softmax {
        try applySoftmax(to: &output, maxThreads: maxThreads, cancel: cancel)
    }
    return output
}

private func convSIMD(
    _ packed: PackedConv3D,
    input: NeuralTensor,
    output: inout NeuralTensor,
    activation: NeuralActivation,
    maxThreads: Int,
    cancel: NeuralCancellationToken?
) throws {
    let D = input.depth, H = input.height, W = input.width
    let cin = packed.conv.inChannels, cout = packed.conv.outChannels
    let G = packed.groups
    let taps = packed.taps
    let rows = D * H
    let workerCount = max(1, min(maxThreads, ProcessInfo.processInfo.activeProcessorCount))
    // One accumulator row per worker, allocated once per layer.
    var scratch = [SIMD8<Float>](repeating: .zero, count: workerCount * W * G)

    try input.data.withUnsafeBufferPointer { inBuffer in
        try output.data.withUnsafeMutableBufferPointer { outBuffer in
            try packed.packedWeights.withUnsafeBufferPointer { wBuffer in
                try packed.packedBias.withUnsafeBufferPointer { bBuffer in
                    try scratch.withUnsafeMutableBufferPointer { sBuffer in
                        let inBase = inBuffer.baseAddress!
                        let outBase = outBuffer.baseAddress!
                        let wBase = wBuffer.baseAddress!
                        let bias = bBuffer.baseAddress!
                        let scratchBase = sBuffer.baseAddress!
                        try NeuralParallel.forEachChunk(count: rows, chunk: 2, maxThreads: workerCount, cancel: cancel) { range, worker in
                            let acc = scratchBase + worker * W * G
                            let accFloats = UnsafeMutableRawPointer(acc).assumingMemoryBound(to: Float.self)
                            for row in range {
                                let d = row / H, h = row % H
                                for x in 0..<W {
                                    for g in 0..<G { acc[x * G + g] = bias[g] }
                                }
                                for (t, tap) in taps.enumerated() {
                                    let sd = d + tap.dd, sh = h + tap.dh
                                    if sd < 0 || sd >= D || sh < 0 || sh >= H { continue }
                                    let dx = tap.dw
                                    let x0 = max(0, -dx), x1 = min(W, W - dx)
                                    if x0 >= x1 { continue }
                                    let inRow = inBase + (sd * H + sh) * W * cin
                                    let wTap = wBase + t * cin * G
                                    switch G {
                                    case 1:
                                        for x in x0..<x1 {
                                            let ip = inRow + (x + dx) * cin
                                            var a = acc[x]
                                            for ic in 0..<cin {
                                                a += SIMD8<Float>(repeating: ip[ic]) * wTap[ic]
                                            }
                                            acc[x] = a
                                        }
                                    case 2:
                                        for x in x0..<x1 {
                                            let ip = inRow + (x + dx) * cin
                                            var a0 = acc[2 * x], a1 = acc[2 * x + 1]
                                            for ic in 0..<cin {
                                                let v = SIMD8<Float>(repeating: ip[ic])
                                                a0 += v * wTap[2 * ic]
                                                a1 += v * wTap[2 * ic + 1]
                                            }
                                            acc[2 * x] = a0
                                            acc[2 * x + 1] = a1
                                        }
                                    case 3:
                                        for x in x0..<x1 {
                                            let ip = inRow + (x + dx) * cin
                                            var a0 = acc[3 * x], a1 = acc[3 * x + 1], a2 = acc[3 * x + 2]
                                            for ic in 0..<cin {
                                                let v = SIMD8<Float>(repeating: ip[ic])
                                                a0 += v * wTap[3 * ic]
                                                a1 += v * wTap[3 * ic + 1]
                                                a2 += v * wTap[3 * ic + 2]
                                            }
                                            acc[3 * x] = a0
                                            acc[3 * x + 1] = a1
                                            acc[3 * x + 2] = a2
                                        }
                                    default:
                                        for x in x0..<x1 {
                                            let ip = inRow + (x + dx) * cin
                                            let ap = acc + x * G
                                            for ic in 0..<cin {
                                                let v = SIMD8<Float>(repeating: ip[ic])
                                                let wp = wTap + ic * G
                                                for g in 0..<G { ap[g] += v * wp[g] }
                                            }
                                        }
                                    }
                                }
                                let outRow = outBase + row * W * cout
                                for x in 0..<W {
                                    let src = accFloats + x * G * 8
                                    let dst = outRow + x * cout
                                    if activation == .linear {
                                        for oc in 0..<cout { dst[oc] = src[oc] }
                                    } else {
                                        for oc in 0..<cout { dst[oc] = neuralActivate(src[oc], activation) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// `C[M×N] = A[M×K] · B[K×N]` (row-major).
@inline(__always)
private func neuralGEMM(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, m: Int, n: Int, k: Int) {
    #if canImport(Accelerate)
    vDSP_mmul(a, 1, b, 1, c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
    #else
    for i in 0..<m {
        let crow = c + i * n
        for j in 0..<n { crow[j] = 0 }
        let arow = a + i * k
        for p in 0..<k {
            let av = arow[p]
            if av == 0 { continue }
            let brow = b + p * n
            for j in 0..<n { crow[j] += av * brow[j] }
        }
    }
    #endif
}

private func convIm2col(
    _ packed: PackedConv3D,
    input: NeuralTensor,
    output: inout NeuralTensor,
    activation: NeuralActivation,
    maxThreads: Int,
    cancel: NeuralCancellationToken?
) throws {
    let conv = packed.conv
    let D = input.depth, H = input.height, W = input.width
    let cin = conv.inChannels, cout = conv.outChannels
    let taps = packed.taps
    let K = taps.count * cin
    let rows = D * H
    let workerCount = max(1, min(maxThreads, ProcessInfo.processInfo.activeProcessorCount))
    var columns = [Float](repeating: 0, count: workerCount * W * K)
    let bias = conv.bias ?? [Float](repeating: 0, count: cout)

    try input.data.withUnsafeBufferPointer { inBuffer in
        try output.data.withUnsafeMutableBufferPointer { outBuffer in
            try conv.weights.withUnsafeBufferPointer { wBuffer in
                try bias.withUnsafeBufferPointer { bBuffer in
                    try columns.withUnsafeMutableBufferPointer { cBuffer in
                        let inBase = inBuffer.baseAddress!
                        let outBase = outBuffer.baseAddress!
                        let wBase = wBuffer.baseAddress!
                        let bBase = bBuffer.baseAddress!
                        let colBase = cBuffer.baseAddress!
                        try NeuralParallel.forEachChunk(count: rows, chunk: 2, maxThreads: workerCount, cancel: cancel) { range, worker in
                            let col = colBase + worker * W * K
                            for row in range {
                                let d = row / H, h = row % H
                                // Build the [W × taps·cin] patch matrix for this output row.
                                for (t, tap) in taps.enumerated() {
                                    let sd = d + tap.dd, sh = h + tap.dh
                                    let rowValid = sd >= 0 && sd < D && sh >= 0 && sh < H
                                    let inRow = rowValid ? inBase + (sd * H + sh) * W * cin : inBase
                                    for x in 0..<W {
                                        let dst = col + x * K + t * cin
                                        let sx = x + tap.dw
                                        if rowValid && sx >= 0 && sx < W {
                                            let src = inRow + sx * cin
                                            for ic in 0..<cin { dst[ic] = src[ic] }
                                        } else {
                                            for ic in 0..<cin { dst[ic] = 0 }
                                        }
                                    }
                                }
                                let outRow = outBase + row * W * cout
                                neuralGEMM(UnsafePointer(col), wBase, outRow, m: W, n: cout, k: K)
                                for x in 0..<W {
                                    let o = outRow + x * cout
                                    for oc in 0..<cout { o[oc] = neuralActivate(o[oc] + bBase[oc], activation) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Output head

/// Per-voxel output of the network head, in the grid of the tensor it was run on
/// (same `(d, h, w)` order, `w` fastest).
public struct NeuralPrediction: Sendable {
    /// Argmax class per voxel.
    public var labels: [UInt8]
    /// Probability that the voxel belongs to any foreground class (softmax over
    /// classes, or sigmoid for single-logit models); nil for multi-label output.
    public var foreground: [Float]?
}

/// Converts per-voxel class scores to labels (+ optional foreground probability).
/// `alreadyProbabilities` skips the softmax when the model ended in softmax/sigmoid.
func neuralHead(
    scores: NeuralTensor,
    foregroundClasses: Set<Int>?,
    alreadyProbabilities: Bool,
    maxThreads: Int,
    cancel: NeuralCancellationToken?
) throws -> NeuralPrediction {
    let channels = scores.channels
    let voxels = scores.voxelCount
    var labels = [UInt8](repeating: 0, count: voxels)
    var foreground = [Float](repeating: 0, count: foregroundClasses == nil ? 0 : voxels)
    var mask = [Bool](repeating: false, count: max(channels, 2))
    if let classes = foregroundClasses {
        for c in classes where c >= 0 && c < mask.count { mask[c] = true }
    }
    try scores.data.withUnsafeBufferPointer { sBuffer in
        try labels.withUnsafeMutableBufferPointer { lBuffer in
            try mask.withUnsafeBufferPointer { mBuffer in
                try foreground.withUnsafeMutableBufferPointer { fBuffer in
                    let fgPointer: UnsafeMutablePointer<Float>? = fBuffer.isEmpty ? nil : fBuffer.baseAddress
                    let s = sBuffer.baseAddress!, l = lBuffer.baseAddress!, m = mBuffer.baseAddress!
                    try NeuralParallel.forEachChunk(count: voxels, chunk: 8192, maxThreads: maxThreads, cancel: cancel) { range, _ in
                        for v in range {
                            let p = s + v * channels
                            if channels == 1 {
                                let prob = alreadyProbabilities ? p[0] : 1 / (1 + Foundation.exp(-p[0]))
                                l[v] = prob > 0.5 ? 1 : 0
                                fgPointer?[v] = m[1] ? prob : 1 - prob
                                continue
                            }
                            var best = 0
                            var bestValue = p[0]
                            for c in 1..<channels where p[c] > bestValue {
                                best = c
                                bestValue = p[c]
                            }
                            l[v] = UInt8(truncatingIfNeeded: best)
                            if let fg = fgPointer {
                                var total: Float = 0, fgSum: Float = 0
                                for c in 0..<channels {
                                    let e = alreadyProbabilities ? p[c] : Foundation.exp(p[c] - bestValue)
                                    total += e
                                    if m[c] { fgSum += e }
                                }
                                fg[v] = total > 0 ? fgSum / total : 0
                            }
                        }
                    }
                }
            }
        }
    }
    return NeuralPrediction(labels: labels, foreground: foregroundClasses == nil ? nil : foreground)
}
