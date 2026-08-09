import AppKit
import ApplicationServices

/// Minimal Accessibility helpers for reading/writing the focused text field.
@MainActor
enum AXText {
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value)
        guard result == .success, let string = value as? String else { return nil }
        return string
    }

    /// The current selection / caret as a UTF-16 range. Length 0 is a caret.
    /// AX text ranges are UTF-16 offsets, matching String.utf16 / NSString.
    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult
    static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        guard let focused = focusedElement() else { return false }
        return CFEqual(focused, element)
    }
}

/// Posts synthetic keystrokes for the clipboard-based fallback path.
@MainActor
enum KeySim {
    private static let keyDelay: Duration = .milliseconds(25)
    /// Distinguishes our own keystrokes from user input in the listen-only
    /// event tap. Rewritely uses this to cancel a pending model response when
    /// the user edits, clicks, or copies while generation is in progress.
    private static let eventMarker: Int64 = 0x4D_54_4B_52_57

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventMarker
    }

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) async {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: keyDelay)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            up.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: keyDelay)
    }

    static func backspace(times: Int) async {
        for _ in 0..<times {
            await press(51) // kVK_Delete
        }
    }

    static func selectAll() async { await press(0, flags: .maskCommand) }   // kVK_ANSI_A
    static func selectToStart() async { await press(126, flags: [.maskCommand, .maskShift]) } // Up: select to doc start
    static func copy() async { await press(8, flags: .maskCommand) }        // kVK_ANSI_C
    static func paste() async { await press(9, flags: .maskCommand) }       // kVK_ANSI_V
}
