import AppKit
import SwiftUI

/// AppKit-managed settings window so it can be opened from anywhere
/// (menu bar, dock reopen, mactoolkit:// URLs) without SwiftUI scene plumbing.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = SettingsView().environmentObject(AppState.shared)
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "macToolKit"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor.appWindowBackground
            window.setContentSize(NSSize(width: 920, height: 640))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
