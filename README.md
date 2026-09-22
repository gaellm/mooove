```bash
cowsay 'MooOve !!!'                                                                        
 ____________
< MooOve !!! >
 ------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
```

# MooOve

Move the window you're using to another macOS Space, to another
display, or snap it to a half or a quarter of the screen — all from the
keyboard, without touching the trackpad.

MooOve is a tiny menu-bar app. It doesn't open windows, it doesn't run
in the Dock, it doesn't send data anywhere. It does three things: it
moves the frontmost window between Spaces, it sends the frontmost
window to another attached display, and it snaps windows to halves and
quarters of the screen. All three are triggered by keyboard shortcuts.

(*"MooOve"* was previously named **SpaceMover**. If you have that older
build installed, `./build.sh --install` will replace it for you and
clear the old permission entries.)

## Why MooOve?

Because macOS hangs a lot of its window management off the `Fn` key —
`Fn + Ctrl + arrow` to tile a window to a half or a corner, `Fn + C` for
Mission Control, and the whole `Fn`-prefixed row of system commands —
and **`Fn` simply doesn't exist on most external keyboards**. Plug in a
mechanical, ergonomic, or plain PC keyboard and those commands become
unreachable. What's left is Mission Control, drag-and-drop, and the
trackpad.

MooOve replaces all of that with a handful of `Fn`-free shortcuts you
can reach with one hand: Spaces on `Shift+Ctrl`, displays on
`Cmd+Shift+Ctrl`, halves and quarters of the screen on `Ctrl+Opt`. Same muscle
memory on the built-in keyboard and on the external one — move any
window anywhere, with a keyboard reflex instead of a mouse trip.

## What you can do

### Move windows between Spaces

| Shortcut                 | What it does                                          |
| ------------------------ | ----------------------------------------------------- |
| `Shift + Ctrl + →`       | Move the current window to the next Space             |
| `Shift + Ctrl + ←`       | Move the current window to the previous Space         |
| `Shift + Ctrl + 1 … 9`   | Move the current window to Space 1 through 9          |

After the move, macOS automatically switches to the destination Space,
brings your window to the front, and gives it focus. You keep working
without a break.

