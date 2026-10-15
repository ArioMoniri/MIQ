# Neural mask models

These are the weights for MIQ's optional on-device brain extraction / tissue preview
(`Sources/MIQCore/Neural`, entry point `NeuralMaskEngine`). They are TensorFlow.js
*layers-model* files (`model.json` plus raw little-endian float32 weight shards). MIQ
reads them directly; no conversion step is needed.

| Folder | Purpose | Files | Size | Parameters | MAC / voxel |
|---|---|---|---|---|---|
| `mindgrab/` | Skull stripping for any modality (MindGrab) | `model.json`, `model.bin`, `colormap.json` | 68 KB + 585 KB | 146,237 | 146k |
| `model5_gw_ae/` | Fast brain-tissue mask: background / grey / white | `model.json`, `group1-shard1of1.bin`, `colormap.json` | 9 KB + 22 KB | 5,598 | 5.6k |

Both sets are well under the 2 MB limit for committed weights, so they are vendored here
unchanged.

## Provenance and licence

* **Source:** <https://github.com/neuroneural/brainchop>, commit
  `4c87885f3a2a8835e260d521dcec922b58d91d41` (2025-08-13), paths `public/models/mindgrab/*`
  and `public/models/model5_gw_ae/*`. Raw URLs:
  * `https://raw.githubusercontent.com/neuroneural/brainchop/4c87885f3a2a8835e260d521dcec922b58d91d41/public/models/mindgrab/model.json`
  * `…/public/models/mindgrab/model.bin`, `…/public/models/mindgrab/colormap.json`
  * `…/public/models/model5_gw_ae/model.json`, `…/public/models/model5_gw_ae/group1-shard1of1.bin`, `…/public/models/model5_gw_ae/colormap.json`
