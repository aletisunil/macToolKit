import Foundation
import UniformTypeIdentifiers

/// One entry, as read off a content provider. Value type so it can cross from
/// the scanner actor to the main actor.
struct PeekItem: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    /// File byte size; nil for directories (Finder shows "--" there too).
    let size: Int64?
    let modified: Date?
    let kind: String
    /// Set for archive entries, whose `url` names nothing on disk, so the row
    /// can still show a real icon. nil means "ask the filesystem".
    let contentType: UTType?

    init(url: URL, name: String, isDirectory: Bool, isPackage: Bool,
         size: Int64?, modified: Date?, kind: String, contentType: UTType? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.kind = kind
        self.contentType = contentType
    }

    var id: URL { url }
}

/// One directory level.
struct PeekListing: Sendable, Equatable {
    var items: [PeekItem]
    /// True when the level holds more entries than the provider is willing to
    /// read. The panel shows a "More items not shown" row instead of drowning
    /// in node_modules.
    var hasMoreItems: Bool

    static let empty = PeekListing(items: [], hasMoreItems: false)
}

/// Recursive size/count totals for the header.
struct PeekDeepStats: Sendable {
    var bytes: Int64
    var files: Int
    /// Recursive byte totals keyed by directory, so every visible folder row
    /// can show a Finder-style calculated size without rescanning subtrees.
    var folderBytes: [URL: Int64]
    /// Still counting (progress update) or gave up at a cap.
    var partial: Bool
}
