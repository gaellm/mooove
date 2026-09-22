import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC.runtime
import OSLog
import ServiceManagement
import UserNotifications

private let log = Logger(subsystem: "com.gael.MooOve", category: "app")

// MooOve
// Menu-bar utility that moves the focused window between macOS Spaces
// and snaps / swap-snaps it to halves and quarters of the screen
// from the keyboard.
// macOS 13+ (menu-bar UI, ServiceManagement login item),
// tested target: macOS 26.4+ for the SkyLight move operation.
//
// Uses Accessibility + private SkyLight APIs. Apple does not provide a
// public API for moving another application's window between Spaces, so
// this is intentionally a personal-use utility. Private APIs can change
// with any macOS release.
//
// The internal `SpaceMover` class name is retained deliberately as the
// name of the Space-moving engine that MooOve wraps; renaming it would
// only churn diffs without changing behavior.

// MARK: - Preferences

private enum Prefs {
    static let followWindowKey = "MooOve.followWindow"
    static let createSpaceIfMissingKey = "MooOve.createSpaceIfMissing"
    static let tilingEnabledKey = "MooOve.tilingEnabled"

    /// Enables the ⌃⌥←/→/↑/↓ window-tiling shortcuts (snap active
    /// window to halves + maximize cycle). Default: on.
    static var tilingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: tilingEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: tilingEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: tilingEnabledKey) }
    }

    static var followWindow: Bool {
        get {
            // Default true: the user asked for follow-by-default behavior.
            if UserDefaults.standard.object(forKey: followWindowKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: followWindowKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: followWindowKey) }
    }

    /// When the user hits "Move Window to Next Space" and the current
    /// Space is already the last one, automatically create a new Space
    /// (via Mission Control UI automation) and move the window there.
    /// On by default: the automation drives the Dock's Mission Control
    /// UI and adds ~1s to the move, but the outcome matches what a user
    /// would do manually and is what most people expect from a
    /// "move to next" shortcut. Toggle it off from the menu bar if you
    /// specifically want boundary presses to be a no-op.
    static var createSpaceIfMissing: Bool {
        get {
            if UserDefaults.standard.object(forKey: createSpaceIfMissingKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: createSpaceIfMissingKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: createSpaceIfMissingKey) }
    }
}

// MARK: - App delegate

