import Foundation

/// Errors raised while loading or running a neural segmentation model.
public enum NeuralModelError: Error, LocalizedError, Equatable {
    case malformedModelJSON(String)
    case unsupportedLayer(name: String, type: String)
    case unsupportedConfiguration(String)
    case missingWeight(String)
    case weightShapeMismatch(name: String, expected: [Int], actual: [Int])
    case unsupportedWeightDType(name: String, dtype: String)
    case truncatedWeights(expectedBytes: Int, actualBytes: Int)
    case shardUnreadable(String)
    case channelMismatch(layer: String, expected: Int, actual: Int)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .malformedModelJSON(let reason):
            return "Malformed model.json: \(reason)."
        case .unsupportedLayer(let name, let type):
            return "Unsupported layer \"\(name)\" of type \(type)."
        case .unsupportedConfiguration(let reason):
            return "Unsupported model configuration: \(reason)."
        case .missingWeight(let name):
            return "Model weight \"\(name)\" is missing from the weights manifest."
        case .weightShapeMismatch(let name, let expected, let actual):
            return "Weight \"\(name)\" has shape \(actual), expected \(expected)."
        case .unsupportedWeightDType(let name, let dtype):
            return "Weight \"\(name)\" uses unsupported dtype \(dtype)."
        case .truncatedWeights(let expected, let actual):
            return "Weight shards hold \(actual) bytes but the manifest needs \(expected)."
        case .shardUnreadable(let path):
            return "Weight shard \"\(path)\" could not be read."
        case .channelMismatch(let layer, let expected, let actual):
            return "Layer \"\(layer)\" expects \(expected) input channels but receives \(actual)."
        case .invalidInput(let reason):
            return "Invalid neural-model input: \(reason)."
        }
    }
}

/// Element-wise activation functions supported by the engine.
public enum NeuralActivation: String, Sendable, Hashable {
    case linear
    case relu
    /// Keras ELU with the default `alpha = 1`.
    case elu
    /// Exact (erf-based) GELU, as used by tfjs-layers' `gelu`.
    case gelu
    /// Tanh-approximated GELU (`gelu_new`, also tinygrad's default `gelu`).
    case geluTanh
    case sigmoid
    case tanh
    /// Channel softmax. Only meaningful as the model's final activation; the head
    /// treats it as already-applied probabilities.
    case softmax
}

/// A 3-D convolution, stride 1, `same` zero padding, odd kernel sizes.
///
/// `weights` keep the Keras/tfjs layout `[kd][kh][kw][inChannels][outChannels]`
/// (out-channel fastest), which is also the GEMM-ready `[taps·in × out]` matrix.
public struct NeuralConv3D: Sendable, Hashable {
    public let name: String
    public let inChannels: Int
    public let outChannels: Int
    /// Kernel extent along (D, H, W) — the model's three spatial axes in order.
    public let kernel: [Int]
    /// Dilation along (D, H, W).
    public let dilation: [Int]
    public let weights: [Float]
    public let bias: [Float]?

    public init(
        name: String,
        inChannels: Int,
        outChannels: Int,
        kernel: [Int],
        dilation: [Int],
        weights: [Float],
        bias: [Float]?
    ) throws {
        guard inChannels > 0, outChannels > 0 else {
            throw NeuralModelError.unsupportedConfiguration("\(name): channel counts must be positive")
        }
        guard kernel.count == 3, kernel.allSatisfy({ $0 > 0 && $0 % 2 == 1 }) else {
            throw NeuralModelError.unsupportedConfiguration("\(name): only odd 3-D kernels are supported (got \(kernel))")
        }
        guard dilation.count == 3, dilation.allSatisfy({ $0 > 0 }) else {
            throw NeuralModelError.unsupportedConfiguration("\(name): invalid dilation \(dilation)")
        }
        let expected = kernel.reduce(1, *) * inChannels * outChannels
        guard weights.count == expected else {
            throw NeuralModelError.weightShapeMismatch(
                name: "\(name)/kernel",
                expected: kernel + [inChannels, outChannels],
                actual: [weights.count]
            )
        }
        if let bias, bias.count != outChannels {
            throw NeuralModelError.weightShapeMismatch(name: "\(name)/bias", expected: [outChannels], actual: [bias.count])
        }
        self.name = name
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.kernel = kernel
        self.dilation = dilation
        self.weights = weights
        self.bias = bias
    }

