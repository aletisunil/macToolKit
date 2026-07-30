import AppKit
import ServiceManagement

/// Removes macToolKit and everything it wrote.
///
/// Dragging the app to the Trash already takes the Quick Look extension with
/// it — the `.appex` lives inside the bundle — but three things survive that:
/// PluginKit's registration record, which keeps a dead row in System Settings
/// until LaunchServices next rescans; the login item; and the settings, which
/// sit in the shared app group container rather than the app.
@MainActor
enum Uninstaller {
    /// Present where Homebrew keeps its cask receipts. Trashing the app behind
    /// Homebrew's back leaves its manifest claiming macToolKit is installed.
    private static let caskReceipts = [
        "/opt/homebrew/Caskroom/mactoolkit",
        "/usr/local/Caskroom/mactoolkit",
    ]

    static var installedViaHomebrew: Bool {
        caskReceipts.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Confirms, then removes everything and quits. Returns without doing
    /// anything if the user cancels.
    static func run() {
        guard confirm() else { return }

        AppState.shared.shutdown()
        try? SMAppService.mainApp.unregister()
        deregisterQuickLookExtension()
        removeUserData()
        trashAppAndQuit()
    }

    private static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall macToolKit?"

        var body = """
            This moves macToolKit to the Trash — including the Peek Quick Look \
            extension inside it — and deletes its settings, caches and login item.

            Any Accessibility or Screen Recording permission you granted has to \
            be removed by hand in System Settings.
            """
        if installedViaHomebrew {
            body = """
                macToolKit looks like it was installed with Homebrew. Uninstalling \
                here leaves Homebrew still thinking it is installed — run this in a \
                terminal instead:

                    brew uninstall --zap --cask mactoolkit

                """ + body
        }
        alert.informativeText = body

        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Steps

    /// Drops the Quick Look registration now rather than whenever
    /// LaunchServices next notices the bundle is gone. Best effort: `pluginkit`
    /// is the only way to ask, and it is fine for it to fail or be missing.
    private static func deregisterQuickLookExtension() {
        let appex = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("Peek.appex")
        guard let appex, FileManager.default.fileExists(atPath: appex.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-r", appex.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func removeUserData() {
        let manager = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sunilaleti.mactoolkit"
        let group = PeekDefaults.groupIdentifier
        let library = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")

        // Settings the Quick Look extension shares with the app.
        if let container = manager.containerURL(
            forSecurityApplicationGroupIdentifier: group) {
            try? manager.removeItem(at: container)
        }
        PeekDefaults.removeLegacyValues()

        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults().removePersistentDomain(forName: group)

        // removePersistentDomain leaves the backing files behind often enough
        // that they are worth deleting outright.
        for path in [
            "Preferences/\(bundleID).plist",
            "Preferences/\(group).plist",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "HTTPStorages/\(bundleID).binarycookies",
            "Saved Application State/\(bundleID).savedState",
            "Application Support/macToolKit",
        ] {
            try? manager.removeItem(at: library.appendingPathComponent(path))
        }
    }

    private static func trashAppAndQuit() {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