@main
final class MooOveApp: NSObject, NSApplicationDelegate {
    static func main() {
        log.notice("main() entered")

        // Uninstaller helper: called by `build.sh --uninstall` before the
        // bundle is deleted. Unregisters the SMAppService login item so
        // System Settings > General > Login Items stops listing us, then
        // exits without launching the UI.
        let args = CommandLine.arguments
        if args.contains("--unregister-login-item") {
            log.notice("main: --unregister-login-item requested")
            if #available(macOS 13.0, *) {
                do {
                    try SMAppService.mainApp.unregister()
                    log.notice("main: SMAppService.unregister ok")
                } catch {
                    log.error("main: SMAppService.unregister failed: \(String(describing: error), privacy: .public)")
                }
            }
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = MooOveApp()
        app.delegate = delegate
        // Retain the delegate for the lifetime of the app.
        _ = Unmanaged.passRetained(delegate)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var hotkeyMonitor: Any?
    private let mover = SpaceMover()
    private let tiler = WindowTiler()
    private let displayMover = DisplayMover()
    private let focusTracker = FocusTracker()

    // Menu items whose title we refresh every time the menu opens.
    private var currentSpaceItem: NSMenuItem!
    private var followWindowItem: NSMenuItem!
    private var createSpaceIfMissingItem: NSMenuItem!
    private var tilingEnabledItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var moveToSpaceSubmenu: NSMenu!

    // Icon assets.
    private lazy var idleIcon: NSImage = Self.bundleImage(named: "mooove",
                                                          pointSize: 18)
        ?? Self.symbol("rectangle.on.rectangle", fallback: "⇧⌃")
    private lazy var successIcon: NSImage = Self.symbol("checkmark.rectangle",
                                                        fallback: "✓")
    private lazy var failureIcon: NSImage = Self.symbol("exclamationmark.triangle",
                                                        fallback: "!")

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        focusTracker.start()
        installGlobalHotkeys()
        DispatchQueue.main.async { [weak self] in
            self?.runFirstLaunchOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        focusTracker.stop()
    }

    // MARK: Menu

    private func setupMenu() {
        log.notice("setupMenu begin")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.behavior = []
        if let button = statusItem.button {
            // Icon only — no title text next to it. The image itself is
            // enough of an identifier once the cow logo is in place.
            button.title = ""
            button.toolTip = "MooOve"
            button.imagePosition = .imageOnly
            idleIcon.isTemplate = true
            button.image = idleIcon
            let w = self.idleIcon.size.width
            let h = self.idleIcon.size.height
            log.notice("button configured, imgSize=\(w)x\(h)")
        } else {
            log.notice("WARNING statusItem.button is nil")
        }
        let visible = self.statusItem.isVisible
        let length = self.statusItem.length
        log.notice("status item created, visible=\(visible), length=\(length)")

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        currentSpaceItem = NSMenuItem(title: "Space —", action: nil, keyEquivalent: "")
        currentSpaceItem.isEnabled = false
        menu.addItem(currentSpaceItem)

        menu.addItem(.separator())

        let prev = NSMenuItem(
            title: "Move Window to Previous Space",
            action: #selector(movePrevious),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSLeftArrowFunctionKey)], count: 1)
        )
        prev.keyEquivalentModifierMask = [.shift, .control]
        prev.target = self
        menu.addItem(prev)

        let next = NSMenuItem(
            title: "Move Window to Next Space",
            action: #selector(moveNext),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSRightArrowFunctionKey)], count: 1)
        )
        next.keyEquivalentModifierMask = [.shift, .control]
        next.target = self
        menu.addItem(next)

        // "Move Window to Space" submenu (populated when opened).
        let moveToItem = NSMenuItem(title: "Move Window to Space", action: nil, keyEquivalent: "")
        moveToSpaceSubmenu = NSMenu()
        moveToItem.submenu = moveToSpaceSubmenu
        menu.addItem(moveToItem)

        menu.addItem(.separator())

        // Cross-display moves. Only useful with 2+ monitors; the items
        // are shown unconditionally so the shortcut hint is always
        // discoverable, and stay enabled — pressing them with a single
        // display attached just triggers the no-op warning flash.
        let prevDisplay = NSMenuItem(
            title: "Move Window to Previous Display",
            action: #selector(moveWindowToPreviousDisplay),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSLeftArrowFunctionKey)], count: 1)
        )
        prevDisplay.keyEquivalentModifierMask = [.command, .shift, .control]
        prevDisplay.target = self
        menu.addItem(prevDisplay)

        let nextDisplay = NSMenuItem(
            title: "Move Window to Next Display",
            action: #selector(moveWindowToNextDisplay),
            keyEquivalent: String(utf16CodeUnits: [unichar(NSRightArrowFunctionKey)], count: 1)
        )
        nextDisplay.keyEquivalentModifierMask = [.command, .shift, .control]
        nextDisplay.target = self
        menu.addItem(nextDisplay)

        menu.addItem(.separator())

        followWindowItem = NSMenuItem(
            title: "Follow Window to Target Space",
            action: #selector(toggleFollowWindow),
            keyEquivalent: ""
        )
        followWindowItem.target = self
        followWindowItem.state = Prefs.followWindow ? .on : .off
        menu.addItem(followWindowItem)

        createSpaceIfMissingItem = NSMenuItem(
            title: "Create New Space if Next Doesn't Exist",
            action: #selector(toggleCreateSpaceIfMissing),
            keyEquivalent: ""
        )
        createSpaceIfMissingItem.target = self
        createSpaceIfMissingItem.state = Prefs.createSpaceIfMissing ? .on : .off
        createSpaceIfMissingItem.toolTip =
            "When moving to the next Space past the last one, add a new Space "
            + "via Mission Control automation and move the window there. "
            + "Requires Accessibility permission."
        menu.addItem(createSpaceIfMissingItem)

        tilingEnabledItem = NSMenuItem(
            title: "Enable Window Tiling Shortcuts (⌃⌥ arrows)",
            action: #selector(toggleTilingEnabled),
            keyEquivalent: ""
        )
        tilingEnabledItem.target = self
        tilingEnabledItem.state = Prefs.tilingEnabled ? .on : .off
        tilingEnabledItem.toolTip =
            "⌃⌥←  Left half (press again for the top-left quarter,\n"
            + "        again for the bottom-left, again to restore)\n"
            + "⌃⌥→  Right half (same cycle on the right side)\n"
            + "⌃⌥↑  Top half (press again to maximize; then restore)\n"
            + "⌃⌥↓  Bottom half (press again to restore)\n"
            + "\n"
            + "Add ⇧ (⌃⌥⇧+arrow) to also tile the previously-focused\n"
            + "window to the opposite side of the screen."
        menu.addItem(tilingEnabledItem)

        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        accessibilityItem = NSMenuItem(
            title: "Accessibility Permission…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let about = NSMenuItem(
            title: "About MooOve",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MooOve", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Hotkeys

    private func installGlobalHotkeys() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode
            log.debug("keyDown seen: keyCode=\(keyCode), flags=\(flags.rawValue)")

            // ⌘⌃⇧ arrows — move the focused window to the previous /
            // next physical display. Checked before the ⇧⌃ Space-move
            // branch because ⇧⌃ is a subset of ⌘⇧⌃ and would otherwise
            // swallow the event first. Only ← / → are meaningful (no
            // vertical stacking of displays that we care to hotkey).
            let displayWanted: NSEvent.ModifierFlags = [.command, .shift, .control]
            if flags.contains(displayWanted),
               !flags.contains(.option) {
                switch keyCode {
                case UInt16(kVK_LeftArrow):
                    self.performDisplayMove(.previous); return
                case UInt16(kVK_RightArrow):
                    self.performDisplayMove(.next);     return
                default:
                    break
                }
            }

            // ⌃⌥⇧ arrows — swap-tile: snap current window to one half
            // and the previously-focused window to the opposite half.
            // Checked before plain ⌃⌥ because Shift is the distinguishing
            // modifier.
            let swapWanted: NSEvent.ModifierFlags = [.control, .option, .shift]
            if Prefs.tilingEnabled,
               flags.contains(swapWanted),
               !flags.contains(.command) {
                switch keyCode {
                case UInt16(kVK_LeftArrow):
                    self.performTileSwap(.left);   return
                case UInt16(kVK_RightArrow):
                    self.performTileSwap(.right);  return
                case UInt16(kVK_UpArrow):
                    self.performTileSwap(.top);    return
                case UInt16(kVK_DownArrow):
                    self.performTileSwap(.bottom); return
                default:
                    break
                }
            }

            // ⌃⌥ arrows — window tiling (snap to halves + maximize cycle).
            // Handled first because ⌃⌥ is a strict superset check
            // (no shift, no cmd) that mustn't collide with ⇧⌃ Space moves.
            let tilingWanted: NSEvent.ModifierFlags = [.control, .option]
            if Prefs.tilingEnabled,
               flags.contains(tilingWanted),
               !flags.contains(.command),
               !flags.contains(.shift) {
                switch keyCode {
                case UInt16(kVK_LeftArrow):
                    self.performTile(.left);   return
                case UInt16(kVK_RightArrow):
                    self.performTile(.right);  return
                case UInt16(kVK_UpArrow):
                    self.performTile(.top);    return
                case UInt16(kVK_DownArrow):
                    self.performTile(.bottom); return
                default:
                    break
                }
            }

            // ⇧⌃ — Space moves (original behavior).
            let wanted: NSEvent.ModifierFlags = [.shift, .control]
            guard flags.contains(wanted),
                  !flags.contains(.command),
                  !flags.contains(.option) else { return }

            log.notice("hotkey matched: keyCode=\(keyCode)")

            switch keyCode {
            case UInt16(kVK_LeftArrow):
                self.performMove(.previous)
            case UInt16(kVK_RightArrow):
                self.performMove(.next)
            case UInt16(kVK_ANSI_1): self.performMoveToIndex(0)
            case UInt16(kVK_ANSI_2): self.performMoveToIndex(1)
            case UInt16(kVK_ANSI_3): self.performMoveToIndex(2)
            case UInt16(kVK_ANSI_4): self.performMoveToIndex(3)
            case UInt16(kVK_ANSI_5): self.performMoveToIndex(4)
            case UInt16(kVK_ANSI_6): self.performMoveToIndex(5)
            case UInt16(kVK_ANSI_7): self.performMoveToIndex(6)
            case UInt16(kVK_ANSI_8): self.performMoveToIndex(7)
            case UInt16(kVK_ANSI_9): self.performMoveToIndex(8)
            default:
                break
            }
        }
        if hotkeyMonitor == nil {
            log.error("addGlobalMonitorForEvents returned nil — missing Input Monitoring permission?")
        } else {
            log.notice("global hotkey monitor installed")
        }
    }

    // MARK: Menu actions

    @objc private func movePrevious() { performMove(.previous) }
    @objc private func moveNext() { performMove(.next) }

    @objc private func moveWindowToPreviousDisplay() {
        performDisplayMove(.previous)
    }
    @objc private func moveWindowToNextDisplay() {
        performDisplayMove(.next)
    }

    @objc private func moveToSpaceMenuAction(_ sender: NSMenuItem) {
        performMoveToIndex(sender.tag)
    }

    @objc private func toggleFollowWindow() {
        Prefs.followWindow.toggle()
        followWindowItem.state = Prefs.followWindow ? .on : .off
    }

    @objc private func toggleCreateSpaceIfMissing() {
        Prefs.createSpaceIfMissing.toggle()
        createSpaceIfMissingItem.state = Prefs.createSpaceIfMissing ? .on : .off
        log.notice("toggleCreateSpaceIfMissing -> \(Prefs.createSpaceIfMissing)")
    }

    @objc private func toggleTilingEnabled() {
        Prefs.tilingEnabled.toggle()
        tilingEnabledItem.state = Prefs.tilingEnabled ? .on : .off
        log.notice("toggleTilingEnabled -> \(Prefs.tilingEnabled)")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if LaunchAtLogin.isEnabled {
                try LaunchAtLogin.disable()
            } else {
                try LaunchAtLogin.enable()
            }
            refreshLaunchAtLoginItem()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login setting."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        promptAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Moves the focused window between macOS Spaces.\n\n"
                + "Shortcuts:\n"
                + "  ⇧⌃←  Previous Space\n"
                + "  ⇧⌃→  Next Space\n"
                + "  ⇧⌃1…9  Space N\n"
                + "  ⌘⇧⌃←  Move window to previous display\n"
                + "  ⌘⇧⌃→  Move window to next display\n"
                + "  ⌃⌥←  Snap window: left half (again = top-left quarter; "
                + "again = bottom-left; again = restore)\n"
                + "  ⌃⌥→  Snap window: right half (same cycle on the right)\n"
                + "  ⌃⌥↑  Snap window: top half (again = maximize; again = restore)\n"
                + "  ⌃⌥↓  Snap window: bottom half (again = restore)\n"
                + "  ⌃⌥⇧+arrow  Tile current + previously-focused window to opposite halves\n\n"
                + "Options:\n"
                + "  • Follow Window to Target Space\n"
                + "  • Create New Space if Next Doesn't Exist "
                + "(uses Mission Control automation)\n"
                + "  • Enable Window Tiling Shortcuts",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Core actions

    private func performMove(_ direction: SpaceMover.Direction) {
        guard ensureAccessibility() else { return }
        let result = mover.move(direction: direction, follow: Prefs.followWindow)

        // Optional: when moving past the last Space, create a new one
        // via Mission Control UI automation and retry the move.
        let resultDesc: String = {
            switch result {
            case .success: return "success"
            case .noop:    return "noop"
            case .failure: return "failure"
            }
        }()
        let info = mover.currentSpaceInfo()
        log.notice("performMove: direction=\(direction == .next ? "next" : "prev", privacy: .public), result=\(resultDesc, privacy: .public), createIfMissing=\(Prefs.createSpaceIfMissing), spaceInfo=\(info?.index ?? -1)/\(info?.total ?? -1)")

        if case .noop = result,
           direction == .next,
           Prefs.createSpaceIfMissing,
           mover.currentSpaceIsLast() {
            log.notice("no next Space, attempting to create one via Mission Control")
            MissionControlSpaceCreator.createNewSpace { [weak self] created in
                guard let self else { return }
                if created {
                    let retry = self.mover.move(direction: .next,
                                                follow: Prefs.followWindow)
                    self.show(retry)
                } else {
                    log.error("failed to create a new Space via Mission Control")
                    self.show(.failure)
                }
            }
            return
        }

        show(result)
    }

    private func performMoveToIndex(_ index: Int) {
        guard ensureAccessibility() else { return }
        let result = mover.move(toIndex: index, follow: Prefs.followWindow)
        show(result)
    }

    private func performTile(_ region: WindowTiler.Region) {
        guard ensureAccessibility() else { return }
        let ok = tiler.tile(region: region)
        show(ok ? .success : .failure)
    }

    private func performDisplayMove(_ direction: DisplayMover.Direction) {
        guard ensureAccessibility() else { return }
        let result = displayMover.move(direction: direction)
        // Reuse the SpaceMover.MoveResult icon feedback (identical
        // semantics: success flashes ✓, noop/failure flash the warning).
        switch result {
        case .success: show(.success)
        case .noop:    show(.noop)
        case .failure: show(.failure)
        }
    }

    /// Tiles the currently-focused window to `region` and the previously
    /// focused window (across all apps) to the opposite region. When
    /// there is no known previous window, falls back to a plain tile of
    /// the front window.
    private func performTileSwap(_ region: WindowTiler.Region) {
        guard ensureAccessibility() else { return }

        // Snapshot the tracker BEFORE we touch anything: tiling the
        // front window can change activation on some apps.
        let entries = focusTracker.recentEntries()
        // `entries[0]` is the current front window (updated by the
        // tracker on activation) and `entries[1]` is the previous one.
        let previous = entries.dropFirst().first

        let frontOK = tiler.tile(region: region, allowCycle: false)

        if let prev = previous {
            // Verify the previous entry is still a live, tileable window
            // before we touch it. Apps quit, windows close, etc.
            if let refreshed = focusTracker.refresh(prev) {
                _ = tiler.tile(
                    window: refreshed.axWindow,
                    wid: refreshed.wid,
                    region: region.opposite,
                    allowCycle: false
                )
            } else {
                log.notice("performTileSwap: previous window no longer valid")
            }
        } else {
            log.notice("performTileSwap: no previous window tracked yet")
        }

        show(frontOK ? .success : .failure)
    }

    // MARK: Feedback

    private func show(_ result: SpaceMover.MoveResult) {
        switch result {
        case .success:
            flashIcon(successIcon)
        case .noop:
            // Boundary (already at the first/last Space). Silent flash to
            // the failure icon so the user gets a hint but no noise.
            flashIcon(failureIcon)
        case .failure:
            flashIcon(failureIcon)
        }
    }

    private var iconFlashWorkItem: DispatchWorkItem?

    private func flashIcon(_ image: NSImage) {
        guard let button = statusItem.button else { return }
        iconFlashWorkItem?.cancel()
        image.isTemplate = true
        button.image = image
        let work = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.idleIcon.isTemplate = true
            button.image = self.idleIcon
        }
        iconFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Accessibility

    @discardableResult
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        promptAccessibility()
        return false
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: First-launch onboarding

    private func runFirstLaunchOnboardingIfNeeded() {
        if AXIsProcessTrusted() { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MooOve needs Accessibility permission"
        alert.informativeText =
            "MooOve reads the currently focused window so it can move it "
            + "between Spaces. macOS requires Accessibility permission for this.\n\n"
            + "Click Open Settings, enable MooOve, then relaunch the app."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

    // MARK: Launch at login state

    private func refreshLaunchAtLoginItem() {
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: Icon helpers

    /// Loads a menu-bar-appropriate template image from the app bundle's
    /// Resources. Expects three files at 1x / 2x / 3x
    /// (e.g. `mooove.png`, `mooove@2x.png`, `mooove@3x.png`) so the icon
    /// stays crisp on every display scale. Returned image is marked as a
    /// template so macOS auto-tints it for light/dark mode.
    private static func bundleImage(named name: String, pointSize: CGFloat) -> NSImage? {
        // NSImage(named:) picks the correct @1x / @2x / @3x variant
        // automatically as long as they sit in Contents/Resources with
        // the standard suffix convention.
        guard let img = NSImage(named: name) else {
            log.notice("bundleImage \(name, privacy: .public) not found in bundle")
            return nil
        }
        img.size = NSSize(width: pointSize, height: pointSize)
        img.isTemplate = true
        log.notice("loaded bundle image \(name, privacy: .public), size=\(img.size.width)x\(img.size.height)")
        return img
    }

    private static func symbol(_ name: String, fallback: String) -> NSImage {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "MooOve") {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let sized = img.withSymbolConfiguration(config) ?? img
            sized.isTemplate = true
            log.notice("loaded SF Symbol \(name, privacy: .public), size=\(sized.size.width)x\(sized.size.height)")
            return sized
        }
        log.notice("SF Symbol \(name) unavailable, using text fallback \(fallback)")
        // Old-macOS fallback: render text.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.black,
        ]
        let size = (fallback as NSString).size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: max(size.width, 16), height: max(size.height, 16)))
        image.lockFocus()
        (fallback as NSString).draw(at: .zero, withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - NSMenuDelegate

extension MooOveApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh dynamic labels every time the menu opens.
        refreshLaunchAtLoginItem()
        followWindowItem.state = Prefs.followWindow ? .on : .off
        createSpaceIfMissingItem.state = Prefs.createSpaceIfMissing ? .on : .off
        tilingEnabledItem.state = Prefs.tilingEnabled ? .on : .off
        accessibilityItem.title = AXIsProcessTrusted()
            ? "Accessibility Permission ✓"
            : "Accessibility Permission…"

        let info = mover.currentSpaceInfo()
        switch info {
        case .some(let (index, total)):
            currentSpaceItem.title = "Space \(index + 1) of \(total)"
            rebuildMoveToSpaceSubmenu(total: total, current: index)
        case .none:
            currentSpaceItem.title = "Space —"
            rebuildMoveToSpaceSubmenu(total: 0, current: -1)
        }
    }

    private func rebuildMoveToSpaceSubmenu(total: Int, current: Int) {
        moveToSpaceSubmenu.removeAllItems()
        if total == 0 {
            let item = NSMenuItem(title: "No Spaces detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            moveToSpaceSubmenu.addItem(item)
            return
        }
        for i in 0..<total {
            let title = "Space \(i + 1)" + (i == current ? "  (current)" : "")
            // ⇧⌃1..9 as key equivalent (visual hint only; global hotkeys
            // are the real trigger, since Cocoa key equivalents don't fire
            // when another app is frontmost).
            let keyEquivalent: String = (i < 9) ? "\(i + 1)" : ""
            let item = NSMenuItem(
                title: title,
                action: #selector(moveToSpaceMenuAction(_:)),
                keyEquivalent: keyEquivalent
            )
            item.keyEquivalentModifierMask = [.shift, .control]
            item.tag = i
            item.target = self
            item.isEnabled = (i != current)
            moveToSpaceSubmenu.addItem(item)
        }
    }
}

// MARK: - Launch at login

private enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func enable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
        } else {
            throw NSError(
                domain: "MooOve",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at Login requires macOS 13 or newer."]
            )
        }
    }

