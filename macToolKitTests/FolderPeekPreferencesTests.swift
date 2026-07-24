import Foundation
import Testing

@testable import macToolKit

/// The app writes these and the sandboxed Quick Look extension reads them, so
/// the shared container has to actually resolve — if the entitlement or the
/// group id ever drifts, `UserDefaults(suiteName:)` returns nil and the store
/// silently falls back to the app's own domain, where the extension can't see
/// it. These tests run in the app host, which carries the same entitlement.
@MainActor
struct FolderPeekPreferencesTests {
    /// True only when the running host actually holds the app-group
    /// entitlement. CI signs ad-hoc (no Team ID, so no group container), so
    /// the container assertion below is gated on this rather than quietly
    /// passing against the fallback store.
    nonisolated static var isEntitledForGroup: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FolderPeekDefaults.groupIdentifier
        ) != nil
    }

    /// Restores whatever was in the store so a test run doesn't clobber the
    /// developer's own Folder Peek settings.
    private func withPreservedStore(_ body: () throws -> Void) rethrows {
        let store = FolderPeekDefaults.store
        let keys = [
            FolderPeekDefaults.showHiddenFiles, FolderPeekDefaults.depthLevel,
            FolderPeekDefaults.showPathBar, FolderPeekDefaults.iconSize,
            FolderPeekDefaults.didMigrateKey,
        ]
        let saved = keys.map { ($0, store.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { store.set(value, forKey: key) }
                else { store.removeObject(forKey: key) }
            }
        }
        try body()
    }

    @Test("Group id is team-prefixed")
    func groupIdentifierIsTeamPrefixed() {
        #expect(FolderPeekDefaults.groupIdentifier.hasPrefix("5432YAY2UX."),
                "group id must be team-prefixed to work without a profile")
    }

    @Test("Settings resolve to the shared app-group container, not the app domain",
          .enabled(if: isEntitledForGroup))
    func storeUsesTheAppGroupContainer() {
        // `UserDefaults(suiteName:)` falls back to `.standard` when the group
        // is unavailable — that fallback is invisible to the extension.
        let group = FolderPeekDefaults.groupIdentifier
        #expect(FolderPeekDefaults.store != UserDefaults.standard,
                "app group \(group) did not resolve; check the application-groups entitlement on both targets")
    }

    @Test("Values written by the app read back through the extension's loader")
    func settingsRoundTrip() {
        withPreservedStore {
            let store = FolderPeekDefaults.store
            store.set(true, forKey: FolderPeekDefaults.showHiddenFiles)
            store.set(7, forKey: FolderPeekDefaults.depthLevel)
            store.set(false, forKey: FolderPeekDefaults.showPathBar)
            store.set(FolderPeekIconSize.large.rawValue,
                      forKey: FolderPeekDefaults.iconSize)

            let settings = FolderPeekSettings.load()
            #expect(settings.showHiddenFiles)
            #expect(settings.depthLevel == 7)
            #expect(!settings.showPathBar)
            #expect(settings.iconSize == .large)
        }
    }

    @Test("Depth level is clamped to the supported range on load")
    func depthLevelClamps() {
        withPreservedStore {
            let store = FolderPeekDefaults.store
            store.set(99, forKey: FolderPeekDefaults.depthLevel)
            #expect(FolderPeekSettings.load().depthLevel == 10)
            store.set(-4, forKey: FolderPeekDefaults.depthLevel)
            #expect(FolderPeekSettings.load().depthLevel == 1)
        }
    }

    @Test("Defaults apply when nothing has been written")
    func unsetKeysFallBackToDefaults() {
        withPreservedStore {
            let store = FolderPeekDefaults.store
            for key in [FolderPeekDefaults.showHiddenFiles,
                        FolderPeekDefaults.depthLevel,
                        FolderPeekDefaults.showPathBar,
                        FolderPeekDefaults.iconSize] {
                store.removeObject(forKey: key)
            }
            let settings = FolderPeekSettings.load()
            #expect(!settings.showHiddenFiles)
            #expect(settings.depthLevel == 3)
            #expect(settings.showPathBar)
            #expect(settings.iconSize == .regular)
        }
    }

    /// The upgrade path for everyone already running 1.9: their settings sit
    /// in NSGlobalDomain and have to end up in the group container, exactly
    /// once, without the "already migrated" flag being claimed before the
    /// values actually moved.
    @Test("Legacy global-domain settings are adopted, then cleared")
    func legacyValuesAreMigrated() {
        withPreservedStore {
            let store = FolderPeekDefaults.store
            for key in [FolderPeekDefaults.showHiddenFiles,
                        FolderPeekDefaults.depthLevel,
                        FolderPeekDefaults.showPathBar,
                        FolderPeekDefaults.iconSize,
                        FolderPeekDefaults.didMigrateKey] {
                store.removeObject(forKey: key)
            }
            Self.setLegacy(FolderPeekDefaults.depthLevel, 8)
            Self.setLegacy(FolderPeekDefaults.showHiddenFiles, true)

            FolderPeekDefaults.migrateFromGlobalDomain(into: store)

            let settings = FolderPeekSettings.load()
            #expect(settings.depthLevel == 8, "legacy depth was not adopted")
            #expect(settings.showHiddenFiles, "legacy hidden-files was not adopted")
            #expect(store.bool(forKey: FolderPeekDefaults.didMigrateKey))
            #expect(Self.legacyValue(FolderPeekDefaults.depthLevel) == nil,
                    "legacy key was left behind in NSGlobalDomain")
        }
    }

    /// A value already in the container wins: the app may have written it
    /// after the extension adopted an older one.
    @Test("Migration doesn't clobber a value already in the container")
    func migrationKeepsExistingValues() {
        withPreservedStore {
            let store = FolderPeekDefaults.store
            store.removeObject(forKey: FolderPeekDefaults.didMigrateKey)
            store.set(4, forKey: FolderPeekDefaults.depthLevel)
            Self.setLegacy(FolderPeekDefaults.depthLevel, 9)

            FolderPeekDefaults.migrateFromGlobalDomain(into: store)

            #expect(FolderPeekSettings.load().depthLevel == 4)
        }
    }

    private static func setLegacy(_ key: String, _ value: Any) {
        CFPreferencesSetValue(
            ("com.sunilaleti.mactoolkit.folderPeek." + key) as CFString,
            value as AnyObject,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }

    private static func legacyValue(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(
            ("com.sunilaleti.mactoolkit.folderPeek." + key) as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }

    /// The old build wrote these into NSGlobalDomain, where they outlived the
    /// app. Touching the store runs the migration, which must clear them.
    @Test("Migration leaves no keys behind in the global domain")
    func globalDomainIsCleanedUp() {
        _ = FolderPeekDefaults.store // force the lazy migration
        for key in ["showHiddenFiles", "depthLevel", "showPathBar",
                    "iconSize", "layout"] {
            let legacy = "com.sunilaleti.mactoolkit.folderPeek." + key
            let value = CFPreferencesCopyValue(
                legacy as CFString,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
            #expect(value == nil, "\(legacy) is still in NSGlobalDomain")
        }
    }
}
