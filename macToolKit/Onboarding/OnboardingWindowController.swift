import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var finished = false

    func show() {
        if window == nil {
            let content = OnboardingView().environmentObject(AppState.shared)
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to macToolKit"
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor.appWindowBackground
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Marks onboarding complete and starts whatever the user had enabled.
    /// Idempotent, because both the Done button and the window's red close
    /// button land here — dismissing the welcome must not strand the user
    /// seeing it again every launch with their features never started.
    func finish() {
        guard !finished else { return }
        finished = true
        AppState.shared.hasCompletedOnboarding = true
        window?.orderOut(nil)
        AppState.shared.startEnabledFeatures()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish() }
    }
}