    static func disable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Mission Control-based Space creation
//
// macOS has no public API to add a Space. The only reliable way to do
// it from outside the Dock process is UI automation:
//
//   1. Open Mission Control (via the private CoreDock notification the
//      Dock uses when the user presses F3).
//   2. Locate the "+" (add Space) button inside the Dock's Mission
//      Control window through the Accessibility API and press it.
//   3. Dismiss Mission Control.
//
// The Dock exposes a stable identifier hierarchy for Mission Control
// (used by Hammerspoon's hs.spaces and unchanged from macOS 13 through
// macOS 26):
//
//   AXApplication (com.apple.dock)
//     └── AXGroup / AXWindow ... with AXIdentifier = "mc"
//           └── AXGroup   AXIdentifier = "mc.display_<UUID>"
//                 └── AXGroup   AXIdentifier = "mc.spaces"
//                       ├── AXGroup   AXIdentifier = "mc.spaces.list"
//                       └── AXButton  AXIdentifier = "mc.spaces.add"
//
// We match on the identifier "mc.spaces.add" first (fast + correct on
// modern macOS) and only fall back to a fuzzier scan if that fails.

private enum MissionControlSpaceCreator {
    /// Attempts to create a new Space. Calls `completion` on the main
    /// queue with `true` on success (the Space appears in
    /// SLSCopyManagedDisplaySpaces after we finish), `false` otherwise.
    static func createNewSpace(completion: @escaping (Bool) -> Void) {
        let before = spaceCountForMainDisplay()
        log.notice("MissionControl: begin, current space count=\(before ?? -1)")

        openMissionControl()

        // Poll for the AX tree to populate. On a fast Mac the "+" button
        // appears within ~200 ms; on a slower one it can take ~800 ms.
        // Polling avoids hard-coded delays that fail on either extreme.
        waitForAddSpaceButton(deadline: .now() + 1.5) { button in
            guard let button else {
                log.error("MissionControl: could not find the '+' button (timed out); dumping Dock AX tree")
                dumpDockAXTree()
                dismissMissionControl()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    completion(false)
                }
                return
            }

            let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if err != .success {
                log.error("MissionControl: AXPress on '+' failed rc=\(err.rawValue)")
                dismissMissionControl()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    completion(false)
                }
                return
            }
            log.notice("MissionControl: pressed '+' button")

