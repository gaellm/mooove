# MooOve — Developer Guide

*(Previously named **SpaceMover**. The app was renamed after gaining the
window-tiling shortcuts; the internal `SpaceMover` class is still the
name of the Space-moving engine that the `MooOveApp` delegate wraps.)*

This document explains how the app is put together, why it uses the code
patterns it does, and where the sharp edges are. Read the top-level
`README.md` for the user-facing description.

## Contents

1. [Project layout](#project-layout)
2. [Runtime architecture](#runtime-architecture)
3. [The move pipeline, step by step](#the-move-pipeline-step-by-step)
4. [Window tiling and swap-tiling](#window-tiling-and-swap-tiling)
5. [Cross-display window moves](#cross-display-window-moves)
6. [Working with private Apple APIs](#working-with-private-apple-apis)
7. [Building, signing, permissions](#building-signing-permissions)
8. [Releasing](#releasing)
9. [Diagnosing problems](#diagnosing-problems)
10. [Design decisions, and mistakes to avoid](#design-decisions-and-mistakes-to-avoid)
11. [Future work](#future-work)

## Project layout

```
.
├── build.sh                          Developer build + install/uninstall.
│                                     Delegates compiling to scripts/build-macos.sh
├── Package.swift                     SwiftPM manifest (unused at runtime; kept
│                                     for editor integration and future SPM use)
├── scripts/
│   ├── build-macos.sh                Compile, assemble the bundle, stamp version
│   ├── create-dmg.sh                 Drag-to-Applications disk image
│   └── verify-release.sh             Check the build products before releasing
├── .github/workflows/
│   ├── ci.yml                        Build + verify on push and PR
│   ├── release.yml                   Tag-driven release, publishes the DMG
│   └── pages.yml                     Deploys docs/ to GitHub Pages
├── docs/                             User-facing site (install, usage,
│                                     troubleshooting). Not this document
├── Resources/
│   └── Info.plist                    Bundle metadata; LSUIElement=true so we
│                                     stay out of the Dock
└── Sources/
    └── MooOve/
        └── MooOveApp.swift           Everything: single-file app
```

Everything lives in one Swift file on purpose. The app is small, and
the private-API glue benefits from being read top-to-bottom in a single
place. If it grows past ~1500 lines it should be split.

## Runtime architecture

At the highest level:

```
┌─────────────────────────────────────────────────────────────────┐
│  MooOveApp (NSApplicationDelegate)                              │
│  ─ menu bar (NSStatusItem)                                      │
│  ─ global hotkey monitor (NSEvent.addGlobalMonitorForEvents)    │
│  ─ preferences (UserDefaults)                                   │
│  ─ launch-at-login (SMAppService)                               │
│  ─ FocusTracker (recency list of focused windows across apps)   │
└────────────────┬────────────────────────────────────────────────┘
                 │  performMove / performMoveToIndex /
                 │  performTile[Swap] / performDisplayMove
                 ▼
┌────────────────────┐  ┌──────────────────┐  ┌────────────────────┐
│  SpaceMover        │  │  WindowTiler     │  │  DisplayMover      │
│  (Spaces engine)   │  │  (halves engine) │  │  (cross-display)   │
│                    │  │                  │  │                    │
│  context()         │  │  tile(region:)   │  │  move(direction:)  │
│    focused win     │  │  tile(window:…)  │  │    focused win     │
│  + display UUID    │  │                  │  │  + NSScreen list   │
│  + Space list      │  │  Public AX only  │  │  + wrap-around     │
│  + current index   │  │  (position/size  │  │  + proportional    │
│                    │  │  on the focused  │  │    frame mapping   │
│  move() → moveWin  │  │  AXUIElement).   │  │                    │
│       → follow…()  │  │                  │  │  Public AX only.   │
└──────────┬─────────┘  └──────────────────┘  └────────────────────┘
           │  dlsym-bound function pointers
           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Private frameworks resolved at runtime                         │
│  ─ SkyLight    (Spaces enumeration, bridged window op)          │
│  ─ HIServices  (_AXUIElementGetWindow, GetProcessForPID,        │
│                 _SLPSSetFrontProcessWithOptions)                │
└─────────────────────────────────────────────────────────────────┘
```

There is exactly one `SpaceMover`, one `WindowTiler`, and one
`DisplayMover` instance, all held by the app delegate. Only `SpaceMover`
touches private symbols; `WindowTiler` and `DisplayMover` are pure
Accessibility clients and would keep working even if every SkyLight
symbol vanished. All private-API bindings are top-level `let`s so
they're resolved lazily the first time they're read, and any that fail
to resolve become `nil` instead of crashing the app (see
[dlsym section](#loadsymbol-and-requiresymbol)).

### Entry point — do not trust `@main` alone

Swift's `@main` on `NSObject: NSApplicationDelegate` does **not** wire up
AppKit for you. The process launches, hits its synthesized `main`, and
exits (or returns to a stub runloop) without ever calling
`applicationDidFinishLaunching`. We therefore provide an explicit
`static func main()`:

```swift
@main
final class MooOveApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = MooOveApp()
        app.delegate = delegate
        _ = Unmanaged.passRetained(delegate)  // keep delegate alive
        app.run()
    }
    ...
}
```

Without this, the menu bar item was created in code but never appeared
because `applicationDidFinishLaunching` was never called. This is the
biggest single "why doesn't it work?" trap in the whole file.

## The move pipeline, step by step

A single Shift+Ctrl+→ press triggers this sequence, all in `SpaceMover`:

### 1. Gather context

`context()` returns `nil` on any failure, which is what causes the
menu bar icon to flash a warning triangle instead of a check mark.

- Verify Accessibility permission (`AXIsProcessTrusted`).
- Get the frontmost app via `NSWorkspace.shared.frontmostApplication`.
- Ask Accessibility for that app's `kAXFocusedWindowAttribute`.
- Convert the `AXUIElement` to a `CGWindowID` via the private
  `_AXUIElementGetWindow`. This is the single most important bridge
  between the Accessibility world and the WindowServer world.
- Ask SkyLight which display the window lives on
  (`SLSCopyManagedDisplayForWindow`), fetch all Spaces on that display
  (`SLSCopyManagedDisplaySpaces`), and locate the current one
  (`SLSManagedDisplayGetCurrentSpace`).

We keep the AXUIElement, the owner PID, the SkyLight display UUID, and
the array of Spaces around for the whole operation.

### 2. Compute the target Space

- For `.previous / .next`: adjust the current index by ±1. If out of
  bounds, return `.noop` (this is what the warning triangle flash after
  a boundary means; on purpose, no beep).
- For `move(toIndex:)`: use the index directly; if it's the current
  Space, return `.noop`.

Extract the ManagedSpaceID of the target via `spaceID(_:)`, which is
resilient to whether SkyLight returns UInt64s, NSNumbers, or Ints
(different macOS versions have used different representations).

### 3. Move the window

`moveWindow(_:toSpace:)` builds an
`SLSBridgedMoveWindowsToManagedSpaceOperation` instance and hands it to
the WindowServer. Three code paths are tried, in this order:

1. **`SLSPerformAsynchronousBridgedWindowManagementOperation`** — the
   direct C entry point. On macOS 26 this symbol is marked with
   internal linkage (`_ZL54…`), so `dlsym` can't reach it, and we fall
   through.
2. **`[[SLSWindowManagementFallbackBridge new] performAsynchronousBridgedWindowManagementOperation:op]`**
   — an Objective-C wrapper that Apple exposes as regular (non-mangled)
   selectors. This is the path that runs on macOS 26.
3. **`[op invokeFallback]`** — synchronous last-resort fallback baked
   into the operation class itself.

The operation is allocated via NSClassFromString + `alloc` +
`initWithWindows:spaceID:`, sent via a private `objc_msgSend`
declaration with the exact signature we need. Swift 6 no longer exposes
the variadic `objc_msgSend`, hence the `@convention(c)` shim.

### 4. Follow the window (`followByActivatingApp`)

This is where SpaceMover feels sanctioned rather than hacky.

On macOS 14+ Apple has essentially locked down programmatic Space
switching from client processes. `CGSManagedDisplaySetCurrentSpace`
updates internal state (you can see the wallpaper change) but nothing
composites, so users are still visually on the old Space. Synthesizing
`Ctrl+←/→` via `CGEvent` does animate correctly, but it fights the
user's own modifier state and can retrigger our own hotkey monitor.

Instead we use a built-in macOS behavior:

> Activating an app whose main window lives on another Space makes
> macOS follow to that Space to reveal the window.

So after the SkyLight move settles (~80 ms), we:

1. Set the moved window as `AXMain` + `AXFocused` on its owner app.
   Without this, the OS might follow the app to a *different* window
   the app already has open on another Space.
2. Call `NSRunningApplication.activate(...)`. macOS animates to the
   target Space (~300 ms).
3. After ~350 ms — the Space animation is done — call
   `promoteToFront(...)` which uses the private
   `_SLPSSetFrontProcessWithOptions` (same API the Dock uses when you
   click an icon) to promote our window over whatever app was
   previously frontmost on that Space. Two calls, one with option
   `0x200` (raise just this window), one with `0x100` (raise the app's
   siblings too), matching the pattern yabai/AeroSpace use.
4. `AXRaise` + `AXMain` + `AXFocused` one more time, so the window
   also sits on top inside its own app's window stack.

Total: about 750 ms from key press to "you're there, window in front,
focus ready to type into". Fast enough to feel responsive, slow enough
to avoid every race.

### 5. Report result

`MoveResult` is `.success`, `.noop`, or `.failure`. The status item
briefly flashes the appropriate icon; no sound, no notification. On
purpose — see the design decisions section.

### 5b. Optional: create a new Space when there isn't one

When the user has **Create New Space if Next Doesn't Exist** enabled
(the default) and `move(.next)` returns `.noop` because the current
Space is already the last one on the display,
`MooOveApp.performMove(_:)` calls
`MissionControlSpaceCreator.createNewSpace(onDisplay:) { … }` with the
managed-display UUID of the focused window's display and, on success,
retries the move.

macOS has no public API to add a Space, and `SLSSpaceCreate` alone
doesn't produce a user-visible Space on macOS 13+ without a Dock
restart. The reliable approach — the same one Hammerspoon's
`hs.spaces.addSpaceToScreen` uses — is to drive the Dock's own Mission
Control UI through the Accessibility API.

The Dock exposes a stable identifier hierarchy for Mission Control on
macOS 13, 14, 15, and 26:

```
AXApplication (com.apple.dock)
  └── ... AXIdentifier = "mc"
        └── AXGroup    AXIdentifier = "mc.display", AXDisplayID = <CGDirectDisplayID>
              └── AXGroup   AXIdentifier = "mc.spaces"
                    ├── AXGroup   AXIdentifier = "mc.spaces.list"
                    └── AXButton  AXIdentifier = "mc.spaces.add"     ← target
```

The full recipe in `MissionControlSpaceCreator`:

There is one `mc.display` group, and so one "+" button, per display.
Searching the whole tree finds the main display's button first, which
adds the Space to the wrong screen when the window is on another one.

1. **Snapshot** the target display's Space count with
   `SLSCopyManagedDisplaySpaces` so we have a `before` value to compare
   against later.
2. **Open Mission Control** — call the private
   `CoreDockSendNotification("com.apple.expose.awake", 0)` (the same
   notification `Dock.app` sends when the user presses F3). If the
   symbol isn't resolvable on the current macOS, fall back to
   `NSWorkspace.openApplication(at: /System/Applications/Mission
   Control.app)`.
3. **Poll** the Dock's AX tree every 100 ms (up to 1.5 s total) for an
   element with `AXIdentifier == "mc.spaces.add"`, searching only under
   the target display's `mc.display*` group. That group is matched by
   `AXDisplayID` (the display UUID resolved to a `CGDirectDisplayID`
   via `CGDisplayCreateUUIDFromDisplayID`) or by an identifier that
   contains the UUID. If the group can't be found the whole Dock is
   searched only when there is a single screen, or when the display is
   `"Main"` (*Displays have separate Spaces* off: one shared Space list). Polling instead of
   a fixed sleep matters: fast Macs surface the button in ~200 ms,
   slower ones can take ~800 ms. Fallbacks (in order):
   1. Exact identifier match `mc.spaces.add`.
   2. `AXButton` whose identifier starts with `mc.spaces.add` (per-display
      suffix variants Apple has shipped occasionally).
   3. Fuzzy `AXDescription`/`AXHelp`/`AXTitle` match for `add_desktop`,
      `add_space`, `"New Desktop"`, `"New Space"`.
4. **Press** the button with `AXUIElementPerformAction(kAXPressAction)`.
   No pixel coordinates: layout changes across macOS releases don't
   break us as long as the button is exposed to AX.
5. **Wait ~600 ms** for the new-Space animation, then dismiss Mission
   Control (re-send the awake toggle and post an Escape key), wait
   one more animation tick, and re-count Spaces. Success = the
   target display's count grew.
6. On success the app runs `move(.next)` again — which now finds a
   real next Space — and shows the usual success/failure feedback.

Failure modes surface in the logs (`MissionControl: could not find the
'+' button (timed out); dumping Dock AX tree` followed by a depth-4
tree dump of the Dock process). To the user they only look like the
standard warning-triangle flash. This preserves the "no sound, no
notification" rule while still giving debuggers something to grep.

**Do not** attempt to click by pixel coordinates. Coordinate-based
clicks broke on every second Ventura/Sonoma/Sequoia point release
during prototyping.

**Do not** switch to a direct `SLSSpaceCreate` call. The symbol exists
and is dlsym-reachable, but on macOS 13+ the Dock does not pick the
new Space up until it is restarted (`killall Dock`), which flashes the
menu bar, drops menu-extras owned by Dock, and is visibly disruptive.
The AX approach reuses the Accessibility permission the app already
has and is invisible except for the short Mission Control animation.

## Window tiling and swap-tiling

The Ctrl+Opt+arrow / Ctrl+Opt+Shift+arrow shortcuts are handled by the
`WindowTiler` and `FocusTracker` classes. They deliberately use **only**
the public Accessibility API — no SkyLight, no CoreDock — because
resizing a focused window is exactly the use case AX was designed for.

### `WindowTiler`

Given a `Region` (`.left`, `.right`, `.top`, `.bottom`) it:

1. Reads the focused `AXUIElement` from the frontmost app.
2. Finds the `NSScreen` whose visible frame contains the window's
   *center* (multi-monitor: the window "belongs" to whichever screen it
   sits mostly on, not to `NSScreen.main`).
3. Converts `NSScreen.visibleFrame` from AppKit's bottom-left global
   coordinate space into AX's top-left space (origin at the top of the
   primary display).
4. Computes the target frame, then applies it via
   `setPosition → setSize → setPosition` — the second `setPosition` is
   there because some apps clamp `setSize` results relative to the
   current position (Rectangle and Magnet use the same trick).

A per-CGWindowID `WindowMemo` remembers the pre-tile frame and the last
tile state, which is what makes repeated presses cycle:

- Left  → left half → top-left quarter → bottom-left quarter → restore
- Right → right half → top-right quarter → bottom-right quarter → restore
- Up    → top half → maximized → restore
- Down  → bottom half → restore

Quarters deliberately have no shortcut of their own — they sit on the
second and third press of the arrow that already snaps to that side.
That makes the memo's accuracy matter more than it used to: before, a
stale entry only affected Up/Down, and now a memo left over from an
hour ago would send `⌃⌥←` to a quarter instead of the half the user
expected. So `WindowMemo` also records the frame it requested and the
frame the window reported back, and `stillTiled(at:)` resets the cycle
when the window has since been moved or resized by hand. Both frames
are kept because apps clamp our request (minimum sizes, terminal
character grids) or report a mid-animation frame on the read right
after the set — matching either one counts as untouched.
The halves and quarters share one set of edge values (`leftX`/`rightX`,
`topY`/`bottomY`, `halfW`/`halfH`), with the trailing half pinned to the
trailing edge, so `floor` rounding can't leave a one-point gap on a
display with an odd-numbered visible width or height.

The public `tile(region:allowCycle:)` targets the front window; a
lower-level `tile(window:wid:region:allowCycle:)` targets a specific
`AXUIElement`. `allowCycle: false` snaps straight to the half and skips
the cycle; the swap-tile shortcut passes it for *both* windows, so
holding ⌃⌥⇧← doesn't walk the front window into a quarter and break the
side-by-side pairing.

### `FocusTracker`

The swap-tile shortcut needs "the window that was focused before the
current one". `FocusTracker` maintains a small recency list by
subscribing to `NSWorkspace.didActivateApplicationNotification` and
capturing the newly-activated app's focused `AXUIElement` +
`CGWindowID`. Details worth knowing:

- **Dedup by CGWindowID.** Re-activating the same window (Cmd-Tab
  round-trip, click on the current app in the Dock) mustn't discard
  the previous entry — that's exactly the window we need to tile to
  the opposite half.
- **Skip our own process.** The menu bar item isn't a tileable window;
  activating MooOve should not push it to the top of the list.
- **AX elements go stale.** When an app quits, its `AXUIElement`
  handles still exist as objects but every attribute read fails.
  `FocusTracker.refresh(_:)` verifies the pid is alive and, on the
  slow path, re-derives the current focused window from `kAXWindows`.
- The tracker also re-reads `frontmostApplication`'s focused window
  every time `recentEntries()` is called, to catch focus changes
  *within* an app that don't trigger an activation notification (e.g.
  clicking one of that app's other windows).

## Cross-display window moves

The ⌘⇧⌃←/→ shortcut is handled by `DisplayMover`. Like `WindowTiler`,
it uses **only** the public Accessibility API — no SkyLight, no
CoreDock, no private symbols. Moving a window from one physical display
to another is exactly what `setPosition` / `setSize` were designed for.

### Why this is simpler than the Space-move pipeline

Space moves have to fight the WindowServer: the target Space lives in a
separate compositor context, so we need SkyLight to enqueue a bridged
move operation, then activate the owner app to make macOS animate to
the new Space, then use `_SLPSSetFrontProcessWithOptions` to promote
the window over whichever app was previously frontmost there.

Cross-display moves have none of that:

- The destination display shares the WindowServer's coordinate space
  with the source (they're both live monitors), so `AXPosition` +
  `AXSize` are enough — no bridged operation, no display UUID lookup.
- Focus does not change: the window stays inside its owning app / PID,
  and that app was already frontmost. We *do* re-set `AXMain` +
  `AXFocused` after the frame update because a handful of apps
  otherwise mark a sibling window as focused when their focused window
  jumps geometrically — a belt-and-braces call, not required.
- macOS handles the Space semantics for free: if *Displays have
  separate Spaces* is on, dropping the window inside display B's
  visible frame automatically enrols it in whichever Space is currently
  showing on display B; if that setting is off, the window simply
  straddles / crosses to the new display without any Space change.

### The algorithm

`DisplayMover.move(direction:)`:

1. Read the focused `AXUIElement` from the frontmost app.
2. Read its AX frame (position + size, top-left origin).
3. Find the source `NSScreen`:
   - Preferred: the screen whose visible frame contains the window's
     center (same rule as `WindowTiler`).
   - Fallback: `bestOverlapScreenIndex(for:in:)` picks the screen with
     the largest intersection area with the window, which matters for
     fully off-screen or partially-hidden windows that would otherwise
     make step 3 return nil.
   - Ultimate fallback: index 0. Rare — only reached if the window has
     zero area, which is already broken.
4. Pick the target with wrap-around: `(idx + 1) mod n` for `.next`,
   `(idx - 1 + n) mod n` for `.previous`. With `n == 1` the target
   equals the source and we return `.noop` (silent warning flash — the
   same UX as pressing next-Space when you're already at the last one).
5. Convert the source and destination `NSScreen.visibleFrame` values to
   AX coordinates (top-left origin, primary-screen top). The helper is
   duplicated from `WindowTiler` on purpose — both classes have exactly
   two callers and inlining beats introducing a shared coordinates
   utility with a single method.
6. Compute the mapped frame proportionally:
   ```
   relX = (frame.x - source.x) / source.width
   relY = (frame.y - source.y) / source.height
   relW =  frame.width  / source.width
   relH =  frame.height / source.height

   newW = min(relW * dest.width,  dest.width)
   newH = min(relH * dest.height, dest.height)
   newX = clamp(dest.x + relX * dest.width,  dest.x, dest.maxX - newW)
   newY = clamp(dest.y + relY * dest.height, dest.y, dest.maxY - newH)
   ```
   Size is capped at the destination's visible frame so a window from a
   32" 4K doesn't spill off a 13" MacBook. Position is clamped so the
   result never leaves the visible frame — no half-window landing
   under the menu bar or behind the Dock.
7. Apply the frame via the same `setPosition → setSize → setPosition`
   dance as `WindowTiler` (some apps clamp size relative to the current
   position).

### What it does *not* do

- **It doesn't pick a Space on the target display.** The window lands
  on whichever Space is currently visible on the destination. To land
  on a specific Space there, move to the display first (⌘⇧⌃→) and then
  walk Spaces (⇧⌃→). A future `SLSMoveWindowsToManagedSpaceOnDisplay`
  binding could do both in one shot; see [Future work](#future-work).
- **It doesn't remember the pre-move frame.** Unlike `WindowTiler`
  (which needs `WindowMemo` for the maximize-then-restore cycle),
  `DisplayMover` has no cycling behaviour: repeatedly pressing ⌘⇧⌃→ on
  a two-display setup just toggles back and forth, which is already
  reversible without any state.
- **It doesn't touch focus / raise / activation.** Same app is still
  frontmost, same window is still focused; the only side effect is a
  frame change.

## Working with private Apple APIs

### `loadSymbol` and `requireSymbol`

There are two failure modes for private symbols: "the symbol simply
does not exist on this OS release" (should degrade gracefully) and
"the symbol is fundamental and its absence means we're on the wrong
platform" (should crash).

```swift
private func loadSymbol<T>(...)     -> T?  // returns nil on miss
private func requireSymbol<T>(...) -> T   // fatalError on miss
```

`requireSymbol` is only used for `objc_msgSend`, `_AXUIElementGetWindow`,
and `GetProcessForPID` — if any of these are missing, macOS itself is
broken.

Everything SkyLight is `loadSymbol` because Apple renames these APIs
freely. The `SkyLight` enum holds all these as static optional
function-pointer properties, resolved lazily at first access. Consumers
must check for `nil`.

### Do not put a Swift body under `@_silgen_name`

`@_silgen_name("foo")` gives your Swift function the *symbol name*
`foo`. If the function has a body, the compiler emits that body under
the C symbol name, **shadowing** the real implementation.

The very first version of this file did:

```swift
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(...) -> AXError {
    return .failure          // <-- WRONG
}
```

The app compiled fine. Every call returned `.failure`, `focusedWindow()`
returned `nil`, every move was silently rejected. The app looked
completely dead.

**Do not reintroduce this pattern.** Use `dlsym` via `loadSymbol`
instead — it's boring but it's unambiguous.

### Objective-C bridge under Swift 6

Swift 6 no longer exposes a variadic `objc_msgSend`. When we need to
call an Objective-C method whose signature Swift doesn't know, we
declare the exact ABI:

```swift
typealias InitFn = @convention(c) (
    AnyObject,      // self
    Selector,       // _cmd
    AnyObject,      // arg1
    UInt64          // arg2
) -> AnyObject

let initFn: InitFn = spacemover_objc_msgSend
let operation = initFn(alloc, initSel, windows, spaceID)
```

`spacemover_objc_msgSend` itself is a `loadSymbol("objc_msgSend", …)`,
i.e. a runtime dlsym. This is safer than `@_silgen_name`.

### Private symbols aren't necessarily in a public spot

We inspect `/System/Library/PrivateFrameworks/SkyLight.framework/…`
during development but the framework's binary is only present inside
the dyld shared cache on modern macOS — `nm` on the raw file will find
nothing. Symbols are still reachable at runtime through `dlsym` as
long as the framework is loaded into the process (any AppKit app has
SkyLight loaded implicitly).

A helper C program that walks `_dyld_get_image_header` for SkyLight
and reads its symbol table via `LC_SYMTAB` can enumerate what's
available; see git history for the throwaway script used to discover
`_SLPSSetFrontProcessWithOptions` on macOS 26.

## Building, signing, permissions

### Building from source

You need the Xcode Command Line Tools (`xcode-select --install`). There
are no other dependencies — no SwiftPM fetch, no CocoaPods, no Homebrew
package (except `create-dmg`, and only when packaging a release).

```bash
git clone https://github.com/gaellm/mooove.git
cd mooove
./build.sh --install
open /Applications/MooOve.app
```

`./build.sh` on its own builds `MooOve.app` into the repo without
installing it, which is enough for a quick `open MooOve.app` test.

A locally built app is never quarantined, so it skips the Gatekeeper
prompt that users of the downloadable DMG have to click through.

### `build.sh`

The compile-and-assemble step lives in `scripts/build-macos.sh`, which
`build.sh` calls. That indirection exists so the release workflow and the
developer script cannot drift: there is exactly one `swiftc` invocation
in the repo. Everything else in `build.sh` — installing, uninstalling,
the TCC housekeeping below — is developer convenience and is not part of
a release.

Three modes:

- `./build.sh` — build only, produces `MooOve.app` in the repo.
- `./build.sh --uninstall` — remove MooOve cleanly (bundle, Login
  Item, TCC approvals, preferences). See
  [`--uninstall`](#--uninstall) below for why the individual steps
  matter.
- `./build.sh --install` — build, then replace `/Applications/MooOve.app`
  in place with all the housekeeping done properly:

  - Kill any running instance (both `MooOve.app` and any legacy
    `SpaceMover.app`).
  - Remove any legacy `/Applications/SpaceMover.app` and stray copies
    found via `mdfind -name SpaceMover.app`, then reset the legacy TCC
    entries under `com.gael.SpaceMover`. Users upgrading from the
    previous name would otherwise end up with two apps fighting over
    the same shortcuts.
  - Find and remove duplicate `MooOve.app` bundles anywhere on the
    filesystem (`mdfind -name MooOve.app`). Duplicates with the same
    bundle ID but different ad-hoc signatures confuse TCC — the app
    becomes invisible in the Accessibility list.
  - Copy the new bundle to `/Applications`, strip the quarantine
    attribute if present, ad-hoc sign in place.
  - Re-register with LaunchServices (`lsregister -f -R`).
  - If duplicates were removed, reset TCC's Accessibility approval for
    the bundle ID (`tccutil reset Accessibility com.gael.MooOve`).
  - Skip the actual copy if the newly compiled binary is byte-identical
    to the installed one (in practice this almost never triggers,
    because the Swift compiler embeds build-time-varying metadata).

Optional: `./build.sh --install --reset-permissions` to force a TCC
reset even without duplicates.

### The Accessibility permission problem

TCC keys Accessibility approvals on the **CDHash** of the specific
binary at the app path. Ad-hoc signatures (`codesign --sign -`) derive
their CDHash from the binary contents, so **every rebuild produces a
new CDHash** and macOS treats the app as brand new. Result: the
Accessibility toggle in Settings looks correct (it shows "MooOve"
enabled), but the approval doesn't apply to the new binary, and macOS
silently re-prompts.

Three options to get around this, in order of ambition:

1. **Live with it.** Grant permission once per meaningful change; the
   permission sticks between launches of the *same* binary. This is
   what MooOve currently does.

2. **Sign with a self-signed cert** created in `Keychain Access.app`
   (the CLI `security import` may be blocked on MDM-managed Macs).
   TCC then keys on the signing identity, and rebuilds keep the
   approval. Requires manual keychain setup and a change to
   `codesign --sign MooOveDev` in `build.sh`.

3. **Real Apple Developer ID.** $99/year, but everything just works
   forever.

### `--install` and TCC — deliberate reset only

`build.sh --install` does *not* reset TCC on every install; it only
does so when it removed a duplicate. Without duplicates, the freshly
installed binary has a new CDHash but the same install path — TCC's
stale approval row will be silently ignored, and the new binary will
be re-prompted. This is by design: resetting on every install would
train the user to click through the permission dialog, defeating its
purpose.

### `--uninstall`

`build.sh --uninstall` removes MooOve completely and, importantly,
clears the residual state that a naive `rm -rf /Applications/MooOve.app`
leaves behind — the main complaint being *"I deleted the app but it
still shows up in System Settings > Privacy & Security > Accessibility"*.

The uninstaller cleans up both the current `com.gael.MooOve` bundle and
the legacy `com.gael.SpaceMover` bundle so upgraders end up with no
leftover TCC rows.

It does, in order:

1. **Kill running instances** with `pkill` (both current and legacy).
2. **Ask each app to unregister its Login Item** — spawns the
   still-installed binary with `--unregister-login-item`, which calls
   `SMAppService.mainApp.unregister()` and exits. Doing this *before*
   deleting the bundle is important: `SMAppService` needs the app to
   exist on disk to unregister it cleanly.
3. **Delete every `MooOve.app` and legacy `SpaceMover.app` bundle**
   found via `mdfind` (not just `/Applications`), so stray copies in
   `~/Downloads` etc. don't leave TCC pointing at a missing binary.
4. **Bounce `backgroundtaskmanagementagent`** with `killall -HUP` and
   run `lsregister -u` so the Login Items panel forgets the deleted
   bundle instead of leaving it greyed-out.
5. **Clear TCC approvals by bundle ID** for both IDs —
   ```
   tccutil reset Accessibility com.gael.MooOve
   tccutil reset ListenEvent   com.gael.MooOve   # Input Monitoring
   tccutil reset AppleEvents   com.gael.MooOve
   tccutil reset PostEvent     com.gael.MooOve
   # ...and the same four resets for com.gael.SpaceMover (legacy)
   ```
   `tccutil` operates on the bundle ID, not the binary path, so it
   works even after the app is deleted. This is the step that answers
   "why is the app still listed in Privacy & Security after I deleted
   it?" — the TCC database keeps its row keyed by bundle ID until
   something explicitly resets it.
6. **Delete `~/Library/Preferences/com.gael.MooOve.plist`** (plus the
   legacy `com.gael.SpaceMover.plist`) and run `defaults delete` for
   both so no follow / create-new / tiling / launch-at-login preference
   survives.
7. **Nudge LaunchServices** with a full `lsregister -kill -r` so
   Spotlight, "Open With", and the Login Items panel stop advertising
   the deleted bundle.

Some UI panes (specifically System Settings > General > Login Items)
cache their state until the next session; a log-out/log-in cycle
guarantees a clean slate but is rarely necessary.

## Releasing

Releases are built by GitHub Actions from a tag, but every step is a
script under `scripts/` that CI calls unchanged. You can therefore
reproduce a release on a laptop before pushing anything:

```bash
./scripts/build-macos.sh --version 1.1.0   # -> dist/MooOve.app
./scripts/create-dmg.sh                    # -> dist/MooOve-1.1.0.dmg
./scripts/verify-release.sh --expect-version 1.1.0
```

`verify-release.sh` is the one worth running habitually. It catches the
failures that produce a *downloadable* but broken release: a bundle
claiming the wrong version, a binary for the wrong architecture, a seal
broken by copying the bundle after signing, a changed bundle identifier
(which would silently invalidate every existing user's Accessibility
approval), or a DMG with no `/Applications` symlink to drag onto.

To publish:

```bash
git tag v1.1.0
git push origin v1.1.0
```

`.github/workflows/release.yml` then builds, packages, generates
`SHA256SUMS`, and creates the GitHub Release with the DMG attached. A tag
containing a hyphen — `v1.1.0-rc.1` — is published as a prerelease, which
makes it a cheap way to exercise the whole pipeline without the result
sitting at the top of the releases page.

### Where the version number comes from

The tag, not `Resources/Info.plist`. `build-macos.sh` reads
`GITHUB_REF_NAME`, strips the leading `v`, and stamps
`CFBundleShortVersionString` into the *copy* of the plist inside the
built bundle. The source plist is never modified, so CI never dirties the
working tree, and the plist value serves only as a fallback for local
builds that pass no `--version`.

`CFBundleVersion` gets `GITHUB_RUN_NUMBER`, or `1` locally.

### Why the DMG has two code paths

`create-dmg.sh` prefers the `create-dmg` Homebrew tool, which produces
the classic layout: volume icon, positioned app icon, `/Applications`
shortcut beside it. It achieves that by driving Finder over AppleScript,
which is the single most fragile thing in the pipeline on a headless CI
runner.

So the script falls back to plain `hdiutil` when `create-dmg` is missing
or fails. The fallback image has Finder's default window layout but is
functionally identical — app and `/Applications` symlink, side by side.
Cosmetics are not worth failing a release over.

### Runner pinning

CI pins `macos-26` rather than `macos-latest`. `Package.swift` declares
`.macOS(.v26)`, so the build needs that SDK, and `macos-latest` is a
moving label that has repointed before. See also the open question in
[Future work](#future-work) about whether that floor is actually needed.

### Signing and notarization

Releases are currently **ad-hoc signed** (`codesign --sign -`), because
notarization requires a paid Apple Developer Program membership. Two
consequences, both user-visible:

- macOS refuses to open the downloaded app until the user allows it in
  System Settings > Privacy & Security. `docs/installation.md` walks
  through this, and it is the single most common support question for
  any unnotarized Mac app.
- Every release has a different CDHash, so **Accessibility approval does
  not survive an update** — see [The Accessibility permission
  problem](#the-accessibility-permission-problem). A Developer ID
  identity is stable across builds, so signing properly would fix this
  outright, not merely hide the Gatekeeper prompt.

`release.yml` already contains the certificate import, `--options
runtime` signing, `notarytool submit --wait` and `stapler staple` steps.
They skip themselves while the secrets are unset, so enabling the whole
path is purely a matter of adding these repository secrets:

```
APPLE_SIGNING_IDENTITY         "Developer ID Application: Name (TEAMID)"
APPLE_CERTIFICATE_P12_BASE64   base64 of the exported .p12
APPLE_CERTIFICATE_PASSWORD     the .p12 export password
APPLE_ID                       Apple account email
APPLE_TEAM_ID                  10-character team identifier
APPLE_APP_SPECIFIC_PASSWORD    app-specific password, not the account one
```

Notarization submits the **DMG**, which covers the app inside it — one
submission, not two — and then staples the ticket to the DMG so first
launch works offline.

Never commit the certificate, the `.p12` password, or an app-specific
password. Secrets are also unavailable to workflows triggered by pull
requests from forks, which is another reason the signing steps live only
in the tag-triggered release workflow.

## Diagnosing problems

All app-level logging uses `OSLog` with subsystem `com.gael.MooOve`
and category `app`. Live-tail from a terminal:

```bash
log stream --predicate 'subsystem == "com.gael.MooOve"' --info --debug
```

Show the last minute after the fact:

```bash
log show --last 1m --predicate 'subsystem == "com.gael.MooOve"' \
  --info --debug
```

Key lines to look for:

| Log line                                              | Meaning                                                          |
| ----------------------------------------------------- | ---------------------------------------------------------------- |
| `main() entered`                                      | Our `static func main()` ran. If missing, `@main` didn't wire up. |
| `applicationDidFinishLaunching`                       | AppKit is up. If missing, something above blocked it.            |
| `status item created, visible=true, length=-1`        | Menu bar item is installed. If length is 0, it's invisible.      |
| `global hotkey monitor installed`                     | `NSEvent.addGlobalMonitorForEvents` returned a non-nil monitor.  |
| `keyDown seen: keyCode=…`                             | The global monitor received a key event.                         |
| `hotkey matched: keyCode=…`                           | The modifier mask matched our shortcut.                          |
| `symbol X not found`                                  | A `loadSymbol` call returned nil. Move may fall through fallbacks.|
| `SkyLight query symbols unavailable on this macOS`   | Fundamental SkyLight enumeration APIs missing. Move impossible. |
| `promoteToFront: GetProcessForPID failed for pid …`   | Legacy Process Manager rejected the PID. Front-raise skipped.    |
| `promoteToFront: _SLPSSetFrontProcessWithOptions unavailable` | Private front-raise API renamed. Window will stay behind.        |
| `performMove: direction=next, result=noop, createIfMissing=…, spaceInfo=N/T` | Per-move state. `createIfMissing=false` means the toggle is off; `spaceInfo=N/T` with `N < T-1` means we aren't at the last Space. Both suppress the automation. |
| `no next Space, attempting to create one via Mission Control` | User has the "create if missing" pref on; automation started.    |
| `MissionControl: sent com.apple.expose.awake`         | Mission Control was opened via CoreDockSendNotification.         |
| `MissionControl: matched AXIdentifier=mc.spaces.add`  | Fast-path button lookup succeeded.                               |
| `MissionControl: matched AXIdentifier prefix mc.spaces.add` | Apple suffixed the identifier per-display; the prefix matcher caught it. |
| `MissionControl: matched via fuzzy description/help/title` | Identifier not found; we fell back to a localized string match.   |
| `MissionControl: pressed '+' button`                  | `AXPress` on the add-Space button returned success.              |
| `MissionControl: could not find the '+' button (timed out); dumping Dock AX tree` | AX walk of the Dock didn't find an add-Space button. A depth-4 tree dump follows in the log. |
| `MissionControl: space count N -> M`                  | Verification after the automation. `N < M` means success; equal counts mean the press didn't take effect (rare; usually a stale Dock state). |
| `DisplayMover: only one display attached`             | ⌘⇧⌃←/→ pressed on a single-display Mac. Silent warning flash, no move attempted. |
| `DisplayMover: no focused window (rc=…)`              | AX couldn't return `kAXFocusedWindowAttribute`. Usually a Finder/full-screen edge case; the shortcut becomes a no-op. |
| `DisplayMover: moved focused window from display N -> M of K` | Success. `N` and `M` are indices into `NSScreen.screens`; `K` is the total display count. |

### The four classic failure modes

1. **App icon doesn't appear.** Menu bar is full (notch on MacBook +
   many icons). Cmd-drag icons to rearrange, or hide something else
   temporarily.

2. **Shortcut does nothing.** No `keyDown seen: …` in the log means
   the global monitor isn't receiving events. Usually: Accessibility
   granted after the app started, so the OS hasn't re-attached the
   event tap. Fix: quit and relaunch MooOve.

3. **Window moves but Space doesn't switch.** Wallpaper changes but
   you stay put. `CGSManagedDisplaySetCurrentSpace` (which we don't
   call anymore) leaked into your setup somehow; make sure the current
   code uses `followByActivatingApp`.

4. **App re-prompts for Accessibility every time you rebuild.** See
   [Building, signing, permissions](#building-signing-permissions).

## Design decisions, and mistakes to avoid

### One file, no framework, no dependencies

Adding SPM dependencies would make `build.sh` more complex and
introduce version pinning. The whole app is under 1000 lines. Split
only if it grows past 1500-ish.

### No sounds, no notifications

Users move windows *between Spaces*, meaning they're already going to
look at another Space in half a second. A sound is annoying and a
notification banner is silly. The icon flash is enough feedback for
success/failure; users learn it in seconds.

If this ever needs revisiting, keep both options behind a preference
and default to icon-only.

### Follow-window on by default

If the user pressed a shortcut to move a window somewhere else, they
almost always want to keep working on it. Following is the
principle-of-least-surprise default. The menu toggle exists for the
minority who use MooOve to shove windows *out of sight*.

### Boundary behavior at the last Space

Original behavior (still available: toggle *Create New Space if Next
Doesn't Exist* off): hitting `Shift+Ctrl+→` on the last Space is a
no-op with a warning-triangle flash. We deliberately never wrapped to
Space 1 — wrap felt cute but is jarring because the direction of the
Space animation reverses under the user's hands.

Current default: create a new Space via the Mission Control AX dance
and move the window there. This is what most users expect from a
"move to next" shortcut and reuses the Accessibility permission the
app already has. The old boundary behavior stays reachable through the
menu toggle for anyone who prefers boundary presses to be silent.

Never wrap-around: even with automation on, we grow the Space list
rather than teleporting the window back to Space 1.

### Never simulate Ctrl+←/→ to switch Spaces

Earlier versions did. Two problems:

- The user's Shift+Ctrl is still held while we send Ctrl+←; some apps
  see the combination as a text-selection shortcut and eat it.
- If the user's Mission Control shortcut is not the default, we send
  the wrong key.

The current activate-app-then-promote approach is more code but has
none of these failure modes.

### Do not eagerly reset TCC on install

Resetting Accessibility approval on every `--install` teaches the
user muscle memory for "click through the permissions dialog", which
is exactly the wrong instinct.

## Future work

Not in scope, but sketched here in case someone picks them up:

- **Settle the minimum macOS version and the shipped architectures.**
  `Package.swift`, `Resources/Info.plist` and `scripts/build-macos.sh`
  all say macOS 26, and releases ship arm64 only — but the source guards
  its newer calls with `if #available(macOS 13.0, *)` in four places,
  which suggests 26 was the development machine's version rather than a
  deliberate floor. `README.md` still advertises macOS 13 and Intel
  support that the published DMG does not provide. Lowering
  `DEPLOYMENT_TARGET` in `scripts/build-macos.sh` and building with
  `--arch universal` is a one-command experiment; if it compiles, the
  floor and the three declarations should move together. Worth settling
  before 1.0, because widening the supported range later is painless
  while narrowing it after people have installed is not.

- **`RegisterEventHotKey` (Carbon)** instead of
  `NSEvent.addGlobalMonitorForEvents`. Works even when MooOve is
  frontmost. Small refactor; would replace `installGlobalHotkeys()`.

- **Preferences window** (real, not menu toggles). Would allow custom
  hotkeys via an `NSButton`-based key recorder. Requires promoting the
  app from `.accessory` to `.regular` briefly when the window is open,
  or (better) making a small SwiftUI window.

- **Persistent code signing identity.** See the signing section; the
  short-term workaround is fine, but a documented "run once" script
  that creates a `MooOveDev` certificate in the login keychain
  (via the GUI-driven Keychain Access.app path, since `security import`
  can be blocked by MDM) would remove the recurring TCC re-prompt.

- **Per-space wallpaper preservation.** Currently macOS does the right
  thing here for free, but if we ever synthesize Space switches again
  we'll need to be careful.

- **Multi-monitor Space movement.** MooOve can send a window from one
  physical display to another via `DisplayMover` (Cmd+Shift+Ctrl+←/→,
  public AX only). What it still cannot do is move a window *directly
  into a specific Space on another display* — that would need a
  different SkyLight operation (`SLSMoveWindowsToManagedSpaceOnDisplay`
  or similar). The current workaround: move to the other display first,
  then use ⇧⌃←/→ to walk to the Space you want.

- **Symbol probe on startup.** Log which of the known SkyLight
  symbols resolved successfully at launch, so users' bug reports
  contain a clear "here's what your macOS version exposes" section.
