---
title: Installation
description: Download the DMG, get past Gatekeeper, and grant Accessibility.
---

[← Back to the home page](../)

## Requirements

- **macOS 26** or later
- **Apple Silicon** (M1 or newer)
- **Accessibility** permission, which macOS will ask for on first use

## 1. Download

Get the latest `MooOve-x.y.z.dmg` from the
[releases page](https://github.com/gaellm/mooove/releases/latest).

## 2. Drag it into Applications

Open the DMG and drag **MooOve** onto the **Applications** shortcut.

Install into `/Applications`, not somewhere else. macOS ties the
Accessibility approval to the app at a specific path, so a copy left in
`~/Downloads` and a copy in `/Applications` end up fighting over the same
permission entry.

## 3. Get past the first-launch warning

Double-click MooOve and macOS will refuse to open it, saying it "cannot
be opened because Apple cannot check it for malicious software", or words
to that effect.

**This is expected.** MooOve is not notarized, because notarizing
requires a paid Apple Developer Program membership. macOS blocks every
unnotarized app downloaded from the internet the same way, regardless of
what it does.

To allow it:

1. Open **System Settings → Privacy & Security**.
2. Scroll down to the **Security** section. You'll see a line about
   MooOve being blocked.
3. Click **Open Anyway**, then confirm.

Older instructions tell you to right-click the app and choose *Open*.
That shortcut no longer works on current macOS versions — use Privacy &
Security.

If you prefer the terminal, this does the same thing in one line:

```bash
xattr -dr com.apple.quarantine /Applications/MooOve.app
```

You only have to do this once per installed version.

### Would you rather not trust a stranger's binary?

Reasonable. MooOve is a single Swift file, and building it yourself takes
about a minute — a locally built app never gets quarantined, so it skips
this step entirely:

```bash
git clone https://github.com/gaellm/mooove.git
cd mooove
./build.sh --install
```

You need the Xcode Command Line Tools (`xcode-select --install`).

## 4. Grant Accessibility permission

The first time you press one of the shortcuts, macOS will ask for
Accessibility permission.

1. Click **Open Settings** in the alert (or go to **System Settings →
   Privacy & Security → Accessibility**).
2. Enable **MooOve** in the list.
3. Quit MooOve from its menu-bar icon and open it again.

MooOve cannot move a single window without this. Reading which window is
focused and repositioning it *is* the Accessibility API.

## 5. You're done

MooOve now sits in your menu bar as a small rectangle icon. There is no
window and no Dock icon — that's by design. Click the icon for the menu,
or go straight to the [shortcuts](../usage/).

To have it start automatically, enable **Launch at Login** from the
menu-bar menu.

## Updating

Download the new DMG and drag it over the old app. macOS will ask you to
confirm the replacement, and you'll need to redo step 3 for the new
version.

Because MooOve is ad-hoc signed, each new build has a different code
signature, so **macOS may ask for Accessibility permission again after an
update**. If the shortcuts stop responding after updating, that's the
first thing to check.

## Verifying your download

Each release includes a `SHA256SUMS` file. To check that the DMG you
downloaded is the one that was published:

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
```

## Uninstalling

If you have the source checkout, this removes the app, cancels the Login
Item registration, and clears the leftover permission entries:

```bash
./build.sh --uninstall
```

Without the source, the manual equivalent:

```bash
# 1. Quit MooOve from its menu-bar icon, then delete the app.
rm -rf /Applications/MooOve.app

# 2. Forget the Accessibility approval. Most people miss this step, and
#    then MooOve keeps appearing in Privacy & Security forever.
tccutil reset Accessibility com.gael.MooOve

# 3. Delete the saved preferences.
defaults delete com.gael.MooOve 2>/dev/null || true

# 4. Refresh LaunchServices so the app stops showing up in Login Items,
#    Spotlight, and "Open With".
killall -HUP backgroundtaskmanagementagent 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user
```

If MooOve still shows up greyed-out in **System Settings → General →
Login Items**, log out and back in — macOS only refreshes that panel at
the start of a session.
