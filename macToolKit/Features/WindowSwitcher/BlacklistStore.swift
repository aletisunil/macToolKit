import AppKit
import Foundation

/// Per-app switcher exceptions, AltTab-style: hide an app's windows from the
/// list, and/or stop intercepting the trigger while the app is frontmost
/// (essential for VMs and remote desktops that need the real Cmd-Tab).
struct BlacklistEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleID: String
    var name: String
    /// Don't show this app's windows in the switcher.
    var hideWindows: Bool
    /// Pass the trigger chord through while this app is frontmost.
    var dontIntercept: Bool

    init(id: UUID = UUID(), bundleID: String, name: String,
         hideWindows: Bool = true, dontIntercept: Bool = false) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.hideWindows = hideWindows
        self.dontIntercept = dontIntercept
    }
}

@MainActor
final class BlacklistStore: ObservableObject {
    @Published var entries: [BlacklistEntry] {
        didSet { save() }
    }

    private static let key = "switcherBlacklist"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([BlacklistEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    var hiddenBundleIDs: Set<String> {
        Set(entries.filter(\.hideWindows).map(\.bundleID))
    }

    var dontInterceptBundleIDs: Set<String> {
        Set(entries.filter(\.dontIntercept).map(\.bundleID))
    }

    func add(bundleID: String, name: String) {
        guard !entries.contains(where: { $0.bundleID == bundleID }) else { return }
        entries.append(BlacklistEntry(bundleID: bundleID, name: name))
    }
}
