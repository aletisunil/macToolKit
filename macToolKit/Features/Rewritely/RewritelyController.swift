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
    private var buffer = ""
    private var busy = false
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

        // Switching apps means a different text field — drop the buffer.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.buffer = "" }
        }
        observers.append(observer)
    }

    func cancelPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func stop() {
        cancelPermissionPoll()
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

    // MARK: Buffer

    func handle(_ event: CGEvent, type: CGEventType) {
        guard !busy else { return }

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
        // Let the final trigger keystroke settle in the target app.
        try? await Task.sleep(for: .milliseconds(120))

        // Split the field at the caret: the trigger sits immediately before the
        // insertion point, so only the text preceding it should be rewritten.
        if let element = AXText.focusedElement(),
           AXText.isValueSettable(element),
           let value = AXText.value(of: element),
           let split = Self.splitAtCursor(trigger.word, value: value,
                                          cursor: AXText.selectedRange(of: element)) {
            await rewriteViaAX(trigger, element: element,
                               before: split.before, after: split.after)
        } else {
            await rewriteViaClipboard(trigger)
        }
    }

    private func rewriteViaAX(_ trigger: RewriteTrigger, element: AXUIElement,
                              before: String, after: String) async {
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to rewrite — just drop the trigger, keep the tail.
            AXText.setValue(before + after, on: element)
            AXText.setSelectedRange(
                NSRange(location: before.utf16.count, length: 0), on: element)
            return
        }
        AXText.setValue(before + after, on: element) // remove the trigger immediately
        RewriteHUD.shared.show("Rewriting…")
        do {
            let rewritten = try await engine.rewrite(before, using: trigger)
            AXText.setValue(rewritten + after, on: element)
            AXText.setSelectedRange(
                NSRange(location: rewritten.utf16.count, length: 0), on: element)
            RewriteHUD.shared.hide()
        } catch {
            AXText.setValue(before + after, on: element)
            AXText.setSelectedRange(
                NSRange(location: before.utf16.count, length: 0), on: element)
            RewriteHUD.shared.flash("Rewrite failed: \(error.localizedDescription)")
        }
    }

    /// Fallback for fields without a settable AX value (many Electron/web
    /// views): backspace the trigger away, select-all + copy to read the text,
    /// then paste the rewrite over the selection.
    private func rewriteViaClipboard(_ trigger: RewriteTrigger) async {
        await KeySim.backspace(times: trigger.word.count)

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.string(forType: .string)
        pasteboard.clearContents()

        // Select only the text before the caret (the trigger was just removed),
        // so text after the trigger survives the paste.
        await KeySim.selectToStart()
        await KeySim.copy()
        try? await Task.sleep(for: .milliseconds(150))

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            restore(pasteboard, to: savedItems)
            RewriteHUD.shared.flash("Rewritely: couldn't read the text field")
            return
        }

        RewriteHUD.shared.show("Rewriting…")
        do {
            let rewritten = try await engine.rewrite(text, using: trigger)
            pasteboard.clearContents()
            pasteboard.setString(rewritten, forType: .string)
            await KeySim.paste()
            RewriteHUD.shared.hide()
        } catch {
            RewriteHUD.shared.flash("Rewrite failed: \(error.localizedDescription)")
        }

        // Give the paste a moment to land before restoring the clipboard.
        try? await Task.sleep(for: .milliseconds(400))
        restore(pasteboard, to: savedItems)
    }

    private func restore(_ pasteboard: NSPasteboard, to saved: String?) {
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }
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
