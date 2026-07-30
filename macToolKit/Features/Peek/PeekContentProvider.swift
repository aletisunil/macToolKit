import Foundation

/// What the panel is browsing. A folder is walked lazily off the filesystem;
/// an archive's whole table of contents is known up front, so the two differ
/// in cost but not in shape.
protocol PeekContentProvider: Sendable {
    /// Children of `item`, or of the peeked root when `item` is nil.
    func children(of item: PeekItem?) async -> PeekListing

    /// Recursive size/count pass for the header. Runs off the main actor and
    /// honors task cancellation.
    func stats(onProgress: @escaping @Sendable (PeekDeepStats) -> Void) -> PeekDeepStats

    /// False inside an archive: an entry has no file on disk to open.
    var canOpenItems: Bool { get }
}

// MARK: - Folders

struct FolderContentProvider: PeekContentProvider {
    let root: URL
    let showHidden: Bool
    private let scanner = FolderScanner()

    init(root: URL, showHidden: Bool) {
        self.root = root
        self.showHidden = showHidden
    }

    func children(of item: PeekItem?) async -> PeekListing {
        await scanner.list(item?.url ?? root, showHidden: showHidden)
    }

    func stats(onProgress: @escaping @Sendable (PeekDeepStats) -> Void) -> PeekDeepStats {
        scanner.deepStats(of: root, onProgress: onProgress)
    }

    var canOpenItems: Bool { true }
}

// MARK: - Archives

/// Serves an archive's central directory as a browsable tree.
///
/// The whole listing is built at init: a zip's table of contents is a single
/// bounded read, so there is nothing to stream and the header's totals are
/// exact immediately.
struct ArchiveContentProvider: PeekContentProvider {
    private let root: URL
    private let tree: ZipTree

    init(archive url: URL, showHidden: Bool) throws {
        root = url
        tree = ZipTree(
            listing: try ZipCentralDirectory.read(url),
            root: url,
            showHidden: showHidden)
    }

    func children(of item: PeekItem?) async -> PeekListing {
        tree.listing(at: path(of: item))
    }

    func stats(onProgress: @escaping @Sendable (PeekDeepStats) -> Void) -> PeekDeepStats {
        PeekDeepStats(
            bytes: tree.totalBytes, files: tree.fileCount,
            folderBytes: tree.folderBytes, partial: false)
    }

    var canOpenItems: Bool { false }

    /// Entry URLs hang off the archive's own URL, so the archive-relative path
    /// is what is left after dropping that prefix.
    private func path(of item: PeekItem?) -> String {
        guard let item else { return "" }
        return String(item.url.path
            .dropFirst(root.path.count)
            .drop(while: { $0 == "/" }))
    }
}
