---
title: Shortcuts and menu
description: Every MooOve shortcut, and what the menu-bar menu controls.
---

[← Back to the home page](../)

## Move windows between Spaces

| Shortcut | What it does |
| --- | --- |
| `Shift + Ctrl + →` | Move the current window to the next Space |
| `Shift + Ctrl + ←` | Move the current window to the previous Space |
| `Shift + Ctrl + 1 … 9` | Move the current window to Space 1 through 9 |

After the move, macOS switches to the destination Space, brings your
window to the front, and focuses it, so you can keep typing.

The shortcuts don't wrap around. If you're already on the last Space,
`Shift+Ctrl+→` adds a new Space and moves the window there — that's the
**Create New Space if Next Doesn't Exist** toggle in the menu, on by
default.

## Move windows between displays

| Shortcut | What it does |
| --- | --- |
| `Cmd + Shift + Ctrl + →` | Move the window to the next physical display |
| `Cmd + Shift + Ctrl + ←` | Move the window to the previous physical display |

The window's position and size are mapped proportionally onto the
destination display's visible area (excluding the menu bar and Dock), and
clamped to fit if the destination is smaller. Two displays: the shortcuts
toggle. Three or more: they cycle and wrap. One display: nothing happens,
and the icon flashes a warning.

## Snap windows to halves and quarters of the screen

| Shortcut | What it does |
| --- | --- |
| `Ctrl + Opt + ←` | Snap to the left half — press again for the top-left quarter, again for the bottom-left, again to restore |
| `Ctrl + Opt + →` | Snap to the right half — same cycle on the right side |
| `Ctrl + Opt + ↑` | Snap to the top half — press again to maximize, again to restore |
| `Ctrl + Opt + ↓` | Snap to the bottom half — press again to restore |

Quarters have no shortcut of their own: you reach them by pressing the
same left or right arrow again. So `Ctrl + Opt + ←` `Ctrl + Opt + ←`
lands the window in the top-left quarter, and a third press drops it to
the bottom-left. A fourth press puts the window back where it was
before you started tiling it.

The cycle is per window, and it resets whenever you move or resize the
window yourself — the next `Ctrl + Opt + ←` starts again from the left
half.

These exist as an easier-to-reach alternative to the built-in
`Fn + Ctrl + arrow`, which is awkward on non-Mac keyboards.

## Snap two windows side by side

| Shortcut | What it does |
| --- | --- |
| `Ctrl + Opt + Shift + arrow` | Snap this window to that side, and the previously-focused window to the opposite side |

This one always uses halves and never cycles into quarters, so you can
press it repeatedly without the pair coming apart.

Good for pairing an editor with a terminal, or a browser with a chat
window. MooOve tracks the most recently focused windows across every app.

## The menu-bar menu

Click the small rectangle icon to find:

- **Space X of Y** — where the current window's app lives.
- **Move Window to Previous / Next Space** — same as the shortcuts.
- **Move Window to Space** — jump to a specific Space, with the current
  one marked.
- **Move Window to Previous / Next Display** — no-op with one display.
- **Follow Window to Target Space** — on by default. Turn it off if you'd
  rather the window move silently while you stay put.
- **Create New Space if Next Doesn't Exist** — on by default. At the last
  Space, MooOve briefly opens Mission Control, clicks "+", closes it, and
  moves your window there. Takes about a second, and reuses the
  Accessibility permission MooOve already has.
- **Enable Window Tiling Shortcuts (⌃⌥ arrows)** — on by default. Turn it
  off to leave `Ctrl+Opt+arrow` to Rectangle, Magnet, or macOS's own
  window tiling.
- **Launch at Login**.
- **Accessibility Permission…** — opens System Settings, for when macOS
  loses the permission and things stop working.
- **About / Quit**.

## What the icon flash means

Every time you trigger a shortcut, the menu-bar icon flashes:

- **✓ check mark** — it worked.
- **⚠ warning triangle** — nothing happened. You're at the first or last
  Space, no window is focused, or MooOve doesn't have Accessibility
  permission.

## Notes for multi-display and multi-Space setups

- **Displays have separate Spaces.** With this enabled (System Settings →
  Desktop & Dock → Mission Control), MooOve operates on the display that
  owns the current window, counting each display's Spaces independently.
  Tiling snaps on the screen containing the window's center. Use
  `Cmd+Shift+Ctrl+←/→` to cross displays.

- **Space order.** If *"Automatically rearrange Spaces based on most
  recent use"* is on, macOS reshuffles your Spaces as you work. The
  arrow shortcuts still work, but Space 1 today may be a different
  desktop tomorrow. Turn it off for predictable numbering.

- **No Dock icon.** MooOve is a menu-bar accessory. It never appears in
  the Dock or in Cmd-Tab.

Something not working? See [troubleshooting](../troubleshooting/).
