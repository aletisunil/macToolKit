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
