import AppKit
import ApplicationServices

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

    /// Unhides/unminimizes if needed, forces the app frontmost and raises
    /// the window. Bringing another app forward from this (background,
    /// non-activating) app needs the private set-front call — cooperative
    /// activation declines a plain `activate()` while e.g. WhatsApp is
    /// frontmost. Other-space windows have no AX handle; fronting the app
    /// makes macOS jump to their Space.
    @MainActor
    func focus() {
        if isHidden { app?.unhide() }
        if let axWindow, isMinimized {
            AXWindow.setMinimized(axWindow, false)
        }
        let fronted = PrivateCGS.setFrontProcess(pid: pid, windowID: id)
        if let axWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        if !fronted {
            app?.activate()
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
