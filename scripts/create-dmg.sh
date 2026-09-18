#!/bin/bash
#
# Package dist/MooOve.app into a drag-to-Applications DMG.
#
# Two paths:
#   1. `create-dmg` (brew install create-dmg) for the classic layout —
#      background-less but with positioned icons, a volume icon, and the
#      Applications shortcut where people expect it.
#   2. A plain hdiutil fallback if create-dmg is missing or fails. It
#      still gives the app and an /Applications symlink side by side, so
#      dragging works; it just uses Finder's default window layout.
#
# create-dmg drives Finder over AppleScript to place the icons, which is
# the one step that can misbehave on a headless CI runner. Hence the
# fallback, rather than failing a release over cosmetics.
#
# Usage: scripts/create-dmg.sh [--app PATH] [--output DIR] [--version X.Y.Z]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

OUTPUT="$ROOT/dist"
APP=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP="$2";     shift 2 ;;
    --output)  OUTPUT="$2";  shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${APP:=$OUTPUT/MooOve.app}"

if [[ ! -d "$APP" ]]; then
  echo "error: no app bundle at $APP — run scripts/build-macos.sh first" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
fi

DMG="$OUTPUT/MooOve-$VERSION.dmg"
STAGING="$OUTPUT/.dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/MooOve.app"

made_with_create_dmg=0
if command -v create-dmg >/dev/null 2>&1; then
  echo "Creating DMG with create-dmg..."
  # create-dmg makes its own /Applications link via --app-drop-link, so
  # the staging dir must contain only the app.
  if create-dmg \
      --volname "MooOve $VERSION" \
      --volicon "$ROOT/Resources/AppIcon.icns" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 128 \
      --icon "MooOve.app" 150 190 \
      --app-drop-link 450 190 \
      --no-internet-enable \
      "$DMG" \
      "$STAGING"; then
    made_with_create_dmg=1
  else
    echo "warning: create-dmg failed; falling back to hdiutil." >&2
    rm -f "$DMG"
  fi
else
  echo "note: create-dmg not installed (brew install create-dmg) — using hdiutil."
fi

if [[ $made_with_create_dmg -eq 0 ]]; then
  echo "Creating DMG with hdiutil..."
  ln -s /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "MooOve $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null
fi

rm -rf "$STAGING"

# Sign the DMG too when a Developer ID is available. Ad-hoc signing a DMG
# buys nothing, so we skip it otherwise.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "Signing DMG with Developer ID..."
  codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
fi

echo
echo "Created: $DMG"
echo "  $(du -h "$DMG" | cut -f1)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "dmg_path=$DMG"
    echo "dmg_name=$(basename "$DMG")"
  } >> "$GITHUB_OUTPUT"
fi
