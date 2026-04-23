#!/usr/bin/env bash
# Package a signed .app into a signed, notarized, stapled DMG.
# Follows Apple's recommended layout: .app alongside an Applications symlink,
# HFS+ filesystem, compressed UDZO image, hardened runtime preserved.
#
# Usage: build-dmg.sh <version> <app-path> <output-dir> <signing-identity>

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <version> <app-path> <output-dir> [signing-identity]" >&2
    exit 1
fi

version="${1#v}"
app_path="$2"
output_dir="$3"
signing_identity="${4:-}"

if [ ! -d "$app_path" ]; then
    echo ".app bundle not found: $app_path" >&2
    exit 1
fi

app_name="$(basename "$app_path" .app)"
volname="${app_name} ${version}"
dmg_basename="${app_name}_${version}.dmg"
dmg_path="${output_dir}/${dmg_basename}"

mkdir -p "$output_dir"

# Remove any stale DMG so hdiutil doesn't prompt.
rm -f "$dmg_path"

# Stage .app plus an /Applications symlink — the standard drag-to-install layout.
staging="$(mktemp -d "${TMPDIR:-/tmp}/thane-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

ditto "$app_path" "$staging/${app_name}.app"
ln -s /Applications "$staging/Applications"

# Size the image with ~20% slack so finder layout metadata fits comfortably.
payload_bytes="$(du -sk "$staging" | awk '{print $1}')"
size_kb=$((payload_bytes * 12 / 10 + 4096))

hdiutil create \
    -volname "$volname" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -size "${size_kb}k" \
    -ov \
    -quiet \
    "$dmg_path"

if [ -n "$signing_identity" ]; then
    codesign \
        --force \
        --sign "$signing_identity" \
        --timestamp \
        "$dmg_path"
fi

printf '%s\n' "$dmg_path"
