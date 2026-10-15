# MIQ: Medical Image Quick Look

MIQ lets you look inside medical image files straight from Finder. Select a file, press **Space**, and you get coronal, sagittal and axial slices next to the key header information. A Windows version, [**MIQ-Win**](https://github.com/marcoduering/MIQ-Win), is also available.

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento.webp" width="90%" alt="MIQ overview: press Space in Finder for a 2x2 preview of a brain MRI (coronal, sagittal, axial) with a metadata panel; also segmentation colours, Finder thumbnails, 4D support and settings.">
  </picture>
</div>

MIQ is meant for a quick look, not for analysis. For anything more, open the file in a full viewer (MIQ can hand it over, see below).

## What it does

- **Preview:** three orthogonal slices with a linked crosshair and the voxel value under it. Scroll through slices, step through 4D volumes, zoom, and adjust brightness and contrast.
- **Header info:** dimensions, voxel size, orientation, datatype and more. MIQ warns if a file's orientation is ambiguous (for example when qform and sform disagree).
- **Segmentations:** FreeSurfer-style label maps get their usual colours, and hovering shows the label name (e.g. `17 Left-Hippocampus`).
- **Extras when you need them:** CT window presets, MIP/MinIP, a simple 3D view, colour maps, overlays from the same folder, and a few data-quality hints (likely sequence, head mask, defaced or not).
- **Finder thumbnails** (optional).

In the MIQ app you can change all settings, open a file in another viewer, and make a brain mask with **Tools → Brain Mask…** (a small model that runs on your Mac). A `miq` command-line tool covers the same formats.

## Supported formats

| Format | Extensions |
|---|---|
| NIfTI-1 / NIfTI-2 | `.nii`, `.nii.gz` |
| FreeSurfer | `.mgh`, `.mgz` |
| MRtrix | `.mif`, `.mif.gz`, `.mih` |
| NRRD | `.nrrd`, `.nhdr` |
| MetaImage (ITK) | `.mha`, `.mhd` |
| DICOM | `.dcm` (uncompressed only) |
| OME-Zarr / NIfTI-Zarr | `.zarr` (shows the lowest-resolution level) |

## Install

> Universal app for Apple Silicon and Intel. Tested on macOS 14, 15, 26 and 27.

**Download:** get [MIQ.app.zip](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip) [![Latest Release](https://img.shields.io/github/v/release/marcoduering/MIQ)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip), unzip it, move `MIQ.app` to `/Applications` and open it once. That registers the Quick Look extension.

**Homebrew:**

```bash
brew tap marcoduering/miq
brew trust --cask marcoduering/miq/miq
brew install --cask miq
```

Then open `MIQ.app` once.

**Updates:** MIQ checks for updates when you open the app (MIQ → Check for Updates…). Homebrew users can also run `brew upgrade --cask miq --greedy`.

## Using it

Click a slice first so the preview gets keyboard input. The app's **Controls** pane has the full list.

| Do this | To |
|---|---|
| Click or drag | Move the crosshair |
| Scroll | Go through slices |
| ⌥ + scroll | Go through volumes (4D) |
| Right-click + drag | Brightness / contrast |
| Pinch or ⌘ + scroll | Zoom |
| Double-click | Enlarge one panel |
| Right-click | Presets, colour maps, overlays, copy image |
| `P` | Switch the fourth panel: info → MIP → MinIP → 3D |
| `1`–`6`, `A` | CT presets, automatic window |
| `⌘C` | Copy the view as an image |

**Orientation:** by default MIQ shows the data the way it is stored in the file, so images can look flipped or rotated. The letters at the edges (R/L, A/P, S/I) tell you the real directions. You can switch to neurological or radiological view in the app.

### Command line

```bash
swift build -c release --product miq
miq info scan.nii.gz
miq render scan.nii.gz --plane coronal -o coronal.png
miq mosaic aseg.mgz -o overview.png
```

`miq help` lists all options.

## Privacy

Everything runs on your Mac. There is no telemetry, and file names never appear in the system log. Header fields that may contain names or IDs (like NIfTI `descrip`) are hidden unless you turn them on. The only network access is the update check, plus a local server if you turn on the optional *Describe file* feature. More in the [privacy policy](https://miq.marco-duering.net/privacy.html); IT admins see [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md).

## Troubleshooting

**A `.nii.gz` file opens in another app's preview.** Several Quick Look extensions claim `.gz`. Turning off the other ones usually fixes it.

**"Detached data file couldn't be read".** For `.nhdr`, `.mih` and `.mhd`, the image data sits in a second file, and macOS only lets Quick Look read the file you selected. Convert to the single-file version (`.nrrd`, `.mif` or `.mha`) to preview it.

## Contributing

Bug reports and ideas are welcome in [Issues](https://github.com/marcoduering/MIQ/issues); see [CONTRIBUTING.md](./CONTRIBUTING.md) for code. MIQ was built with help from AI coding agents. If it is useful to you, you can [sponsor the project](https://github.com/sponsors/marcoduering).

## License and disclaimer

MIT License, provided "as is" without warranty. See [LICENSE](./LICENSE).

> [!CAUTION]
> MIQ is **not a medical device** and is **not for diagnosis**. It is a convenience tool for researchers and developers. Do not use it to make clinical decisions.

## See it in action

<div align="center">
  <video src="https://github.com/user-attachments/assets/3058f94e-4ffa-4c0a-a1b8-d1578de0f651" width="600"></video>
</div>
