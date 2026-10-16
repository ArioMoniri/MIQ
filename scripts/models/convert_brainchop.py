#!/usr/bin/env python3
"""Inspect, verify and cross-check brainchop MeshNet models for MIQ's neural mask engine.

MIQ reads TensorFlow.js *layers-model* files (model.json + float32 .bin shards) directly
(Sources/MIQCore/Neural/NeuralModel.swift), so no format conversion is needed for the
brainchop models. This script exists to:

  inspect   <model.json>                    list layers/params, validate shard sizes, print SHA-256s
  tiny      <out_dir>                       write a tiny synthetic tfjs model (stdlib only) for tests
  reference <model.json> <in.f32> D H W <out.f32>
                                            numpy forward pass (float32 logits, channels-last) on a
                                            raw little-endian float32 (D,H,W) volume, to cross-check
                                            the Swift engine numerically (requires numpy)

Only the Python standard library is needed except for `reference`.
"""
import hashlib
import json
import math
import os
import struct
import sys


def _layers(model):
    topo = model["modelTopology"]
    cfg = topo.get("model_config", topo)
    conf = cfg["config"]
    return conf["layers"] if isinstance(conf, dict) else conf


def _inside(base, *parts):
    """Resolve ``parts`` under ``base`` and refuse anything that lands outside it
    (``..``, absolute paths or symlinks in a model.json's shard list)."""
    root = os.path.realpath(base)
    path = os.path.realpath(os.path.join(root, *parts))
    if os.path.commonpath([root, path]) != root:
        raise SystemExit(f"refusing path outside {root}: {os.path.join(*parts)}")
    return path


def _user_path(arg):
    """A path given on the command line, confined to the current directory tree."""
    return _inside(os.getcwd(), arg)


def _read_weights(model_path):
    """Return {name: (shape, flat list or bytes)} from the weightsManifest."""
    model_path = _user_path(model_path)
    with open(model_path, encoding="utf-8") as fh:
        model = json.load(fh)
    base = os.path.dirname(model_path)
    out = {}
    for group in model["weightsManifest"]:
        chunks = []
        for shard in group["paths"]:
            with open(_inside(base, shard), "rb") as fh:
                chunks.append(fh.read())
        blob = b"".join(chunks)
        offset = 0
        for spec in group["weights"]:
            if spec.get("dtype", "float32") != "float32" or "quantization" in spec:
                raise SystemExit(f"unsupported dtype/quantization for {spec['name']}")
            n = math.prod(spec["shape"])
            need = offset + 4 * n
            if need > len(blob):
                raise SystemExit(f"shards truncated: need {need} bytes, have {len(blob)}")
            out[spec["name"]] = (spec["shape"], blob[offset:need])
            offset = need
        if offset != len(blob):
            print(f"warning: {len(blob) - offset} trailing bytes in group {group['paths']}")
    return model, out


def cmd_inspect(model_path):
    model_path = _user_path(model_path)
    model, weights = _read_weights(model_path)
    total = 0
    for layer in _layers(model):
        c = layer["config"]
        extra = {k: c[k] for k in ("filters", "kernel_size", "dilation_rate", "padding", "activation", "use_bias") if k in c}
        print(f"{layer['class_name']:>20} {c.get('name', ''):<16} {extra}")
    for name, (shape, _) in weights.items():
        total += math.prod(shape)
    print(f"parameters: {total}")
    base = os.path.dirname(model_path)
    files = [os.path.basename(model_path)] + [p for g in model["weightsManifest"] for p in g["paths"]]
    for f in files:
        with open(_inside(base, f), "rb") as fh:
            data = fh.read()
        print(f"sha256 {hashlib.sha256(data).hexdigest()}  {len(data):>8}  {f}")


