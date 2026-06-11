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

    static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    @discardableResult
    static func setValue(_ string: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, string as CFString) == .success
    }
}

/// Posts synthetic keystrokes for the clipboard-based fallback path.
@MainActor
enum KeySim {
    private static let keyDelay: Duration = .milliseconds(25)

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) async {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: keyDelay)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
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
    static func copy() async { await press(8, flags: .maskCommand) }        // kVK_ANSI_C
    static func paste() async { await press(9, flags: .maskCommand) }       // kVK_ANSI_V
}