            // Wait for the new-Space animation, then dismiss and verify.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismissMissionControl()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let after = spaceCountForMainDisplay()
                    let ok = (before ?? 0) < (after ?? 0)
                    log.notice("MissionControl: space count \(before ?? -1) -> \(after ?? -1), ok=\(ok)")
                    completion(ok)
                }
            }
        }
    }

    // MARK: Mission Control open/close

    private static func openMissionControl() {
        if let send = spacemover_CoreDockSendNotification {
            send("com.apple.expose.awake" as CFString, 0)
            log.notice("MissionControl: sent com.apple.expose.awake")
        } else {
            // Fallback: launch Mission Control.app. Works on older macOS.
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
            log.notice("MissionControl: launched Mission Control.app fallback")
        }
    }

    private static func dismissMissionControl() {
        // Sending the same notification a second time toggles it off in
        // recent macOS releases. If that stops working, we fall back to
        // posting an Escape key event.
        if let send = spacemover_CoreDockSendNotification {
            send("com.apple.expose.awake" as CFString, 0)
            log.notice("MissionControl: sent close (awake toggle)")
        }
        postEscape()
    }

    private static func postEscape() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: '+' button lookup via Accessibility on the Dock process

    private static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?
            .processIdentifier
    }

    /// Polls up to `deadline` for the "+" button to appear in the Dock's
    /// AX tree, calling `completion` on the main queue when found or when
    /// the deadline passes.
    private static func waitForAddSpaceButton(
        deadline: DispatchTime,
        completion: @escaping (AXUIElement?) -> Void
    ) {
        if let btn = findAddSpaceButton() {
            completion(btn)
            return
        }
        if DispatchTime.now() >= deadline {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitForAddSpaceButton(deadline: deadline, completion: completion)
        }
    }

    /// Locates the Mission Control "add Space" button in the Dock's AX
    /// tree. Preferred path: match `AXIdentifier == "mc.spaces.add"`
    /// (present on every macOS version we support, as used by hs.spaces).
    /// Fallback path: a fuzzy search over identifier / description /
    /// help / title strings, for robustness against a future rename.
    private static func findAddSpaceButton() -> AXUIElement? {
        guard let pid = dockPID() else {
            log.error("MissionControl: Dock process not running")
            return nil
        }
        let app = AXUIElementCreateApplication(pid)

        // Fast path: exact identifier match.
        if let hit = findElement(in: app, depth: 0, maxDepth: 10, matching: { el in
            axString(el, kAXIdentifierAttribute as String) == "mc.spaces.add"
        }) {
            log.notice("MissionControl: matched AXIdentifier=mc.spaces.add")
            return hit
        }

        // Fallback: any AXButton whose identifier starts with "mc.spaces.add"
        // (e.g. Apple sometimes suffixes it per-display: "mc.spaces.add.<uuid>").
        if let hit = findElement(in: app, depth: 0, maxDepth: 10, matching: { el in
            guard axRole(el) == (kAXButtonRole as String) else { return false }
            guard let id = axString(el, kAXIdentifierAttribute as String) else { return false }
            return id.hasPrefix("mc.spaces.add")
        }) {
            log.notice("MissionControl: matched AXIdentifier prefix mc.spaces.add")
            return hit
        }

        // Last-ditch: heuristic on description/help/title.
        if let hit = findElement(in: app, depth: 0, maxDepth: 10, matching: fuzzyAddSpaceMatch) {
            log.notice("MissionControl: matched via fuzzy description/help/title")
            return hit
        }

        return nil
    }

    /// Depth-limited DFS over the AX tree, invoking `matches` on each
    /// element and returning the first hit.
    private static func findElement(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        matching matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if depth > maxDepth { return nil }
        if matches(element) { return element }

        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        )
        guard err == .success, let arr = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in arr {
            if let hit = findElement(in: child, depth: depth + 1, maxDepth: maxDepth, matching: matches) {
                return hit
            }
        }
        return nil
    }

    private static func fuzzyAddSpaceMatch(_ element: AXUIElement) -> Bool {
        guard axRole(element) == (kAXButtonRole as String) else { return false }
        let candidates: [String] = [
            axString(element, kAXIdentifierAttribute as String),
            axString(element, kAXDescriptionAttribute as String),
            axString(element, kAXHelpAttribute as String),
            axString(element, kAXTitleAttribute as String),
        ].compactMap { $0 }.map { $0.lowercased() }

        for c in candidates {
            if c.contains("add_desktop") || c.contains("add_space") { return true }
            if c.contains("add") && (c.contains("space") || c.contains("desktop")) {
                return true
            }
            if c.contains("new desktop") || c.contains("new space") { return true }
        }
        return false
    }

    // MARK: AX helpers

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        axString(element, kAXRoleAttribute as String)
    }

    /// Dumps a shallow view of the Dock's AX tree to the log. Used only
    /// when the "+" button lookup fails, to help debug on user machines
    /// where Apple may have changed the identifier layout.
    private static func dumpDockAXTree() {
        guard let pid = dockPID() else { return }
        let app = AXUIElementCreateApplication(pid)
        log.error("--- Dock AX tree (depth=4) ---")
        dumpElement(app, depth: 0, maxDepth: 4)
        log.error("--- end Dock AX tree ---")
    }

    private static func dumpElement(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        if depth > maxDepth { return }
        let indent = String(repeating: "  ", count: depth)
        let role = axString(element, kAXRoleAttribute as String) ?? "?"
        let id = axString(element, kAXIdentifierAttribute as String) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as String) ?? ""
        let title = axString(element, kAXTitleAttribute as String) ?? ""
        let publicRole = role
        let publicID = id
        let publicDesc = desc
        let publicTitle = title
        log.error("\(indent, privacy: .public)[\(publicRole, privacy: .public)] id=\(publicID, privacy: .public) desc=\(publicDesc, privacy: .public) title=\(publicTitle, privacy: .public)")

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let arr = childrenRef as? [AXUIElement] {
            for child in arr {
                dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    // MARK: Space count probe (uses SkyLight, same as SpaceMover engine)

    private static func spaceCountForMainDisplay() -> Int? {
        guard let cgsMainConnectionID = SkyLight.cgsMainConnectionID,
              let slsCopyManagedDisplaySpaces = SkyLight.slsCopyManagedDisplaySpaces else {
            return nil
        }
        let cid = cgsMainConnectionID()
        guard let displays = slsCopyManagedDisplaySpaces(cid)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        // Sum across displays: we only care that *some* display gained a
        // Space. Users almost always trigger this on the main display.
        var total = 0
        for d in displays {
            if let spaces = d["Spaces"] as? [[String: Any]] {
                total += spaces.count
            }
        }
        return total
    }
}

// MARK: - Focus tracker
//
// Keeps a small history of "the window that was focused when app X became
// frontmost". Used by the ⌃⌥⇧ swap-tile shortcut so we know which window
// to send to the opposite half of the screen.
//
// Approach: subscribe to NSWorkspace.didActivateApplicationNotification.
// Every time a new app becomes frontmost we capture its focused
// AXUIElement + CGWindowID and prepend the entry. We keep only a handful
// of entries, dedup by CGWindowID (so re-activating the same window
// doesn't push the useful "previous" entry off the list), and skip our
// own process (we never want to swap-tile the MooOve menu bar).
//
// AXUIElements hold a reference to a process; if the app quits, the
// element remains but its attribute queries fail. `refresh(_:)`
// re-derives the current focused window for the entry's pid and returns
// nil if that pid is gone.

final class FocusTracker {
    struct Entry {
        let pid: pid_t
        let bundleID: String?
        var axWindow: AXUIElement
        var wid: UInt32
    }

    private var entries: [Entry] = []
    private let maxEntries = 8
    private var observer: NSObjectProtocol?

    func start() {
        // Seed with the current frontmost app so ⌃⌥⇧ works on the very
        // first press without waiting for an activation.
        if let front = NSWorkspace.shared.frontmostApplication {
            record(app: front)
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self.record(app: app)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Snapshot of the current recency list, front-most first.
    func recentEntries() -> [Entry] {
        // Also refresh entry[0] (the front app's focused window may have
        // changed since the last activation without a new activation
        // notification firing — e.g. the user clicked another window in
        // the same app).
        if let front = NSWorkspace.shared.frontmostApplication,
           let fresh = focusedWindowInfo(for: front) {
            promote(fresh)
        }
        return entries
    }

    /// Returns an up-to-date (AXUIElement, wid) for `entry` if the
    /// process is still alive AND the entry's window is still present.
    /// Nil otherwise.
    func refresh(_ entry: Entry) -> (axWindow: AXUIElement, wid: UInt32)? {
        guard NSRunningApplication(processIdentifier: entry.pid) != nil else {
            return nil
        }

        // Fast path: entry.axWindow may still be valid. Probe by reading
        // one attribute. If it succeeds, use it.
        var pos: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            entry.axWindow, kAXPositionAttribute as CFString, &pos
        ) == .success {
            return (entry.axWindow, entry.wid)
        }

        // Slow path: enumerate the app's windows and find one whose
        // CGWindowID matches the entry we stored.
        let appEl = AXUIElementCreateApplication(entry.pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXWindowsAttribute as CFString, &winRef
        ) == .success,
              let winArr = winRef as? [AXUIElement] else { return nil }

        for w in winArr {
            var wid: UInt32 = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == entry.wid {
                return (w, wid)
            }
        }
        return nil
    }

    // MARK: Internals

    private func record(app: NSRunningApplication) {
        // Skip our own process — the menu bar icon isn't a tileable
        // window and we never want to swap it.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        guard let info = focusedWindowInfo(for: app) else { return }
        promote(info)
    }

    private func promote(_ info: Entry) {
        // Dedup by wid: re-activating the same window shouldn't discard
        // the previous entry, which is exactly the one the swap needs.
        entries.removeAll { $0.wid == info.wid }
        entries.insert(info, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    private func focusedWindowInfo(for app: NSRunningApplication) -> Entry? {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXFocusedWindowAttribute as CFString, &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        var wid: UInt32 = 0
        guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else {
            return nil
        }
        return Entry(
            pid: pid,
            bundleID: app.bundleIdentifier,
            axWindow: window,
            wid: wid
        )
    }
}

// MARK: - Window tiler
//
// Snaps the focused window to a half or a quarter of the screen it
// currently lives on (or the screen where the window's center sits).
// Every arrow cycles on repeated presses:
//
//   ⌃⌥← from any state                -> left half
//   ⌃⌥← when already left half        -> top-left quarter
//   ⌃⌥← when already top-left         -> bottom-left quarter
//   ⌃⌥← when already bottom-left      -> restore previous frame
//
//   ⌃⌥→ mirrors that on the right side.
//
//   ⌃⌥↑ from any state           -> top half
//   ⌃⌥↑ when already top half    -> maximize (full visible frame)
//   ⌃⌥↑ when already maximized   -> restore previous frame
//
//   ⌃⌥↓ from any state           -> bottom half
//   ⌃⌥↓ when already bottom half -> restore previous frame
//
// On the first press we remember the pre-tiling frame so we can restore
// it later.
//
// Coordinates: the Accessibility API uses a top-left origin in points
// (unlike NSScreen, which uses a bottom-left origin). We work in the AX
// coordinate space throughout and convert only when reading NSScreen
// frames.

final class WindowTiler {
    enum Region {
        case left
        case right
        case top
        case bottom

        var opposite: Region {
            switch self {
            case .left:   return .right
            case .right:  return .left
            case .top:    return .bottom
            case .bottom: return .top
            }
        }
    }

    /// The last tiled state we applied to a given AXUIElement, keyed by
    /// its CGWindowID. Used for the Up-key maximize-then-restore cycle.
    private enum TileState {
        case none
        case leftHalf
        case rightHalf
        case topHalf
        case bottomHalf
        case topLeftQuarter
        case bottomLeftQuarter
        case topRightQuarter
        case bottomRightQuarter
        case maximized
    }

    private struct WindowMemo {
        var state: TileState
        /// Frame before we started tiling this window, in AX coordinates.
        /// Used to restore the window on the "cycle back" press.
        var originalFrame: CGRect?
        /// The frame we asked for on the last tile, and the one the
        /// window reported afterwards. They differ when an app clamps
        /// us (minimum sizes, terminal character grids) or animates the
        /// resize, so a window counts as untouched if it matches
        /// either. Used to notice the user moving it by hand.
        var requestedFrame: CGRect? = nil
        var appliedFrame: CGRect? = nil

        /// True when the window still sits where our last tile left it.
        func stillTiled(at frame: CGRect, tolerance: CGFloat = 4) -> Bool {
            let known = [requestedFrame, appliedFrame].compactMap { $0 }
            guard !known.isEmpty else { return true }
            return known.contains { candidate in
                abs(frame.minX - candidate.minX) <= tolerance
                    && abs(frame.minY - candidate.minY) <= tolerance
                    && abs(frame.width - candidate.width) <= tolerance
                    && abs(frame.height - candidate.height) <= tolerance
            }
        }
    }

    private var memos: [UInt32: WindowMemo] = [:]

    /// Snap the focused window to the requested region. Returns true if
    /// anything was actually applied. Pass `allowCycle: false` to snap
    /// straight to the half and skip the repeated-press cycle.
    func tile(region: Region, allowCycle: Bool = true) -> Bool {
        guard AXIsProcessTrusted() else {
            log.notice("WindowTiler: not trusted for AX")
            return false
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log.notice("WindowTiler: no frontmost app")
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard rc == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            log.notice("WindowTiler: no focused window (rc=\(rc.rawValue))")
            return false
        }
        let window = value as! AXUIElement

        var wid: UInt32 = 0
        _ = _AXUIElementGetWindow(window, &wid)

        return tile(window: window, wid: wid, region: region, allowCycle: allowCycle)
    }

    /// Snap a specific window (already resolved) to `region`. When
    /// `allowCycle` is false no arrow runs its repeated-press cycle —
    /// each one just snaps to the corresponding half. Used by the swap
    /// shortcut, where cycling would be surprising.
    @discardableResult
    func tile(
        window: AXUIElement,
        wid: UInt32,
        region: Region,
        allowCycle: Bool
    ) -> Bool {
        guard let currentFrame = axFrame(window) else {
            log.notice("WindowTiler: could not read window frame (wid=\(wid))")
            return false
        }

        // Pick the screen whose visible frame contains the window's
        // center. Falls back to main screen when none contains the point
        // (happens for off-screen windows).
        let screen = screenForAXRect(currentFrame) ?? NSScreen.main
        guard let screen else {
            log.notice("WindowTiler: no screen available")
            return false
        }
        let visible = axRect(fromScreenVisibleFrameOf: screen)

        var memo = memos[wid] ?? WindowMemo(state: .none, originalFrame: nil)

        // If the window is no longer where we last put it, the user has
        // dragged or resized it by hand (or another tool has, or it
        // moved to a different screen). The cycle we were tracking is
        // stale: start over from the half, and treat where the window
        // sits now as the layout to restore to.
        if !memo.stillTiled(at: currentFrame) {
            memo = WindowMemo(state: .none, originalFrame: nil)
        }

        let prevState = memo.state

        // Half / quarter geometry. The leading half is flush to the
        // leading edge and the trailing half to the trailing edge, so
        // the rounding in `floor` never leaves a one-point gap at the
        // screen edge on an odd-sized display.
        let halfW = floor(visible.width / 2)
        let halfH = floor(visible.height / 2)
        let leftX = visible.minX
        let rightX = visible.minX + (visible.width - halfW)
        let topY = visible.minY
        let bottomY = visible.minY + (visible.height - halfH)

        // Determine the target frame + new state.
        let target: CGRect
        let newState: TileState

        switch region {
        case .left:
            // Cycle (when allowed): left half -> top-left quarter ->
            // bottom-left quarter -> restore.
            if allowCycle, prevState == .leftHalf {
                target = CGRect(x: leftX, y: topY, width: halfW, height: halfH)
                newState = .topLeftQuarter
            } else if allowCycle, prevState == .topLeftQuarter {
                target = CGRect(x: leftX, y: bottomY, width: halfW, height: halfH)
                newState = .bottomLeftQuarter
            } else if allowCycle, prevState == .bottomLeftQuarter,
                      let orig = memo.originalFrame {
                target = orig
                newState = .none
            } else {
                target = CGRect(
                    x: leftX, y: visible.minY,
                    width: halfW, height: visible.height
                )
                newState = .leftHalf
            }

        case .right:
            // Cycle (when allowed): right half -> top-right quarter ->
            // bottom-right quarter -> restore.
            if allowCycle, prevState == .rightHalf {
                target = CGRect(x: rightX, y: topY, width: halfW, height: halfH)
                newState = .topRightQuarter
            } else if allowCycle, prevState == .topRightQuarter {
                target = CGRect(x: rightX, y: bottomY, width: halfW, height: halfH)
                newState = .bottomRightQuarter
            } else if allowCycle, prevState == .bottomRightQuarter,
                      let orig = memo.originalFrame {
                target = orig
                newState = .none
            } else {
                target = CGRect(
                    x: rightX, y: visible.minY,
                    width: halfW, height: visible.height
                )
                newState = .rightHalf
            }

        case .top:
            // Cycle (when allowed): top half -> maximized -> restore.
            if allowCycle, prevState == .topHalf {
                target = visible
                newState = .maximized
            } else if allowCycle, prevState == .maximized, let orig = memo.originalFrame {
                target = orig
                newState = .none
            } else {
                target = CGRect(
                    x: visible.minX, y: topY,
                    width: visible.width, height: halfH
                )
                newState = .topHalf
            }

        case .bottom:
            // Cycle (when allowed): bottom half -> restore.
            if allowCycle, prevState == .bottomHalf, let orig = memo.originalFrame {
                target = orig
                newState = .none
            } else {
                target = CGRect(
                    x: visible.minX, y: bottomY,
                    width: visible.width, height: halfH
                )
                newState = .bottomHalf
            }
        }

        // Remember the pre-tile frame the first time we touch this
        // window, so any later "restore" step returns to the user's
        // original layout.
        if memo.state == .none {
            memo.originalFrame = currentFrame
        }
        memo.state = newState

        applyFrame(window, target)

        // Record both what we asked for and where the window says it
        // landed, so the next press can tell "the app clamped our
        // frame" apart from "the user dragged the window".
        memo.requestedFrame = target
        memo.appliedFrame = axFrame(window)
        memos[wid] = memo
        log.notice("WindowTiler: region=\(String(describing: region), privacy: .public) state=\(String(describing: newState), privacy: .public) wid=\(wid)")
        return true
    }

    // MARK: AX geometry helpers

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        guard let pos: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private func applyFrame(_ window: AXUIElement, _ frame: CGRect) {
        // AX rejects size changes on some non-resizable windows. Set
        // position first, then size, then position again — this matches
        // what Rectangle/Magnet do to work around apps that clamp size
        // relative to the current position.
        setAXPoint(window, kAXPositionAttribute, frame.origin)
        setAXSize(window, kAXSizeAttribute, frame.size)
        setAXPoint(window, kAXPositionAttribute, frame.origin)
    }

    private func axValue<T>(
        _ element: AXUIElement,
        _ attr: String,
        _ type: AXValueType
    ) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        // swiftlint:disable:next force_cast
        let axVal = ref as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        if AXValueGetValue(axVal, type, out) {
            return out.pointee
        }
        return nil
    }

    private func setAXPoint(_ element: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        if let val = AXValueCreate(.cgPoint, &p) {
            _ = AXUIElementSetAttributeValue(element, attr as CFString, val)
        }
    }

    private func setAXSize(_ element: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        if let val = AXValueCreate(.cgSize, &s) {
            _ = AXUIElementSetAttributeValue(element, attr as CFString, val)
        }
    }

    /// NSScreen returns frames in a bottom-left global coordinate space
    /// whose origin is the bottom-left of the *primary* screen. The AX
    /// API uses a top-left coordinate space whose origin is the
    /// top-left of the primary screen. Convert.
    private func axRect(fromScreenVisibleFrameOf screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first ?? screen
        let primaryHeight = primary.frame.height
        let vf = screen.visibleFrame
        return CGRect(
            x: vf.origin.x,
            y: primaryHeight - vf.origin.y - vf.height,
            width: vf.width,
            height: vf.height
        )
    }

    /// Find the NSScreen whose visible frame (in AX coordinates)
    /// contains the center of `rect`.
    private func screenForAXRect(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            let axVisible = axRect(fromScreenVisibleFrameOf: screen)
            if axVisible.contains(center) {
                return screen
            }
        }
        return nil
    }
}

// MARK: - Display mover
//
// Moves the focused window from its current display to another physical
// display attached to the Mac. Unlike SpaceMover, this uses ONLY the
// public Accessibility API (setPosition/setSize) — moving a window across
// displays is exactly what AX resizing was designed for; no SkyLight or
// private symbols are needed. macOS handles the rest: if
// "Displays have separate Spaces" is on, the window becomes part of the
// currently-shown Space on the destination display; otherwise the window
// simply straddles/crosses to the new display.
//
// Sizing: the window's frame is mapped from the source display's visible
// frame to the destination display's visible frame preserving RELATIVE
// position and size ratios. This behaves well for displays of similar
// aspect ratio and clamps to fit when the destination is smaller.
//
// Wrap-around: with N displays, moving "next" past the last wraps to the
// first, and "previous" past the first wraps to the last. With 2
// displays (the common case) both directions simply toggle between them.

final class DisplayMover {
    enum Direction {
        case previous
        case next
    }

    enum MoveResult {
        case success
        case noop     // Only one display attached, or destination == source.
        case failure  // Missing permission / focused window / frame read fails.
    }

    /// Moves the currently-focused window to the neighbouring display in
    /// `direction`. Returns `.noop` if there is only a single display
    /// attached, `.failure` if we can't read the focused window.
    func move(direction: Direction) -> MoveResult {
        guard AXIsProcessTrusted() else {
            log.notice("DisplayMover: not trusted for AX")
            return .failure
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            log.notice("DisplayMover: no frontmost app")
            return .failure
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard rc == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            log.notice("DisplayMover: no focused window (rc=\(rc.rawValue))")
            return .failure
        }
        let window = value as! AXUIElement

        guard let frame = axFrame(window) else {
            log.notice("DisplayMover: could not read window frame")
            return .failure
        }

        let screens = NSScreen.screens
        guard screens.count > 1 else {
            log.notice("DisplayMover: only one display attached")
            return .noop
        }

        // Find the source screen (screen containing the window's center;
        // fall back to the screen that overlaps most of the frame if the
        // center is outside every visible frame).
        let currentIndex = screens.firstIndex(where: {
            axRect(fromScreenVisibleFrameOf: $0).contains(
                CGPoint(x: frame.midX, y: frame.midY)
            )
        }) ?? bestOverlapScreenIndex(for: frame, in: screens) ?? 0

        // Wrap-around neighbour selection.
        let n = screens.count
        let targetIndex: Int
        switch direction {
        case .next:     targetIndex = (currentIndex + 1) % n
        case .previous: targetIndex = (currentIndex - 1 + n) % n
        }

        if targetIndex == currentIndex {
            return .noop
        }

        let sourceVisible = axRect(fromScreenVisibleFrameOf: screens[currentIndex])
        let destVisible   = axRect(fromScreenVisibleFrameOf: screens[targetIndex])

        let target = mappedFrame(
            frame,
            fromSource: sourceVisible,
            toDestination: destVisible
        )

        applyFrame(window, target)

        // Best-effort focus preservation: activation state doesn't change
        // (the window stays in the same app / same process), but on some
        // apps setting AXMain again after the move helps keep it as the
        // focused window from the app's perspective.
        _ = AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            window, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )

        log.notice("DisplayMover: moved focused window from display \(currentIndex) -> \(targetIndex) of \(screens.count)")
        return .success
    }

    // MARK: Frame mapping

    /// Maps `frame` from a rectangle inside `source` to the equivalent
    /// rectangle inside `destination`, preserving relative position and
    /// size ratios. Clamps to `destination` so the result always fits
    /// (never larger than the destination's visible frame, never leaves
    /// the destination).
    private func mappedFrame(
        _ frame: CGRect,
        fromSource source: CGRect,
        toDestination destination: CGRect
    ) -> CGRect {
        // Guard against zero-sized source (should never happen for a real
        // display but let's not divide by zero).
        guard source.width > 0, source.height > 0 else {
            return CGRect(
                origin: destination.origin,
                size: CGSize(
                    width: min(frame.width, destination.width),
                    height: min(frame.height, destination.height)
                )
            )
        }

        let relX = (frame.origin.x - source.origin.x) / source.width
        let relY = (frame.origin.y - source.origin.y) / source.height
        let relW = frame.width  / source.width
        let relH = frame.height / source.height

        // Size — cap at the destination's visible frame so windows moved
        // from a larger display don't spill off the smaller one.
        let newW = min(relW * destination.width,  destination.width)
        let newH = min(relH * destination.height, destination.height)

        // Position — same relative offset, then clamp so the window's
        // bounding rect stays inside the destination visible frame.
        var newX = destination.origin.x + relX * destination.width
        var newY = destination.origin.y + relY * destination.height
        newX = max(destination.minX, min(newX, destination.maxX - newW))
        newY = max(destination.minY, min(newY, destination.maxY - newH))

        return CGRect(x: newX, y: newY, width: newW, height: newH)
    }

    /// Fallback when the window's center lies outside every visible
    /// frame (fully off-screen). Picks the screen that overlaps the most
    /// window area; nil if there's no overlap at all.
    private func bestOverlapScreenIndex(
        for frame: CGRect,
        in screens: [NSScreen]
    ) -> Int? {
        var bestIdx: Int?
        var bestArea: CGFloat = 0
        for (i, screen) in screens.enumerated() {
            let v = axRect(fromScreenVisibleFrameOf: screen)
            let inter = v.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: AX helpers (duplicated from WindowTiler to keep the class
    // self-contained; both are trivial and inlining them costs nothing).

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        guard let pos: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private func applyFrame(_ window: AXUIElement, _ frame: CGRect) {
        // Same setPosition -> setSize -> setPosition dance as WindowTiler:
        // some apps clamp size relative to the current position.
        setAXPoint(window, kAXPositionAttribute, frame.origin)
        setAXSize(window, kAXSizeAttribute, frame.size)
        setAXPoint(window, kAXPositionAttribute, frame.origin)
    }

    private func axValue<T>(
        _ element: AXUIElement,
        _ attr: String,
        _ type: AXValueType
    ) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        // swiftlint:disable:next force_cast
        let axVal = ref as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        if AXValueGetValue(axVal, type, out) {
            return out.pointee
        }
        return nil
    }

    private func setAXPoint(_ element: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        if let val = AXValueCreate(.cgPoint, &p) {
            _ = AXUIElementSetAttributeValue(element, attr as CFString, val)
        }
    }

    private func setAXSize(_ element: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        if let val = AXValueCreate(.cgSize, &s) {
            _ = AXUIElementSetAttributeValue(element, attr as CFString, val)
        }
    }

    /// Convert NSScreen.visibleFrame (bottom-left origin, primary-screen
    /// coordinate space) into AX coordinates (top-left origin, primary
    /// screen top). Identical to the WindowTiler helper — see the
    /// comment there for the coordinate-system rationale.
    private func axRect(fromScreenVisibleFrameOf screen: NSScreen) -> CGRect {
        let primary = NSScreen.screens.first ?? screen
        let primaryHeight = primary.frame.height
        let vf = screen.visibleFrame
        return CGRect(
            x: vf.origin.x,
            y: primaryHeight - vf.origin.y - vf.height,
            width: vf.width,
            height: vf.height
        )
    }
}

// MARK: - Space mover

final class SpaceMover {
    enum Direction {
        case previous
        case next
    }

    enum MoveResult {
        case success
        case noop     // At a boundary, or already on the requested Space.
        case failure  // Missing permission, no focused window, API error, etc.
    }

    private typealias ConnectionID = Int32

    private let cgsMainConnectionID                                    = SkyLight.cgsMainConnectionID
    private let slsCopyManagedDisplaySpaces                            = SkyLight.slsCopyManagedDisplaySpaces
    private let slsCopyManagedDisplayForWindow                         = SkyLight.slsCopyManagedDisplayForWindow
    private let slsManagedDisplayGetCurrentSpace                       = SkyLight.slsManagedDisplayGetCurrentSpace
    private let slsPerformAsynchronousBridgedWindowManagementOperation = SkyLight.slsPerformAsynchronousBridgedWindowManagementOperation
    private let cgsManagedDisplaySetCurrentSpace                       = SkyLight.cgsManagedDisplaySetCurrentSpace

    private let moveOperationClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"

    // MARK: Public API

    func move(direction: Direction, follow: Bool) -> MoveResult {
        guard let ctx = context() else { return .failure }

        let offset = (direction == .next) ? 1 : -1
        let targetIndex = ctx.currentIndex + offset
        guard ctx.spaces.indices.contains(targetIndex) else {
            return .noop
        }
        return performMove(context: ctx, targetIndex: targetIndex, follow: follow)
    }

    func move(toIndex targetIndex: Int, follow: Bool) -> MoveResult {
        guard let ctx = context() else { return .failure }
        guard ctx.spaces.indices.contains(targetIndex) else {
            return .noop
        }
        if targetIndex == ctx.currentIndex {
            return .noop
        }
        return performMove(context: ctx, targetIndex: targetIndex, follow: follow)
    }

    /// Returns (currentIndex, total) for the display containing the focused
    /// window. Nil if not available (no focused window, no Accessibility,
    /// etc.). Safe to call from menu opening.
    func currentSpaceInfo() -> (index: Int, total: Int)? {
        guard let ctx = context() else { return nil }
        return (ctx.currentIndex, ctx.spaces.count)
    }

    /// True when the focused window's display is currently showing the
    /// last Space in the ordered Space list. Used to decide whether to
    /// create a new Space when moving past the end.
    func currentSpaceIsLast() -> Bool {
        guard let (index, total) = currentSpaceInfo() else { return false }
        return index == total - 1
    }

    // MARK: Internals

    private struct Context {
        let windowID: UInt32
        let axWindow: AXUIElement
        let ownerPID: pid_t
        let cid: Int32
        let displayUUID: CFString
        let spaces: [[String: Any]]
        let currentIndex: Int
    }

    private func context() -> Context? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focused = focusedWindow() else { return nil }
        guard let cgsMainConnectionID,
              let slsCopyManagedDisplayForWindow,
              let slsCopyManagedDisplaySpaces,
              let slsManagedDisplayGetCurrentSpace else {
            log.notice("SkyLight query symbols unavailable on this macOS")
            return nil
        }

        let cid = cgsMainConnectionID()

        guard let displayUUIDRef = slsCopyManagedDisplayForWindow(cid, focused.windowID)?
            .takeRetainedValue() else { return nil }
        let displayUUID = displayUUIDRef as CFString

        guard let displays = slsCopyManagedDisplaySpaces(cid)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }

        guard let display = displays.first(where: {
            ($0["Display Identifier"] as? String) == (displayUUID as String)
        }) else { return nil }

        guard let spaces = display["Spaces"] as? [[String: Any]],
              !spaces.isEmpty else { return nil }

        let currentID = slsManagedDisplayGetCurrentSpace(cid, displayUUID)

        guard let currentIndex = spaces.firstIndex(where: { spaceID($0) == currentID }) else {
            return nil
        }

        return Context(
            windowID: focused.windowID,
            axWindow: focused.axWindow,
            ownerPID: focused.pid,
            cid: cid,
            displayUUID: displayUUID,
            spaces: spaces,
            currentIndex: currentIndex
        )
    }

    private func performMove(
        context ctx: Context,
        targetIndex: Int,
        follow: Bool
    ) -> MoveResult {
        guard let targetID = spaceID(ctx.spaces[targetIndex]) else {
            return .failure
        }

        guard moveWindow(ctx.windowID, toSpace: targetID) else {
            return .failure
        }

        if follow {
            followByActivatingApp(
                ownerPID: ctx.ownerPID,
                axWindow: ctx.axWindow
            )
        }

        return .success
    }

    /// After the window has been moved to another Space, follow it by
    /// activating its owning app with that window marked as `AXMain`.
    ///
    /// macOS built-in behavior: activating an app whose main window lives
    /// on another Space causes the OS to switch to that Space to reveal
    /// the window. That works reliably, but it does NOT guarantee the
    /// moved window ends up above whatever app was previously frontmost
    /// on the target Space — the previous app keeps its front-process
    /// status inside the WindowServer, so its window paints on top.
    ///
    /// To fix that we use the private `_SLPSSetFrontProcessWithOptions`
    /// call (the same API the Dock uses) *after* the Space animation
    /// completes. It updates WindowServer's front-process identity
    /// authoritatively, over any other app.
    private func followByActivatingApp(
        ownerPID: pid_t,
        axWindow: AXUIElement
    ) {
        // Step 1 — Wait for the async SkyLight move to complete. If we
        // activate the app before the move settles, macOS follows to the
        // window's OLD Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // Mark the moved window as the app's main/focused window so
            // that when the app activates, macOS follows to THIS window
            // and not to whichever other window the app has open.
            _ = AXUIElementSetAttributeValue(
                axWindow, kAXMainAttribute as CFString, kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )

            // Trigger the Space switch by activating the owner app.
            if let owner = NSRunningApplication(processIdentifier: ownerPID) {
                owner.activate(options: [.activateIgnoringOtherApps])
            }

            // Step 2 — After the Space animation has settled, promote
            // the moved window over any previously-frontmost app on the
            // target Space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Self.promoteToFront(ownerPID: ownerPID, axWindow: axWindow)
            }
        }
    }

    /// Promotes the given window to the very front of the WindowServer's
    /// front-process order via the private `_SLPSSetFrontProcessWithOptions`
    /// (same API the Dock uses when you click an icon), then re-raises
    /// the window inside its app's stack.
    private static func promoteToFront(ownerPID: pid_t, axWindow: AXUIElement) {
        var wid: UInt32 = 0
        _ = _AXUIElementGetWindow(axWindow, &wid)

        if let setFront = spacemover_SLPSSetFrontProcessWithOptions {
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
            if spacemover_GetProcessForPID(ownerPID, &psn) == 0 {
                // 0x200 — bring just this window forward
                // 0x100 — plus the app's other windows
                _ = setFront(&psn, wid, 0x200)
                _ = setFront(&psn, wid, 0x100)
            } else {
                log.notice("promoteToFront: GetProcessForPID failed for pid \(ownerPID)")
            }
        } else {
            log.notice("promoteToFront: _SLPSSetFrontProcessWithOptions unavailable")
        }

        // Belt-and-braces: also raise within the app's own window stack.
        _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(
            axWindow, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
    }

    private func spaceID(_ space: [String: Any]) -> UInt64? {
        if let id = space["ManagedSpaceID"] as? UInt64 { return id }
        if let id = space["id64"] as? UInt64 { return id }
        if let id = space["ManagedSpaceID"] as? NSNumber { return id.uint64Value }
        if let id = space["id64"] as? NSNumber { return id.uint64Value }
        if let id = space["ManagedSpaceID"] as? Int { return UInt64(id) }
        if let id = space["id64"] as? Int { return UInt64(id) }
        return nil
    }

    private struct FocusedWindow {
        let windowID: UInt32
        let axWindow: AXUIElement
        let pid: pid_t
    }

    private func focusedWindow() -> FocusedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = value as! AXUIElement
        var windowID: UInt32 = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success else {
            return nil
        }
        return FocusedWindow(windowID: windowID, axWindow: window, pid: app.processIdentifier)
    }

    private func moveWindow(_ windowID: UInt32, toSpace spaceID: UInt64) -> Bool {
        guard let cls = NSClassFromString(moveOperationClassName) else {
            let name = self.moveOperationClassName
            log.notice("\(name) is not available on this macOS version.")
            return false
        }

        // [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc]
        //     initWithWindows:@[@(windowID)] spaceID:spaceID]
        let initSel = NSSelectorFromString("initWithWindows:spaceID:")
        guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue() else {
            return false
        }

        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, UInt64
        ) -> AnyObject
        let initFn: InitFn = spacemover_objc_msgSend

        let windows: NSArray = [NSNumber(value: windowID)]
        let operation = initFn(alloc, initSel, windows, spaceID)

        // Path 1: try the async SkyLight runner if we managed to resolve
        // one of its C entry points (name varies across macOS releases).
        if let performOp = slsPerformAsynchronousBridgedWindowManagementOperation {
            let unmanaged = Unmanaged.passUnretained(operation)
            _ = performOp(unmanaged.toOpaque())
            unmanaged.release()
            return true
        }

        // Path 2: use the Objective-C fallback bridge exposed by SkyLight.
        // On macOS 15/26 the C symbol is private-linkage, but
        // `SLSWindowManagementFallbackBridge` is a regular class that
        // exposes the same operation runner as an instance method.
        if let bridgeCls = NSClassFromString("SLSWindowManagementFallbackBridge"),
           let bridge = (bridgeCls as AnyObject).perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue(),
           let initedBridge = (bridge as AnyObject).perform(NSSelectorFromString("init"))?
            .takeUnretainedValue() {
            let sel = NSSelectorFromString("performAsynchronousBridgedWindowManagementOperation:")
            if (initedBridge as AnyObject).responds(to: sel) {
                _ = (initedBridge as AnyObject).perform(sel, with: operation)
                return true
            }
        }

        // Path 3 (last resort): the operation class implements
        // `invokeFallback`, which performs the same work synchronously via
        // the WindowServer fallback path.
        let fallbackSel = NSSelectorFromString("invokeFallback")
        if (operation as AnyObject).responds(to: fallbackSel) {
            _ = (operation as AnyObject).perform(fallbackSel)
            return true
        }

        log.notice("no known way to dispatch the bridged move operation.")
        return false
    }
}

