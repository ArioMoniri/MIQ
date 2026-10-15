# Spotlight importer and App Intents

MIQ adds two features beyond Quick Look. Both read only the file header and work offline.

- **Spotlight importer** (`MIQSpotlightImporter.mdimporter`). Indexes dimensions, voxel spacing, datatype, number of volumes and orientation for every NIfTI, MGH/MGZ, MIF and NRRD file, so you can search for them and see the values in Finder's Get Info.
- **App Intents** (in the MIQ app). Adds **Get Volume Info** and **Render Center Slice** actions to Shortcuts and Spotlight.

Both use `VolumeSummary` (`Sources/MIQCore/VolumeSummary.swift`) for header-only parsing, the same code as `miq info`. Their numbers always match.

## What gets indexed

| Attribute | Type | Example | Source |
|---|---|---|---|
| `kMDItemKind` | string | `Compressed NIfTI-1` | format label, as in the preview's Format row |
| `kMDItemPixelWidth` / `kMDItemPixelHeight` | number | `256` / `256` | x / y dimension |
| `org_miq_dimensions` | number list | `256, 256, 128` | spatial dimensions x, y, z |
| `org_miq_voxelSpacing` | number list | `1, 1, 1.2` | voxel size x, y, z (absolute values) |
| `org_miq_spacingUnit` | string | `mm` | NIfTI `xyzt_units`; always `mm` for MGH/MIF; left out when unknown (always the case for NRRD) |
| `org_miq_datatype` | string | `int16` | datatype label (MIF `bit` stays `bit`) |
| `org_miq_volumes` | number | `1` | 4th dimension; `1` for 3D |
| `org_miq_orientation` | string | `RAS` | 3-letter storage orientation code; left out when the header has none |

**No free-text header fields are indexed.** That includes NIfTI `descrip`/`aux_file`/`intent_name`, MIF comments and `command_history`, and NRRD `content`. These fields can contain patient identifiers, and any process can query the Spotlight index.

**Header-only.** The importer never reads the voxel data.
- Uncompressed files: it reads at most a few 16 KB chunks.
- `.nii.gz`, `.mgz` and `.mif.gz`: it decompresses only until the header is complete.
- MIF and NRRD text headers: capped at 4 MB.

## Example queries

```bash
mdfind 'org_miq_volumes > 1'                               # every 4D volume
mdfind 'org_miq_orientation == "LAS"'                      # radiological storage order
mdfind 'org_miq_datatype == "float32" && org_miq_dimensions == 256'
mdfind -onlyin ~/data 'kMDItemKind == "Compressed NIfTI-1"'
```

In the Finder search bar, use **Kind → Other…** and look for the "Volume Dimensions", "Voxel Spacing", … attributes (display names come from `en.lproj/schema.strings`).

## How it is built

- **Why `.mdimporter` instead of `CSImportExtension`:** on macOS, `CSImportExtension` app extensions are accepted but index nothing (Apple DTS). The legacy CFPlugIn bundle is still the mechanism that works.
- **Target:** `MIQSpotlightImporter`, product type `com.apple.product-type.bundle` with `WRAPPER_EXTENSION = mdimporter`.
- **Embedding:** the app target's **Embed Spotlight Importer** Copy Files phase (Wrapper, `Contents/Library/Spotlight`, code-sign on copy) puts it at `MIQ.app/Contents/Library/Spotlight/MIQSpotlightImporter.mdimporter`. LaunchServices registers importers found there when it registers the app.
- **`main.c`:** COM-style factory (`MIQImporterPluginFactory`, factory UUID `14059883-C04B-47A0-B570-4FC07264A531`). It answers both `kMDImporterURLInterfaceID` (`ImporterImportURLData`) and `kMDImporterInterfaceID` (`ImporterImportData`, path-based). Both call the Swift entry point.
- **`MIQSpotlightImporter.swift`:** the `@_cdecl("MIQImporterImportURL")` entry point, plus the pure `MIQSpotlightAttributes` table. Links the MIQCore Swift package statically, like the extensions do.
- **`Info.plist`:** `CFPlugInFactories`/`CFPlugInTypes` and `CFBundleDocumentTypes` (role `MDImporter`). `LSItemContentTypes` matches the thumbnail extension's list: the MIQ UTIs plus `gov.nih.nifti-1`, `public.gzip` and `org.gnu.gnu-zip-archive`, since macOS often resolves `.nii.gz` to the generic gzip type. For an unrelated `.gz`, the extension check fails before any I/O and the importer returns `false`.
- **`schema.xml` / `en.lproj/schema.strings`:** declare the `org_miq_*` attributes and their display names.
- **Signing:** the importer has no entitlements and no provisioning profile. It runs inside `mdworker`'s own sandbox. Hardened runtime and Developer ID signing come from `Config/*.xcconfig`, the same as the other targets.