    public var tapCount: Int { kernel[0] * kernel[1] * kernel[2] }
    public var isPointwise: Bool { kernel == [1, 1, 1] }
}

/// One step of a sequential (chain-shaped) network.
public enum NeuralLayer: Sendable, Hashable {
    case conv3D(NeuralConv3D)
    case activation(NeuralActivation)
    /// Per-channel normalisation over all spatial positions (no learned affine):
    /// `(x − mean_c) / sqrt(var_c + ε)`. This is brainchop's `LayerNormInPlace`,
    /// applied after every Conv3D whose name ends in `_gn` (equivalent to a
    /// PyTorch `GroupNorm(groups = channels, affine = False)`).
    case instanceNorm(epsilon: Float)
    /// Per-channel `x · scale + shift` (a folded inference-mode BatchNormalization).
    case channelAffine(scale: [Float], shift: [Float])
}

/// A loaded, validated sequential network operating on single-channel 3-D input.
public struct NeuralModel: Sendable {
    public let name: String
    public let layers: [NeuralLayer]
    public let inputChannels: Int
    public let outputChannels: Int
    /// Spatial input shape declared by the model (e.g. `[256, 256, 256]`), if any.
    /// MeshNet is fully convolutional, so the engine accepts any grid size.
    public let declaredInputShape: [Int]?

    public init(name: String, layers: [NeuralLayer], inputChannels: Int = 1, declaredInputShape: [Int]? = nil) throws {
        var channels = inputChannels
        for layer in layers {
            switch layer {
            case .conv3D(let conv):
                guard conv.inChannels == channels else {
                    throw NeuralModelError.channelMismatch(layer: conv.name, expected: conv.inChannels, actual: channels)
                }
                channels = conv.outChannels
            case .channelAffine(let scale, let shift):
                guard scale.count == channels, shift.count == channels else {
                    throw NeuralModelError.channelMismatch(layer: "channelAffine", expected: scale.count, actual: channels)
                }
            case .activation, .instanceNorm:
                break
            }
        }
        guard layers.contains(where: { if case .conv3D = $0 { return true } else { return false } }) else {
            throw NeuralModelError.unsupportedConfiguration("model has no convolution layers")
        }
        guard channels <= 256 else {
            throw NeuralModelError.unsupportedConfiguration("at most 256 output classes are supported (got \(channels))")
        }
        self.name = name
        self.layers = layers
        self.inputChannels = inputChannels
        self.outputChannels = channels
        self.declaredInputShape = declaredInputShape
    }

    /// Number of learned parameters (weights + biases + affine terms).
    public var parameterCount: Int {
        layers.reduce(0) { total, layer in
            switch layer {
            case .conv3D(let c): return total + c.weights.count + (c.bias?.count ?? 0)
            case .channelAffine(let s, let t): return total + s.count + t.count
            default: return total
            }
        }
    }

    /// Multiply-accumulates per output voxel (useful for timing estimates).
    public var macsPerVoxel: Int {
        layers.reduce(0) { total, layer in
            if case .conv3D(let c) = layer { return total + c.weights.count }
            return total
        }
    }
}

// MARK: - TensorFlow.js layers-model loader

extension NeuralModel {
    /// Loads a TensorFlow.js *layers-model* (`model.json` + binary weight shards
    /// listed in its `weightsManifest`, resolved relative to `modelURL`).
    ///
    /// Supported layers: `InputLayer`, `Conv3D` (stride 1, `same` padding, odd kernel,
    /// any dilation), `Activation`, `ReLU`, `ELU` (alpha 1), `BatchNormalization`
    /// (folded), `Dropout`/`SpatialDropout3D` (identity at inference). Conv3D layers
    /// named `*_gn` get brainchop's per-channel normalisation appended. Anything else
    /// (or a branching functional graph) is rejected with a descriptive error.
    public static func load(modelURL: URL) throws -> NeuralModel {
        let json: Data
        do {
            json = try Data(contentsOf: modelURL)
        } catch {
            throw NeuralModelError.shardUnreadable(modelURL.lastPathComponent)
        }
        let base = modelURL.deletingLastPathComponent()
        let name = base.lastPathComponent
        return try NeuralModel(tfjsModelJSON: json, name: name) { path in
            // Shard paths are relative names; refuse anything that escapes the folder.
            guard !path.contains(".."), !path.hasPrefix("/") else {
                throw NeuralModelError.shardUnreadable(path)
            }
            do {
                return try Data(contentsOf: base.appendingPathComponent(path))
            } catch {
                throw NeuralModelError.shardUnreadable(path)
            }
        }
    }

