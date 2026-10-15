# Zarr (OME-Zarr / NIfTI-Zarr) — Info.plist snippets

MIQCore previews Zarr directory stores (`MIQFileKind.zarr`, detected by the
`.zarr` / `.ome.zarr` / `.nii.zarr` directory suffix; `MIQParser.parse(url:)`
dispatches to `parseZarr(url:)`). Quick Look only hands a *directory* to a
preview extension when the directory's UTI is a **package**, so the plists need
the declarations below (now applied in this repo's plists).

## 1. `MIQApp/Info.plist` — declare the type

Add to the existing `UTImportedTypeDeclarations` array (imported, not
exported: MIQ doesn't own the format; another app may declare the same UTI):

```xml
<dict>
    <key>UTTypeConformsTo</key>
    <array>
        <string>com.apple.package</string>
        <string>public.directory</string>
    </array>
    <key>UTTypeDescription</key>
    <string>Zarr Image Store</string>
    <key>UTTypeIdentifier</key>
    <string>dev.zarr.zarr</string>
    <key>UTTypeTagSpecification</key>
    <dict>
        <key>public.filename-extension</key>
        <array>
            <!-- covers .ome.zarr and .nii.zarr too: the path extension is "zarr" -->
            <string>zarr</string>
        </array>
    </dict>
</dict>
```

If the app lists document types for "Open With", add a matching
`CFBundleDocumentTypes` entry with `LSItemContentTypes = [dev.zarr.zarr]`,
`CFBundleTypeRole = Viewer`, `LSHandlerRank = Alternate` and
`LSTypeIsPackage = true`.

## 2. `MIQQuickLookExtension/Info.plist` and `MIQThumbnailExtension/Info.plist`

Add to `NSExtensionAttributes > QLSupportedContentTypes`:

```xml
<string>dev.zarr.zarr</string>
```

The preview extension must keep `QLIsDataBasedPreview` false/absent (it is a
view-based preview that receives a URL) — a data-based preview cannot be handed
a directory.

## Caveat: existing `.zarr` folders become opaque packages in Finder

Declaring the UTI as conforming to `com.apple.package` makes Finder show every
`*.zarr` directory as a single file-like item once MIQ is installed (Launch
Services applies it system-wide). Double-clicking no longer opens the folder,
and users who browse stores in Finder will need **right-click → Show Package
Contents** to see inside. Terminal, `open -R`, Python/napari and other tools are
unaffected (it is only a Finder presentation flag), but it is a visible behaviour
change worth a release-notes line, and possibly an opt-out note in the README.
Without the package conformance, Quick Look never asks MIQ for the folder, so
there is no way to get Zarr previews without this trade-off.

## Network volumes

`MIQFileKind.zarr.supportsBoundedNetworkRead` is `true` (only the coarsest
level's chunks are read), and the directory's `fileSizeKey` is meaningless for
a store, so size-based network deferral/thumbnail gates won't trigger for
`.zarr` — intended, since the read is already bounded by
`MIQParser.zarrMaxPreviewBytes` (512 MiB).
