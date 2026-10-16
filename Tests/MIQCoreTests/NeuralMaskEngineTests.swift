import Foundation
import Testing
@testable import MIQCore

/// Neural mask engine: convolution maths against a naive reference, the tfjs loader,
/// the conform → infer → map-back pipeline on a synthetic phantom, cancellation, and
/// (when the repo's `Models/` folder is reachable) the bundled brainchop weights.
struct NeuralMaskEngineTests {

    // MARK: - Helpers

    /// Deterministic pseudo-random floats in [-1, 1).
    struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
        }
        mutating func array(_ n: Int, scale: Float = 1) -> [Float] { (0..<n).map { _ in next() * scale } }
    }

    static func conv(
        _ name: String, _ cin: Int, _ cout: Int, kernel: [Int] = [3, 3, 3], dilation: [Int] = [1, 1, 1],
        bias: Bool = true, rng: inout LCG
    ) throws -> NeuralConv3D {
        let n = kernel.reduce(1, *) * cin * cout
        return try NeuralConv3D(
            name: name, inChannels: cin, outChannels: cout, kernel: kernel, dilation: dilation,
            weights: rng.array(n, scale: 0.5), bias: bias ? rng.array(cout, scale: 0.2) : nil
        )
    }

    /// Straightforward Double-precision evaluation of a layer list (channels-last).
    static func naiveForward(_ input: NeuralTensor, layers: [NeuralLayer]) -> NeuralTensor {
        var x = input.data.map(Double.init)
        var channels = input.channels
        let depth = input.depth
        let height = input.height
        let width = input.width
        let voxels = depth * height * width
        func act(_ v: Double, _ a: NeuralActivation) -> Double {
            switch a {
            case .linear, .softmax: return v
            case .relu: return max(0, v)
            case .elu: return v > 0 ? v : Foundation.exp(v) - 1
            case .gelu: return 0.5 * v * (1 + Foundation.erf(v / 2.0.squareRoot()))
            case .geluTanh: return 0.5 * v * (1 + Foundation.tanh(0.7978845608028654 * (v + 0.044715 * v * v * v)))
            case .sigmoid: return 1 / (1 + Foundation.exp(-v))
            case .tanh: return Foundation.tanh(v)
            }
        }
        for layer in layers {
            switch layer {
            case .conv3D(let c):
                var y = [Double](repeating: 0, count: voxels * c.outChannels)
                let (kd, kh, kw) = (c.kernel[0], c.kernel[1], c.kernel[2])
                for d in 0..<depth { for h in 0..<height { for w in 0..<width { for oc in 0..<c.outChannels {
                    var s = Double(c.bias?[oc] ?? 0)
                    for a in 0..<kd { for b in 0..<kh { for e in 0..<kw {
                        let sd = d + (a - kd / 2) * c.dilation[0]
                        let sh = h + (b - kh / 2) * c.dilation[1]
                        let sw = w + (e - kw / 2) * c.dilation[2]
                        guard sd >= 0, sd < depth, sh >= 0, sh < height, sw >= 0, sw < width else { continue }
                        for ic in 0..<c.inChannels {
                            let wi = (((a * kh + b) * kw + e) * c.inChannels + ic) * c.outChannels + oc
                            s += Double(c.weights[wi]) * x[((sd * height + sh) * width + sw) * channels + ic]
                        }
                    } } }
                    y[((d * height + h) * width + w) * c.outChannels + oc] = s
                } } } }
                x = y
                channels = c.outChannels
            case .activation(let a):
                if a == .softmax {
                    for v in 0..<voxels {
                        let row = (0..<channels).map { x[v * channels + $0] }
                        let m = row.max()!
                        let e = row.map { Foundation.exp($0 - m) }
                        let s = e.reduce(0, +)
                        for c in 0..<channels { x[v * channels + c] = e[c] / s }
                    }
                } else {
                    x = x.map { act($0, a) }
                }
            case .instanceNorm(let eps):
                for c in 0..<channels {
                    var mean = 0.0
                    var sq = 0.0
                    for v in 0..<voxels { mean += x[v * channels + c] }
                    mean /= Double(voxels)
                    for v in 0..<voxels { sq += (x[v * channels + c] - mean) * (x[v * channels + c] - mean) }
                    let inv = 1 / (sq / Double(voxels) + Double(eps)).squareRoot()
                    for v in 0..<voxels { x[v * channels + c] = (x[v * channels + c] - mean) * inv }
                }
            case .channelAffine(let scale, let shift):
                for v in 0..<voxels { for c in 0..<channels {
                    x[v * channels + c] = x[v * channels + c] * Double(scale[c]) + Double(shift[c])
                } }
            }
        }
        return NeuralTensor(depth: depth, height: height, width: width, channels: channels, data: x.map(Float.init))
    }

    static func randomInput(_ d: Int, _ h: Int, _ w: Int, seed: UInt64) -> NeuralTensor {
        var rng = LCG(state: seed)
        return NeuralTensor(depth: d, height: h, width: w, channels: 1, data: rng.array(d * h * w))
    }

    static func maxRelativeError(_ a: [Float], _ b: [Float]) -> Float {
        let scale = max(1e-3, b.map(abs).max() ?? 1)
        return zip(a, b).map { abs($0 - $1) }.max()! / scale
    }

    // MARK: - Convolution maths

    @Test(arguments: [NeuralConvBackend.simd, .im2colGEMM])
    func forwardMatchesNaiveReference(backend: NeuralConvBackend) throws {
        var rng = LCG(state: 42)
        let layers: [NeuralLayer] = [
            .conv3D(try Self.conv("c0", 1, 3, rng: &rng)),
            .activation(.relu),
            .conv3D(try Self.conv("c1", 3, 10, dilation: [2, 2, 2], rng: &rng)), // two 8-lane groups
            .activation(.elu),
            .conv3D(try Self.conv("c2", 10, 17, kernel: [3, 1, 5], dilation: [1, 1, 3], bias: false, rng: &rng)), // three groups
            .instanceNorm(epsilon: 1e-5),
            .activation(.gelu),
            .channelAffine(scale: rng.array(17), shift: rng.array(17)),
            .conv3D(try Self.conv("c3", 17, 26, dilation: [4, 1, 2], rng: &rng)), // four groups: generic path
            .activation(.geluTanh),
            .conv3D(try Self.conv("out", 26, 3, kernel: [1, 1, 1], rng: &rng)),
        ]
        let model = try NeuralModel(name: "t", layers: layers)
        let engine = NeuralMaskEngine(model: model, profile: .parcellation())
        let input = Self.randomInput(7, 9, 11, seed: 7) // non-cubic: catches axis mix-ups
        let options = NeuralRunOptions(gridSpacing: 1, maxThreads: 3, backend: backend)
        let got = try engine.forward(input, layers: layers, options: options, cancellation: nil, progress: nil)
        let want = Self.naiveForward(input, layers: layers)
        #expect(got.channels == 3)
        #expect(Self.maxRelativeError(got.data, want.data) < 1e-4)
    }

    @Test(arguments: [NeuralConvBackend.simd, .im2colGEMM])
    func dilatedTapShiftsAlongTheRightAxisWithZeroPadding(backend: NeuralConvBackend) throws {
        // Kernel non-zero only at the last tap of one axis: out[p] = in[p + dilation·axis].
        for axis in 0..<3 {
            var weights = [Float](repeating: 0, count: 27)
            let index = [axis == 0 ? 2 : 1, axis == 1 ? 2 : 1, axis == 2 ? 2 : 1]
            weights[(index[0] * 3 + index[1]) * 3 + index[2]] = 1
            let conv = try NeuralConv3D(name: "shift", inChannels: 1, outChannels: 1, kernel: [3, 3, 3],
                                        dilation: [2, 2, 2], weights: weights, bias: nil)
            let input = NeuralTensor(depth: 5, height: 6, width: 7, channels: 1, data: (0..<210).map { Float($0 + 1) })
            let out = try runConv3D(PackedConv3D(conv), input: input, backend: backend, maxThreads: 2, cancel: nil)
            for d in 0..<5 { for h in 0..<6 { for w in 0..<7 {
                var p = [d, h, w]
                p[axis] += 2
                let inside = p[0] < 5 && p[1] < 6 && p[2] < 7
                let expected: Float = inside ? input.data[input.index(p[0], p[1], p[2])] : 0
                #expect(out.data[out.index(d, h, w)] == expected)
            } } }
        }
    }

    @Test
    func dilationAdaptationHalvesDilationsOnACoarserGrid() throws {
        let conv = try NeuralConv3D(name: "c", inChannels: 1, outChannels: 1, kernel: [3, 3, 3],
                                    dilation: [16, 8, 1], weights: [Float](repeating: 0, count: 27), bias: nil)
        let packed = PackedConv3D(conv, dilationScale: NeuralRunOptions(gridSpacing: 2).dilationScale)
        #expect(packed.taps.first! == (dd: -8, dh: -4, dw: -1))
        #expect(NeuralRunOptions(gridSpacing: 2, adaptDilationToSpacing: false).dilationScale == 1)
        #expect(NeuralRunOptions(gridSpacing: 1).dilationScale == 1)
    }

    @Test
    func fusedHeadMatchesExplicitSoftmaxArgmax() throws {
        var rng = LCG(state: 9)
        let layers: [NeuralLayer] = [
            .conv3D(try Self.conv("c0", 1, 6, rng: &rng)),
            .activation(.relu),
            .conv3D(try Self.conv("out", 6, 3, kernel: [1, 1, 1], rng: &rng)),
            .activation(.softmax),
        ]
        let model = try NeuralModel(name: "t", layers: layers)
        var profile = NeuralModelProfile.brainMaskFast
        profile.foregroundClasses = [1, 2]
        let engine = NeuralMaskEngine(model: model, profile: profile)
        let input = Self.randomInput(6, 5, 8, seed: 3)
        let prediction = try engine.predict(conformed: input)
        let probabilities = Self.naiveForward(input, layers: layers)
        for v in 0..<input.voxelCount {
            let p = (0..<3).map { probabilities.data[v * 3 + $0] }
            #expect(Int(prediction.labels[v]) == p.firstIndex(of: p.max()!)!)
            #expect(abs(prediction.foreground![v] - (p[1] + p[2])) < 1e-4)
        }
    }

    // MARK: - tfjs loader

    /// Builds a tfjs layers-model in memory; `mutate` can corrupt the JSON for error tests.
    static func makeTFJS(
        rng: inout LCG,
        mutate: (inout [String: Any]) -> Void = { _ in /* default: leave the valid model untouched */ }
    ) throws -> (json: Data, shard: Data, weights: [String: [Float]]) {
        var specs: [(String, [Int])] = [
            ("c0_gn/kernel", [3, 3, 3, 1, 4]),
            ("bn/gamma", [4]), ("bn/beta", [4]), ("bn/moving_mean", [4]), ("bn/moving_variance", [4]),
            ("c1/kernel", [3, 3, 3, 4, 4]), ("c1/bias", [4]),
            ("output/kernel", [1, 1, 1, 4, 2]), ("output/bias", [2]),
        ]
        var weights: [String: [Float]] = [:]
        var shard = Data()
        for (name, shape) in specs {
            var values = rng.array(shape.reduce(1, *))
            if name.hasSuffix("moving_variance") { values = values.map { abs($0) + 0.5 } }
            weights[name] = values
            for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { shard.append(contentsOf: $0) } }
        }
        func convConfig(_ name: String, _ filters: Int, _ k: Int, _ dil: Int, bias: Bool, act: String = "linear") -> [String: Any] {
            ["class_name": "Conv3D", "config": [
                "name": name, "filters": filters, "kernel_size": [k, k, k], "dilation_rate": [dil, dil, dil],
                "padding": "same", "strides": [1, 1, 1], "activation": act, "use_bias": bias,
                "data_format": "channels_last",
            ] as [String: Any]]
        }
        var layers: [[String: Any]] = [
            ["class_name": "InputLayer", "config": ["name": "input", "batch_input_shape": [NSNull(), 256, 256, 256, 1]] as [String: Any]],
            convConfig("c0_gn", 4, 3, 2, bias: false),
            ["class_name": "Activation", "config": ["name": "a0", "activation": "gelu"]],
            ["class_name": "BatchNormalization", "config": ["name": "bn", "axis": -1, "epsilon": 0.001, "center": true, "scale": true] as [String: Any]],
            ["class_name": "Dropout", "config": ["name": "drop", "rate": 0.2] as [String: Any]],
            convConfig("c1", 4, 3, 1, bias: true, act: "elu"),
            convConfig("output", 2, 1, 1, bias: true),
        ]
        // Functional-style chain wiring.
        for i in 1..<layers.count {
            let previous = (layers[i - 1]["config"] as! [String: Any])["name"] as! String
            layers[i]["inbound_nodes"] = [[[previous, 0, 0, [String: Any]()]]]
        }
        var root: [String: Any] = [
            "format": "layers-model",
            "generatedBy": "test",
            "modelTopology": ["model_config": ["class_name": "Functional", "config": ["layers": layers]]],
            "weightsManifest": [["paths": ["w.bin"], "weights": specs.map { ["name": $0.0, "shape": $0.1, "dtype": "float32"] }]],
        ]
        mutate(&root)
        specs.removeAll()
        return (try JSONSerialization.data(withJSONObject: root), shard, weights)
    }

    @Test
    func tfjsRoundTripFromDisk() throws {
        var rng = LCG(state: 1)
        let (json, shard, weights) = try Self.makeTFJS(rng: &rng)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miq-neural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try json.write(to: dir.appendingPathComponent("model.json"))
        try shard.write(to: dir.appendingPathComponent("w.bin"))

        let model = try NeuralModel.load(modelURL: dir.appendingPathComponent("model.json"))
        #expect(model.declaredInputShape == [256, 256, 256])
        #expect(model.outputChannels == 2)
        #expect(model.layers.count == 7)
        guard case .conv3D(let c0) = model.layers[0], case .instanceNorm = model.layers[1],
              case .activation(.gelu) = model.layers[2], case .channelAffine(let scale, let shift) = model.layers[3],
              case .conv3D(let c1) = model.layers[4], case .activation(.elu) = model.layers[5],
              case .conv3D(let out) = model.layers[6] else {
            Issue.record("unexpected layer structure \(model.layers)")
            return
        }
        #expect(c0.weights == weights["c0_gn/kernel"]!)
        #expect(c0.bias == nil)
        #expect(c0.dilation == [2, 2, 2])
        #expect(c1.bias == weights["c1/bias"]!)
        #expect(out.isPointwise && out.weights == weights["output/kernel"]!)
        let g = weights["bn/gamma"]!
        let b = weights["bn/beta"]!
        let m = weights["bn/moving_mean"]!
        let v = weights["bn/moving_variance"]!
        for c in 0..<4 {
            let expectedScale = g[c] / (v[c] + 0.001).squareRoot()
            #expect(abs(scale[c] - expectedScale) < 1e-6)
            #expect(abs(shift[c] - (b[c] - m[c] * expectedScale)) < 1e-6)
        }
        // BatchNorm's four vectors fold into two (scale, shift).
        #expect(model.parameterCount == weights.values.reduce(0) { $0 + $1.count } - 2 * 4)
    }

    /// Inserts an unsupported `Conv3DTranspose` layer named "up" at index 3.
    private static func insertTransposeConvLayer(_ layers: inout [[String: Any]]) {
        layers.insert(["class_name": "Conv3DTranspose", "config": ["name": "up"]], at: 3)
        layers[3].removeValue(forKey: "inbound_nodes")
    }

    /// c1 claims two inputs (a skip connection) — not a chain.
    private static func addSkipConnectionInput(_ layers: inout [[String: Any]]) {
        layers[5]["inbound_nodes"] = [[["drop", 0, 0, [String: Any]()], ["a0", 0, 0, [String: Any]()]]]
    }

    @Test
    func tfjsLoaderRejectsUnsupportedModels() throws {
        func load(_ mutate: (inout [String: Any]) -> Void, shardBytes: Int? = nil, path: String = "w.bin") throws {
            var rng = LCG(state: 5)
            let (json, shard, _) = try Self.makeTFJS(rng: &rng, mutate: mutate)
            _ = try NeuralModel(tfjsModelJSON: json) { requested in
                guard requested == path else { throw NeuralModelError.shardUnreadable(requested) }
                return shardBytes.map { shard.prefix($0) } ?? shard
            }
        }
        func editLayers(_ root: inout [String: Any], _ edit: (inout [[String: Any]]) -> Void) {
            var topo = root["modelTopology"] as! [String: Any]
            var mc = topo["model_config"] as! [String: Any]
            var cfg = mc["config"] as! [String: Any]
            var layers = cfg["layers"] as! [[String: Any]]
            edit(&layers)
            cfg["layers"] = layers; mc["config"] = cfg; topo["model_config"] = mc; root["modelTopology"] = topo
        }
        func editConfig(_ index: Int, _ key: String, _ value: Any) -> (inout [String: Any]) -> Void {
            { root in editLayers(&root) { layers in
                var cfg = layers[index]["config"] as! [String: Any]
                cfg[key] = value
                layers[index]["config"] = cfg
            } }
        }

        try load { _ in /* sanity: unmodified model loads */ }

        #expect(throws: NeuralModelError.unsupportedLayer(name: "up", type: "Conv3DTranspose")) {
            try load { root in editLayers(&root, Self.insertTransposeConvLayer) }
        }
        #expect(throws: NeuralModelError.self) { try load(editConfig(1, "strides", [2, 2, 2])) }
        #expect(throws: NeuralModelError.self) { try load(editConfig(1, "padding", "valid")) }
        #expect(throws: NeuralModelError.self) { try load(editConfig(2, "activation", "swish")) }
        #expect(throws: NeuralModelError.weightShapeMismatch(name: "c1/kernel", expected: [3, 3, 3, 4, 5], actual: [3, 3, 3, 4, 4])) {
            try load(editConfig(5, "filters", 5))
        }
        #expect(throws: NeuralModelError.truncatedWeights(expectedBytes: 432, actualBytes: 100)) {
            try load({ _ in /* valid model; only the shard is truncated */ }, shardBytes: 100)
        }
        #expect(throws: NeuralModelError.shardUnreadable("w.bin")) {
            try load({ _ in /* valid model; only the shard path differs */ }, path: "other.bin")
        }
        #expect(throws: NeuralModelError.self) {
            try load { root in editLayers(&root, Self.addSkipConnectionInput) }
        }
        #expect(throws: NeuralModelError.unsupportedWeightDType(name: "c0_gn/kernel", dtype: "float16")) {
            try load { root in
                var manifest = root["weightsManifest"] as! [[String: Any]]
                var specs = manifest[0]["weights"] as! [[String: Any]]
                specs[0]["dtype"] = "float16"
                manifest[0]["weights"] = specs
                root["weightsManifest"] = manifest
            }
        }
        #expect(throws: NeuralModelError.self) {
            _ = try NeuralModel(tfjsModelJSON: Data("{\"format\":\"graph-model\"}".utf8)) { _ in Data() }
        }
        #expect(throws: NeuralModelError.malformedModelJSON("invalid JSON")) {
            _ = try NeuralModel(tfjsModelJSON: Data("not json".utf8)) { _ in Data() }
        }
    }

    @Test
    func loadFromURLRefusesShardPathsOutsideTheModelFolder() throws {
        var rng = LCG(state: 2)
        let (json, _, _) = try Self.makeTFJS(rng: &rng) { root in
            var manifest = root["weightsManifest"] as! [[String: Any]]
            manifest[0]["paths"] = ["../w.bin"]
            root["weightsManifest"] = manifest
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miq-neural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try json.write(to: dir.appendingPathComponent("model.json"))
        #expect(throws: NeuralModelError.shardUnreadable("../w.bin")) {
            _ = try NeuralModel.load(modelURL: dir.appendingPathComponent("model.json"))
        }
    }

    // MARK: - End-to-end pipeline

    /// Thresholding "network": one pointwise conv giving logits (10 − 20x, 20x − 10), so
    /// class 1 wins wherever the normalised intensity exceeds 0.5.
    static func thresholdEngine(keepLargest: Bool = true) throws -> NeuralMaskEngine {
        let head = try NeuralConv3D(name: "out", inChannels: 1, outChannels: 2, kernel: [1, 1, 1],
                                    dilation: [1, 1, 1], weights: [-20, 20], bias: [10, -10])
        let model = try NeuralModel(name: "threshold", layers: [.conv3D(head)])
        let profile = NeuralModelProfile(normalization: .minMax, cropThreshold: 0, cropPaddingMM: 4,
                                         foregroundClasses: [1], keepLargestComponent: keepLargest)
        return NeuralMaskEngine(model: model, profile: profile)
    }

    /// 32³ phantom at 4 mm with permuted/flipped axes: a bright sphere plus a small
    /// detached bright blob on a dim background.
    static func phantom() throws -> (NeuralInputVolume, sphere: [Bool], blob: [Bool]) {
        let n = 32
        var voxels = [Float](repeating: 10, count: n * n * n)
        var sphere = [Bool](repeating: false, count: n * n * n)
        var blob = [Bool](repeating: false, count: n * n * n)
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            let i = (z * n + y) * n + x
            let dc = Double((x - 15) * (x - 15) + (y - 16) * (y - 16) + (z - 14) * (z - 14))
            let db = Double((x - 28) * (x - 28) + (y - 3) * (y - 3) + (z - 27) * (z - 27))
            if dc <= 81 { voxels[i] = 100; sphere[i] = true }
            if db <= 2 { voxels[i] = 100; blob[i] = true }
        } } }
        // voxel x → world −y, voxel y → world +z, voxel z → world −x (4 mm), arbitrary origin.
        let affine = NeuralAffine(entries: [
            0, 0, -4, 30,
            -4, 0, 0, -12,
            0, 4, 0, 7,
        ])
        return (try NeuralInputVolume(width: n, height: n, depth: n, voxels: voxels, voxelToWorld: affine), sphere, blob)
    }

    @Test
    func phantomMaskMapsBackOntoTheSourceGrid() async throws {
        let (input, sphere, blob) = try Self.phantom()
        let options = NeuralRunOptions(gridSpacing: 4, fieldOfView: 128, maxThreads: 2)
        let result = try await Self.thresholdEngine().run(volume: input, options: options)
        #expect(result.gridSize == 32)
        #expect(result.isBinaryMask)
        #expect((result.width, result.height, result.depth) == (32, 32, 32))
        // The grid coincides with the source voxels, so the mask must be exact.
        let mismatches = zip(result.labels, sphere).filter { ($0 != 0) != $1 }.count
        #expect(mismatches == 0)
        #expect(zip(result.labels, blob).allSatisfy { !$1 || $0 == 0 }, "detached blob should be removed")

        let keepAll = try Self.thresholdEngine(keepLargest: false).runSynchronously(volume: input, options: options)
        #expect(keepAll.foregroundVoxelCount == sphere.filter { $0 }.count + blob.filter { $0 }.count)
    }

    @Test
    func coarserGridStillProducesAPlausibleMask() throws {
        let (input, sphere, _) = try Self.phantom()
        let options = NeuralRunOptions(gridSpacing: 6, fieldOfView: 132, maxThreads: 2)
        let result = try Self.thresholdEngine().runSynchronously(volume: input, options: options)
        let overlap = zip(result.labels, sphere).filter { $0 != 0 && $1 }.count
        let dice = 2 * Double(overlap) / Double(result.foregroundVoxelCount + sphere.filter { $0 }.count)
        #expect(dice > 0.85)
    }

    @Test
    func emptyVolumeYieldsEmptyMask() throws {
        let input = try NeuralInputVolume(width: 8, height: 8, depth: 8, voxels: [Float](repeating: 0, count: 512),
                                          voxelToWorld: .scaling(2, 2, 2))
        let result = try Self.thresholdEngine().runSynchronously(volume: input, options: NeuralRunOptions(gridSpacing: 2, fieldOfView: 32))
        #expect(result.foregroundVoxelCount == 0)
        #expect(result.labels.count == 512)
    }

    @Test
    func multiLabelOutputUsesNearestNeighbourLabels() throws {
        // Pointwise "network" with 3 classes: background below 0.3, class 1 in between, class 2 above 0.7.
        let head = try NeuralConv3D(name: "out", inChannels: 1, outChannels: 3, kernel: [1, 1, 1], dilation: [1, 1, 1],
                                    weights: [0, 10, 20], bias: [3, 0, -7])
        let engine = NeuralMaskEngine(model: try NeuralModel(name: "3c", layers: [.conv3D(head)]), profile: .parcellation(normalization: .minMax))
        let n = 16
        let voxels = (0..<(n * n * n)).map { Float(($0 % n) * 10) } // ramp along x
        let input = try NeuralInputVolume(width: n, height: n, depth: n, voxels: voxels, voxelToWorld: .scaling(2, 2, 2))
        let result = try engine.runSynchronously(volume: input, options: NeuralRunOptions(gridSpacing: 2, fieldOfView: 32))
        #expect(!result.isBinaryMask)
        #expect(result.labels[0] == 0)
        #expect(result.labels[n - 1] == 2)
        #expect(Set(result.labels) == [0, 1, 2])
    }

    @Test
    func inputVolumeTakesTheAffineFromTheHeader() throws {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .int16, sformCode: 1,
            srowX: [0, 0, -2, 5], srowY: [3, 0, 0, 1], srowZ: [0, 1.5, 0, -4],
            qformCode: 0, quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))
        let input = try NeuralInputVolume(volume: volume)
        #expect(input.voxels.count == 24)
        #expect(input.voxels[5] == volume.voxel(x: 1, y: 1, z: 0))
        let a = input.voxelToWorld.entries
        #expect(a[0...2] == [0, 0, -2] && a[4...6] == [3, 0, 0] && a[8...10] == [0, 1.5, 0])

        let plain = TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .uint8, pixdim: [1, 2, 3, 4])
        let plainInput = try NeuralInputVolume(volume: MIQVolume(image: try MIQParser().parseNifti(plain)))
        #expect(plainInput.voxelToWorld.column(0) == (2, 0, 0) || plainInput.voxelToWorld.column(0) == (-2, 0, 0))
        #expect(abs(plainInput.voxelToWorld.column(2).2) == 4)
    }

    @Test
    func affineInverseAndComposition() throws {
        let a = NeuralAffine(entries: [0, 0, -4, 30, -4, 0, 0, -12, 0, 4, 0, 7])
        let inv = try #require(a.inverted())
        let p = a.apply(1, 2, 3)
        let q = inv.apply(p.0, p.1, p.2)
        #expect(abs(q.0 - 1) < 1e-12 && abs(q.1 - 2) < 1e-12 && abs(q.2 - 3) < 1e-12)
        let identity = inv.concatenating(a)
        for (x, y) in zip(identity.entries, NeuralAffine.identity.entries) { #expect(abs(x - y) < 1e-12) }
        #expect(NeuralAffine(entries: [1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]).inverted() == nil)
        #expect(throws: NeuralModelError.self) {
            _ = try NeuralInputVolume(width: 2, height: 2, depth: 2, voxels: [0], voxelToWorld: .identity)
        }
    }

    // MARK: - Cancellation and timing

    @Test
    func cancellationStopsTheRun() async throws {
        let (input, _, _) = try Self.phantom()
        let engine = try Self.thresholdEngine()
        let token = NeuralCancellationToken()
        token.cancel()
        #expect(throws: CancellationError.self) {
            _ = try engine.runSynchronously(volume: input, cancellation: token)
        }
        let task = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // ensure cancel() lands first
            return try await engine.run(volume: input)
        }
        task.cancel()
        let outcome = await task.result
        #expect(throws: CancellationError.self) { _ = try outcome.get() }
    }

    @Test
    func meshNetShapedModelTimingSmoke() throws {
        // brainchop "model5" topology: 9 × (3³ conv, 5 ch, dilation 1-2-4-8-16-8-4-2-1) + ReLU + 1³ head.
        var rng = LCG(state: 77)
        var layers: [NeuralLayer] = []
        var cin = 1
        for d in [1, 2, 4, 8, 16, 8, 4, 2, 1] {
            layers.append(.conv3D(try Self.conv("c\(d)", cin, 5, dilation: [d, d, d], rng: &rng)))
            layers.append(.activation(.relu))
            cin = 5
        }
        layers.append(.conv3D(try Self.conv("out", 5, 3, kernel: [1, 1, 1], rng: &rng)))
        let model = try NeuralModel(name: "mesh5", layers: layers)
        #expect(model.macsPerVoxel == 27 * 5 + 8 * 27 * 25 + 15)
        let engine = NeuralMaskEngine(model: model, profile: .brainMaskFast)
        let input = Self.randomInput(24, 24, 24, seed: 11)
        let start = Date()
        let progressLog = ProgressLog()
        let prediction = try engine.infer(input, options: NeuralRunOptions(gridSpacing: 1), cancellation: nil) { progressLog.append($0) }
        let elapsed = Date().timeIntervalSince(start)
        print("NeuralMaskEngine timing smoke: 24³ × \(model.macsPerVoxel) MAC/voxel in \(String(format: "%.3f", elapsed)) s")
        #expect(prediction.labels.count == 24 * 24 * 24)
        #expect(elapsed < 120)
        let values = progressLog.values
        #expect(values.count == 9 && values == values.sorted() && values.last! > 0.9)
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: - Bundled brainchop models (skipped when Models/ is not next to the tests)

    static var modelsDirectory: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["MIQ_MODELS_DIR"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Models"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("mindgrab/model.json").path)
        }
    }

    @Test
    func bundledBrainchopModelsLoadAndRun() throws {
        guard let dir = Self.modelsDirectory else { return }
        let mindgrab = try NeuralModel.load(modelURL: dir.appendingPathComponent("mindgrab/model.json"))
        #expect(mindgrab.parameterCount == 146_237)
        #expect(mindgrab.outputChannels == 2)
        #expect(mindgrab.layers.filter { if case .instanceNorm = $0 { return true }; return false }.count == 25)
        #expect(mindgrab.layers.filter { $0 == .activation(.gelu) }.count == 25)

        let fast = try NeuralModel.load(modelURL: dir.appendingPathComponent("model5_gw_ae/model.json"))
        #expect(fast.parameterCount == 5_598)
        #expect(fast.outputChannels == 3)

        let prediction = try NeuralMaskEngine(model: fast, profile: .brainMaskFast)
            .predict(conformed: Self.randomInput(12, 12, 12, seed: 4))
        #expect(prediction.labels.allSatisfy { $0 < 3 })
    }
}
