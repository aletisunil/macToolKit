import AppKit
import SwiftUI

@main
struct MacToolKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MainMenuView()
                .environmentObject(appState)
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 14, weight: .bold))
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
