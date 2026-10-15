# Deploying MIQ in managed environments

Notes for IT administrators who package, distribute or approve MIQ on managed Macs. MIQ is a sandboxed macOS app (`MIQ.app`) that carries two Quick Look extensions: a **preview** extension (Space in Finder) and an optional **thumbnail** extension (Finder icons, off by default).

> [!CAUTION]
> MIQ is **not a medical device** and is not intended for diagnostic use. It is a convenience previewer for researchers and developers.

Settings marked **verify on your fleet** follow documented macOS/Sparkle behaviour but have not been tested by the project against every MDM product. Test them on a pilot group before rolling them out widely.

## Identity and code signing

| Item | Value |
|---|---|
| App bundle ID | `net.marco-duering.miq` |
| Preview extension | `net.marco-duering.miq.extension` |
| Thumbnail extension | `net.marco-duering.miq.thumbnail` |
| App Group (shared settings) | `group.net.marco-duering.miq` |
| Signing | Developer ID Application, notarized by Apple |
| Minimum macOS | 14 (Sonoma) |
| Architectures | Universal (arm64 + x86_64) |

To read the Team ID and the signing authority from an installed copy, for allow-lists, PPPC/system-extension policies or Santa-style rules:

```bash
codesign -dv --verbose=4 /Applications/MIQ.app 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier'
spctl --assess --type execute --verbose /Applications/MIQ.app   # Gatekeeper + notarization check
```

`TeamIdentifier=` is the 10-character Team ID. The extensions inside `MIQ.app/Contents/PlugIns/` are signed with the same Team ID. Copy it from the signature itself; this document does not list it.

## Installing