* **Licence:** MIT, "Copyright (c) 2021 neuroneural/brainchop". The full text is in
  [`LICENSE-brainchop`](LICENSE-brainchop) and must ship with any build that bundles
  these files. The weights live in the MIT-licensed repository and have no separate
  licence. The Python CLI that serves the same models (`brainchop` on PyPI,
  <https://github.com/neuroneural/brainchop-cli>) is also MIT.
* **MindGrab paper:** Fani, Doan, Le, Fedorov, Hoffmann, Rorden, Plis, *MindGrab for
  BrainChop: Fast and Accurate Skull Stripping for Command Line and Browser*, arXiv
  [2506.11860](https://arxiv.org/abs/2506.11860) (2025). It was trained on synthetic
  data only and reports a mean Dice of 95.9 on 606 multimodal scans.
* **Not used, on licence grounds:** SynthStrip (its upstream code is GPL-2.0), and the
  `neuroneural/brainchop-models` repository, which has no LICENSE file. No NC or SA
  licensed weights are included.

### SHA-256

```
24d1bcccba736a83c80b336ca349297f4839ae08b8ec92ec72c5d6adb9afe76e  mindgrab/model.json
c9a01490fe2d13acc1515fd019b69db176ebe6f40c9b84aeb77f25acbc2ee0f3  mindgrab/model.bin
b29809105747c752c889036bb953744cbd63b67f25b9c1b0657eaf00841fd1bf  mindgrab/colormap.json
7aabd59933bd3528f120107165f5dd577c5b749cf91fc2f949987d7bc620ce59  model5_gw_ae/model.json
ca0d1b8ff72f8719d9525acaf9a1f1cb66dbb173b4ee1d7540f99e022cf4bfd8  model5_gw_ae/group1-shard1of1.bin
36a45c1cc84ccb73482f3ad5a4d482da1f965e55c4b59f8f18d3649a8e7fd94d  model5_gw_ae/colormap.json
```

`python3 scripts/models/convert_brainchop.py inspect Models/mindgrab/model.json`
reprints these hashes, validates the shard sizes, and lists the layers.

## Architecture (MeshNet)

Both models are MeshNets: a chain of 3×3×3 dilated convolutions (stride 1, `same` zero
padding, channels-last) followed by a 1×1×1 convolution to class logits and an argmax.

* **mindgrab:** 25 blocks of `Conv3D(15, no bias) → per-channel normalisation → GELU`.
  Dilations cycle 16, 8, 4, 2, 1 five times. Head: `Conv3D(2, 1×1×1, bias)`, where class 1
  is brain. The normalisation is brainchop's `LayerNormInPlace`, applied to every
  Conv3D whose name ends in `_gn`: per-channel mean and variance over all voxels,
  ε = 1e-5, no affine. In PyTorch terms this is `GroupNorm(groups = channels, affine = False)`.
  The GELU is tfjs `gelu`, the exact erf form.
* **model5_gw_ae:** 9 blocks of `Conv3D(5, bias) → ReLU` with dilations
  1, 2, 4, 8, 16, 8, 4, 2, 1. Head: `Conv3D(3, 1×1×1)`. The classes are background, grey
  and white matter, and brainchop's "Brain Mask (FAST)" treats any class above 0 as brain.

## Input conforming (as brainchop does it, and as MIQ reproduces it)

1. **Conform** the volume to 256³ at 1 mm, using the FreeSurfer **LIA** orientation and
   uint8 intensities. brainchop uses niivue/niimath `conform`. Tensor axes are
   (i, j, k) of the conformed grid: the web app transposes the `[z][y][x]` slices and
   the CLI calls `permute(2,1,0)`. MIQ resamples straight into that grid with trilinear
   interpolation through the image affine, box-supersampled when the grid is coarser
   than the source. It centres the grid on the volume and emulates the uint8 scaling
   with a 0 to 99.9th percentile range quantised to 256 levels.
2. **Normalise:** min-max to [0, 1] for both models (web app setting
   `enableQuantileNorm: false`). The CLI instead uses `qnormalize`, which clips the 2–98 %
   quantiles. Both are available as `NeuralNormalization`.
3. **Crop** to the bounding box of voxels above `autoThreshold × max` and pad the box.
   mindgrab uses a threshold of 0.5 and 20 voxels of padding. model5 uses a threshold
   of 0 (any voxel above 0) and 17 voxels. MIQ converts the padding to millimetres.
4. **Post-process:** argmax, keep the largest connected component (brainchop's
   `isPostProcessEnable`), then map back to the source grid. Binary masks use trilinear
   interpolation of the foreground probability; label maps use nearest neighbour.

## Accuracy and speed on this Linux sandbox

Test image: `examples/brain.nii.gz` from brainchop-cli (a conformed 256³ T1). Its
licence is not stated, so it is not committed. The machine has 4 shared cores and was
heavily contended (load average about 4–6 from other agents). Build was Swift 6.2 in
release mode with the portable SIMD backend; the Accelerate path was not measured.

| Model | Grid | Inferred crop | Inference | Total | Mask | Dice vs mindgrab 1 mm |
|---|---|---|---|---|---|---|
| mindgrab | 1 mm, 256³ | 204×203×255 | 103.5 s | 105.7 s | 1646 mL | (reference) |
| mindgrab | 1.5 mm, 171³ (dilations ÷1.5) | 136×135×169 | 21.3 s | 22.0 s | 1640 mL | 0.990 |
| mindgrab | 2 mm, 128³ (dilations ÷2) | 102×101×127 | 11.6 s | 12.1 s | 1626 mL | **0.988** |
| mindgrab | 2 mm, 128³, verbatim dilations | 102×101×127 | 12.6 s | 13.2 s | 2021 mL (leaks into scalp) | 0.895 |
| model5 | 1 mm | 198×198×256 | 6.1 s | 7.8 s | 1250 mL (tissue only, no CSF) | 0.863 |
| model5 | 2 mm (dilations ÷2) | 101×100×128 | 0.85 s | 1.5 s | 1351 mL | 0.893 |

The 2 mm runs use the **dilation adaptation** (`NeuralRunOptions.adaptDilationToSpacing`,
on by default). Every dilation is divided by the spacing ratio, rounded, with a minimum
of 1, so the receptive field keeps its physical size on the coarser grid. Without it,
the dilation-16 layers reach twice as far and MindGrab over-segments badly. 2 mm is
about 9× faster than 1 mm and makes a good preview. Use 1 mm when the mask must be exact.

Numerical check: on a 20×18×22 input with the real MindGrab weights, the Swift engine
matches the NumPy reference (`convert_brainchop.py reference`) to within 5e-6 in
foreground probability, on both the SIMD and the im2col/GEMM backends.

## Updating or adding models

1. Copy the tfjs `model.json` and its shards into a new folder here. Keep it under
   2 MB, or download it on demand in the app and record the URL and SHA-256 here.
2. Run `python3 scripts/models/convert_brainchop.py inspect <folder>/model.json`, then
   add the hashes and provenance to this file.
3. Add a `NeuralModelProfile` that sets normalisation, crop threshold and padding, and
   the foreground classes from the matching `brainchop-parameters.js` entry.

The loader rejects unsupported layers with a clear error: transposed or strided
convolutions, `valid` padding, quantized or float16 weights, and branching graphs.
