#!/usr/bin/env python3
"""Regenerates Tests/Fixtures/codecs/: Zstandard, Blosc and LZ4 test vectors
plus small zarr-python v2/v3 stores, for `ZarrCodecTests`.

Requires numpy, numcodecs and zarr (>= 3). Output is deterministic for a given
library version, but compressors may change their output between versions, so
only rerun this to add cases; the committed bytes are the reference.

    python3 scripts/dev/make_codec_fixtures.py

`manifest.json` lists every stream with its codec, decompressed size and the
SHA-256 of the decompressed bytes, and every store with the SHA-256 of the
array's C-order little-endian bytes (which is MIQ's x-fastest voxel layout).
"""
import hashlib
import json
import os
import shutil
import struct
import sys

import numpy as np
import numcodecs
from numcodecs import Blosc, LZ4, Zstd
import zarr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Tests", "Fixtures", "codecs")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def text_bytes(n, seed, vocab=32):
    rng = np.random.default_rng(seed)
    words = ["".join(chr(97 + c) for c in rng.integers(0, 26, rng.integers(2, 9))) for _ in range(vocab)]
    out = []
    size = 0
    while size < n:
        w = words[int(rng.integers(0, vocab))]
        sep = " " if rng.random() < 0.9 else ".\n"
        out.append(w + sep)
        size += len(w) + len(sep)
    return "".join(out).encode()[:n]


def smooth(n, dtype, seed, noise=0.6):
    rng = np.random.default_rng(seed)
    t = np.arange(n)
    info = np.iinfo(dtype) if np.issubdtype(dtype, np.integer) else None
    base = np.round(1000 + 400 * np.sin(t / 37.0) + rng.normal(0, noise, n))
    if info is not None:
        base = np.clip(base * (1 if info.bits > 8 else 0.1), info.min, info.max)
    return base.astype(dtype)


