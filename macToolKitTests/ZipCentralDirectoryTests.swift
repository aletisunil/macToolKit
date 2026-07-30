import Foundation
import Testing

@testable import macToolKit

/// Peek lists a zip straight out of its central directory, so a malformed or
/// hostile archive must degrade to a short listing rather than trap, hang or
/// hand back nonsense.
struct ZipCentralDirectoryTests {
    // MARK: Fixtures

    /// Builds an archive with `/usr/bin/zip` and hands back its URL. The
    /// directory is removed when `body` returns.
    private func withArchive(
        files: [String: String],
        arguments: [String] = [],
        _ body: (URL) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-zip-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (path, contents) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        let archive = root.appendingPathComponent("fixture.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-r"] + arguments + [archive.path, "."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "zip failed to build the fixture")

        try body(archive)
    }

    private func entry(_ listing: ZipListing, _ path: String) -> ZipEntry? {
        listing.entries.first { $0.path == path }
    }

    // MARK: Tests

    @Test func readsAFlatArchive() throws {
        try withArchive(files: ["a.txt": "hello", "b.txt": "worldly"]) { url in
            let listing = try ZipCentralDirectory.read(url)
            #expect(!listing.hasMoreEntries)
            #expect(entry(listing, "a.txt")?.uncompressedSize == 5)
            #expect(entry(listing, "b.txt")?.uncompressedSize == 7)
            #expect(entry(listing, "a.txt")?.isDirectory == false)
        }
    }

    @Test func readsNestedPathsAndMarksDirectories() throws {
        try withArchive(files: ["docs/deep/note.txt": "x"]) { url in
            let listing = try ZipCentralDirectory.read(url)
            #expect(entry(listing, "docs")?.isDirectory == true)
            #expect(entry(listing, "docs/deep")?.isDirectory == true)
            #expect(entry(listing, "docs/deep/note.txt")?.isDirectory == false)
        }
    }

    /// Plenty of archives carry no directory records at all. The tree has to
    /// come out of the paths themselves, which is `ArchiveContentProvider`'s
    /// job — the parser just has to not invent them.
    @Test func archiveWithoutDirectoryRecordsStillListsFiles() throws {
        try withArchive(files: ["one/two/three.txt": "y"], arguments: ["-D"]) { url in
            let listing = try ZipCentralDirectory.read(url)
            #expect(listing.entries.contains { $0.path == "one/two/three.txt" })
            #expect(!listing.entries.contains { $0.isDirectory })
        }
    }

    @Test func readsModificationDates() throws {
        try withArchive(files: ["a.txt": "hello"]) { url in
            let listing = try ZipCentralDirectory.read(url)
            let modified = try #require(entry(listing, "a.txt")?.modified)
            // MS-DOS timestamps have a two-second resolution and no time zone.
            #expect(abs(modified.timeIntervalSinceNow) < 300)
        }
    }

    /// An empty archive is nothing but a 22-byte end-of-central-directory
    /// record, so it is written by hand — `zip` refuses to create one.
    @Test func emptyArchiveReadsAsEmpty() throws {
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-empty-archive-\(UUID().uuidString).zip")
        try Data(eocd).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let listing = try ZipCentralDirectory.read(url)
        #expect(listing.entries.isEmpty)
        #expect(!listing.hasMoreEntries)
    }

    @Test func rejectsAFileThatIsNotAnArchive() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-not-a-zip-\(UUID().uuidString).zip")
        try String(repeating: "not a zip at all. ", count: 200)
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ZipReadError.self) {
            _ = try ZipCentralDirectory.read(url)
        }
    }

    @Test func rejectsAnEmptyFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-empty-\(UUID().uuidString).zip")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ZipReadError.self) {
            _ = try ZipCentralDirectory.read(url)
        }
    }

    /// A download that stopped halfway keeps its local file headers but loses
    /// the central directory that lives at the end.
    @Test func rejectsATruncatedArchive() throws {
        try withArchive(files: ["a.txt": "hello", "b.txt": "world"]) { url in
            let whole = try Data(contentsOf: url)
            let cut = url.deletingLastPathComponent()
                .appendingPathComponent("truncated.zip")
            try whole.prefix(whole.count / 2).write(to: cut)

            #expect(throws: ZipReadError.self) {
                _ = try ZipCentralDirectory.read(cut)
            }
        }
    }

    /// Corruption inside the directory must end the listing, not throw away
    /// the records that were already read or run off the end of the buffer.
    @Test func stopsAtACorruptRecordWithoutLosingEarlierOnes() throws {
        try withArchive(files: ["a.txt": "hello", "b.txt": "world"]) { url in
            var bytes = [UInt8](try Data(contentsOf: url))
            // Find the second central-directory header and break its signature.
            let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
            var found = 0
            for index in 0..<(bytes.count - 4) where Array(bytes[index..<index + 4]) == signature {
                found += 1
                if found == 2 { bytes[index + 3] = 0xFF; break }
            }
            #expect(found >= 2, "fixture should hold at least two records")

            let damaged = url.deletingLastPathComponent()
                .appendingPathComponent("damaged.zip")
            try Data(bytes).write(to: damaged)

            let listing = try ZipCentralDirectory.read(damaged)
            #expect(listing.entries.count == 1)
            #expect(listing.hasMoreEntries)
        }
    }

    /// Nothing is ever extracted, but a traversing path would still build a
    /// nonsense tree in the panel.
    @Test func stripsTraversalComponentsFromPaths() throws {
        try withArchive(files: ["a.txt": "hello"]) { url in
            let listing = try ZipCentralDirectory.read(url)
            #expect(listing.entries.allSatisfy { !$0.path.contains("..") })
            #expect(listing.entries.allSatisfy { !$0.path.hasPrefix("/") })
            // `zip -r . ` records paths as "./a.txt"; the leading "." is dropped.
            #expect(listing.entries.contains { $0.path == "a.txt" })
        }
    }
}
