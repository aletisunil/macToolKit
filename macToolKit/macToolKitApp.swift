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
        AppState.shared.startEnabledFeatures()
        OnboardingWindowController.shared.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            FinderBridge.handle(url)
        }
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
