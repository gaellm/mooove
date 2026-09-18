---
title: Troubleshooting
description: What to do when MooOve won't open, won't move windows, or won't go away.
---

[← Back to the home page](../)

## "MooOve cannot be opened because Apple cannot check it"

Expected — MooOve isn't notarized. Open **System Settings → Privacy &
Security**, scroll to the Security section, and click **Open Anyway**.
Full walkthrough in the [installation guide](../installation/#3-get-past-the-first-launch-warning).

## "MooOve is damaged and should be moved to the Trash"

Almost always the quarantine flag rather than actual damage. Run:

```bash
xattr -dr com.apple.quarantine /Applications/MooOve.app
```

Then open it again. If it still fails, the download may genuinely be
incomplete — check it against the release's `SHA256SUMS` and download
again.

## The shortcuts do nothing

In order of likelihood:

1. **Accessibility permission is missing or stale.** Open **System
   Settings → Privacy & Security → Accessibility**. If MooOve isn't
   listed, or is listed but switched off, fix that, then **quit and
   reopen MooOve** — the permission is only picked up at launch.

2. **You updated MooOve.** Each build has a different ad-hoc signature,
   so macOS may treat the new version as a different app and drop the
   approval. Toggle MooOve off and on in the Accessibility list, then
   restart it.

3. **Two copies are installed.** A copy in `~/Downloads` and one in
   `/Applications` share a bundle identifier but not a signature, and
   macOS gets confused about which one it approved. Find them all and
   keep only the one in `/Applications`:

   ```bash
   mdfind -name MooOve.app
   ```

4. **Another app owns the shortcut.** Rectangle, Magnet, or macOS's own
   window tiling may be grabbing `Ctrl+Opt+arrow`. Turn off **Enable
   Window Tiling Shortcuts** in MooOve's menu, or change the other app's
   bindings.

5. **No window is focused.** MooOve acts on the frontmost window. With
   only Finder's desktop in front, there is nothing to move — the icon
   flashes a warning triangle.

## The permission reset dance

When Accessibility gets into a bad state, this clears it completely so
macOS re-prompts from scratch:

```bash
tccutil reset Accessibility com.gael.MooOve
```

Then quit MooOve, open it again, and press a shortcut to trigger the
prompt.

## The icon flashes a warning triangle

Nothing happened, and MooOve is telling you so. Causes: you're at the
first or last Space with new-Space creation turned off; no window is
focused; there's only one display and you pressed a display shortcut; or
Accessibility permission is missing.

## Moving to a new Space doesn't switch me there

**Follow Window to Target Space** is turned off in the menu. Turn it back
on if you want to travel with the window.

## Spaces keep renumbering themselves

macOS is rearranging them. System Settings → Desktop & Dock → Mission
Control → turn off *"Automatically rearrange Spaces based on most recent
use"*.

## MooOve still appears in System Settings after I deleted it

The Accessibility entry outlives the app bundle. Run
`tccutil reset Accessibility com.gael.MooOve`, then refresh
LaunchServices — the full sequence is in
[uninstalling](../installation/#uninstalling).

If it's still listed as greyed-out under **General → Login Items**, log
out and back in. macOS only rebuilds that panel at the start of a
session.

## It broke after a macOS update

Plausible. MooOve relies on a handful of Apple-private functions to move
windows between Spaces, because macOS offers no public API for it. Those
can change in any macOS release. Check the
[releases page](https://github.com/gaellm/mooove/releases) for a newer
build, and [open an issue](https://github.com/gaellm/mooove/issues) if
there isn't one.

## Something else

Open an issue at
[github.com/gaellm/mooove/issues](https://github.com/gaellm/mooove/issues).
Include your macOS version (`sw_vers`), your MooOve version (menu bar →
About), and what the icon flashes when you press the shortcut.
