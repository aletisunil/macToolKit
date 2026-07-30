import Foundation
import UniformTypeIdentifiers

/// Reads folder contents off the main actor. Shallow listings are fast and
/// synchronous per call; the deep size/count pass for the panel header is a
/// separate cancellable walk.
actor FolderScanner {
    /// Entries per directory before the listing is truncated — the panel
    /// shows a "More items not shown" row instead of drowning in node_modules.
    static let listCap = 2000
    /// Deep-stat walk gives up beyond this many files and reports the
    /// running total as a lower bound.
    static let deepCap = 100_000

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .fileSizeKey,
        .localizedTypeDescriptionKey, .isHiddenKey,
    ]

    func list(_ url: URL, showHidden: Bool) -> PeekListing {
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants,
            .skipsPackageDescendants,
        ]
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: options,
            errorHandler: nil)
        else { return PeekListing(items: [], hasMoreItems: false) }

        var items: [PeekItem] = []
        items.reserveCapacity(Self.listCap)
        while items.count <= Self.listCap,
              let itemURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else {
                return PeekListing(items: [], hasMoreItems: false)
            }
            items.append(Self.item(for: itemURL))
        }

        let hasMoreItems = items.count > Self.listCap
        if hasMoreItems {
            items.removeLast()
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return PeekListing(items: items, hasMoreItems: hasMoreItems)
    }

    private static func item(for url: URL) -> PeekItem {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        return PeekItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            size: (isDirectory && !isPackage) ? nil : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            kind: values?.localizedTypeDescription
                ?? (isDirectory ? "Folder" : "Document"))
    }

    /// Walks the whole subtree summing file sizes, reporting progress every
    /// couple thousand files. Honors task cancellation between batches, so
    /// closing the panel abandons the walk promptly.
    /// Nonisolated on purpose: the walk can run for seconds and must not
    /// serialize against the shallow `list` calls on the actor.
    nonisolated func deepStats(of url: URL,
                   onProgress: @escaping @Sendable (PeekDeepStats) -> Void) -> PeekDeepStats {
        var bytes: Int64 = 0
        var files = 0
        var folderBytes: [URL: Int64] = [:]
        let root = url.standardizedFileURL
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [])
        while let next = enumerator?.nextObject() as? URL {
            if Task.isCancelled {
                return PeekDeepStats(bytes: bytes, files: files,
                                     folderBytes: folderBytes, partial: true)
            }
            files += 1
            if let values = try? next.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                values.isRegularFile ?? false {
                let fileBytes = Int64(values.totalFileAllocatedSize ?? 0)
                bytes += fileBytes

                var parent = next.deletingLastPathComponent().standardizedFileURL
                while parent.path.count >= root.path.count {
                    folderBytes[parent, default: 0] += fileBytes
                    if parent == root { break }
                    let ancestor = parent.deletingLastPathComponent()
                    guard ancestor != parent else { break }
                    parent = ancestor
                }
            }
            if files % 2000 == 0 {
                // Folder totals are published once at the end. Copying a
                // potentially large dictionary for every progress tick
                // would make the background walk needlessly expensive.
                onProgress(PeekDeepStats(bytes: bytes, files: files,
                                         folderBytes: [:], partial: true))
            }
            if files >= Self.deepCap {
                return PeekDeepStats(bytes: bytes, files: files,
                                     folderBytes: folderBytes, partial: true)
            }
        }
        return PeekDeepStats(bytes: bytes, files: files,
                             folderBytes: folderBytes, partial: false)
    }
}
