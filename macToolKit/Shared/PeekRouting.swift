import Foundation
import UniformTypeIdentifiers

/// What Quick Look should do with an item it offered to the extension.
enum PeekTarget: Equatable {
    case folder
    case archive
    /// Hand the item back so Quick Look shows whatever it would have shown
    /// without this extension.
    case refuse
}

enum PeekRouting {
    static func target(for url: URL, isDirectory: Bool, contentType: UTType?) -> PeekTarget {
        if isTrashRoot(url) { return .refuse }
        if isDirectory { return .folder }
        if contentType?.conforms(to: .zip) == true { return .archive }
        return .refuse
    }

    /// The Trash is a folder, so Quick Look offers it to this extension —
    /// including when Space is pressed on the Dock's Trash icon. Browsing it as
    /// a tree is not what anyone means by peeking.
    ///
    /// Only the trash roots are refused. An ordinary folder that happens to sit
    /// inside the Trash still previews normally.
    static func isTrashRoot(_ url: URL) -> Bool {
        let name = url.standardizedFileURL.lastPathComponent
        if name == ".Trash" || name == ".Trashes" { return true }
        // Per-uid subdirectory of a volume's trash, e.g. /Volumes/x/.Trashes/501.
        return url.standardizedFileURL.deletingLastPathComponent()
            .lastPathComponent == ".Trashes"
            && !name.isEmpty
            && name.allSatisfy(\.isNumber)
    }
}
