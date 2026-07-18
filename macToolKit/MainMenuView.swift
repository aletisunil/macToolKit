import SwiftUI

struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        Toggle("Color Temperature", isOn: $appState.colorTemperatureEnabled)
        Toggle("Scroll Reverser", isOn: $appState.scrollReverserEnabled)
        Toggle("Rewritely", isOn: $appState.rewritelyEnabled)
        Toggle("Window Switcher", isOn: $appState.windowSwitcherEnabled)

        Divider()

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
