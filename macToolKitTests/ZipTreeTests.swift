import Foundation
import Testing

@testable import macToolKit

/// The panel browses an archive as a tree, but a zip's central directory is a
/// flat list of paths that may or may not include directory records.
struct ZipTreeTests {
    private let archive = URL(fileURLWithPath: "/tmp/fixture.zip")

    private func file(_ path: String, _ bytes: Int64) -> ZipEntry {
        ZipEntry(path: path, uncompressedSize: bytes, compressedSize: bytes / 2,
                 modified: nil, isDirectory: false)
    }

    private func directory(_ path: String) -> ZipEntry {
        ZipEntry(path: path, uncompressedSize: 0, compressedSize: 0,
                 modified: nil, isDirectory: true)
    }

    private func tree(_ entries: [ZipEntry], showHidden: Bool = false) -> ZipTree {
        ZipTree(
            listing: ZipListing(entries: entries, hasMoreEntries: false),
            root: archive,
            showHidden: showHidden)
    }

    private func names(_ tree: ZipTree, at path: String) -> [String] {
        tree.listing(at: path).items.map(\.name)
    }

    @Test func buildsLevelsFromFlatPaths() {
        let tree = tree([file("a.txt", 10), file("docs/b.txt", 20)])
        #expect(names(tree, at: "") == ["a.txt", "docs"])
        #expect(names(tree, at: "docs") == ["b.txt"])
    }

    /// Archives written with `zip -D`, and plenty of other writers, record no
    /// directories at all. The intermediate folders have to be inferred.
    @Test func internsDirectoriesTheArchiveNeverRecorded() {
        let tree = tree([file("one/two/three.txt", 5)])
        #expect(names(tree, at: "") == ["one"])
        #expect(names(tree, at: "one") == ["two"])
        #expect(names(tree, at: "one/two") == ["three.txt"])
        #expect(tree.listing(at: "one").items.first?.isDirectory == true)
    }

    /// An explicit directory record for a folder already inferred from a file
    /// path must not produce a second row.
    @Test func explicitDirectoryRecordDoesNotDuplicateAnInferredOne() {
        let tree = tree([file("docs/b.txt", 20), directory("docs")])
        #expect(names(tree, at: "") == ["docs"])
        #expect(tree.listing(at: "").items.count == 1)
    }

    @Test func rollsFileSizesUpThroughEveryAncestor() {
        let tree = tree([file("one/two/a.txt", 100), file("one/b.txt", 20)])
        #expect(tree.totalBytes == 120)
        #expect(tree.fileCount == 2)
        #expect(tree.folderBytes[archive] == 120)
        #expect(tree.folderBytes[archive.appendingPathComponent("one")] == 120)
        #expect(tree.folderBytes[archive.appendingPathComponent("one/two")] == 100)
    }

    /// Directory records carry no payload, so they must not inflate the count.
    @Test func directoryRecordsAreNotCountedAsFiles() {
        let tree = tree([directory("docs"), file("docs/a.txt", 7)])
        #expect(tree.fileCount == 1)
        #expect(tree.totalBytes == 7)
    }

    @Test func honorsTheShowHiddenFilesSetting() {
        let entries = [file(".DS_Store", 6), file("visible.txt", 1)]
        #expect(names(tree(entries)) == ["visible.txt"])
        #expect(names(tree(entries, showHidden: true)) == [".DS_Store", "visible.txt"])
    }

    private func names(_ tree: ZipTree) -> [String] { names(tree, at: "") }

    @Test func sortsEachLevelByName() {
        let tree = tree([file("b.txt", 1), file("A.txt", 1), file("c10.txt", 1),
                         file("c9.txt", 1)])
        // localizedStandardCompare, so c9 sorts before c10 the way Finder does.
        #expect(names(tree) == ["A.txt", "b.txt", "c9.txt", "c10.txt"])
    }

    /// The entry cap truncates the central directory as a whole, so only the
    /// root level can honestly claim there is more to see.
    @Test func onlyTheRootReportsTruncation() {
        let tree = ZipTree(
            listing: ZipListing(entries: [file("one/a.txt", 1)], hasMoreEntries: true),
            root: archive,
            showHidden: false)
        #expect(tree.listing(at: "").hasMoreItems)
        #expect(!tree.listing(at: "one").hasMoreItems)
    }

    /// The Kind column sits next to rows reading "PNG image" and "Folder", so
    /// a lowercase type description would stand out as a bug.
    @Test func kindAlwaysStartsWithACapital() {
        #expect(ZipTree.kind(of: .plainText) == "Text")
        #expect(ZipTree.kind(of: .png) == "PNG image")
        #expect(ZipTree.kind(of: nil) == "Document")
    }

    @Test func filesCarryTheKindAndTypeOfTheirExtension() {
        let tree = tree([file("photo.png", 1)])
        let item = tree.listing(at: "").items.first
        #expect(item?.kind == "PNG image")
        #expect(item?.contentType == .png)
    }

    @Test func emptyArchiveHasAnEmptyRoot() {
        let tree = tree([])
        #expect(tree.listing(at: "").items.isEmpty)
        #expect(tree.totalBytes == 0)
        // An unknown path is empty rather than missing, so the panel never
        // has to special-case it.
        #expect(tree.listing(at: "nope").items.isEmpty)
    }

    /// Entry URLs hang off the archive's own URL. They name nothing on disk;
    /// they only have to be unique, since the panel uses them as row ids.
    @Test func entryURLsAreUniqueAndRootedAtTheArchive() {
        let tree = tree([file("one/a.txt", 1), file("two/a.txt", 1)])
        let one = tree.listing(at: "one").items.first?.url
        let two = tree.listing(at: "two").items.first?.url
        #expect(one == archive.appendingPathComponent("one/a.txt"))
        #expect(one != two)
    }
}
