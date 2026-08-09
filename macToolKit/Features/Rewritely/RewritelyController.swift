import AppKit
import CoreGraphics
import Combine

/// Watches typing through a listen-only key tap. When the buffer ends with a
/// configured trigger word, rewrites the focused field's text in place:
/// Accessibility value read/write when possible, clipboard simulation as a
/// fallback for fields that don't expose a settable AX value.
@MainActor
final class RewritelyController: ObservableObject {
    let triggers = TriggerStore()
    private let engine = RewriteEngine()

    @Published private(set) var tapActive = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPoll: Timer?
    private var watchdog: Timer?
    private var buffer = ""
    private var busy = false
    private var interactionGeneration = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard tap == nil else { return }
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            // Retry until access is granted so the user doesn't have to
            // toggle the feature again after visiting System Settings.
            if permissionPoll == nil {
                permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    Task { @MainActor in
                        let rewritely = AppState.shared.rewritely
                        guard AppState.shared.rewritelyEnabled else {
                            rewritely.cancelPermissionPoll()
                            return
                        }
                        if Permissions.accessibilityGranted {
                            rewritely.cancelPermissionPoll()
                            rewritely.start()
                        }
                    }
                }
            }
            return
        }
        cancelPermissionPoll()
        attachTap()

        // Switching apps means a different text field — drop the buffer.
        if observers.isEmpty {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.buffer = "" }
            }
            observers.append(observer)
        }
        // Started even if the tap creation above failed, so it can retry.
        startWatchdog()
    }

    /// One attempt at creating the tap. `CGEvent.tapCreate` can fail even with
    /// Accessibility granted — most often right after login, while the window
    /// server and TCC are still settling — and a failure here used to be
    /// terminal: no watchdog was started, the permission poll had already been
    /// cancelled, and nothing else called `start()` again, so trigger words
    /// silently did nothing until the feature was toggled or the app
    /// relaunched. The watchdog retries this every 2 s instead.
    private func attachTap() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: rewriteTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
    }

    func cancelPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func stop() {
        cancelPermissionPoll()
        watchdog?.invalidate()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without this the server-side tap leaks (stays registered,
            // disabled) every time the feature is toggled off.
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapActive = false
        buffer = ""
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func reenableAfterTimeout() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// macOS disables taps it considers too slow. The in-callback re-enable
    /// only fires if the disable notification is actually delivered, and this
    /// tap's source lives on the main run loop, so a stalled main thread is
    /// exactly when the notification is most likely to be missed. Poll as a
    /// backstop — same watchdog ScrollTap and SwitcherTap run — and keep
    /// `tapActive` honest so the settings pane stops claiming it is running.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let tap = self.tap else {
                    // Tap creation failed earlier; keep trying rather than
                    // leaving the feature dead until the next toggle.
                    self.attachTap()
                    return
                }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                self.tapActive = CGEvent.tapIsEnabled(tap: tap)
            }
        }
    }

    // MARK: Buffer

    func handle(_ event: CGEvent, type: CGEventType) {
        if busy {
            if !KeySim.isSynthetic(event) {
                interactionGeneration &+= 1
            }
            return
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            buffer = ""
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 { // delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4,
                                       actualStringLength: &length,
                                       unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)

        // Arrows/function keys land in the Unicode PUA range — cursor moved,
        // buffer no longer reflects what's at the insertion point.
        if typed.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
            buffer = ""
            return
        }

        buffer += typed
        if buffer.count > 128 {
            buffer.removeFirst(buffer.count - 128)
        }

        if let trigger = triggers.match(suffixOf: buffer) {
            buffer = ""
            busy = true
            Task { @MainActor in
                await self.runRewrite(trigger)
                self.busy = false
            }
        }
    }

    // MARK: Rewrite flow

    private func runRewrite(_ trigger: RewriteTrigger) async {
        let generation = interactionGeneration
        // Let the final trigger keystroke settle in the target app.
        try? await Task.sleep(for: .milliseconds(120))
        guard interactionGeneration == generation else { return }

        // AX is safe for reading the field, but writing kAXValue directly is
        // not: several web/Electron editors update their visible AX value
        // without updating the real editor model. The field then appears
        // rewritten but can no longer be edited or copied correctly. Use AX
        // only to capture the exact text around the caret, then commit the
        // result through normal keyboard selection and paste events.
        if let element = AXText.focusedElement(),
           let value = AXText.value(of: element),
           let split = Self.splitAtCursor(trigger.word, value: value,
                                          cursor: AXText.selectedRange(of: element)) {
            await rewriteUsingAXSnapshot(trigger, element: element,
                                         before: split.before, after: split.after,
                                         interactionGeneration: generation)
        } else {
            await rewriteViaClipboard(trigger, interactionGeneration: generation)
        }
    }

    private func rewriteUsingAXSnapshot(_ trigger: RewriteTrigger, element: AXUIElement,
                                        before: String, after: String,
                                        interactionGeneration generation: Int) async {
        guard await removeTrigger(trigger.word,
                                  interactionGeneration: generation) else { return }

        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to rewrite — removing the trigger is enough.
            return
        }

        RewriteHUD.shared.show("Rewriting…")
        do {
            let rewritten = try await engine.rewrite(before, using: trigger)
            guard interactionGeneration == generation,
                  AXText.isFocused(element),
                  AXText.value(of: element) == before + after else {
                RewriteHUD.shared.flash("Rewrite cancelled: text changed")
                return
            }

            let pasteboard = NSPasteboard.general
            let savedClipboard = Self.snapshot(pasteboard)
            let changeCount = pasteboard.changeCount
            await pasteReplacingTextBeforeCursor(
                with: rewritten, savedClipboard: savedClipboard,
                expectedChangeCount: changeCount,
                interactionGeneration: generation)
        } catch {
            RewriteHUD.shared.flash("Rewrite failed: \(error.localizedDescription)")
        }
    }

    /// Fallback for fields without a readable AX value: backspace the trigger,
    /// select from the caret to the start, copy to read the text, then paste
    /// the rewrite over that same range.
    private func rewriteViaClipboard(_ trigger: RewriteTrigger,
                                     interactionGeneration generation: Int) async {
        guard await removeTrigger(trigger.word,
                                  interactionGeneration: generation) else { return }

        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshot(pasteboard)
        pasteboard.clearContents()

        // Select only the text before the caret (the trigger was just removed),
        // so text after the trigger survives the paste.
        await KeySim.selectToStart()
        await KeySim.copy()
        let copiedTextChangeCount = pasteboard.changeCount
        try? await Task.sleep(for: .milliseconds(100))

        guard interactionGeneration == generation,
              pasteboard.changeCount == copiedTextChangeCount else {
            restore(pasteboard, to: savedItems,
                    ifChangeCountIs: copiedTextChangeCount)
            RewriteHUD.shared.flash("Rewrite cancelled: text changed")
            return
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            restore(pasteboard, to: savedItems,
                    ifChangeCountIs: copiedTextChangeCount)
            RewriteHUD.shared.flash("Rewritely: couldn't read the text field")
            return
        }

        // Leave the caret where it was instead of holding the user's text
        // selected during model generation.
        await KeySim.press(124) // kVK_RightArrow collapses to selection end

        RewriteHUD.shared.show("Rewriting…")
        do {
            let rewritten = try await engine.rewrite(text, using: trigger)
            guard interactionGeneration == generation,
                  pasteboard.changeCount == copiedTextChangeCount else {
                restore(pasteboard, to: savedItems,
                        ifChangeCountIs: copiedTextChangeCount)
                RewriteHUD.shared.flash("Rewrite cancelled: text changed")
                return
            }

            await pasteReplacingTextBeforeCursor(
                with: rewritten, savedClipboard: savedItems,
                expectedChangeCount: copiedTextChangeCount,
                interactionGeneration: generation)
        } catch {
            restore(pasteboard, to: savedItems,
                    ifChangeCountIs: copiedTextChangeCount)
            RewriteHUD.shared.flash("Rewrite failed: \(error.localizedDescription)")
        }
    }

    private func removeTrigger(_ word: String,
                               interactionGeneration generation: Int) async -> Bool {
        for _ in word {
            guard interactionGeneration == generation else { return false }
            await KeySim.press(51) // kVK_Delete
        }
        return interactionGeneration == generation
    }

    /// Commits through real editor input so the target app updates its own
    /// model, undo stack, selection, and copy behavior. Clipboard restoration
    /// is conditional: if the user copies something before restoration, their
    /// newer clipboard wins.
    private func pasteReplacingTextBeforeCursor(
        with rewritten: String,
        savedClipboard: [NSPasteboardItem],
        expectedChangeCount: Int,
        interactionGeneration generation: Int
    ) async {
        let pasteboard = NSPasteboard.general
        guard interactionGeneration == generation,
              pasteboard.changeCount == expectedChangeCount else {
            RewriteHUD.shared.flash("Rewrite cancelled: text changed")
            return
        }

        await KeySim.selectToStart()
        guard interactionGeneration == generation,
              pasteboard.changeCount == expectedChangeCount else {
            restore(pasteboard, to: savedClipboard,
                    ifChangeCountIs: expectedChangeCount)
            RewriteHUD.shared.flash("Rewrite cancelled: text changed")
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(rewritten, forType: .string)
        let replacementChangeCount = pasteboard.changeCount
        await KeySim.paste()
        RewriteHUD.shared.hide()

        // Pasteboard reads are normally synchronous, but allow the target app
        // a short turn before restoring rich clipboard contents.
        try? await Task.sleep(for: .milliseconds(150))
        restore(pasteboard, to: savedClipboard,
                ifChangeCountIs: replacementChangeCount)
    }

    /// Detached copy of everything on the pasteboard. `NSPasteboardItem`s
    /// belonging to the pasteboard are invalidated by `clearContents()`, so
    /// each item's data has to be copied out up front — and every type has to
    /// come along, not just plain text: the user's clipboard may well hold an
    /// image, files or rich text that the rewrite would otherwise destroy.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func shouldRestorePasteboard(currentChangeCount: Int,
                                        expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
    }

    private func restore(_ pasteboard: NSPasteboard, to saved: [NSPasteboardItem],
                         ifChangeCountIs expectedChangeCount: Int) {
        guard Self.shouldRestorePasteboard(
            currentChangeCount: pasteboard.changeCount,
            expectedChangeCount: expectedChangeCount) else { return }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.writeObjects(saved)
    }

    /// Splits the field value at the caret into the text before the trigger and
    /// the text after it. The trigger must sit immediately before the caret;
    /// returns nil otherwise (so the caller falls back to the clipboard path).
    /// Offsets are UTF-16 to match AX text ranges and `NSString`.
    static func splitAtCursor(_ word: String, value: String,
                              cursor: NSRange?) -> (before: String, after: String)? {
        let ns = value as NSString
        let triggerLen = (word as NSString).length

        // Resolve the caret. With no range, fall back to end-of-field only when
        // the value actually ends with the trigger (single-line / suffix case).
        let caret: Int
        if let cursor, cursor.length == 0 {
            caret = cursor.location
        } else if cursor == nil, ns.hasSuffix(word) {
            caret = ns.length
        } else {
            return nil
        }

        guard caret >= triggerLen, caret <= ns.length else { return nil }
        let triggerRange = NSRange(location: caret - triggerLen, length: triggerLen)
        guard ns.substring(with: triggerRange) == word else { return nil }

        let before = ns.substring(to: caret - triggerLen)
        let after = ns.substring(from: caret)
        return (before, after)
    }
}

/// C callback — tap source scheduled on the main run loop.
private func rewriteTapCallback(proxy: CGEventTapProxy,
                                type: CGEventType,
                                event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<RewritelyController>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableAfterTimeout() }
        return Unmanaged.passUnretained(event)
    }
    // Tap source is on the main run loop; CGEvent is not Sendable.
    nonisolated(unsafe) let unsafeEvent = event
    MainActor.assumeIsolated { controller.handle(unsafeEvent, type: type) }
    return Unmanaged.passUnretained(event)
}
