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
        return Self(
            showHiddenFiles: FolderPeekDefaults.bool(
                for: FolderPeekDefaults.showHiddenFiles, fallback: false),
            depthLevel: max(1, min(10,
                FolderPeekDefaults.integer(
                    for: FolderPeekDefaults.depthLevel, fallback: 3))),
            showPathBar: FolderPeekDefaults.bool(
                for: FolderPeekDefaults.showPathBar, fallback: true),
            iconSize: FolderPeekIconSize(
                rawValue: FolderPeekDefaults.string(
                    for: FolderPeekDefaults.iconSize) ?? "") ?? .regular)
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
        FolderPeekDefaults.set(value, for: key)
    }
}

private enum FolderPeekDefaults {
    private static let prefix = "com.sunilaleti.mactoolkit.folderPeek."
    static let showHiddenFiles = "\(prefix)showHiddenFiles"
    static let depthLevel = "\(prefix)depthLevel"
    static let showPathBar = "\(prefix)showPathBar"
    static let iconSize = "\(prefix)iconSize"

    static func bool(for key: String, fallback: Bool) -> Bool {
        (value(for: key) as? NSNumber)?.boolValue ?? fallback
    }

    static func integer(for key: String, fallback: Int) -> Int {
        (value(for: key) as? NSNumber)?.intValue ?? fallback
    }

    static func string(for key: String) -> String? {
        value(for: key) as? String
    }

    static func set(_ value: Any, for key: String) {
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }

    private static func value(for key: String) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }
}
