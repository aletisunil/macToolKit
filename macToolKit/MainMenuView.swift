import SwiftUI

struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        // Onboarding is skipped at login launches, so this is the way back to
        // it. Nothing is started until it has run, and the toggles are
        // disabled to match: left live they would report a feature as on while
        // it is stopped, and flipping one would fire a permission prompt
        // before the user has seen the welcome flow that explains it.
        if !appState.hasCompletedOnboarding {
            Button("Finish Setup…") {
                OnboardingWindowController.shared.show()
            }

            Divider()
        }

        Group {
            Toggle("Color Temperature", isOn: $appState.colorTemperatureEnabled)
            Toggle("Scroll Reverser", isOn: $appState.scrollReverserEnabled)
            Toggle("Rewritely", isOn: $appState.rewritelyEnabled)
            Toggle("Window Switcher", isOn: $appState.windowSwitcherEnabled)
        }
        .disabled(!appState.hasCompletedOnboarding)

        Divider()

        // A background check found this one; the menu is where the badge on
        // the menu bar icon leads. Clicking it opens Sparkle's update alert.
        if let version = updater.pendingUpdateVersion {
            Button("Update to \(version)…") {
                updater.checkForUpdates()
            }
        }

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Settings…") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",")

        Button("Quit macToolKit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
