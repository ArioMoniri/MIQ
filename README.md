# MIQ: Medical Image Quick Look

MIQ is a lightweight **macOS QuickLook extension** for medical volume images. Press **Space** on a supported file in Finder to instantly get an **interactive orthogonal slice view** alongside a metadata panel. A Windows counterpart, [**MIQ-Win**](https://github.com/marcoduering/MIQ-Win), is also available.

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento.webp" width="90%" alt="Bento-style feature grid for MIQ: press Space in Finder for an interactive Quick Look preview; supports NIfTI, FreeSurfer, MRtrix and NRRD formats; the center tile shows a brain MRI in a coronal/sagittal/axial 2x2 grid with a metadata panel listing format NIfTI-1, dimensions 211 x 215 x 175, spacing 1.00 mm isotropic, orientation RAS, datatype int16 and 1 volume; other tiles show FreeSurfer LUT segmentation coloring, color label files, Finder thumbnails, 4D file support, full configurability, and availability on macOS and Windows.">
  </picture>
</div>

**See it in action** in the short video at the bottom of this page.

## Main Features and Supported Formats

- **Instant, interactive preview** — press Space for the 2×2 orthogonal slice and metadata view
- **Built for speed** — memory-mapping, partial decompression, and network volumes read only what's needed for the first preview
- **4D support** — scrub through timepoints/volumes interactively
- **Segmentation coloring** — including automatic label-color detection for FreeSurfer-style parcellations
- **Finder thumbnails** — optional file-icon slice previews while browsing
- **Fully configurable** — orientation display, intensity windowing, label colors, and metadata panel content/order, all from the main app

Supported formats:

- :white_check_mark: **NIfTI-1 & NIfTI-2** — `.nii`, `.nii.gz`
- :white_check_mark: **FreeSurfer** — `.mgh`, `.mgz`, `.mgh.gz`
- :white_check_mark: **MRtrix** — `.mif`, `.mif.gz`, `.mih` *(detached header + data file)*
- :white_check_mark: **NRRD** — `.nrrd`, `.nhdr` *(detached header: single data file, `LIST`, or printf-style `slice%03d.raw` multi-file)*
- :white_check_mark: **MetaImage (ITK)** — `.mha`, `.mhd` *(detached header + `.raw`/`.zraw`)*

All formats are supported uncompressed and gzip-compressed (MetaImage: zlib `CompressedData`).

Detached headers (`.nhdr`, `.mih`, `.mhd`) only read data files in the header's own folder or a subfolder; a data file referenced by an absolute path elsewhere, via `..`, or through a symlink leading out of that folder is refused.

## Installation & Updates

The app and extension can be installed manually or via the package manager [Homebrew](https://brew.sh).

> The app is a universal binary for Apple Silicon (arm64) and Intel (x86_64) Macs and has been tested on macOS 14 (Sonoma), 15 (Sequoia), 26 (Tahoe) and 27 (Golden Gate).

### Manual installation

1. 👉 **[Download the latest release (MIQ.app.zip)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)**
[![Latest Release](https://img.shields.io/github/v/release/marcoduering/MIQ)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)
2. Unzip and move **`MIQ.app`** to your **`/Applications`** folder.
3. **Open `MIQ.app`** at least once to register the Quick Look extension.
4. Press **Space** on any supported file in Finder.
5. Optional: **Customize the preview** in the MIQ app.

#### Updating

MIQ updates itself. Open the MIQ app and choose MIQ → Check for Updates…, or leave **Check for updates automatically** enabled in the app's **General** pane (on by default).

Automatic checks and updates happen when you open the main app, so make sure to do this from time to time.

### Installation via Homebrew

1. Install on the command line:

   ```bash
   brew tap marcoduering/miq
   brew trust --cask marcoduering/miq/miq
   brew install --cask miq
   ```

2. **Open `MIQ.app`** (in `/Applications`) at least once to register the Quick Look extension.
3. Press **Space** on any supported file in Finder.
4. Optional: **Customize the preview** in the MIQ app.

#### Updating via Homebrew

The cask is marked `auto_updates`, so the app updates itself (see above). To update through Homebrew instead:

```bash
brew update
brew upgrade --cask miq --greedy
```

## Usage

MIQ is a lightweight convenience tool for quickly inspecting medical image files directly from the Finder. It prioritizes speed and ease of use over advanced visualization, and is not meant to replace dedicated medical image viewers.

### Customization

Use the MIQ app to tailor the preview, metadata panel and thumbnails. Live examples show the effect of each setting as you change it. The **Controls** pane lists all gestures for the interactive preview.

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings1_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings1.webp" width="32%" alt="MIQ settings, Preview pane: orientation, segmentation colours, axis label and crosshair colour, and intensity window controls beside a live example of the rendered preview.">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings2_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings2.webp" width="32%" alt="MIQ settings, Metadata pane: a reorderable list of metadata fields, each with an on/off toggle, beside a live example of the metadata panel.">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings3_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings3.webp" width="32%" alt="MIQ settings, Thumbnails pane: a toggle for Finder slice thumbnails with orientation, segmentation colour and intensity window controls, beside a live example of the Finder icons.">
  </picture>
</div>

### Orientation

By default, MIQ displays data **as stored on disk**, without reorienting. Images may appear upside down, mirrored, or rotated depending on acquisition. This is by design, so you can inspect the raw data "as is". Optional settings reorient to **Neurological** or **Radiological view**.

### Command-line tool (`miq`)

The same parsers and renderer are available as a small command-line tool, handy for scripts, headless machines and bug reports. It is not part of the app download (yet). Build it from a checkout with Swift 6 on macOS or Linux:

```bash
swift build -c release --product miq     # binary: .build/release/miq
```

```bash
miq info sub-01_T1w.nii.gz               # format, dimensions, spacing, datatype, volumes, orientation, scaling
miq info --json sub-01_T1w.nii.gz        # same, machine-readable
miq info --include-phi sub-01_T1w.nii.gz # also print free-text fields (descrip, command history)
miq render sub-01_T1w.nii.gz --plane coronal --slice 120 -o coronal.png
miq render bold.nii.gz --volume 10 --window 0,1500 -o vol10.png
miq mosaic aparc+aseg.mgz -o overview.png  # the preview's 2×2 layout as one PNG
```

`info` leaves out free-text header fields that can carry identifying details (NIfTI `descrip`/`intent_name`, MIF `command_history`), matching the preview's defaults; pass `--include-phi` to print them. `render` and `mosaic` also accept `--orientation stored|neurological|radiological`, `--segmentation auto|off|random` and `--max-size N`. Run `miq help <command>` for details. PNGs are written by a built-in encoder and contain pixels only, with no text or metadata chunks.

## Privacy

MIQ runs entirely on your Mac. It has **no telemetry, analytics or crash reporting**, keeps no history of the files you preview, and never uploads image data. The only network access is the optional update check (see [Updating](#updating)). Details: [privacy policy](https://miq.marco-duering.net/privacy.html). IT administrators: see [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md) for signing, update control and offline deployment.

## Troubleshooting

### `.gz` File Handling

macOS Quick Look routes files to extensions by file name suffix. Several kinds of tools, including archive utilities, source-code viewers, and format-specific extensions like MIQ, need to claim the broad `.gz` suffix to support compound extensions such as `.nii.gz`/`.mif.gz`. When more than one installed extension claims `.gz`, which one macOS shows isn't always consistent; this is general Quick Look behavior, not specific to MIQ. If a gzip-compressed file isn't opening with MIQ's preview, try deactivating other `.gz`-handling extensions.

### Detached headers (`.nhdr`, `.mih`, `.mhd`)

A detached header keeps the voxel data in a separate file next to it. macOS sandboxes Quick Look extensions and normally grants them access only to the file being previewed, so the preview may show *"Detached data file '…' couldn't be read from Quick Look (sandbox)"* even though the data file is right there. The same restriction can apply when the file is shown from MIQ.app via **Open With**. If you hit it, use the attached variant of the format — `.nrrd` instead of `.nhdr`, `.mif` instead of `.mih`, `.mha` instead of `.mhd` (e.g. `unu save -f nrrd`, `mrconvert in.mih out.mif`, or re-saving from ITK/3D Slicer). Finder thumbnails hit the same limit and fall back to the system icon; Spotlight metadata only needs the header, so it is indexed either way.

## Active Development

MIQ is free and open source, in active development, and was created with the support of AI coding agents. Report issues or feature suggestions via [**GitHub Issues**](https://github.com/marcoduering/MIQ/issues), or see [CONTRIBUTING.md](./CONTRIBUTING.md) to contribute. If MIQ is useful to you, consider [**sponsoring the project**](https://github.com/sponsors/marcoduering) (entirely optional, always appreciated).

## Disclaimer & License

MIQ is provided "as is" under [MIT License](./LICENSE), without warranty of any kind, express or implied. The authors and contributors accept no liability whatsoever for any direct, indirect, incidental, special, or consequential damages arising from the use or inability to use this software, including but not limited to data loss, incorrect image rendering, or any decisions made on the basis of previews generated by this tool.

> [!CAUTION]
> This software is **<ins>not</ins> a medical device and is <ins>not</ins> intended for diagnostic use**. It is a developer and researcher convenience tool only. Do not use it to make clinical decisions.

**Scope by design:** MIQ deliberately does **not** read DICOM and contains **no AI/ML features**. It is a fast previewer for research volume formats (NIfTI, MGH/MGZ, MIF, NRRD, MetaImage), not a clinical viewer or an analysis tool.

## See it in action

<div align="center">
  <video src="https://github.com/user-attachments/assets/3058f94e-4ffa-4c0a-a1b8-d1578de0f651" width="600"></video>
</div>
