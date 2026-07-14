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
    /// CGS id of the window's Space when it lived on another Space at
    /// snapshot time; nil on the current space. Drives the Space badge and
    /// filters. `focus()` re-resolves the Space live instead of trusting
    /// this — the snapshot may predate a Space change (e.g. the app just
    /// went fullscreen) and a stale nil would skip the explicit switch.
    let spaceID: PrivateCGS.SpaceID?
    let isOnActiveSpace: Bool
    let frame: CGRect

    var displayTitle: String { title.isEmpty ? appName : title }

    private var app: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    /// The window's Space right now, when that Space is not the current
    /// one. Resolved live because the snapshot's `spaceID` can be stale —
    /// most notably a snapshot taken on the normal Space just before the
    /// frontmost app went fullscreen, where every window still reads
    /// "current space". nil = already current / can't tell, so no switch.
    private var otherSpaceIDNow: PrivateCGS.SpaceID? {
        let liveIDs = PrivateCGS.spaceIDs(of: id)
        let ids = liveIDs.isEmpty ? spaceID.map { [$0] } ?? [] : liveIDs
        guard !ids.isEmpty else { return nil }
        let spaces = PrivateCGS.spaces()
        // Sticky windows list several spaces; one of them being current
        // means the window is already reachable without a switch.
        if ids.contains(where: { spaces[$0]?.isCurrent == true }) { return nil }
        return ids.first
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
        if let sid = otherSpaceIDNow {
            _ = PrivateCGS.switchToSpace(sid)
        }
        let fronted = PrivateCGS.setFrontProcess(pid: pid, windowID: id)
        _ = PrivateCGS.makeKeyWindow(pid: pid, windowID: id)
        if let axWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        if !fronted || axWindow == nil {
            app?.activate()
        }

        // A cross-Space arrival can re-activate the destination Space's
        // remembered front app over the one just fronted (the transition
        // finishes asynchronously ~0.5 s later). Check once after it settles
        // and re-assert if something stomped the target.
        focusGeneration += 1
        let generation = focusGeneration
        Task { [self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard generation == focusGeneration,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
            else { return }
            if let sid = otherSpaceIDNow {
                _ = PrivateCGS.switchToSpace(sid)
            }
            _ = PrivateCGS.setFrontProcess(pid: pid, windowID: id)
            _ = PrivateCGS.makeKeyWindow(pid: pid, windowID: id)
            if let axWindow {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
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