    /// Parses a tfjs `model.json`, fetching each shard through `shardLoader`.
    public init(tfjsModelJSON: Data, name: String = "model", shardLoader: (String) throws -> Data) throws {
        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: tfjsModelJSON) as? [String: Any] else {
                throw NeuralModelError.malformedModelJSON("top level is not an object")
            }
            root = parsed
        } catch let error as NeuralModelError {
            throw error
        } catch {
            throw NeuralModelError.malformedModelJSON("invalid JSON")
        }
        if let format = root["format"] as? String, format != "layers-model" {
            throw NeuralModelError.unsupportedConfiguration("tfjs format \"\(format)\" (only layers-model is supported)")
        }
        guard let topology = root["modelTopology"] as? [String: Any] else {
            throw NeuralModelError.malformedModelJSON("missing modelTopology")
        }
        let modelConfig = (topology["model_config"] as? [String: Any]) ?? topology
        let layerList: [[String: Any]]
        if let config = modelConfig["config"] as? [String: Any], let list = config["layers"] as? [[String: Any]] {
            layerList = list
        } else if let list = modelConfig["config"] as? [[String: Any]] {
            layerList = list // legacy Sequential
        } else {
            throw NeuralModelError.malformedModelJSON("missing model_config.config.layers")
        }
        guard let manifest = root["weightsManifest"] as? [[String: Any]] else {
            throw NeuralModelError.malformedModelJSON("missing weightsManifest")
        }
        let weights = try TFJSWeights(manifest: manifest, shardLoader: shardLoader)

        var layers: [NeuralLayer] = []
        var channels = 1
        var declaredShape: [Int]?
        var previousName: String?
        for entry in layerList {
            guard let className = entry["class_name"] as? String,
                  let config = entry["config"] as? [String: Any] else {
                throw NeuralModelError.malformedModelJSON("layer without class_name/config")
            }
            let layerName = (config["name"] as? String) ?? (entry["name"] as? String) ?? className
            try Self.checkChainInbound(entry: entry, layerName: layerName, previous: previousName)
            previousName = layerName

            switch className {
            case "InputLayer":
                if let shape = config["batch_input_shape"] as? [Any] {
                    let dims = shape.dropFirst().map { ($0 as? Int) ?? -1 }
                    guard dims.count == 4 else {
                        throw NeuralModelError.unsupportedConfiguration("input must be 5-D (batch + 3 spatial + channel)")
                    }
                    let channelsFirst = (config["data_format"] as? String) == "channels_first"
                    let ch = channelsFirst ? dims[0] : dims[3]
                    guard ch == 1 || ch == -1 else {
                        throw NeuralModelError.unsupportedConfiguration("only single-channel input is supported (got \(ch))")
                    }
                    declaredShape = channelsFirst ? Array(dims[1...3]) : Array(dims[0...2])
                }
            case "Conv3D":
                let conv = try Self.parseConv3D(config: config, name: layerName, inChannels: channels, weights: weights)
                layers.append(.conv3D(conv))
                channels = conv.outChannels
                if layerName.hasSuffix("_gn") {
                    layers.append(.instanceNorm(epsilon: 1e-5))
                }
                if let act = config["activation"] as? String {
                    let parsed = try Self.parseActivation(act, layer: layerName)
                    if parsed != .linear { layers.append(.activation(parsed)) }
                }
            case "Activation":
                guard let act = config["activation"] as? String else {
                    throw NeuralModelError.malformedModelJSON("\(layerName) has no activation")
                }
                let parsed = try Self.parseActivation(act, layer: layerName)
                if parsed != .linear { layers.append(.activation(parsed)) }
            case "ReLU":
                if let maxValue = config["max_value"], !(maxValue is NSNull) {
                    throw NeuralModelError.unsupportedConfiguration("\(layerName): ReLU max_value is not supported")
                }
                if let slope = config["negative_slope"] as? Double, slope != 0 {
                    throw NeuralModelError.unsupportedConfiguration("\(layerName): ReLU negative_slope is not supported")
                }
                layers.append(.activation(.relu))
            case "ELU":
                if let alpha = config["alpha"] as? Double, abs(alpha - 1) > 1e-9 {
                    throw NeuralModelError.unsupportedConfiguration("\(layerName): ELU alpha \(alpha) (only 1 is supported)")
                }
                layers.append(.activation(.elu))
            case "BatchNormalization":
                layers.append(try Self.parseBatchNorm(config: config, name: layerName, channels: channels, weights: weights))
            case "Dropout", "SpatialDropout3D", "GaussianDropout", "AlphaDropout":
                break
            default:
                throw NeuralModelError.unsupportedLayer(name: layerName, type: className)
            }
        }
        try self.init(name: name, layers: layers, inputChannels: 1, declaredInputShape: declaredShape)
    }

    /// Rejects functional graphs that are not a simple chain (skip connections,
    /// multiple inputs), which a sequential engine would silently mis-evaluate.
    private static func checkChainInbound(entry: [String: Any], layerName: String, previous: String?) throws {
        guard let inbound = entry["inbound_nodes"] as? [Any], !inbound.isEmpty else { return }
        var sources: [String] = []
        func collect(_ value: Any) {
            if let array = value as? [Any] {
                // Keras node form: [layer_name, node_index, tensor_index, kwargs]
                if let first = array.first as? String, array.count >= 3, array[1] is Int {
                    sources.append(first)
                } else {
                    array.forEach(collect)
                }
            } else if let dict = value as? [String: Any] {
                if let history = (dict["config"] as? [String: Any])?["keras_history"] as? [Any],
                   let source = history.first as? String {
                    sources.append(source)
                } else {
                    dict.values.forEach(collect)
                }
            }
        }
        collect(inbound)
        guard !sources.isEmpty else { return }
        guard sources.count == 1, sources[0] == previous else {
            throw NeuralModelError.unsupportedConfiguration("\(layerName) is not a sequential chain (inputs: \(sources))")
        }
    }

    private static func intTriple(_ value: Any?, default fallback: Int, layer: String, key: String) throws -> [Int] {
        guard let value else { return [fallback, fallback, fallback] }
        if let single = value as? Int { return [single, single, single] }
        if let list = value as? [Any] {
            let ints = list.compactMap { $0 as? Int }
            if ints.count == 3 { return ints }
            if ints.count == 1 { return [ints[0], ints[0], ints[0]] }
        }
        throw NeuralModelError.malformedModelJSON("\(layer).\(key) is not a 3-tuple")
    }

    private static func parseConv3D(config: [String: Any], name: String, inChannels: Int, weights: TFJSWeights) throws -> NeuralConv3D {
        guard let filters = config["filters"] as? Int else {
            throw NeuralModelError.malformedModelJSON("\(name) has no filters")
        }
        let kernel = try intTriple(config["kernel_size"], default: 1, layer: name, key: "kernel_size")
        let dilation = try intTriple(config["dilation_rate"], default: 1, layer: name, key: "dilation_rate")
        let strides = try intTriple(config["strides"], default: 1, layer: name, key: "strides")
        guard strides == [1, 1, 1] else {
            throw NeuralModelError.unsupportedConfiguration("\(name): strides \(strides) (only 1 is supported)")
        }
        let padding = (config["padding"] as? String) ?? "valid"
        guard padding == "same" || kernel == [1, 1, 1] else {
            throw NeuralModelError.unsupportedConfiguration("\(name): padding \"\(padding)\" (only same is supported)")
        }
        if let groups = config["groups"] as? Int, groups != 1 {
            throw NeuralModelError.unsupportedConfiguration("\(name): grouped convolution")
        }
        let kernelShape = kernel + [inChannels, filters]
        let kernelValues = try weights.tensor(layer: name, suffix: "kernel", shape: kernelShape)
        let useBias = (config["use_bias"] as? Bool) ?? true
        let bias = useBias ? try weights.tensor(layer: name, suffix: "bias", shape: [filters]) : nil
        return try NeuralConv3D(
            name: name, inChannels: inChannels, outChannels: filters,
            kernel: kernel, dilation: dilation, weights: kernelValues, bias: bias
        )
    }

    private static func parseBatchNorm(config: [String: Any], name: String, channels: Int, weights: TFJSWeights) throws -> NeuralLayer {
        if let axis = config["axis"] {
            let axes = (axis as? [Int]) ?? ((axis as? Int).map { [$0] } ?? [])
            guard axes == [-1] || axes == [4] else {
                throw NeuralModelError.unsupportedConfiguration("\(name): BatchNormalization axis \(axes) (channels-last only)")
            }
        }
        let epsilon = Float((config["epsilon"] as? Double) ?? 1e-3)
        let center = (config["center"] as? Bool) ?? true
        let scale = (config["scale"] as? Bool) ?? true
        let gamma = scale ? try weights.tensor(layer: name, suffix: "gamma", shape: [channels]) : [Float](repeating: 1, count: channels)
        let beta = center ? try weights.tensor(layer: name, suffix: "beta", shape: [channels]) : [Float](repeating: 0, count: channels)
        let mean = try weights.tensor(layer: name, suffix: "moving_mean", shape: [channels])
        let variance = try weights.tensor(layer: name, suffix: "moving_variance", shape: [channels])
        var folded = [Float](repeating: 0, count: channels)
        var shift = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            folded[c] = gamma[c] / (variance[c] + epsilon).squareRoot()
            shift[c] = beta[c] - mean[c] * folded[c]
        }
        return .channelAffine(scale: folded, shift: shift)
    }

    private static func parseActivation(_ name: String, layer: String) throws -> NeuralActivation {
        switch name {
        case "linear": return .linear
        case "relu": return .relu
        case "elu": return .elu
        case "gelu": return .gelu
        case "gelu_new": return .geluTanh
        case "sigmoid": return .sigmoid
        case "tanh": return .tanh
        case "softmax": return .softmax
        default: throw NeuralModelError.unsupportedLayer(name: layer, type: "activation \(name)")
        }
    }
}

