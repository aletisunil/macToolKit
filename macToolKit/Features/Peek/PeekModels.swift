import AppKit
import SwiftUI

/// Sort order for the list; column headers toggle it.
struct PeekSort: Sendable, Equatable {
    enum Column: Sendable { case name, modified, size, kind }
    var column: Column = .name
    var ascending = true

    func areSorted(_ a: PeekItem, _ b: PeekItem) -> Bool {
        switch column {
        case .name:
            let order = a.name.localizedStandardCompare(b.name)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        case .modified:
            let first = a.modified ?? .distantPast
            let second = b.modified ?? .distantPast
            return ascending ? first < second : first > second
        case .size:
            let first = a.size ?? -1
            let second = b.size ?? -1
            return ascending ? first < second : first > second
        case .kind:
            let order = a.kind.localizedStandardCompare(b.kind)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// A node in the lazily-loaded tree the panel renders. `children == nil`
/// means "not fetched yet"; expanding a folder row triggers the fetch.
@MainActor
final class PeekNode: Identifiable {
    let item: PeekItem
    let depth: Int
    var children: [PeekNode]?
    var isExpanded = false
    var isLoading = false
    /// True on the synthetic trailing row of a capped directory listing.
    let isTruncationMarker: Bool

    init(item: PeekItem, depth: Int, isTruncationMarker: Bool = false) {
        self.item = item
        self.depth = depth
        self.isTruncationMarker = isTruncationMarker
    }

    nonisolated var id: URL { item.url }

    private var cachedIcon: NSImage?
    var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        // Archive entries have no file behind their URL, so the path-based
        // lookup would hand back the generic document icon for every row.
        let icon = item.contentType.map(NSWorkspace.shared.icon(for:))
            ?? NSWorkspace.shared.icon(forFile: item.url.path)
        cachedIcon = icon
        return icon
    }
}

/// Main-actor: formatters aren't Sendable and the panel formats on the
/// main actor only.
@MainActor
enum PeekFormat {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func size(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return bytes.string(fromByteCount: value)
    }

    static func modified(_ value: Date?) -> String {
        guard let value else { return "--" }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(value) {
            return "Today, \(time.string(from: value))"
        }
        if calendar.isDateInYesterday(value) {
            return "Yesterday, \(time.string(from: value))"
        }
        return "\(date.string(from: value)), \(time.string(from: value))"
    }
}
