import AppKit
import ApplicationServices

/// Invalidates a pending post-focus verification when another focus starts.
@MainActor private var focusGeneration = 0

/// Snapshot of one switchable window. Built off the main thread by
/// `WindowTracker`; AXUIElement and NSImage are thread-safe to hold and
/// read, hence the unchecked Sendable.
struct WindowInfo: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    /// nil for windows on other Spaces — the Accessibility API can't see
    /// those, so they can only be focused by activating their app.
    let axWindow: AXUIElement?
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let icon: NSImage?
    let title: String
    let isMinimized: Bool
    /// The owning app is hidden (⌘H).
    let isHidden: Bool
    let isFullscreen: Bool
    /// Mission Control number of the window's Space; nil on the current
    /// space, for fullscreen spaces, or when the private API is unavailable.
    let spaceNumber: Int?
    let isOnActiveSpace: Bool
    let frame: CGRect

    var displayTitle: String { title.isEmpty ? appName : title }

    private var app: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    /// The window's Space right now, when that Space is not the current
    /// one. Resolved live at focus time rather than from the snapshot — the
    /// snapshot can be stale, most notably one taken on the normal Space
    /// just before the frontmost app went fullscreen, where every window
    /// still reads "current space". nil = already current / can't tell, so
    /// no switch. (A closed window also resolves to no Spaces — deliberately
    /// no switch for it either.)
    private var otherSpaceIDNow: PrivateCGS.SpaceID? {
        let ids = PrivateCGS.spaceIDs(of: id)
        guard !ids.isEmpty else { return nil }
        let spaces = PrivateCGS.spaces()
        // Sticky windows list several spaces; one of them being current
        // means the window is already reachable without a switch.
        if ids.contains(where: { spaces[$0]?.isCurrent == true }) { return nil }
        return ids.first
    }

    /// One focus attempt: switch to the window's Space when it lives on
    /// another one, force the app frontmost, key the window and raise it.
    /// Shared by `focus()` and its post-transition re-assert.
    @MainActor
    private func assertFrontmost() -> (fronted: Bool, keyed: Bool, switchedSpace: Bool) {
        var switchedSpace = false
        if let sid = otherSpaceIDNow {
            switchedSpace = PrivateCGS.switchToSpace(sid)
        }
        let fronted = PrivateCGS.setFrontProcess(pid: pid, windowID: id)
        let keyed = PrivateCGS.makeKeyWindow(pid: pid, windowID: id)
        if let axWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        return (fronted, keyed, switchedSpace)
    }

    /// The user pressed a key or clicked since roughly the last focus()
    /// call — the re-assert must not fight a deliberate focus change
    /// (Cmd-Tab, Dock click) made while it was pending.
    @MainActor
    private static func userActedRecently(within seconds: Double) -> Bool {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .contains {
                CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                        eventType: $0) < seconds
            }
    }

    /// Unhides/unminimizes if needed, forces the app frontmost, keys the
    /// window and raises it. Bringing another app forward from this
    /// (background, non-activating) app needs the private set-front call —
    /// cooperative activation declines a plain `activate()` while e.g.
    /// WhatsApp is frontmost. Set-front/makeKey alone never *reliably*
    /// switches Spaces though (and never exits a fullscreen Space), so
    /// cross-Space focus switches Spaces explicitly first.
    @MainActor
    func focus() {
        if isHidden { app?.unhide() }
        if let axWindow, isMinimized {
            AXWindow.setMinimized(axWindow, false)
        }
        let attempt = assertFrontmost()
        // Cooperative fallback only when the private path failed somewhere:
        // an unconditional activate() can raise the app's remembered key
        // window on a *different* Space and undo the explicit switch.
        if !attempt.fronted || (axWindow == nil && !attempt.keyed) {
            app?.activate()
        }

        // A cross-Space arrival can re-activate the destination Space's
        // remembered front app over the one just fronted (the transition
        // finishes asynchronously ~0.5 s later). Check once after it
        // settles and re-assert if something stomped the target. Same-space
        // focuses have no transition, so nothing to guard there.
        guard attempt.switchedSpace else { return }
        focusGeneration += 1
        let generation = focusGeneration
        Task { [self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard generation == focusGeneration,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
                  !Self.userActedRecently(within: 0.55)
            else { return }
            _ = assertFrontmost()
        }
    }

    // MARK: Actions while the switcher is open

    /// Closes this window — but if it's the app's only remaining switchable
    /// window, quits the app instead, so closing a single-window app from the
    /// switcher fully dismisses it rather than leaving a windowless process
    /// behind. Multi-window apps still lose just the one window.
    @MainActor
    func close() {
        guard let axWindow else { return }
        if AXWindow.switchableWindowCount(pid: pid) <= 1 {
            app?.terminate()
        } else {
            AXWindow.close(axWindow)
        }
    }

    @MainActor
    func toggleMinimized() {
        guard let axWindow else { return }
        AXWindow.setMinimized(axWindow, !isMinimized)
    }

    @MainActor
    func toggleFullscreen() {
        guard let axWindow else { return }
        AXWindow.setFullscreen(axWindow, !isFullscreen)
    }

    @MainActor
    func hideApp() {
        app?.hide()
    }

    @MainActor
    func quitApp() {
        app?.terminate()
    }
}
