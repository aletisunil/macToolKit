import AppKit
import ApplicationServices

/// The only reliable way to match an AXUIElement window to its CGWindowID.
/// Private but stable since 10.10 and used by every switcher (AltTab, etc.).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility helpers for enumerating, classifying and controlling app
/// windows. Safe to call from any thread; every app element gets a short
/// messaging timeout so a hung app can't stall enumeration.
enum AXWindow {
    /// Per-call timeout for AX round-trips to other processes.
    private static let messagingTimeout: Float = 0.25

    static func appElement(for pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return [] }
        return list
    }

    /// Live count of the app's switchable windows (standard windows and
    /// dialogs, including minimized ones). Used to decide whether closing a
    /// window should instead quit its otherwise-windowless app.
    static func switchableWindowCount(pid: pid_t) -> Int {
        windows(of: appElement(for: pid)).filter(isSwitchable).count
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String
        else { return "" }
        return title
    }

    private static func boolAttribute(_ window: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, name as CFString, &value) == .success,
              let flag = value as? Bool
        else { return false }
        return flag
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        boolAttribute(window, kAXMinimizedAttribute)
    }

    static func isFullscreen(_ window: AXUIElement) -> Bool {
        boolAttribute(window, "AXFullScreen")
    }

    /// Standard windows and dialogs belong in the switcher; palettes,
    /// popovers and system overlays don't.
    static func isSwitchable(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String
        else { return false }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    static func frame(of window: AXUIElement) -> CGRect {
        var frame = CGRect.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
               window, kAXPositionAttribute as CFString, &value) == .success,
           let position = value {
            AXValueGetValue(position as! AXValue, .cgPoint, &frame.origin)
        }
        if AXUIElementCopyAttributeValue(
               window, kAXSizeAttribute as CFString, &value) == .success,
           let size = value {
            AXValueGetValue(size as! AXValue, .cgSize, &frame.size)
        }
        return frame
    }

    // MARK: Window control

    /// Presses the window's close button (same as clicking the red button).
    static func close(_ window: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func setFullscreen(_ window: AXUIElement, _ fullscreen: Bool) {
        AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString,
            fullscreen ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
