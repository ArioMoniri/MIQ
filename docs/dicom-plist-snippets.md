# DICOM plist wiring (applied)

MIQCore can parse DICOM (`MIQFileKind.dicom`, `MIQParser.parse(url:)`), but
Quick Look only hands a file to an extension whose `QLSupportedContentTypes`
lists the file's UTI. These snippets are applied in this repo's plists; they are kept here as the record of why.

## 1. `MIQApp/Info.plist` — imported UTI declaration

Append inside the existing `UTImportedTypeDeclarations` array. It is *imported*
(not exported) because MIQ does not own the format; if another installed app
exports `org.nema.dicom`, that declaration wins and this one is a fallback.

```xml
<dict>
	<key>UTTypeConformsTo</key>
	<array>
		<string>public.data</string>
		<string>public.image</string>
	</array>
	<key>UTTypeDescription</key>
	<string>DICOM Image</string>
	<key>UTTypeIdentifier</key>
	<string>org.nema.dicom</string>
	<key>UTTypeReferenceURL</key>
	<string>https://www.dicomstandard.org/current</string>
	<key>UTTypeTagSpecification</key>
	<dict>
		<key>public.filename-extension</key>
		<array>
			<string>dcm</string>
			<string>dicom</string>
		</array>
		<key>public.mime-type</key>
		<array>
			<string>application/dicom</string>
		</array>
	</dict>
</dict>
```

## 2. `MIQQuickLookExtension/Info.plist` and `MIQThumbnailExtension/Info.plist`

Add to each `QLSupportedContentTypes` array:

```xml
<string>org.nema.dicom</string>
```

## Caveats

- **Extensionless files are not routed.** DICOM exports from PACS/scanners are
  often named `IM000123` or `1.3.12.2...` with no extension. macOS derives the
  UTI from the extension, so those files get `public.data` and Quick Look never
  calls MIQ. Claiming `public.data` in `QLSupportedContentTypes` would hijack
  every unknown file and is not recommended. Users can rename to `.dcm`, or
  open the file in the MIQ app, which can use `MIQFileKind.sniffDICOM(url:)`
  (checks the `DICM` marker at offset 128) when the extension is unknown.
  `MIQParser.parse(url:)` already falls back to that sniff.
- **Series assembly needs sibling access.** `DICOMSeriesAssembler` reads the other
  files in the folder; the Quick Look sandbox usually only grants the previewed
  file, so in the extension it will normally return `nil` (silently) and the
  single-slice/multi-frame preview is shown. It is intended for the app, or for
  an extension with broader read access.
- `.dcm` collisions: some CAD tools also use `.dcm`; the parser rejects non-DICOM
  content with `MIQError.malformedFile("not a DICOM Part-10 file (no DICM marker)")`.