// MARK: - Private symbol bindings
//
// These symbols are resolved at runtime via dlsym. Do NOT reintroduce
// `@_silgen_name` with a Swift function body: that emits Swift code under
// the C symbol name and shadows the real implementation.

// RTLD_DEFAULT on Darwin is defined as ((void *) -2).
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

private func loadSymbol<T>(
    _ name: String,
    fallbackFrameworks: [String] = [],
    as type: T.Type
) -> T? {
    if let sym = dlsym(rtldDefault, name) {
        return unsafeBitCast(sym, to: T.self)
    }
    for path in fallbackFrameworks {
        if let handle = dlopen(path, RTLD_NOW),
           let sym = dlsym(handle, name) {
            return unsafeBitCast(sym, to: T.self)
        }
    }
    log.notice("symbol \(name) not found")
    log.notice("symbol \(name) not found")
    return nil
}

private func requireSymbol<T>(
    _ name: String,
    fallbackFrameworks: [String] = [],
    as type: T.Type
) -> T {
    if let sym: T = loadSymbol(name, fallbackFrameworks: fallbackFrameworks, as: type) {
        return sym
    }
    fatalError("MooOve: cannot resolve symbol \(name)")
}

// SkyLight is a private Apple framework. It is normally already loaded
// into any AppKit process (WindowServer client), so RTLD_DEFAULT finds
// these symbols without an explicit dlopen.
private enum SkyLight {
    private static let framework =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    static let cgsMainConnectionID: (@convention(c) () -> Int32)? =
        loadSymbol("CGSMainConnectionID",
                   fallbackFrameworks: [framework],
                   as: (@convention(c) () -> Int32).self)

