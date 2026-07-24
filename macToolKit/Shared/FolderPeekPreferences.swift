import Foundation
import SwiftUI

enum FolderPeekIconSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case regular
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .regular: "Regular"
        case .large: "Large"
        }
    }

    var listPoints: CGFloat {
        switch self {
        case .small: 16
        case .regular: 22
        case .large: 30
        }
    }
}

struct FolderPeekSettings: Sendable {
    var showHiddenFiles: Bool
    var depthLevel: Int
    var showPathBar: Bool
    var iconSize: FolderPeekIconSize

    static func load() -> Self {
        let defaults = FolderPeekDefaults.store
        return Self(
            showHiddenFiles: defaults.object(forKey: FolderPeekDefaults.showHiddenFiles)
                as? Bool ?? false,
            depthLevel: max(1, min(10, defaults.object(forKey: FolderPeekDefaults.depthLevel)
                as? Int ?? 3)),
            showPathBar: defaults.object(forKey: FolderPeekDefaults.showPathBar)
                as? Bool ?? true,
            iconSize: FolderPeekIconSize(
                rawValue: defaults.string(forKey: FolderPeekDefaults.iconSize) ?? "")
                ?? .regular)
    }
}

@MainActor
final class FolderPeekPreferences: ObservableObject {
    @Published var showHiddenFiles: Bool { didSet { save(showHiddenFiles, key: FolderPeekDefaults.showHiddenFiles) } }
    @Published var depthLevel: Int {
        didSet {
            let clamped = max(1, min(10, depthLevel))
            if clamped != depthLevel { depthLevel = clamped; return }
            save(depthLevel, key: FolderPeekDefaults.depthLevel)
        }
    }
    @Published var showPathBar: Bool { didSet { save(showPathBar, key: FolderPeekDefaults.showPathBar) } }
    @Published var iconSize: FolderPeekIconSize { didSet { save(iconSize.rawValue, key: FolderPeekDefaults.iconSize) } }

    init() {
        let settings = FolderPeekSettings.load()
        showHiddenFiles = settings.showHiddenFiles
        depthLevel = settings.depthLevel
        showPathBar = settings.showPathBar
        iconSize = settings.iconSize
    }

    private func save(_ value: Any, key: String) {
        FolderPeekDefaults.store.set(value, forKey: key)
    }
}

/// Shared between the app and the sandboxed Quick Look extension.
///
/// This used to write through `CFPreferences` into `kCFPreferencesAnyApplication`
/// — i.e. `NSGlobalDomain` — which reaches the sandbox but litters every
/// process's global preferences with our keys and leaves them behind after
/// uninstall. An App Group container is the supported channel for exactly this
/// and stays confined to the app.
enum FolderPeekDefaults {
    static let showHiddenFiles = "showHiddenFiles"
    static let depthLevel = "depthLevel"
    static let showPathBar = "showPathBar"
    static let iconSize = "iconSize"

    /// Group id is team-prefixed and carries the debug bundle suffix, so a
    /// debug build keeps its own settings. Declared in each target's Info.plist
    /// from the `APP_GROUP_ID` build setting, keeping one source of truth with
    /// the entitlements.
    static let groupIdentifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "5432YAY2UX.com.sunilaleti.mactoolkit"

    // UserDefaults is thread-safe but not Sendable; the store is created once
    // and only ever read/written through its own synchronized API.
    nonisolated(unsafe) static let store: UserDefaults = {
        // A missing/unentitled group yields nil; falling back to `.standard`
        // keeps the app's own settings pane working rather than silently
        // dropping every write.
        let defaults = UserDefaults(suiteName: groupIdentifier) ?? .standard
        migrateFromGlobalDomain(into: defaults)
        return defaults
    }()

    // MARK: Legacy global-domain migration

    private static let legacyPrefix = "com.sunilaleti.mactoolkit.folderPeek."
    /// `layout` is not read any more — listed so the cleanup takes it with it.
    private static let legacyKeys = [
        "showHiddenFiles", "depthLevel", "showPathBar", "iconSize", "layout",
    ]
    /// Internal so the tests can reset it and re-run the migration.
    static let didMigrateKey = "didMigrateFromGlobalDomain"

    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// One-time move of any values still sitting in `NSGlobalDomain`, then
    /// deletes them from there.
    ///
    /// Only the app finishes the migration. The flag lives in the shared
    /// container, and the extension usually runs first — Finder loads it
    /// whenever someone presses Space on a folder, which needs no app launch.
    /// Writes to the global domain are redirected inside its sandbox, so if it
    /// were allowed to claim the migration the legacy keys would sit there
    /// forever, and if its reads are redirected too every existing user's
    /// settings would reset to defaults. It adopts whatever it can still read
    /// instead, and leaves the flag to the app.
    static func migrateFromGlobalDomain(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: didMigrateKey) else { return }
        adoptLegacyValues(into: defaults)
        guard !isAppExtension else { return }
        removeLegacyValues()
        defaults.set(true, forKey: didMigrateKey)
    }

    /// Copies legacy values into the group container without clobbering
    /// anything already set there. Idempotent, so the extension repeating it
    /// until the app runs costs nothing.
    private static func adoptLegacyValues(into defaults: UserDefaults) {
        for key in legacyKeys where key != "layout" {
            guard defaults.object(forKey: key) == nil,
                  let value = CFPreferencesCopyValue(
                    (legacyPrefix + key) as CFString,
                    kCFPreferencesAnyApplication,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesAnyHost)
            else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private static func removeLegacyValues() {
        for key in legacyKeys {
            CFPreferencesSetValue(
                (legacyPrefix + key) as CFString, nil,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }
}
