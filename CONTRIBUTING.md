# Contributing to MIQ

Thank you for your interest in contributing!

## Project Structure

- `Sources/MIQCore` — pure Swift package, no AppKit/UIKit; consumed by SPM and both extension targets
- `MIQQuickLookExtension` — the Quick Look **preview** target (Space in Finder): preview controller, views, slice cache
- `MIQThumbnailExtension` — the Finder **thumbnail** target: renders the axial centre slice as the file icon. Off by default; shares `MIQImageBridge` and `MIQLogger` with the preview target
- `MIQApp` — SwiftUI host app that installs both extensions and provides the Settings UI (image orientation, intensity windowing, segmentation colouring, axis labels, metadata panel configuration, thumbnails)
- `Config/` — build settings shared across configurations and targets (see below)
- `Sources/miq` — the `miq` command-line tool (`info` / `render` / `mosaic`), built on `MIQCore` only; no third-party dependencies
- `Tests/MIQCoreTests` — Swift Testing coverage for `MIQCore`; `Tests/MIQCLITests` covers the CLI's argument parsing and commands

## Building from Source

### Prerequisites

- macOS 14 or later
- Xcode 16 or later
- An Apple Developer account (free or paid) for code signing

### First-time Setup

Signing credentials are kept out of the repository via a gitignored xcconfig file.

1. Copy the template:

   ```bash
   cp LocalSigning.xcconfig.template LocalSigning.xcconfig
   ```

2. Open `LocalSigning.xcconfig` and fill in your values:
   - `APP_BUNDLE_ID` → a reverse-DNS identifier you own, e.g. `com.yourname.miq`
   - `EXTENSION_BUNDLE_ID` → same prefix with `.extension`, e.g. `com.yourname.miq.extension`
   - `DEVELOPMENT_TEAM` → leave empty for Debug builds; Xcode infers the team from your signed-in Apple ID automatically
   - `APP_GROUP_ID` → already set to `group.$(APP_BUNDLE_ID)` in the template; change only if your App Group is named differently

`LocalSigning.xcconfig` is gitignored and will never appear in commits or pull requests.

It is the only signing file you need to touch. The committed `Config/` xcconfigs hold the build settings shared across configurations and targets — `Shared.xcconfig` (versioning, deployment target, warnings), plus `Debug.xcconfig` and `Release.xcconfig` for the parts that differ. Change a shared setting by editing those files rather than Xcode's Build Settings GUI: the GUI writes into the target's own settings, which shadows the xcconfig instead of updating it. The app version in particular lives in `Config/Shared.xcconfig`, not in the General tab's Version field.

### App Group and Settings

The app and both extensions share settings through an App Group (`group.<your-bundle-id>`). All three targets' entitlements files must declare it. With Automatic signing (the default for Debug builds), Xcode registers the App Group in the Apple Developer Portal automatically the first time you build.

If the App Group is not provisioned — for example, before the first successful Automatic-signing build — an extension still renders correctly but will probably ignore any settings changed in the app and use built-in defaults for everything instead. Or you will get an OS-level error message about external access.

Declaring the entitlement is not sufficient on its own: it must also be *authorized by the provisioning profile embedded at build time*, or the sandbox drops it silently — no error, no crash, just built-in defaults. `codesign --verify` does not catch this. To check which entitlements a built extension was actually granted:

```bash
security cms -D -i <path>/MIQThumbnailExtension.appex/Contents/embedded.provisionprofile \
  | plutil -extract Entitlements xml1 -o - - | grep -A3 application-groups
```

(Extract `Entitlements` and grep — `plutil` splits a key path on dots, so it cannot address the dotted `com.apple.security.application-groups` key directly.)

This is the practical difference between Debug and Release builds here. The **thumbnail** extension in particular needs a profile that authorizes the App Group for the `.thumbnail` App ID, which Automatic signing does not produce — so in a Debug build the thumbnail extension falls back to built-in defaults and ignores the Thumbnails settings pane. The preview extension is unaffected. Build Release if you are working on thumbnail settings.

### Build and Run

```bash
# Install both extensions and refresh Quick Look services (recommended during
# development). Builds Release with the project's signing configuration.
./scripts/build.sh

# Debug build — use this if you don't have a Developer ID certificate. The
# thumbnail extension will ignore its settings (see App Group and Settings above).
./scripts/build.sh --debug

# Or build directly with xcodebuild
xcodebuild -project MIQ.xcodeproj -scheme MIQ -configuration Debug \
  -destination 'generic/platform=macOS' build
```

