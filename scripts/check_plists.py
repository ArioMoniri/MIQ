#!/usr/bin/env python3
"""Consistency checks for MIQ's Info.plists (run by the `plist-consistency` CI job).

Finder only routes a file to a Quick Look extension when the extension's
QLSupportedContentTypes names a UTI that macOS can resolve for that file. MIQ's
own UTIs are declared by the host app (UTImportedTypeDeclarations), so the three
plists must agree — miss one and the parser is silently never called.

Checks:
  1. Every Info.plist in the repo parses.
  2. Every UTI the preview and thumbnail extensions claim is either declared by
     MIQApp/Info.plist or in an explicit allowlist below: SYSTEM_UTIS (types
     macOS itself owns) or THIRD_PARTY_UTIS (aliases other apps declare).
  3. Every UTI the app declares is claimed by both extensions (an orphaned
     declaration usually means a forgotten extension entry).
  4. The preview and thumbnail extensions claim the same set of UTIs.
  5. Each declared UTI has at least one filename extension, and no two
     declarations claim the same filename extension.

Usage: scripts/check_plists.py [--root DIR]
Exit status 0 when consistent, 1 on any problem (each printed with a diff).
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path

APP_PLIST = "MIQApp/Info.plist"
EXTENSION_PLISTS = {
    "preview": "MIQQuickLookExtension/Info.plist",
    "thumbnail": "MIQThumbnailExtension/Info.plist",
}

# UTIs an extension may claim without the app declaring them, because macOS
# (CoreTypes) already does. Keep this list short and justified: anything else
# should be declared in MIQApp/Info.plist.
SYSTEM_UTIS = {
    "public.data": "root data type",
    "public.gzip": "system gzip type (catches compound .nii.gz/.mif.gz names)",
    "org.gnu.gnu-zip-archive": "system gzip archive type that .gz resolves to",
}

# UTIs other software declares for MIQ's formats. Claiming them lets MIQ still
# preview a file when another installed app's declaration wins the extension
# (macOS then resolves `.nii` to that app's UTI, not `org.nifti.nii`). MIQ may
# import-declare one only without filename tags, so it never competes with the
# owner for the extension. Allowed, but listed as a notice on every run so the
# list stays deliberate.
THIRD_PARTY_UTIS = {
    "gov.nih.nifti-1": "NIfTI-1 UTI declared by third-party neuroimaging apps",
}

# Declared types that deliberately carry no filename-extension tag. Launch
# Services matches only the last extension, so a `.nii.gz` tag would never match
# (these files arrive via the extensions' gzip claims plus the MIQFileKind name
# check); the declaration stays to document intent. Third-party aliases are
# tagless so they never compete with MIQ's own type for the extension.
TAGLESS_UTIS = {
    "org.nifti.nii-gz": "compound .nii.gz extension; routed via the gzip claim",
    "org.mrtrix.mif-gz": "compound .mif.gz extension; routed via the gzip claim",
    "gov.nih.nifti-1": "third-party alias; tagless so it never competes for .nii",
}

SKIP_DIRS = {".git", ".build", "build", "DerivedData", ".swiftpm", "node_modules"}


def find_plists(root: Path) -> list[Path]:
    found = []
    for path in root.rglob("Info.plist"):
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts):
            continue
        found.append(path)
    return sorted(found)


def load(path: Path, errors: list[str]) -> dict | None:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except FileNotFoundError:
        errors.append(f"{path}: missing")
        return None
    except Exception as exc:  # plistlib raises several types for malformed input
        errors.append(f"{path}: does not parse: {exc}")
        return None
    if not isinstance(value, dict):
        errors.append(f"{path}: top level is {type(value).__name__}, expected dict")
        return None
    return value


def claimed_types(plist: dict) -> list[str]:
    attributes = plist.get("NSExtension", {}).get("NSExtensionAttributes", {})
    return list(attributes.get("QLSupportedContentTypes", []))


def declared_types(plist: dict) -> dict[str, list[str]]:
    """UTI -> filename extensions, from imported and exported declarations."""
    result: dict[str, list[str]] = {}
    for key in ("UTImportedTypeDeclarations", "UTExportedTypeDeclarations"):
        for decl in plist.get(key, []):
            uti = decl.get("UTTypeIdentifier")
            if not uti:
                continue
            tags = decl.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])
            if isinstance(tags, str):
                tags = [tags]
            result[uti] = list(tags)
    return result


def diff_block(title: str, items: list[str]) -> str:
    return title + "\n" + "\n".join(f"    {line}" for line in items)


def check_extension_claims(name: str, types: list[str], declared: dict[str, list[str]],
                           errors: list[str]) -> None:
    """Checks 2 and 3 for one extension, plus empty / duplicate claim lists."""
    rel = EXTENSION_PLISTS[name]
    if not types:
        errors.append(f"{rel}: QLSupportedContentTypes is empty or missing")
    duplicates = sorted({t for t in types if types.count(t) > 1})
    if duplicates:
        errors.append(diff_block(f"{rel}: duplicate QLSupportedContentTypes entries:", duplicates))

    # 2. Claimed but undeclared.
    for uti in sorted(set(types) & set(THIRD_PARTY_UTIS)):
        print(f"note: {name} extension claims third-party UTI {uti} ({THIRD_PARTY_UTIS[uti]})")
    undeclared = sorted(set(types) - set(declared) - set(SYSTEM_UTIS) - set(THIRD_PARTY_UTIS))
    if undeclared:
        errors.append(diff_block(
            f"{rel}: claims UTIs that {APP_PLIST} does not declare and that are not "
            f"allowlisted (declare them in UTImportedTypeDeclarations, or add a "
            f"justified entry to SYSTEM_UTIS / THIRD_PARTY_UTIS):",
            [f"+ {uti}" for uti in undeclared]))

    # 3. Declared but not claimed.
    unclaimed = sorted(set(declared) - set(types))
    if unclaimed:
        errors.append(diff_block(
            f"{rel}: does not claim UTIs declared by {APP_PLIST}:",
            [f"- {uti}" for uti in unclaimed]))


def check_preview_matches_thumbnail(claims: dict[str, list[str]], errors: list[str]) -> None:
    """Check 4: the preview and thumbnail extensions claim the same UTIs."""
    preview, thumbnail = set(claims["preview"]), set(claims["thumbnail"])
    if preview != thumbnail:
        lines = [f"- {uti}  (preview only)" for uti in sorted(preview - thumbnail)]
        lines += [f"+ {uti}  (thumbnail only)" for uti in sorted(thumbnail - preview)]
        errors.append(diff_block("preview and thumbnail QLSupportedContentTypes differ:", lines))


def check_filename_tags(declared: dict[str, list[str]], errors: list[str]) -> None:
    """Check 5: every declared UTI has a filename extension, none shared."""
    owner: dict[str, str] = {}
    for uti, tags in sorted(declared.items()):
        if not tags and uti not in TAGLESS_UTIS:
            errors.append(f"{APP_PLIST}: {uti} declares no public.filename-extension")
        for tag in tags:
            tag_key = tag.lower().lstrip(".")
            if tag_key in owner:
                errors.append(f"{APP_PLIST}: filename extension '{tag}' declared by both "
                              f"{owner[tag_key]} and {uti}")
            else:
                owner[tag_key] = uti


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path,
                        help="repository root (default: this script's parent directory)")
    args = parser.parse_args()
    root: Path = args.root.resolve()

    errors: list[str] = []

    # 1. Every Info.plist parses.
    plists = find_plists(root)
    for path in plists:
        load(path, errors)
    print(f"Parsed {len(plists)} Info.plist file(s).")

    app = load(root / APP_PLIST, errors)
    extensions = {name: load(root / rel, errors) for name, rel in EXTENSION_PLISTS.items()}
    if app is None or any(v is None for v in extensions.values()):
        return report(errors)

    declared = declared_types(app)
    claims = {name: claimed_types(plist) for name, plist in extensions.items()}

    print(f"App declares {len(declared)} UTI(s): {', '.join(sorted(declared)) or '(none)'}")
    for name, types in claims.items():
        print(f"{name} extension claims {len(types)} UTI(s)")

    for name, types in claims.items():
        check_extension_claims(name, types, declared, errors)
    check_preview_matches_thumbnail(claims, errors)
    check_filename_tags(declared, errors)

    return report(errors)


def report(errors: list[str]) -> int:
    if errors:
        print(f"\n{len(errors)} problem(s):\n", file=sys.stderr)
        for error in errors:
            print(f"✘ {error}\n", file=sys.stderr)
        return 1
    print("✔ Info.plists are consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