/// Weight-manifest view: maps tensor names to their slices of the concatenated shards.
struct TFJSWeights {
    private struct Entry {
        let shape: [Int]
        let values: [Float]
    }
    private var entries: [String: Entry] = [:]

    init(manifest: [[String: Any]], shardLoader: (String) throws -> Data) throws {
        for group in manifest {
            guard let paths = group["paths"] as? [String], let specs = group["weights"] as? [[String: Any]] else {
                throw NeuralModelError.malformedModelJSON("weightsManifest group without paths/weights")
            }
            var blob = Data()
            for path in paths { blob.append(try shardLoader(path)) }
            var offset = 0
            for spec in specs {
                guard let name = spec["name"] as? String, let shape = spec["shape"] as? [Int] else {
                    throw NeuralModelError.malformedModelJSON("weight spec without name/shape")
                }
                guard shape.allSatisfy({ $0 >= 0 }) else {
                    throw NeuralModelError.malformedModelJSON("\(name) has a negative dimension")
                }
                let dtype = (spec["dtype"] as? String) ?? "float32"
                guard dtype == "float32" else {
                    throw NeuralModelError.unsupportedWeightDType(name: name, dtype: dtype)
                }
                if spec["quantization"] != nil {
                    throw NeuralModelError.unsupportedWeightDType(name: name, dtype: "quantized")
                }
                let count = shape.reduce(1, *)
                let byteCount = count * 4
                guard offset + byteCount <= blob.count else {
                    throw NeuralModelError.truncatedWeights(expectedBytes: offset + byteCount, actualBytes: blob.count)
                }
                var values = [Float](repeating: 0, count: count)
                blob.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let bits = raw.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self)
                        values[i] = Float(bitPattern: UInt32(littleEndian: bits))
                    }
                }
                entries[name] = Entry(shape: shape, values: values)
                offset += byteCount
            }
        }
    }

    /// Looks up `<layer>/<suffix>`, tolerating a scope prefix (`model/<layer>/<suffix>`).
    func tensor(layer: String, suffix: String, shape: [Int]) throws -> [Float] {
        let key = "\(layer)/\(suffix)"
        let entry = entries[key] ?? entries.first(where: { $0.key.hasSuffix("/" + key) })?.value
        guard let entry else { throw NeuralModelError.missingWeight(key) }
        guard entry.shape == shape else {
            throw NeuralModelError.weightShapeMismatch(name: key, expected: shape, actual: entry.shape)
        }
        return entry.values
    }
}