The shortcuts don't wrap: if you're already on the last Space, pressing
`Shift+Ctrl+→` will (by default) add a new Space and move the window
there. That behavior is a toggle in the menu — see [Menu bar](#menu-bar).

### Move windows between displays

| Shortcut                  | What it does                                                     |
| ------------------------- | ---------------------------------------------------------------- |
| `Cmd + Shift + Ctrl + →`  | Move the current window to the **next** physical display         |
| `Cmd + Shift + Ctrl + ←`  | Move the current window to the **previous** physical display     |

The window's position and size are mapped proportionally onto the
destination display's visible area (menu bar / Dock excluded), and
clamped to fit if the destination is smaller. With two displays the two
shortcuts simply toggle between them; with three or more they cycle
through in order and wrap around at the ends. On a single-display Mac
the shortcut is a silent no-op (warning flash).

### Snap windows to halves and quarters of the screen

| Shortcut                 | What it does                                                    |
| ------------------------ | --------------------------------------------------------------- |
| `Ctrl + Opt + ←`         | Snap to the **left half**. Press again for the **top-left quarter**, again for the **bottom-left**, again to **restore** |
| `Ctrl + Opt + →`         | Snap to the **right half**, with the same cycle on the right side |
| `Ctrl + Opt + ↑`         | Snap to the **top half**. Press again to **maximize**, again to **restore** |
| `Ctrl + Opt + ↓`         | Snap to the **bottom half**. Press again to **restore**         |

Quarters don't get a shortcut of their own — you reach them by pressing
the same arrow again:

```
Ctrl+Opt+←        Ctrl+Opt+←        Ctrl+Opt+←        Ctrl+Opt+←
┌─────┬─────┐     ┌─────┬─────┐     ┌─────┬─────┐     ┌─────────┐
│     │     │     │█████│     │     │     │     │     │  where  │
│█████│     │  →  │█████│     │  →  ├─────┤     │  →  │ it was  │
│█████│     │     ├─────┤     │     │█████│     │     │ before  │
│     │     │     │     │     │     │█████│     │     │         │
└─────┴─────┘     └─────┴─────┘     └─────┴─────┘     └─────────┘
  left half      top-left quarter  bottom-left qtr.     restored
```

The cycle is tracked per window and resets as soon as you move or
resize the window yourself, so the next `Ctrl + Opt + ←` always starts
again from the left half.

These are meant as an easier-to-reach alternative to the macOS built-in
`Fn + Ctrl + arrow` shortcuts, which are awkward on non-Mac keyboards.

### Snap two windows side-by-side

| Shortcut                       | What it does                                                                 |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `Ctrl + Opt + Shift + arrow`   | Snap the current window to that side **and** the previously-focused window to the opposite side |

Perfect for pairing an editor with a terminal, a browser with a chat
window, etc. MooOve tracks the most recently focused windows across
every app. This shortcut always uses halves and never cycles into
quarters, so you can press it repeatedly without the pair coming apart.

## Menu bar

Click the small rectangle icon in the menu bar to see:

- **Space X of Y** — where the current window's app lives.
- **Move Window to Previous / Next Space** — same as the keyboard shortcuts.
- **Move Window to Space** — jump directly to a specific Space (with the
  current one marked).
- **Move Window to Previous / Next Display** — send the current window
  to another attached display (no-op with only one display).
- **Follow Window to Target Space** — on by default. Turn it off if you
  prefer the window to move silently while you stay where you are.
- **Create New Space if Next Doesn't Exist** — **on** by default. When
  you press `Shift+Ctrl+→` while you're already on the last Space,
  MooOve opens Mission Control briefly, presses the "+" button to add a
  new Space, closes Mission Control, and then moves your window there.
  The whole thing takes about a second and reuses the same Accessibility
  permission MooOve already needs. Turn it off if you'd rather have
  boundary presses do nothing.
- **Enable Window Tiling Shortcuts (⌃⌥ arrows)** — on by default. Covers
  both the halves and the quarters. Turn
  it off if you'd like `Ctrl+Opt+arrow` to be handled by another tool
  (e.g. Rectangle, Magnet, macOS built-in Window Tiling).
- **Launch at Login** — MooOve starts automatically when you log in.
- **Accessibility Permission…** — opens System Settings, in case macOS
  ever loses the permission and things stop working.
- **About / Quit**.

Every time you trigger a shortcut the icon briefly flashes:

- ✓ **check mark** — the action succeeded.
- ⚠ **warning triangle** — nothing happened (you're at the first/last
  Space, no window is focused, or MooOve doesn't have Accessibility
  permission).

## Install

**[Download the latest DMG](https://github.com/gaellm/mooove/releases/latest)**,
open it, and drag `MooOve.app` onto `Applications`.

The prebuilt DMG is **Apple Silicon, macOS 26+**, and it is *not*
notarized — macOS will refuse to open it the first time, and you have to
allow it once in **System Settings > Privacy & Security > Open Anyway**.
The [installation guide](https://gaellm.github.io/mooove/installation/)
walks through it. [Building from source](./DEVELOPER_GUIDE.md#building-from-source)
skips that step entirely.

The **first time** you use any shortcut, macOS will ask for Accessibility
permission. Click **Open Settings** in the alert, enable MooOve in the
list, then quit and reopen MooOve.

That's it — MooOve is now waiting quietly in your menu bar.

Full documentation: **<https://gaellm.github.io/mooove/>**

## Requirements

- **macOS 26** or later. Tested on macOS 26.4.
- **Apple Silicon.** The published DMG contains an arm64-only binary.
- Accessibility permission for MooOve (macOS will ask on first use).

Those are the requirements of the *download*. The macOS 26 floor comes
from how the app is currently built, not from anything the code is known
to need — most of it guards its newer calls with `if #available(macOS
13.0, *)`. Building from source on an older macOS, or for Intel, may
well work; it simply hasn't been verified. If you try it, please
[open an issue](https://github.com/gaellm/mooove/issues) and say whether
it worked — that's the missing data point for widening the supported
range.

## For developers

Building from source, how a release is cut, and why the app is signed the
way it is: see [`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md).

