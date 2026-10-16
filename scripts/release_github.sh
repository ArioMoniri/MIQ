#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/release_github.sh              # auto-discovers latest build/release-*/MIQ.app.zip; creates a DRAFT release
#   ./scripts/release_github.sh <path.zip>   # use a specific zip (still draft by default)
#   ./scripts/release_github.sh --publish    # publish immediately instead of creating a draft
#   ./scripts/release_github.sh --with-cli   # also build a universal `miq` CLI and attach it
#
# --with-cli builds `miq` for arm64 and x86_64 (`swift build -c release --product miq`),
# merges them with lipo, and attaches miq-<tag>-macos-universal.tar.gz to the release.
# Optional environment for that step:
#   MIQ_CLI_SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: …"
#                          (hardened runtime + timestamp). Unset: the binary is ad-hoc signed.
#   NOTARY_PROFILE         notarytool keychain profile; with a signing identity, the binary
#                          is submitted for notarization (a bare binary can't be stapled;
#                          Gatekeeper checks the ticket online).
#
# Requires:
# - HEAD checked out at an exact git tag
# - gh CLI installed and authenticated (brew install gh && gh auth login)
# - A completed release_notarize.sh run (MIQ.app.zip is the stapled distribution artifact)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRAFT=true
DIST_ZIP=""
WITH_CLI=false

for arg in "$@"; do
  case "$arg" in
    --publish) DRAFT=false ;;
    --with-cli) WITH_CLI=true ;;
    --*) echo "ERROR: Unknown option: $arg" >&2; exit 1 ;;
    *) DIST_ZIP="$arg" ;;
  esac
done

# Auto-discover latest stapled distribution zip
if [[ -z "$DIST_ZIP" ]]; then
  LATEST_DIR=$(find build -maxdepth 1 -name 'release-*' -type d | sort | tail -1)
  if [[ -z "$LATEST_DIR" ]]; then
    echo "ERROR: No build/release-* directory found. Run release_notarize.sh first." >&2
    exit 1
  fi
  DIST_ZIP="$LATEST_DIR/MIQ.app.zip"
  echo "==> Auto-discovered: $DIST_ZIP"
fi

if [[ ! -f "$DIST_ZIP" ]]; then
  echo "ERROR: Distribution zip not found: $DIST_ZIP" >&2
  echo "      MIQ.app.zip is produced by release_notarize.sh after stapling."
  exit 1
fi

# Require HEAD to be on an exact tag
if ! TAG=$(git describe --exact-match --tags HEAD 2>/dev/null); then
  echo "ERROR: HEAD is not on an exact git tag." >&2
  echo "       Tag first: git tag <version> && git push origin <version>"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found. Install with: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

ASSET_NAME="MIQ.app.zip"
ASSETS=("$DIST_ZIP#$ASSET_NAME")
CLI_SHA256=""

# Optional: universal `miq` CLI (arm64 + x86_64), built from this exact tag.
if [[ "$WITH_CLI" == true ]]; then
  for tool in swift lipo codesign; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found (needs Xcode)" >&2; exit 1; }
  done
  CLI_DIR="$(dirname "$DIST_ZIP")/cli"
  rm -rf "$CLI_DIR"
  mkdir -p "$CLI_DIR/stage"
  SLICES=()
  for arch in arm64 x86_64; do
    echo "==> Building miq ($arch)"
    SCRATCH="$CLI_DIR/build-$arch"
    swift build -c release --product miq --arch "$arch" --scratch-path "$SCRATCH"
    BIN_PATH=$(swift build -c release --product miq --arch "$arch" --scratch-path "$SCRATCH" --show-bin-path)
    SLICES+=("$BIN_PATH/miq")
  done
  CLI_BIN="$CLI_DIR/stage/miq"
  lipo -create -output "$CLI_BIN" "${SLICES[@]}"
  lipo "$CLI_BIN" -verify_arch arm64 x86_64

  if [[ -n "${MIQ_CLI_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$MIQ_CLI_SIGN_IDENTITY" "$CLI_BIN"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      echo "==> Notarizing miq"
      ditto -c -k "$CLI_BIN" "$CLI_DIR/miq-notarize.zip"
      xcrun notarytool submit "$CLI_DIR/miq-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    fi
  else
    echo "==> MIQ_CLI_SIGN_IDENTITY not set: ad-hoc signing miq (not notarized)"
    codesign --force --sign - "$CLI_BIN"
  fi
  "$CLI_BIN" --help >/dev/null

  CLI_ASSET="miq-${TAG}-macos-universal.tar.gz"
  tar -C "$CLI_DIR/stage" -czf "$CLI_DIR/$CLI_ASSET" miq
  CLI_SHA256=$(shasum -a 256 "$CLI_DIR/$CLI_ASSET" | awk '{print $1}')
  ASSETS+=("$CLI_DIR/$CLI_ASSET#$CLI_ASSET")
  echo "==> CLI:      $CLI_DIR/$CLI_ASSET"
fi

DRAFT_ARGS=(--draft)
[[ "$DRAFT" == false ]] && DRAFT_ARGS=()

echo "==> Tag:      $TAG"
echo "==> Artifact: $DIST_ZIP → $ASSET_NAME"
echo "==> Mode:     $( [[ "$DRAFT" == true ]] && echo 'draft' || echo 'publish' )"

SHA256=$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')

RELEASE_NOTES=$(cat <<'EOF'
**New features:**
-

**Performance improvements:**
-

**Fixes:**
-

**Other:**
-
EOF
)

RELEASE_URL=$(env GH_PAGER=cat gh release create "$TAG" \
  "${ASSETS[@]}" \
  --title "MIQ ${TAG#v}" \
  --notes "$RELEASE_NOTES" \
  "${DRAFT_ARGS[@]+"${DRAFT_ARGS[@]}"}")

echo
echo "SUCCESS"
echo

if [[ "$DRAFT" == true ]]; then
  echo "Release created as DRAFT — review and publish at:"
  echo "  $RELEASE_URL"
  echo
fi

echo "Homebrew cask sha256:"
echo "  $SHA256"

if [[ -n "$CLI_SHA256" ]]; then
  echo
  echo "CLI tarball sha256 (miq-${TAG}-macos-universal.tar.gz):"
  echo "  $CLI_SHA256"
fi
echo
echo "Homebrew formula (packaging/homebrew/miq.rb) source-tarball sha256 — run after the tag is pushed:"
echo "  curl -fsSL https://github.com/marcoduering/MIQ/archive/refs/tags/${TAG}.tar.gz | shasum -a 256"
