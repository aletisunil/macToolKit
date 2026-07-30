import Foundation
import UniformTypeIdentifiers

/// Turns a zip's flat list of paths into the per-directory listings the panel
/// browses.
///
/// Archives routinely omit directory records — `zip -D` does it on purpose, and
/// plenty of writers never emit them — so every path component gets a folder
/// interned for it whether or not the archive said so.
struct ZipTree: Sendable {
    /// Listings keyed by archive-relative directory path; "" is the root.
    let children: [String: PeekListing]
    let totalBytes: Int64
    let fileCount: Int
    /// Recursive byte totals keyed by the synthetic entry URLs, matching what
    /// `FolderScanner.deepStats` produces for a real directory.
    let folderBytes: [URL: Int64]

    /// - Parameter root: the archive's own URL. Entry URLs hang off it, which
    ///   makes them unique — all a row id needs — without naming a real file.
    init(listing: ZipListing, root: URL, showHidden: Bool) {
        var items: [String: [String: PeekItem]] = [:]
        var folderBytes: [URL: Int64] = [:]
        var totalBytes: Int64 = 0
        var fileCount = 0

        for entry in listing.entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            for depth in components.indices {
                let isLeaf = depth == components.count - 1
                let parent = components[0..<depth].joined(separator: "/")
                let name = components[depth]
                let url = root.appendingPathComponent(
                    components[0...depth].joined(separator: "/"))

                if isLeaf, !entry.isDirectory {
                    let type = UTType(filenameExtension: url.pathExtension)
                    items[parent, default: [:]][name] = PeekItem(
                        url: url, name: name, isDirectory: false, isPackage: false,
                        size: entry.uncompressedSize, modified: entry.modified,
                        kind: Self.kind(of: type),
                        contentType: type ?? .data)
                } else if items[parent]?[name] == nil {
                    // A directory record for a folder already interned by an
                    // earlier entry adds nothing, so first writer wins.
                    items[parent, default: [:]][name] = PeekItem(
                        url: url, name: name, isDirectory: true, isPackage: false,
                        size: nil, modified: isLeaf ? entry.modified : nil,
                        kind: "Folder", contentType: .folder)
                }
            }

            guard !entry.isDirectory else { continue }
            fileCount += 1
            totalBytes += entry.uncompressedSize

            // Charge the bytes to every ancestor, the way FolderScanner's deep
            // walk does, so folder rows show a recursive total.
            var ancestor = root
            folderBytes[ancestor, default: 0] += entry.uncompressedSize
            for component in components.dropLast() {
                ancestor = ancestor.appendingPathComponent(component)
                folderBytes[ancestor, default: 0] += entry.uncompressedSize
            }
        }

        var children: [String: PeekListing] = [:]
        for (parent, level) in items {
            var visible = Array(level.values)
            if !showHidden {
                visible.removeAll { $0.name.hasPrefix(".") }
            }
            visible.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            children[parent] = PeekListing(
                items: visible,
                // Only the root can honestly claim there is more: the entry cap
                // truncates the central directory, not one subtree.
                hasMoreItems: listing.hasMoreEntries && parent.isEmpty)
        }
        if children[""] == nil {
            children[""] = PeekListing(items: [], hasMoreItems: listing.hasMoreEntries)
        }

        self.children = children
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.folderBytes = folderBytes
    }

    /// Children of the directory at `path` ("" is the archive root).
    func listing(at path: String) -> PeekListing {
        children[path] ?? .empty
    }

    /// Kind for an archive entry. A real file gets this from its own
    /// `localizedTypeDescription`; an entry has no file to ask, so the type's
    /// description is as close as it gets. Most of those already read as
    /// "PNG image" or "MacBinary archive", but a few (notably plain text) come
    /// back lowercase, which looks like a bug next to them — so lift the first
    /// letter without touching the rest of the casing.
    static func kind(of type: UTType?) -> String {
        guard let description = type?.localizedDescription, !description.isEmpty else {
            return "Document"
        }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}
