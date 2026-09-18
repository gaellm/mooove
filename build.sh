#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build/mooove-app"
APP="$ROOT/MooOve.app"
BIN="$BUILD/MooOve"

# Legacy names — from before the app was renamed to MooOve. We use these
# to clean up old SpaceMover installs, TCC entries, and preferences so a
# user upgrading from the old build ends up with no leftovers.
LEGACY_BUNDLE_ID="com.gael.SpaceMover"
LEGACY_APP_NAME="SpaceMover.app"
LEGACY_BIN_NAME="SpaceMover"

BUNDLE_ID="com.gael.MooOve"

INSTALL=0
UNINSTALL=0
if [[ "${1:-}" == "--install" ]]; then
  INSTALL=1
elif [[ "${1:-}" == "--uninstall" ]]; then
  UNINSTALL=1
fi

if [[ $UNINSTALL -eq 1 ]]; then
  echo "Uninstalling MooOve..."

  # 1. Kill any running instance (new or legacy).
  pkill -f "MooOve.app/Contents/MacOS/MooOve" 2>/dev/null || true
  pkill -f "${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" 2>/dev/null || true
  sleep 0.3

  # 2. Try to unregister the Login Item cleanly. SMAppService needs the
  #    app binary to still exist, so do this before removing bundles.
  if [[ -x /Applications/MooOve.app/Contents/MacOS/MooOve ]]; then
    /Applications/MooOve.app/Contents/MacOS/MooOve --unregister-login-item 2>/dev/null || true
  fi
  if [[ -x "/Applications/${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" ]]; then
    "/Applications/${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" \
      --unregister-login-item 2>/dev/null || true
  fi

  # 3. Remove every bundle we can find, not just /Applications, so a stray
  #    copy in ~/Downloads doesn't keep TCC pointing at a missing binary.
  BUNDLES=$(mdfind -name MooOve.app 2>/dev/null || true)
  BUNDLES="$BUNDLES
$(mdfind -name ${LEGACY_APP_NAME} 2>/dev/null || true)
/Applications/MooOve.app
/Applications/${LEGACY_APP_NAME}
$APP
$ROOT/${LEGACY_APP_NAME}"
  echo "$BUNDLES" | awk 'NF' | sort -u | while read -r p; do
    if [[ -d "$p" ]]; then
      echo "  removing $p"
      rm -rf "$p"
    fi
  done

  # 4. Belt-and-braces: bounce the backgroundtaskmanagementagent so the
  #    Login Items panel re-reads its state from disk. Without this, an
  #    already-registered MooOve can linger (greyed-out) in
  #    System Settings > General > Login Items until next login.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u /Applications/MooOve.app >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "/Applications/${LEGACY_APP_NAME}" >/dev/null 2>&1 || true
  killall -HUP backgroundtaskmanagementagent 2>/dev/null || true

  # 5. Reset the TCC approvals that reference the bundle ID (new + legacy).
  #    tccutil operates by bundle ID and doesn't need the app to be present.
  echo "Clearing Accessibility, Input Monitoring, and Automation TCC entries..."
  for bid in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    tccutil reset Accessibility "$bid" >/dev/null 2>&1 || true
    tccutil reset ListenEvent   "$bid" >/dev/null 2>&1 || true
    tccutil reset AppleEvents   "$bid" >/dev/null 2>&1 || true
    tccutil reset PostEvent     "$bid" >/dev/null 2>&1 || true
  done

  # 6. Remove the app's own preferences plist so nothing lingers under
  #    ~/Library/Preferences (both new and legacy).
  for bid in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
    rm -f "$HOME/Library/Preferences/${bid}.plist" 2>/dev/null || true
    defaults delete "$bid" 2>/dev/null || true
  done

  # 7. Nudge LaunchServices so the deleted bundle stops appearing in
  #    Spotlight / "Open With" / the Login Items list.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true

  echo
  echo "Uninstalled."
  echo "If MooOve is still shown in System Settings > Privacy & Security,"
  echo "log out and back in — macOS refreshes the panel on session start."
  exit 0
fi

# The compile + bundle step lives in scripts/build-macos.sh so that this
# script and the CI release workflow cannot drift apart. Everything below
# (--install, --uninstall, TCC handling) stays here: it is developer
# convenience, not part of a release.
rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD"

"$ROOT/scripts/build-macos.sh" --output "$ROOT"

# Keep a copy of the binary where the --install path expects it, so the
# "is the installed binary byte-identical?" check below still works.
cp "$APP/Contents/MacOS/MooOve" "$BIN"

