import Foundation
import Testing

@testable import macToolKit

/// The app writes these and the sandboxed Quick Look extension reads them, so
/// the shared container has to actually resolve — if the entitlement or the
/// group id ever drifts, `UserDefaults(suiteName:)` returns nil and the store
/// silently falls back to the app's own domain, where the extension can't see
/// it. These tests run in the app host, which carries the same entitlement.
@MainActor
struct PeekPreferencesTests {
    /// True only when the running host actually holds the app-group
    /// entitlement. CI signs ad-hoc (no Team ID, so no group container), so
    /// the container assertion below is gated on this rather than quietly
    /// passing against the fallback store.
    nonisolated static var isEntitledForGroup: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PeekDefaults.groupIdentifier
        ) != nil
    }

    /// Restores whatever was in the store so a test run doesn't clobber the
    /// developer's own Peek settings.
    private func withPreservedStore(_ body: () throws -> Void) rethrows {
        let store = PeekDefaults.store
        let keys = [
            PeekDefaults.showHiddenFiles, PeekDefaults.depthLevel,
            PeekDefaults.showPathBar, PeekDefaults.iconSize,
            PeekDefaults.didMigrateKey,
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
        #expect(PeekDefaults.groupIdentifier.hasPrefix("5432YAY2UX."),
                "group id must be team-prefixed to work without a profile")
    }

    @Test("Settings resolve to the shared app-group container, not the app domain",
          .enabled(if: isEntitledForGroup))
    func storeUsesTheAppGroupContainer() {
        // `UserDefaults(suiteName:)` falls back to `.standard` when the group
        // is unavailable — that fallback is invisible to the extension.
        let group = PeekDefaults.groupIdentifier
        #expect(PeekDefaults.store != UserDefaults.standard,
                "app group \(group) did not resolve; check the application-groups entitlement on both targets")
    }

    @Test("Values written by the app read back through the extension's loader")
    func settingsRoundTrip() {
        withPreservedStore {
            let store = PeekDefaults.store
            store.set(true, forKey: PeekDefaults.showHiddenFiles)
            store.set(7, forKey: PeekDefaults.depthLevel)
            store.set(false, forKey: PeekDefaults.showPathBar)
            store.set(PeekIconSize.large.rawValue,
                      forKey: PeekDefaults.iconSize)

            let settings = PeekSettings.load()
            #expect(settings.showHiddenFiles)
            #expect(settings.depthLevel == 7)
            #expect(!settings.showPathBar)
            #expect(settings.iconSize == .large)
        }
    }

    @Test("Depth level is clamped to the supported range on load")
    func depthLevelClamps() {
        withPreservedStore {
            let store = PeekDefaults.store
            store.set(99, forKey: PeekDefaults.depthLevel)
            #expect(PeekSettings.load().depthLevel == 10)
            store.set(-4, forKey: PeekDefaults.depthLevel)
            #expect(PeekSettings.load().depthLevel == 1)
        }
    }

    @Test("Defaults apply when nothing has been written")
    func unsetKeysFallBackToDefaults() {
        withPreservedStore {
            let store = PeekDefaults.store
            for key in [PeekDefaults.showHiddenFiles,
                        PeekDefaults.depthLevel,
                        PeekDefaults.showPathBar,
                        PeekDefaults.iconSize] {
                store.removeObject(forKey: key)
            }
            let settings = PeekSettings.load()
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
            let store = PeekDefaults.store
            for key in [PeekDefaults.showHiddenFiles,
                        PeekDefaults.depthLevel,
                        PeekDefaults.showPathBar,
                        PeekDefaults.iconSize,
                        PeekDefaults.didMigrateKey] {
                store.removeObject(forKey: key)
            }
            Self.setLegacy(PeekDefaults.depthLevel, 8)
            Self.setLegacy(PeekDefaults.showHiddenFiles, true)

            PeekDefaults.migrateFromGlobalDomain(into: store)

            let settings = PeekSettings.load()
            #expect(settings.depthLevel == 8, "legacy depth was not adopted")
            #expect(settings.showHiddenFiles, "legacy hidden-files was not adopted")
            #expect(store.bool(forKey: PeekDefaults.didMigrateKey))
            #expect(Self.legacyValue(PeekDefaults.depthLevel) == nil,
                    "legacy key was left behind in NSGlobalDomain")
        }
    }

    /// A value already in the container wins: the app may have written it
    /// after the extension adopted an older one.
    @Test("Migration doesn't clobber a value already in the container")
    func migrationKeepsExistingValues() {
        withPreservedStore {
            let store = PeekDefaults.store
            store.removeObject(forKey: PeekDefaults.didMigrateKey)
            store.set(4, forKey: PeekDefaults.depthLevel)
            Self.setLegacy(PeekDefaults.depthLevel, 9)

            PeekDefaults.migrateFromGlobalDomain(into: store)

            #expect(PeekSettings.load().depthLevel == 4)
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
        _ = PeekDefaults.store // force the lazy migration
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