    static let slsCopyManagedDisplaySpaces:
        (@convention(c) (Int32) -> Unmanaged<CFArray>?)? =
        loadSymbol("SLSCopyManagedDisplaySpaces",
                   fallbackFrameworks: [framework],
                   as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)

    static let slsCopyManagedDisplayForWindow:
        (@convention(c) (Int32, UInt32) -> Unmanaged<CFString>?)? =
        loadSymbol("SLSCopyManagedDisplayForWindow",
                   fallbackFrameworks: [framework],
                   as: (@convention(c) (Int32, UInt32) -> Unmanaged<CFString>?).self)

    static let slsManagedDisplayGetCurrentSpace:
        (@convention(c) (Int32, CFString) -> UInt64)? =
        loadSymbol("SLSManagedDisplayGetCurrentSpace",
                   fallbackFrameworks: [framework],
                   as: (@convention(c) (Int32, CFString) -> UInt64).self)

    // Try several candidate names for the async bridged-operation runner.
    // Apple has renamed this over macOS releases.
    static let slsPerformAsynchronousBridgedWindowManagementOperation:
        (@convention(c) (UnsafeRawPointer) -> Int64)? = {
            let candidates = [
                "SLSPerformAsynchronousBridgedWindowManagementOperation",
                "SLSPerformBridgedWindowManagementOperation",
                "SLSPerformBridgedOperation",
            ]
            for name in candidates {
                if let sym: (@convention(c) (UnsafeRawPointer) -> Int64) = loadSymbol(
                    name,
                    fallbackFrameworks: [framework],
                    as: (@convention(c) (UnsafeRawPointer) -> Int64).self
                ) {
                    log.notice("using \(name)")
                    return sym
                }
            }
            return nil
        }()