echo
echo "Built:"
echo "  $APP"

if [[ $INSTALL -eq 1 ]]; then
  echo
  echo "Installing to /Applications..."

  # Kill any running instance so we can replace the bundle safely.
  pkill -f "MooOve.app/Contents/MacOS/MooOve" 2>/dev/null || true
  pkill -f "${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" 2>/dev/null || true
  sleep 0.3

  # Remove any old SpaceMover install and its TCC entries. Two apps with
  # overlapping keyboard shortcuts would fight each other, and the old
  # bundle ID lingering in Privacy & Security is confusing.
  RESET_TCC=0
  if [[ -d "/Applications/${LEGACY_APP_NAME}" ]]; then
    echo "Removing legacy /Applications/${LEGACY_APP_NAME}..."
    if [[ -x "/Applications/${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" ]]; then
      "/Applications/${LEGACY_APP_NAME}/Contents/MacOS/${LEGACY_BIN_NAME}" \
        --unregister-login-item 2>/dev/null || true
    fi
    rm -rf "/Applications/${LEGACY_APP_NAME}"
    RESET_TCC=1
  fi
  LEGACY_DUPES=$(mdfind -name "${LEGACY_APP_NAME}" 2>/dev/null || true)
  if [[ -n "$LEGACY_DUPES" ]]; then
    echo "Removing stray legacy bundles:"
    echo "$LEGACY_DUPES" | sed 's/^/  /'
    echo "$LEGACY_DUPES" | while read -r p; do
      [[ -n "$p" ]] && rm -rf "$p"
    done
    RESET_TCC=1
  fi
  if [[ $RESET_TCC -eq 1 ]]; then
    for perm in Accessibility ListenEvent AppleEvents PostEvent; do
      tccutil reset "$perm" "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || true
    done
  fi

  # Nuke duplicates *other than* the target install location, so TCC
  # doesn't get confused by multiple bundles sharing the same bundle ID
  # but with different ad-hoc signatures.
  DUPES=$(mdfind -name MooOve.app 2>/dev/null \
    | grep -v "^/Applications/MooOve.app\$" \
    | grep -v "^$APP\$" || true)
  if [[ -n "$DUPES" ]]; then
    echo "Removing duplicate bundles:"
    echo "$DUPES" | sed 's/^/  /'
    echo "$DUPES" | while read -r p; do
      [[ -n "$p" ]] && rm -rf "$p"
    done
    RESET_TCC=1
  fi

  # If the new binary is byte-identical to the installed one, skip the
  # replacement entirely: keeping the same CDHash means macOS won't
  # re-prompt for Accessibility permission.
  INSTALL_BIN=/Applications/MooOve.app/Contents/MacOS/MooOve
  if [[ -x "$INSTALL_BIN" ]] && cmp -s "$BIN" "$INSTALL_BIN"; then
    echo "Installed binary is unchanged; keeping existing bundle (Accessibility approval preserved)."
  else
    if [[ -x "$INSTALL_BIN" ]]; then
      echo "Binary changed; installing a new copy. macOS may re-prompt for Accessibility."
    fi
    pkill -f "MooOve.app/Contents/MacOS/MooOve" 2>/dev/null || true
    sleep 0.2
    rm -rf /Applications/MooOve.app
    cp -R "$APP" /Applications/
    xattr -dr com.apple.quarantine /Applications/MooOve.app 2>/dev/null || true
    # Re-sign in place (path change can invalidate a bundle's seal).
    codesign --force --deep --sign - /Applications/MooOve.app >/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f -R /Applications/MooOve.app >/dev/null 2>&1 || true
  fi

  # Only reset TCC if we actually removed a duplicate signature or if the
  # user explicitly asked to. Otherwise the user keeps their previously
  # granted Accessibility permission across rebuilds.
  if [[ $RESET_TCC -eq 1 || "${2:-}" == "--reset-permissions" ]]; then
    echo "Resetting Accessibility approval (you will be re-prompted)."
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  # Remove the local build product so it isn't re-detected as a duplicate.
  rm -rf "$APP"

  echo "Installed: /Applications/MooOve.app"
  echo
  echo "Launch:"
  echo "  open /Applications/MooOve.app"
  echo
  echo "On first move attempt the app will ask for Accessibility permission."
  echo "Enable MooOve in System Settings > Privacy & Security > Accessibility."
else
  echo
  echo "Open it with:"
  echo "  open \"$APP\""
  echo
  echo "Or install it system-wide with:"
  echo "  ./build.sh --install"
fi
