import SwiftUI

struct MainMenuView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("Color Temperature", isOn: $appState.colorTemperatureEnabled)
        Toggle("Scroll Reverser", isOn: $appState.scrollReverserEnabled)
        Toggle("Rewritely", isOn: $appState.rewritelyEnabled)

        Divider()

        Toggle("Show in Dock", isOn: $appState.showInDock)

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