    // Switches the given display to the target Space.
    // Signature per SkyLight headers reverse-engineered by yabai/AeroSpace.
    static let cgsManagedDisplaySetCurrentSpace:
        (@convention(c) (Int32, CFString, UInt64) -> Int32)? =
        loadSymbol("CGSManagedDisplaySetCurrentSpace",
                   fallbackFrameworks: [framework],
                   as: (@convention(c) (Int32, CFString, UInt64) -> Int32).self)
}

private typealias ObjcMsgSendInitFn = @convention(c) (
    AnyObject,
    Selector,
    AnyObject,
    UInt64
) -> AnyObject

private let spacemover_objc_msgSend: ObjcMsgSendInitFn =
    requireSymbol("objc_msgSend", as: ObjcMsgSendInitFn.self)

// Private Accessibility API used by macOS window managers to map an
// AXUIElement to the WindowServer CGWindowID.
private typealias AXUIElementGetWindowFn = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<UInt32>
) -> AXError

private let _AXUIElementGetWindow: AXUIElementGetWindowFn = requireSymbol(
    "_AXUIElementGetWindow",
    fallbackFrameworks: [
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    ],
    as: AXUIElementGetWindowFn.self
)

// Legacy Carbon Process Manager: converts a Unix PID to a
// ProcessSerialNumber that the SkyLight front-process API accepts.
private typealias GetProcessForPIDFn =
    @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