def main():
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT)
    os.makedirs(ROOT)
    manifest = {"streams": [], "stores": [],
                "versions": {"numcodecs": numcodecs.__version__, "zarr": zarr.__version__}}

    def add(name, codec, raw, encoded, **extra):
        path = name + "." + codec
        with open(os.path.join(ROOT, path), "wb") as f:
            f.write(encoded)
        entry = {"file": path, "codec": codec, "size": len(raw), "sha256": sha(raw)}
        entry.update(extra)
        manifest["streams"].append(entry)

    # --- Zstandard -------------------------------------------------------
    text = text_bytes(40_000, 1, vocab=16)           # multi-block, Huffman 4-stream + treeless literals
    image = smooth(8_000, np.uint16, 2).tobytes()
    rng = np.random.default_rng(3)
    unit = rng.integers(0, 256, 2_000, dtype=np.uint8).tobytes()
    repeated = unit * 100                    # long matches, repeat offsets
    random = rng.integers(0, 256, 3_000, dtype=np.uint8).tobytes()  # raw blocks
    zeros = bytes(300_000)                   # RLE blocks
    for level in (1, 3, 19):
        add(f"text_l{level}", "zst", text, Zstd(level=level).encode(text))
    # Two blocks of skewed bytes: Huffman literals in both, so the second block
    # can reuse the first's Huffman table (treeless) and FSE tables (repeat).
    skew = np.random.default_rng(5).geometric(0.85, 135_000).clip(1, 40).astype(np.uint8) + 64
    skewed = skew.tobytes()
    for level in (3, 19):
        add(f"skewed_l{level}", "zst", skewed, Zstd(level=level).encode(skewed))
    for level in (3, 19):
        add(f"image_l{level}", "zst", image, Zstd(level=level).encode(image))
    add("text_lneg5", "zst", text, Zstd(level=-5).encode(text))
    add("repeated_l3", "zst", repeated, Zstd(level=3).encode(repeated))
    add("random_l3", "zst", random, Zstd(level=3).encode(random))
    add("zeros_l3", "zst", zeros, Zstd(level=3).encode(zeros))
    add("short_l3", "zst", b"hello, zstd", Zstd(level=3).encode(b"hello, zstd"))
    add("empty_l3", "zst", b"", Zstd(level=3).encode(b""))
    add("text_checksum_l3", "zst", text[:50_000], Zstd(level=3, checksum=True).encode(text[:50_000]))
    parts = [text[:20_000], image[:10_000], b"tail"]
    skippable = struct.pack("<II", 0x184D2A53, 5) + b"skip!"
    multi = Zstd(level=3).encode(parts[0]) + skippable + Zstd(level=1).encode(parts[1]) + Zstd(level=19).encode(parts[2])
    add("multiframe", "zst", b"".join(parts), multi)

    # --- Blosc -----------------------------------------------------------
    dtypes = {1: np.uint8, 2: np.uint16, 4: np.uint32, 8: np.float64}
    for cname in ("blosclz", "lz4", "lz4hc", "zlib", "zstd"):
        for shuffle in ((1,) if cname == "lz4hc" else (0, 1, 2)):  # lz4hc shares the LZ4 decoder
            for ts, dt in dtypes.items():
                raw = smooth(301, dt, 10 + ts, noise=0.3).tobytes()
                enc = Blosc(cname=cname, clevel=5, shuffle=shuffle, blocksize=256).encode(raw)
                add(f"blosc_{cname}_s{shuffle}_t{ts}", "blosc", raw, enc)
    raw = rng.integers(0, 256, 3000, dtype=np.uint8).tobytes()
    add("blosc_memcpyed", "blosc", raw, Blosc(cname="lz4", clevel=0, shuffle=0).encode(raw))
    raw = smooth(3_000, np.uint16, 7).tobytes()
    add("blosc_lz4_default", "blosc", raw, Blosc().encode(raw))

    # --- numcodecs LZ4 ---------------------------------------------------
    add("numcodecs_lz4", "lz4", text[:20_000], LZ4().encode(text[:20_000]))

    # --- zarr-python stores ------------------------------------------------
    data = (np.arange(6 * 20 * 24, dtype=np.uint16).reshape(6, 20, 24) * 7) % 4099
    axes = [{"name": n, "type": "space", "unit": "micrometer"} for n in "zyx"]
    transforms = [{"type": "scale", "scale": [2.0, 0.5, 0.25]},
                  {"type": "translation", "translation": [10.0, 20.0, 30.0]}]
    multiscales = [{"version": "0.4", "axes": axes, "datasets": [{"path": "0", "coordinateTransformations": transforms}]}]
    stores = [
        ("v2_blosc.ome.zarr", 2, {"compressors": Blosc()}),          # zarr-python 2 default
        ("v2_zstd.ome.zarr", 2, {}),                                  # zarr-python 3 default for v2
        ("v3_zstd.ome.zarr", 3, {}),                                  # zarr-python 3 default
        ("v3_blosc.ome.zarr", 3, {"compressors": zarr.codecs.BloscCodec(cname="zstd", shuffle="bitshuffle")}),
    ]
    for name, fmt, kwargs in stores:
        path = os.path.join(ROOT, name)
        group = zarr.open_group(path, mode="w", zarr_format=fmt)
        array = group.create_array("0", shape=data.shape, chunks=(4, 8, 16), dtype=data.dtype, **kwargs)
        array[:] = data
        if fmt == 2:
            group.attrs["multiscales"] = multiscales
        else:
            ms = json.loads(json.dumps(multiscales))
            del ms[0]["version"]
            group.attrs["ome"] = {"version": "0.5", "multiscales": ms}
        manifest["stores"].append({"store": name, "shape": list(data.shape), "sha256": sha(data.astype("<u2").tobytes()),
                                   "origin_mm": [0.030, 0.020, 0.010], "spacing_mm": [0.00025, 0.0005, 0.002]})

    with open(os.path.join(ROOT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    total = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(ROOT) for n in ns)
    print(f"wrote {len(manifest['streams'])} streams, {len(manifest['stores'])} stores, {total} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
