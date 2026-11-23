import AppKit
import SwiftUI

@main
struct MacToolKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon and its menu are AppKit (StatusMenuController):
        // a SwiftUI menu closes after every toggle. SwiftUI's App still runs
        // the app - it supplies the main menu the Settings window relies on
        // for Edit commands when the Dock icon is shown - and an App needs a
        // scene, so this one is declared but never inserted.
        MenuBarExtra("macToolKit", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instantiating starts Sparkle's scheduled background checks.
        _ = UpdaterManager.shared
        StatusMenuController.shared.install()
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
        // thing to do, so stay in the menu bar - the status menu offers "Finish
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
