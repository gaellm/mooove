#!/bin/bash
#
# Check the build products before they become a release.
#
# Catches the things that silently produce a broken download: a bundle
# that says 1.0.0 when the tag said 1.2.0, a binary for the wrong
# architecture, a seal broken by copying the bundle around, a DMG with no
# way to drag the app into /Applications.
#
# Usage: scripts/verify-release.sh [--output DIR] [--expect-version X.Y.Z]
#                                  [--expect-arch arm64|x86_64|universal]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

OUTPUT="$ROOT/dist"
EXPECT_VERSION=""
EXPECT_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)         OUTPUT="$2";         shift 2 ;;
    --expect-version) EXPECT_VERSION="$2"; shift 2 ;;
    --expect-arch)    EXPECT_ARCH="$2";    shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$EXPECT_VERSION" && -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" == v* ]]; then
  EXPECT_VERSION="${GITHUB_REF_NAME#v}"
fi

APP="$OUTPUT/MooOve.app"
FAILURES=0
MOUNTPOINT=""

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '  --   %s\n' "$1"; }

cleanup() {
  if [[ -n "$MOUNTPOINT" && -d "$MOUNTPOINT" ]]; then
    hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Verifying $OUTPUT"
echo
echo "App bundle:"

if [[ ! -d "$APP" ]]; then
  fail "no bundle at $APP"
  echo; echo "Nothing to verify. Run scripts/build-macos.sh first."; exit 1
fi
pass "bundle exists"

BIN="$APP/Contents/MacOS/MooOve"
if [[ -x "$BIN" ]]; then pass "executable present"; else fail "missing or non-executable $BIN"; fi

PLIST="$APP/Contents/Info.plist"
if plutil -lint "$PLIST" >/dev/null 2>&1; then pass "Info.plist is valid"; else fail "Info.plist is malformed"; fi

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""; }

BUNDLE_ID="$(plist_get CFBundleIdentifier)"
[[ "$BUNDLE_ID" == "com.gael.MooOve" ]] \
  && pass "bundle id: $BUNDLE_ID" \
  || fail "unexpected bundle id: '$BUNDLE_ID' (TCC approvals are keyed to this)"

# LSUIElement is what keeps MooOve out of the Dock. Losing it would turn
# a menu-bar app into a windowless app with a Dock icon and no window.
[[ "$(plist_get LSUIElement)" == "true" ]] \
  && pass "LSUIElement set (menu-bar only, no Dock icon)" \
  || fail "LSUIElement is not true — the app would show a Dock icon"

[[ -n "$(plist_get CFBundleIconFile)" ]] \
  && pass "icon file declared" \
  || fail "CFBundleIconFile missing"

[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] \
  && pass "AppIcon.icns bundled" \
  || fail "AppIcon.icns missing from Resources"

for img in mooove.png mooove@2x.png mooove@3x.png; do
  [[ -f "$APP/Contents/Resources/$img" ]] \
    && pass "menu-bar image $img bundled" \
    || fail "menu-bar image $img missing"
done

VERSION="$(plist_get CFBundleShortVersionString)"
if [[ -n "$EXPECT_VERSION" ]]; then
  [[ "$VERSION" == "$EXPECT_VERSION" ]] \
    && pass "version is $VERSION" \
    || fail "version is $VERSION, expected $EXPECT_VERSION"
else
  info "version is $VERSION (nothing to compare against)"
fi

MIN_OS="$(plist_get LSMinimumSystemVersion)"
[[ -n "$MIN_OS" ]] \
  && pass "LSMinimumSystemVersion: $MIN_OS" \
  || fail "LSMinimumSystemVersion missing"

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo "?")"
if [[ -n "$EXPECT_ARCH" ]]; then
  case "$EXPECT_ARCH" in
    universal) [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] \
                 && pass "architectures: $ARCHS" \
                 || fail "architectures: $ARCHS, expected universal" ;;
    *)         [[ "$ARCHS" == *"$EXPECT_ARCH"* ]] \
                 && pass "architectures: $ARCHS" \
                 || fail "architectures: $ARCHS, expected $EXPECT_ARCH" ;;
  esac
else
  info "architectures: $ARCHS"
fi

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  pass "code signature seal is intact"
else
  fail "code signature is broken (was the bundle modified after signing?)"
fi

# Report, but never fail on, Gatekeeper. Without a Developer ID this is
# *expected* to be rejected, and the install docs are written around it.
if spctl -a -t exec -vv "$APP" >/dev/null 2>&1; then
  info "Gatekeeper: accepted (signed with a Developer ID)"
else
  info "Gatekeeper: rejected — expected for an ad-hoc signed build."
  info "             Users must use the first-launch steps in docs/installation.md."
fi

echo
echo "Disk image:"

DMG="$(ls -1 "$OUTPUT"/MooOve-*.dmg 2>/dev/null | head -1 || true)"
if [[ -z "$DMG" ]]; then
  info "no DMG in $OUTPUT (run scripts/create-dmg.sh to make one)"
else
  pass "found $(basename "$DMG")"

  if hdiutil verify "$DMG" >/dev/null 2>&1; then
    pass "image checksum verifies"
  else
    fail "image is corrupt"
  fi

  MOUNTPOINT="$(mktemp -d)"
  if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNTPOINT" -quiet 2>/dev/null; then
    pass "image mounts"

    [[ -d "$MOUNTPOINT/MooOve.app" ]] \
      && pass "MooOve.app is inside" \
      || fail "MooOve.app is not inside the image"

    # The whole point of the classic layout: a symlink users can drag onto.
    if [[ -L "$MOUNTPOINT/Applications" ]]; then
      pass "/Applications shortcut present (drag-to-install works)"
    else
      fail "no /Applications shortcut — users cannot drag the app in"
    fi

    DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$MOUNTPOINT/MooOve.app/Contents/Info.plist" 2>/dev/null || echo "")"
    [[ "$DMG_VERSION" == "$VERSION" ]] \
      && pass "app inside the image is version $DMG_VERSION" \
      || fail "app inside the image is $DMG_VERSION, image was built from $VERSION"

    hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
    MOUNTPOINT=""
  else
    fail "image does not mount"
  fi
fi

# Launching is deliberately not tested here: MooOve is LSUIElement and
# does nothing visible without Accessibility approval, so a CI "did it
# launch" check would pass on a build that is useless to a real user.
# Smoke-test by hand with ./build.sh --install.

echo
if [[ $FAILURES -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