def cmd_tiny(out_dir):
    """Two 3x3x3 convs (dilation 1 and 2) + ReLU + 1x1x1 head, deterministic weights."""
    out_dir = _user_path(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    def vals(n, seed):
        return [((i * 37 + seed * 11) % 17 - 8) / 16.0 for i in range(n)]
    specs = [
        ("c1/kernel", [3, 3, 3, 1, 2], vals(54, 1)), ("c1/bias", [2], [0.1, -0.2]),
        ("c2/kernel", [3, 3, 3, 2, 2], vals(108, 2)), ("c2/bias", [2], [0.0, 0.05]),
        ("output/kernel", [1, 1, 1, 2, 2], [1.0, -1.0, -0.5, 0.5]), ("output/bias", [2], [0.0, 0.0]),
    ]
    layers = [{"class_name": "InputLayer", "config": {"name": "input", "batch_input_shape": [None, 8, 8, 8, 1]}}]
    for name, dil in (("c1", 1), ("c2", 2)):
        layers.append({"class_name": "Conv3D", "config": {"name": name, "filters": 2, "kernel_size": [3, 3, 3],
                       "dilation_rate": [dil] * 3, "padding": "same", "strides": [1, 1, 1], "activation": "linear", "use_bias": True}})
        layers.append({"class_name": "Activation", "config": {"name": name + "_relu", "activation": "relu"}})
    layers.append({"class_name": "Conv3D", "config": {"name": "output", "filters": 2, "kernel_size": [1, 1, 1],
                   "dilation_rate": [1, 1, 1], "padding": "same", "strides": [1, 1, 1], "activation": "linear", "use_bias": True}})
    model = {"format": "layers-model", "generatedBy": "MIQ convert_brainchop.py tiny",
             "modelTopology": {"model_config": {"class_name": "Functional", "config": {"layers": layers}}},
             "weightsManifest": [{"paths": ["tiny.bin"], "weights": [{"name": n, "shape": s, "dtype": "float32"} for n, s, _ in specs]}]}
    with open(_inside(out_dir, "model.json"), "w", encoding="utf-8") as f:
        json.dump(model, f, indent=1)
    with open(_inside(out_dir, "tiny.bin"), "wb") as f:
        for _, _, v in specs:
            f.write(struct.pack(f"<{len(v)}f", *v))
    print(f"wrote {out_dir}/model.json and tiny.bin")


def _activation(x, name):
    """Applies a Keras activation by name (softmax is left to the caller)."""
    import numpy as np  # optional dependency
    if name in ("linear", "softmax", None):
        return x
    if name == "relu":
        return np.maximum(x, 0)
    if name == "elu":
        return np.where(x > 0, x, np.expm1(np.minimum(x, 0)))
    if name == "gelu":
        erf = np.vectorize(math.erf, otypes=[np.float32])
        return 0.5 * x * (1 + erf(x / math.sqrt(2)))
    raise SystemExit(f"activation {name} not handled")


def _conv3d(x, c, w_arr):
    """'same'-padded dilated Conv3D of ``x`` (D, H, W, Cin) with layer config ``c``,
    plus bias and, for ``*_gn`` layers, per-channel normalisation (before activation)."""
    import numpy as np  # optional dependency
    k = w_arr[c["name"] + "/kernel"]
    kd, kh, kw, _, cout = k.shape
    dil = c.get("dilation_rate", [1, 1, 1])
    pads = [(dil[i] * (k.shape[i] // 2),) * 2 for i in range(3)]
    xp = np.pad(x, pads + [(0, 0)])
    y = np.zeros(x.shape[:3] + (cout,), dtype=np.float32)
    for a in range(kd):
        for b in range(kh):
            for e in range(kw):
                sa, sb, se = a * dil[0], b * dil[1], e * dil[2]
                patch = xp[sa:sa + x.shape[0], sb:sb + x.shape[1], se:se + x.shape[2], :]
                y += patch @ k[a, b, e]
    if c.get("use_bias", True):
        y += w_arr[c["name"] + "/bias"]
    if c["name"].endswith("_gn"):
        mean = y.mean(axis=(0, 1, 2), dtype=np.float64)
        var = y.var(axis=(0, 1, 2), dtype=np.float64)
        y = ((y - mean) / np.sqrt(var + 1e-5)).astype(np.float32)
    return y


def cmd_reference(model_path, in_path, d, h, w, out_path):
    import numpy as np  # optional dependency
    model, weights = _read_weights(model_path)
    w_arr = {k: np.frombuffer(b, dtype="<f4").reshape(s) for k, (s, b) in weights.items()}
    x = np.fromfile(in_path, dtype="<f4").reshape(d, h, w, 1)

    for layer in _layers(model):
        c = layer["config"]
        kind = layer["class_name"]
        if kind == "Conv3D":
            x = _activation(_conv3d(x, c, w_arr), c.get("activation"))
        elif kind == "Activation":
            x = _activation(x, c["activation"])
        elif kind in ("InputLayer", "Dropout"):
            continue
        else:
            raise SystemExit(f"layer {kind} not handled by the reference")
        print(f"{c.get('name')}: {x.shape} mean {float(x.mean()):.5f}", file=sys.stderr)
    x.astype("<f4").tofile(out_path)
    print(f"wrote {out_path} {x.shape}")


def main(argv):
    if len(argv) >= 2 and argv[0] == "inspect":
        cmd_inspect(argv[1])
    elif len(argv) >= 2 and argv[0] == "tiny":
        cmd_tiny(argv[1])
    elif len(argv) >= 7 and argv[0] == "reference":
        cmd_reference(argv[1], argv[2], int(argv[3]), int(argv[4]), int(argv[5]), argv[6])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
