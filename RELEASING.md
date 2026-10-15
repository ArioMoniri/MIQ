# Releasing MIQ

Maintainer-only. This is the running order. The rationale for the Sparkle and Homebrew rules is kept in the maintainer's notes; the steps below are complete without them.

## One-time setup

- Developer ID Application certificate, plus the `MIQ_Provisioning`, `MIQ_Extension_Provisioning` and `MIQ_Thumbnails_Provisioning` profiles.
- A notarytool profile: `xcrun notarytool store-credentials "<profile>" --apple-id <email> --team-id <id> --password <app-specific>`.
- `gh` authenticated (`gh auth login`).
- Sparkle's private EdDSA key in the login keychain, account `ed25519`. **Unrecoverable**: lose it and no installed copy can ever update again. Keep an offline export (`generate_keys -x <file>`).
- A checkout of the tap `github.com/marcoduering/homebrew-miq`. Never edit the clone under `/opt/homebrew/Library/Taps/`, which `brew update` resets.

## Release

1. **Bump** `MARKETING_VERSION` in `Config/Shared.xcconfig`, never in Xcode's General tab. Sparkle compares `CFBundleVersion`, which follows it. No bump means no update is ever offered.
2. **Test.** `cd /tmp && swift test --package-path /path/to/MIQ --scratch-path /tmp/miq-build`
3. **Commit and tag** with a clean tree and `Package.resolved` committed: `git tag vX.Y.Z && git push origin main vX.Y.Z`
4. **Notarize.** `NOTARY_PROFILE=<profile> ./scripts/release_notarize.sh` produces `build/release-<timestamp>/MIQ.app.zip`. It fails on a bad Sparkle signature, missing mach-lookup entitlements, an unauthorized App Group, a non-production feed URL, or an unbumped version.
5. **GitHub release.** `./scripts/release_github.sh` creates a draft. Write the notes and publish it. The asset must stay named `MIQ.app.zip`. Keep the printed sha256 for step 7. The notes are not just for the web page: step 6 pulls this body into the appcast and refuses to run while the body is empty or still the seeded template.
6. **Appcast.** `./scripts/release_appcast.sh`, then `git add docs/appcast.xml && git commit -m "Appcast X.Y.Z" && git push`. Never push the feed while the release is still a draft; the script checks and warns. Confirm with `curl -fsSL https://miq.marco-duering.net/appcast.xml | grep -c "<item>"`.
7. **Cask.** In the tap checkout set `version` and `sha256` in `Casks/miq.rb`, then audit by name against the installed tap clone and restore it:
   ```bash
   TAP=/opt/homebrew/Library/Taps/marcoduering/homebrew-miq
   cp Casks/miq.rb "$TAP/Casks/miq.rb"
   brew audit --cask --strict marcoduering/miq/miq
   git -C "$TAP" checkout -- Casks/miq.rb
   ```
8. **CLI (optional).** See [CLI (Homebrew formula and universal binary)](#cli-homebrew-formula-and-universal-binary).
9. **Verify.** Install the previous release, open it, choose **MIQ → Check for Updates…**, and confirm it installs and relaunches. Then press Space on a `.nii.gz` in Finder.

## CLI (Homebrew formula and universal binary)

The `miq` command-line tool isn't part of `MIQ.app`. It ships two ways, both optional per release:

- **Universal binary on the GitHub release.** Pass `--with-cli` in step 5: `./scripts/release_github.sh --with-cli`. The script builds `swift build -c release --product miq` for arm64 and x86_64, merges them with `lipo`, checks that `miq --help` runs, and attaches `miq-vX.Y.Z-macos-universal.tar.gz`. Set `MIQ_CLI_SIGN_IDENTITY` to your Developer ID Application identity to sign it with the hardened runtime, and add `NOTARY_PROFILE` to notarize it as well. Without an identity it is only ad-hoc signed, and a copy downloaded with a browser is quarantined, so say so in the release notes.
- **Homebrew formula.** `packaging/homebrew/miq.rb` builds the CLI from the tag's source tarball. Per release:
  1. Set `url` to the new tag and `sha256` to the output of `curl -fsSL https://github.com/marcoduering/MIQ/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`. `release_github.sh` prints this command. Commit the change here.
  2. Copy it to `Formula/miq.rb` in the tap checkout. The tap also has the `miq` cask, so audit and test it as a formula:
     ```bash
     TAP=/opt/homebrew/Library/Taps/marcoduering/homebrew-miq
     mkdir -p "$TAP/Formula" && cp packaging/homebrew/miq.rb "$TAP/Formula/miq.rb"
     brew audit --formula --strict marcoduering/miq/miq
     brew install --formula --build-from-source marcoduering/miq/miq && brew test marcoduering/miq/miq
     git -C "$TAP" checkout -- Formula/miq.rb 2>/dev/null || rm "$TAP/Formula/miq.rb"
     ```
  3. Commit and push `Formula/miq.rb` in the tap checkout. Users install it with `brew install --formula marcoduering/miq/miq`.

Nothing in this repository updates the tap automatically. Until step 3 is done for a release, the tap still serves the previous formula, or none at all.

## First Sparkle release (1.4.0 only)

- Installs older than 1.4.0 have no Sparkle. Those users update manually one last time.
- `docs/appcast.xml` does not exist yet, so **Check for Updates…** errors until step 6 is pushed. Do that before announcing.
- The 1.4.0 cask commit is the one that adds `auto_updates true`. Never push that stanza earlier.

## When it breaks

- **Downloads, then installs nothing.** Missing mach-lookup entitlements, missing `SUEnableInstallerLauncherService`, or unsigned nested Sparkle code. Step 4 catches all three.
- **Says you are up to date.** `CFBundleVersion` did not increase. Cut a new version; feed items cannot be edited into existence.
- **Signature mismatch on download.** The appcast was signed with a key that is not `SUPublicEDKey`.
- **Bad appcast.** It is plain XML in git. Revert the commit and re-run step 6.