`build.sh` also unregisters every other `MIQ.app` LaunchServices knows about before registering this build. Stray copies — an extracted release zip, archive intermediates, a sibling Debug/Release build — otherwise compete for the same bundle ID and `quicklookd` may load the wrong extension.

Then open a supported file in Finder and press **Space**.

### Run Tests

```bash
swift test --package-path .
```

#### Without a Mac (Linux)

`MIQCore`, the `miq` command-line tool and their tests also build on Linux. Apple-only bits (`os.log`, the BSD I/O-policy and `statfs` calls) are swapped for small shims in a scratch copy, and your checkout is not modified. With a Swift 6.x toolchain, `zlib1g-dev` and `python3` installed:

```bash
scripts/ci/linux_core_tests.sh                          # build + run all core tests
scripts/ci/linux_core_tests.sh --filter PNGEncoderTests  # extra args go to `swift test`
```

The harness skips `PerformanceBaselineTests` (it uses Apple's Compression framework) and treats every volume as local disk. Anything touching AppKit, Quick Look or the app still needs a Mac.

#### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

- **core-tests**: `swift test` on macOS
- **xcode-build**: an unsigned Debug `xcodebuild` of the app and both extensions. It copies `LocalSigning.xcconfig.template` to `LocalSigning.xcconfig` first.
- **linux-core**: `scripts/ci/linux_core_tests.sh` in a `swift:6.2` container
- **plist-consistency**: `scripts/check_plists.py`. It checks that every Info.plist parses and that the UTIs the extensions claim match the ones the app declares.
- **performance**: opt-in `MIQ_PERF=1` baselines. This job is informational and never blocks a merge.

## Performance Notes

These design decisions affect the render path — keep them in mind when working on parsing or preview code:

- Uncompressed files (`.nii`, `.mgh`, `.mif`) on a local disk are memory-mapped; the payload is never copied.
- Slice extraction computes only the requested planes — no full volume resampling.
- Each slice is downsampled to a maximum of 512 px on the long side before display.
- A cold `.nii.gz` preview decompresses only the header plus volume 0; stepping past volume 0 re-parses once in the background. Other compressed formats can't be bounded that way and decompress in full.
- Files on network volumes take a separate path: NIfTI reads only the volume-0 prefix off the mount, and other formats use a cancelable, I/O-throttled chunked read so a dismissed preview stops pulling bytes instead of stalling Finder.
- Parsing, slicing and pixel work all run off the MainActor; only the final `NSImage` wrapping happens on it.
- Parsers are implemented from scratch in Swift, without third-party dependencies or bindings to C/C++ libraries.

`Tests/MIQCoreTests/PerformanceBaselineTests.swift` is the yardstick for any change to parsing, slicing, windowing, or decompression — measure against it rather than asserting a speedup. It is skipped in a normal run; opt in with `MIQ_PERF=1` and a `-c release` build.

> Please note that Debug builds are not optimized for performance and are much slower. Test performance only with Release builds.

## Submitting Changes

- Open an issue first for anything beyond small bug fixes.
- Keep pull requests focused — one concern per PR.
- Run `swift test` before submitting.
- Use `MIQ`-prefixed names for product-level types, concise domain names for generic imaging concepts (`GrayscaleImage`, `SlicePlane`), and descriptive names for internal helpers.
- Adding a file format takes four wirings, not just a parser: the `MIQFileKind` case and parser, plus the new UTI in `MIQApp/Info.plist`, `MIQQuickLookExtension/Info.plist`, and `MIQThumbnailExtension/Info.plist`. Miss one of the plists and Finder never routes the file to that extension, so your parser is never called. Also add the UTI to `CFBundleDocumentTypes` (Finder "Open With") and give the kind a `badgeLabel`. Launch Services matches only the last extension, so a two-part extension such as `.nii.gz` resolves to the system gzip type: tag only single extensions, and let gzip-wrapped formats arrive via the extensions' gzip claims plus the `MIQFileKind` filename check. `python3 scripts/check_plists.py` (also run in CI) catches a missing or mismatched entry. `MIQParser+NRRD.swift` is the most recent worked example.

## Releasing (maintainers only)

Notarized release builds require a Developer ID Application certificate (paid Apple Developer Program membership) and the `scripts/release_notarize.sh` script.
