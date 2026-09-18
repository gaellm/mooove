---
title: MooOve
description: Move the window you're using to another Space, another display, or a half of the screen — without touching the trackpad.
---

MooOve is a tiny macOS menu-bar app. It doesn't open windows, it doesn't
run in the Dock, and it doesn't send data anywhere. It does three things,
all from the keyboard:

- moves the frontmost window between **Spaces**,
- sends the frontmost window to another **display**,
- **snaps** windows to halves of the screen.

[**Download the latest release**](https://github.com/gaellm/mooove/releases/latest){: .btn }
[Installation guide](installation/){: .btn }
[Shortcuts](usage/){: .btn }

## The shortcuts, at a glance

| Shortcut | What it does |
| --- | --- |
| `Shift + Ctrl + →` / `←` | Move the window to the next / previous Space |
| `Shift + Ctrl + 1 … 9` | Move the window to Space 1 through 9 |
| `Cmd + Shift + Ctrl + →` / `←` | Move the window to the next / previous display |
| `Ctrl + Opt + ←` / `→` | Snap to the left / right half |
| `Ctrl + Opt + ↑` / `↓` | Snap to the top / bottom half (press again to maximize or restore) |
| `Ctrl + Opt + Shift + arrow` | Snap this window to one side and the previously-focused window to the other |

Full details on the [shortcuts page](usage/).

## Before you download

MooOve is **not signed with a paid Apple Developer certificate**, so the
first launch takes two extra clicks. This is not a bug and not a warning
you should ignore lightly — it simply means macOS can't verify who built
the app. The [installation guide](installation/) walks through it, and
the source is right there if you'd rather
[build it yourself](https://github.com/gaellm/mooove/blob/main/DEVELOPER_GUIDE.md#building-from-source).

MooOve also needs **Accessibility** permission. There is no way around
this: moving another app's window *is* the Accessibility API. MooOve uses
it only to find the focused window and move or resize it — not to read
keystrokes, text, or screen contents.

## Privacy

MooOve makes no network connections, collects no analytics or telemetry,
and touches no files outside its own bundle and its preferences file at
`~/Library/Preferences/com.gael.MooOve.plist`.

## Why it isn't in the App Store

macOS has no public API for moving another application's window between
Spaces. MooOve uses a handful of Apple-private functions, which the App
Store does not allow. In exchange: everything runs locally, with no
daemon, no kernel extension, and no SIP changes.

Because private APIs can change with each macOS release, a future macOS
update may require a new version of MooOve.
