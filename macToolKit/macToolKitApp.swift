import AppKit
import SwiftUI

@main
struct MacToolKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    // MenuBarExtra's `systemImage:` draws at the symbol's regular weight, which
    // reads thin next to the system's own menu bar glyphs.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(systemSymbolName: "rectangle.3.group",
                            accessibilityDescription: "macToolKit")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .bold))
            ?? NSImage()
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instantiating starts Sparkle's scheduled background checks.
        _ = UpdaterManager.shared
        AppState.shared.applyLaunchAppearance()
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            AppState.shared.startEnabledFeatures()
        } else {
            // Features (and their permission prompts) wait until the user
            // finishes the welcome flow.
            OnboardingWindowController.shared.show()
        }
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
