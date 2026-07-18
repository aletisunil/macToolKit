import SwiftUI

@main
struct MacToolKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra("macToolKit", systemImage: "wrench.and.screwdriver") {
            MainMenuView()
                .environmentObject(appState)
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
