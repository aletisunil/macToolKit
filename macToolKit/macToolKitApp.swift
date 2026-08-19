import AppKit
import SwiftUI

@main
struct MacToolKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var updater = UpdaterManager.shared

    /// The menu bar glyph, optionally carrying the dot that says a background
    /// update is waiting. Drawn into a canvas with room for the dot so the
    /// menu bar clips neither it nor the symbol's outer strokes.
    private static func menuBarIcon(badged: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: "rectangle.3.group",
                             accessibilityDescription: "macToolKit")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
            ?? NSImage()
        let dot: CGFloat = 4
        let size = NSSize(width: symbol.size.width + dot,
                          height: symbol.size.height + dot)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: NSPoint(x: 0, y: dot / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
            if badged {
                // Template images keep only alpha, so the fill colour is
                // irrelevant - the menu bar tints it for light and dark.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - dot,
                                            y: size.height - dot,
                                            width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some Scene {
        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
        } label: {
            // MenuBarExtra's label only renders its image content - overlays
            // drawn on top of it are dropped - so the update badge is composed
            // into the image itself.
            Image(nsImage: Self.menuBarIcon(badged: updater.pendingUpdateVersion != nil))
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instantiating starts Sparkle's scheduled background checks.
        _ = UpdaterManager.shared
        AppState.shared.applyLaunchAppearance()
        if AppState.shared.hasCompletedOnboarding {
            AppState.shared.startEnabledFeatures()
        } else if isDefaultLaunch(notification) {
            // Features (and their permission prompts) wait until the user
            // finishes the welcome flow.
            OnboardingWindowController.shared.show()
        }
        // Otherwise: launched at login with onboarding still pending. Opening
        // a window and stealing focus while someone is logging in is the wrong
        // thing to do, so stay in the menu bar - MainMenuView offers "Finish
        // Setup…" for as long as this is unfinished.
    }

    /// False when macOS started us for its own reasons rather than because
    /// someone opened the app - a login item, an Apple event, state
    /// restoration. `SMAppService.mainApp` launches land here.
    @MainActor
    private func isDefaultLaunch(_ notification: Notification) -> Bool {
        notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey]
            as? Bool ?? true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    // Clicking the dock icon (when visible) opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SettingsWindowController.shared.show()
        }
        return true
    }
}