The UTI identifiers are the ones in `MIQApp/Info.plist` at the time of writing. If those identifiers change, update `MIQSpotlightImporter/Info.plist`, `schema.xml` and `MIQApp/Intents/IntentSupport.swift` to match.

## Testing the importer

Build and install MIQ.app once (`./scripts/build.sh`), then open it so LaunchServices registers it. After that:

```bash
# Is the importer registered? (Look for MIQSpotlightImporter.mdimporter.)
mdimport -L 2>&1 | grep -i miq

# Dry-run import of one file with debug output. Prints the attribute dictionary
# without touching the index. "with no plugIn" means the importer did not load
# or does not claim the file's UTI (check `mdls -name kMDItemContentType file`).
mdimport -t -d3 /path/to/file.nii.gz

# Real (re)import of a file or a folder, then read the stored attributes back.
mdimport /path/to/file.nii.gz
mdls -name kMDItemKind -name org_miq_dimensions -name org_miq_voxelSpacing \
     -name org_miq_datatype -name org_miq_volumes -name org_miq_orientation \
     /path/to/file.nii.gz

# Re-index everything the importer claims, e.g. after changing schema.xml.
mdimport -r /Applications/MIQ.app/Contents/Library/Spotlight/MIQSpotlightImporter.mdimporter
```

If a rebuilt importer does not seem to take effect, do the following:
- Kill the Spotlight workers: `sudo killall mdworker mdworker_shared`.
- Re-register the app: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MIQ.app`.
- Make sure there is only one copy of MIQ.app on disk. Spotlight may pick the importer from another copy, such as one in DerivedData.

## Testing the App Intents

1. Open the Shortcuts app. MIQ's actions are under **Apps → MIQ**: **Get Volume Info** and **Render Center Slice**. They need macOS 15 or later.
2. **Get Volume Info** takes a file and an output format (Text or JSON). It returns the summary as text, or as JSON for **Get Dictionary from Input**.
3. **Render Center Slice** takes a file and a plane (Axial/Coronal/Sagittal). It returns a PNG named `<file>_<plane>.png`.
4. Rendering uses the Quick Look preview's Settings: intensity window percentiles, image orientation and segmentation colouring. No labels or crosshair are drawn.
5. In Spotlight on macOS 26, type "Volume Info" or "Render Center Slice" to run the App Shortcuts directly.

Both intents are read-only. They never write next to the source file and never use the network. A file passed as data rather than as a URL (some share-sheet paths) goes to a private temporary directory, which is deleted afterwards.

## Limitations and unverified points

These parts could only be checked on Linux. They have not been run on a Mac.

- **Unverified on macOS 26/27.** Nobody has run the importer or the intents on real hardware yet, including whether `mdworker` loads a Developer ID–signed, hardened-runtime importer whose Swift code links MIQCore statically.
  - Checked: the C glue (syntax, plus the COM refcount/QueryInterface logic against stub CoreFoundation headers, under ASan) and the Swift attribute table (compiled and run against MIQCore on Linux).
  - Not compiled anywhere: the `@_cdecl` entry point and everything that needs the macOS SDK (CoreServices, AppIntents, ImageIO).
- **Sandbox.** `mdworker` runs importers in its own sandbox, which grants read access to the file being imported. The importer needs no more than that.
- **App Intents** run in the MIQ app's sandbox. Shortcuts hands over security-scoped URLs, so files the user selects are readable.
- **NRRD detached headers (`.nhdr`)** are not supported (same as the preview). `.nrrd` reports no spacing unit, because MIQCore does not parse `space units`.
- **4D `.nii.gz`:** the volume count comes from the header. The importer never checks that every volume is actually present.
- **macOS 14:** no intents. `@Parameter(supportedContentTypes:)` for `IntentFile` is only available from macOS 15 in the current SDK. The Spotlight importer does work on macOS 14.
- **Spotlight does not index network volumes** by default, so files on SMB/NFS shares get no attributes.
