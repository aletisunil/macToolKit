import Foundation
import Testing
import UniformTypeIdentifiers

@testable import macToolKit

/// Quick Look hands the extension every `public.folder` and every
/// `public.zip-archive`. What it does with them is decided here.
struct PeekRoutingTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func peeksAnOrdinaryFolder() {
        #expect(PeekRouting.target(
            for: url("/Users/someone/Documents"),
            isDirectory: true, contentType: .folder) == .folder)
    }

    @Test func peeksAZipArchive() {
        #expect(PeekRouting.target(
            for: url("/Users/someone/Downloads/photos.zip"),
            isDirectory: false, contentType: .zip) == .archive)
    }

    /// A real .zip on macOS reports `public.zip-archive`, which is the *narrow*
    /// end of the pair — it conforms to `com.pkware.zip-archive`, not the other
    /// way round. Declaring the narrow one in `QLSupportedContentTypes` is what
    /// keeps the extension from being offered every zip-shaped document format.
    @Test func zipConformanceRunsFromPublicToPkware() throws {
        let pkware = try #require(UTType("com.pkware.zip-archive"))
        #expect(UTType.zip.conforms(to: pkware))
        #expect(!pkware.conforms(to: .zip))
    }

    /// The whole point of the trash rule: Space on the Dock's Trash must not
    /// open a browsable tree.
    @Test(arguments: [
        "/Users/someone/.Trash",
        "/Volumes/Backup/.Trashes",
        "/Volumes/Backup/.Trashes/501",
    ])
    func refusesTrashRoots(path: String) {
        #expect(PeekRouting.isTrashRoot(url(path)))
        #expect(PeekRouting.target(
            for: url(path), isDirectory: true, contentType: .folder) == .refuse)
    }

    /// Only the roots. A folder that happens to be sitting in the Trash is
    /// still an ordinary folder.
    @Test(arguments: [
        "/Users/someone/.Trash/Old Project",
        "/Users/someone/.Trash/a/b",
        "/Volumes/Backup/.Trashes/501/Notes",
        "/Users/someone/Documents/.Trashy",
        "/Users/someone/Documents/501",
    ])
    func peeksFoldersInsideTheTrash(path: String) {
        #expect(!PeekRouting.isTrashRoot(url(path)))
        #expect(PeekRouting.target(
            for: url(path), isDirectory: true, contentType: .folder) == .folder)
    }

    /// Declaring public.zip-archive must not drag in anything else. These are
    /// the types that would hurt most if it did.
    @Test(arguments: [
        "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.spreadsheetml.sheet",
        "org.idpf.epub-container",
        "com.apple.iwork.pages.sffpages",
    ])
    func refusesZipLikeDocumentFormats(identifier: String) throws {
        guard let type = UTType(identifier) else { return }  // not declared on this host
        #expect(PeekRouting.target(
            for: url("/tmp/file"), isDirectory: false, contentType: type) == .refuse,
            "\(identifier) must keep its own preview")
    }

    @Test func refusesPlainFiles() {
        #expect(PeekRouting.target(
            for: url("/tmp/notes.txt"), isDirectory: false, contentType: .plainText) == .refuse)
        #expect(PeekRouting.target(
            for: url("/tmp/mystery"), isDirectory: false, contentType: nil) == .refuse)
    }
}
