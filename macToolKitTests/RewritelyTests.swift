import Foundation
import Testing

@testable import macToolKit

@MainActor
struct RewritelyTests {
    @Test("Trigger is split at the caret while trailing text is preserved")
    func splitAtCaret() {
        let value = "Rewrite this;;fix and keep this"
        let caret = ("Rewrite this;;fix" as NSString).length

        let split = RewritelyController.splitAtCursor(
            ";;fix", value: value, cursor: NSRange(location: caret, length: 0))

        #expect(split?.before == "Rewrite this")
        #expect(split?.after == " and keep this")
    }

    @Test("Caret offsets use UTF-16 for text containing emoji")
    func splitUsesUTF16Offsets() {
        let prefix = "Hello 👋🏽"
        let value = prefix + ";;fix"

        let split = RewritelyController.splitAtCursor(
            ";;fix", value: value,
            cursor: NSRange(location: (value as NSString).length, length: 0))

        #expect(split?.before == prefix)
        #expect(split?.after == "")
    }

    @Test("A selection is not mistaken for a caret")
    func selectionDoesNotTriggerAXPath() {
        let split = RewritelyController.splitAtCursor(
            ";;fix", value: "Rewrite this;;fix",
            cursor: NSRange(location: 18, length: 1))

        #expect(split == nil)
    }

    @Test("Clipboard is restored only while Rewritely still owns it")
    func clipboardOwnership() {
        #expect(RewritelyController.shouldRestorePasteboard(
            currentChangeCount: 42, expectedChangeCount: 42))
        #expect(!RewritelyController.shouldRestorePasteboard(
            currentChangeCount: 43, expectedChangeCount: 42))
    }
}
