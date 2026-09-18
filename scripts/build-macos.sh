#!/bin/bash
#
# Build MooOve.app.
#
# This is the single source of truth for compiling the binary and
# assembling the bundle. build.sh (the developer install/uninstall
# helper) delegates here, and so does CI — so there is only one place
# where the swiftc invocation can drift.
#
# Usage:
#   scripts/build-macos.sh [--version X.Y.Z] [--build-number N]
#                          [--arch arm64|x86_64|universal] [--output DIR]
#
# Defaults: version from Resources/Info.plist, arch = the host arch,
# output = dist/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION=""
BUILD_NUMBER=""
ARCH=""
OUTPUT="$ROOT/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      VERSION="$2";      shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --arch)         ARCH="$2";         shift 2 ;;
    --output)       OUTPUT="$2";       shift 2 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A tag like "v1.2.3" arrives from CI as GITHUB_REF_NAME. Strip the "v"
# so it is a valid CFBundleShortVersionString.
if [[ -z "$VERSION" && -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" == v* ]]; then
  VERSION="${GITHUB_REF_NAME#v}"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/Info.plist")"
fi
: "${BUILD_NUMBER:=${GITHUB_RUN_NUMBER:-1}}"
: "${ARCH:=$(uname -m)}"

# The deployment target has to match Package.swift's .macOS(.v26). If you
# ever lower it there, lower it here too.
DEPLOYMENT_TARGET="26.0"

APP="$OUTPUT/MooOve.app"
OBJ="$OUTPUT/.obj"

rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

compile_slice() {
  local arch="$1" out="$2"
  echo "  compiling $arch..."
  swiftc \
    -O \
    -parse-as-library \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    "$ROOT/Sources/MooOve/MooOveApp.swift" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework Carbon \
    -o "$out"
}

echo "Building MooOve $VERSION ($BUILD_NUMBER) for $ARCH..."
case "$ARCH" in
  universal)
    compile_slice arm64  "$OBJ/MooOve-arm64"
    compile_slice x86_64 "$OBJ/MooOve-x86_64"
    echo "  lipo..."
    lipo -create "$OBJ/MooOve-arm64" "$OBJ/MooOve-x86_64" \
      -output "$APP/Contents/MacOS/MooOve"
    ;;
  arm64|x86_64)
    compile_slice "$ARCH" "$APP/Contents/MacOS/MooOve"
    ;;
  *)
    echo "error: unsupported --arch: $ARCH (want arm64, x86_64, or universal)" >&2
    exit 2
    ;;
esac

cp "$ROOT/Resources/Info.plist"     "$APP/Contents/Info.plist"
cp "$ROOT/Resources/mooove.png"     "$APP/Contents/Resources/mooove.png"
cp "$ROOT/Resources/mooove@2x.png"  "$APP/Contents/Resources/mooove@2x.png"
cp "$ROOT/Resources/mooove@3x.png"  "$APP/Contents/Resources/mooove@3x.png"
cp "$ROOT/Resources/AppIcon.icns"   "$APP/Contents/Resources/AppIcon.icns"

# Stamp the version into the copy inside the bundle, never into the
# source plist — the tag is the source of truth for releases, and we do
# not want CI dirtying the working tree.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"       "$APP/Contents/Info.plist"

# Signing. With no Developer ID we ad-hoc sign: it is what makes the
# bundle's identity stable enough for TCC to prompt for Accessibility at
# all. It does NOT satisfy Gatekeeper for a downloaded app — see
# docs/installation.md for what users have to do on first launch.
#
# If APPLE_SIGNING_IDENTITY is set (a "Developer ID Application: ..."
# identity present in the keychain), we use it with Hardened Runtime
# instead, and the app becomes notarizable. Nothing else has to change.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "  signing with Developer ID: $APPLE_SIGNING_IDENTITY"
  codesign --force --deep --timestamp --options runtime \
    --sign "$APPLE_SIGNING_IDENTITY" "$APP"
else
  echo "  ad-hoc signing (no APPLE_SIGNING_IDENTITY set)"
  codesign --force --deep --sign - "$APP"
fi

rm -rf "$OBJ"

echo
echo "Built: $APP"
echo "  version $VERSION ($BUILD_NUMBER), arch: $(lipo -archs "$APP/Contents/MacOS/MooOve")"

# Let CI pick these up without re-parsing the plist.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$VERSION"
    echo "app_path=$APP"
  } >> "$GITHUB_OUTPUT"
fi