- **Release zip:** download `MIQ.app.zip` from the [latest release](https://github.com/marcoduering/MIQ/releases/latest), unzip it and place `MIQ.app` in `/Applications`. The zip is self-contained, so it can be mirrored internally and installed offline.
- **Homebrew:** `brew install --cask marcoduering/miq/miq`. Installing by the fully qualified name trusts only this cask, which is what Homebrew's tap-trust model wants.
- **Registering the extensions:** macOS registers the Quick Look extensions when `MIQ.app` is first launched. With MDM-pushed installs, either have users open the app once, or run the following in the user's session after install:

  ```bash
  open -g -j /Applications/MIQ.app   # launch hidden, in the background
  ```

  Users (or a policy) can enable or disable the extensions under **System Settings → General → Login Items & Extensions → Quick Look**. *Verify on your fleet.*

### Offline / air-gapped use

MIQ needs no network access to work. Parsing and rendering happen entirely on the Mac. The only network traffic is the optional update check described below. With updates disabled, or the feed host blocked, the app and extensions work exactly as they do online.

## Updates (Sparkle)

MIQ updates itself with [Sparkle](https://sparkle-project.org). The app (never the extensions) fetches the appcast from `https://miq.marco-duering.net/appcast.xml` and downloads updates from `github.com`. Each update is verified against the EdDSA public key (`SUPublicEDKey`) built into the app before it is installed. Checks only happen while the MIQ app is running, not from the Quick Look extensions.

Automatic checks are **on by default**. This comes from `SUEnableAutomaticChecks = true` in `MIQApp/Info.plist`. Users can turn them off in the app's **General** pane.

### Disabling automatic update checks centrally

If you manage updates yourself (Munki, Jamf, an internal Homebrew mirror…), push a configuration profile that sets Sparkle's user-default keys for the app's preference domain `net.marco-duering.miq`. A managed (forced) preference takes precedence over both the user's choice and the `Info.plist` default.

*Verify on your fleet:* this relies on Sparkle reading its settings through the app's standard `UserDefaults`, which is where managed preferences appear. The project has not tested it under every MDM.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadDisplayName</key>
    <string>MIQ – disable automatic updates</string>
    <key>PayloadIdentifier</key>
    <string>org.example.miq.updates</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-UUID-1</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>net.marco-duering.miq</string>
            <key>PayloadIdentifier</key>
            <string>org.example.miq.updates.sparkle</string>
            <key>PayloadUUID</key>
            <string>REPLACE-WITH-UUID-2</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <!-- Sparkle keys -->
            <key>SUEnableAutomaticChecks</key>
            <false/>
            <key>SUAutomaticallyUpdate</key>
            <false/>
        </dict>
    </array>
</dict>
</plist>
```

Most MDMs also accept the inner dictionary directly as a "Custom Settings" / "Application & Custom Settings" payload for the domain `net.marco-duering.miq`.

To check what the app sees on a test Mac (MIQ is sandboxed, so its own preferences live in its container, while managed values come from `/Library/Managed Preferences`):

```bash
defaults read "/Library/Managed Preferences/net.marco-duering.miq" 2>/dev/null
defaults read ~/Library/Containers/net.marco-duering.miq/Data/Library/Preferences/net.marco-duering.miq 2>/dev/null
```

Notes:

- The profile stops *automatic* checks. **MIQ → Check for Updates…** still lets a user check by hand. To prevent that too, block `miq.marco-duering.net` at your proxy or firewall. The app keeps working without it.
- With automatic checks forced off, the toggle in the app's General pane may still appear switchable but will not persist. *Verify on your fleet.*
- The Homebrew cask is marked `auto_updates`, so `brew upgrade` skips it unless you pass `--greedy`.

## Privacy and data handling

- **No telemetry, analytics or crash reporting.** MIQ contains no analytics SDK and sends no usage data. Its only network requests are the Sparkle update check and download above. Those requests carry the installed MIQ version (and, like any web request, reveal the Mac's IP address to the host). See the [privacy policy](https://miq.marco-duering.net/privacy.html).
- **No record of opened files.** MIQ keeps no history or list of the files it has previewed, writes no caches to disk, and uploads nothing. Previews are rendered in memory inside the sandboxed extension process, and the slice cache is discarded with it. Diagnostic messages that MIQ writes to the macOS unified log do not include file names or paths.
- **Settings** (orientation, windowing, metadata fields…) live in the App Group container `~/Library/Group Containers/group.net.marco-duering.miq/`. They contain rendering preferences only, never file names or image data.
- **No DICOM, no AI.** MIQ reads NIfTI, MGH/MGZ, MRtrix MIF and NRRD only, and has no machine-learning or cloud features.

### macOS thumbnail and Quick Look caches

Independently of MIQ, **macOS caches Quick Look thumbnails** it has generated. If Finder thumbnails are enabled in MIQ (they are off by default), small rendered slice images of viewed files can stay in the system's Quick Look cache (managed by `com.apple.quicklook.ThumbnailsAgent`, in the per-user `$(getconf DARWIN_USER_CACHE_DIR)com.apple.QuickLook.thumbnailcache/`; the exact location may change between macOS releases) after the files themselves have been moved or deleted. This is standard macOS behaviour for every Quick Look generator, not something MIQ writes or controls.

To clear it (per user, no admin rights needed):

```bash
qlmanage -r cache    # reset the Quick Look thumbnail cache
qlmanage -r          # reload Quick Look generators/extensions
```

For sensitive data, you can leave MIQ's thumbnail extension off (the default), or disable it centrally under **Login Items & Extensions → Quick Look**. FileVault protects the cache at rest like everything else in the user's home directory.

## Removing MIQ

```bash
rm -rf /Applications/MIQ.app
rm -rf ~/Library/Containers/net.marco-duering.miq \
       ~/Library/Containers/net.marco-duering.miq.extension \
       ~/Library/Containers/net.marco-duering.miq.thumbnail \
       ~/Library/Group\ Containers/group.net.marco-duering.miq
qlmanage -r && qlmanage -r cache
```

Or, with Homebrew: `brew uninstall --cask miq`. Adding `--zap` also removes whatever leftover paths the cask's `zap` stanza lists.