private let spacemover_GetProcessForPID: GetProcessForPIDFn = requireSymbol(
    "GetProcessForPID",
    fallbackFrameworks: [
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    ],
    as: GetProcessForPIDFn.self
)

// Private SkyLight function used by the Dock to promote an app + window
// to the very front of the WindowServer's process stack.
//   options 0x100 = bring the app's windows forward
//   options 0x200 = bring only the specified window forward
private typealias SLPSSetFrontProcessWithOptionsFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus

private let spacemover_SLPSSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFn? =
    loadSymbol(
        "_SLPSSetFrontProcessWithOptions",
        fallbackFrameworks: [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        ],
        as: SLPSSetFrontProcessWithOptionsFn.self
    )

// Private CoreDock notification — same call the Dock itself uses when the
// user presses F3 / Mission Control. Sending "com.apple.expose.awake"
// toggles Mission Control. Used only for the optional
// "create a new Space if next doesn't exist" feature.
private typealias CoreDockSendNotificationFn =
    @convention(c) (CFString, Int32) -> Void

private let spacemover_CoreDockSendNotification: CoreDockSendNotificationFn? =
    loadSymbol(
        "CoreDockSendNotification",
        fallbackFrameworks: [
            "/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock",
            "/System/Library/PrivateFrameworks/HIServices.framework/HIServices",
        ],
        as: CoreDockSendNotificationFn.self
    )


