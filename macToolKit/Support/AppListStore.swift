import AppKit
import Combine
import os

/// One app in a user-picked list, remembered by bundle id so the entry
/// survives updates and moves of the app itself.
struct AppRef: Codable, Identifiable, Equatable, Sendable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    /// The installed app's icon, or a generic one when it's gone.
    @MainActor
    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// A persisted list of apps - the exceptions of Quit on Close and Side
/// Buttons. Features read `bundleIDs` and subscribe to `$apps` to push
/// changes to their event-tap threads.
@MainActor
final class AppListStore: ObservableObject {
    @Published private(set) var apps: [AppRef] {
        didSet { save() }
    }

    var bundleIDs: Set<String> { Set(apps.map(\.bundleID)) }

    private let key: String

    /// `initial` seeds the list the first time only; once the user has edited
    /// it, an emptied list stays empty.
    init(key: String, initial: [AppRef] = []) {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([AppRef].self, from: data) {
            apps = saved
        } else {
            apps = initial
        }
    }

    func add(_ app: AppRef) {
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)
    }

    func remove(bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Asks the user for one or more apps from /Applications.
    static func chooseApps(message: String) -> [AppRef] {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return AppRef(bundleID: bundleID, name: name)
        }
    }
}

extension Logger {
    /// Feature-level log. Actions are logged at the default level so they
    /// persist and show up in `log show`.
    static func feature(_ category: String) -> Logger {
        Logger(subsystem: "com.sunilaleti.mactoolkit", category: category)
    }
}
