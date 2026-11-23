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
    static let messagingTimeout: Float = 0.25

    /// The timeout belongs to this element only. Never set one on the
    /// system-wide element: that one changes the default for every element
    /// in the process, Rewritely's included.
    static func appElement(for pid: pid_t, timeout: Float = messagingTimeout) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        windowsIfAnswered(of: app) ?? []
    }

    /// The app's windows, or nil when the app didn't answer. An app with no
    /// windows at all answers with no value, which is an empty list.
    static func windowsIfAnswered(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) {
        case .success: return value as? [AXUIElement] ?? []
        case .noValue: return []
        default: return nil
        }
    }

    /// Live count of the app's switchable windows (standard windows and
    /// dialogs, including minimized ones), without windows the app never
    /// shows. Used to decide whether closing a window should instead quit
    /// its otherwise-windowless app.
    static func switchableWindowCount(pid: pid_t) -> Int {
        reachableWindows(windows(of: appElement(for: pid))).count
    }

    /// The switchable windows among `windows` that the user can reach:
    /// standard windows and dialogs, without the ones the app never shows.
    static func reachableWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        let spaces = PrivateCGS.spaces()
        // No window list, no filtering: counting a helper as a window only
        // keeps an app running, which is the safe mistake.
        let onScreen = onScreenWindowIDs()
        return windows.filter { window in
            guard isSwitchable(window) else { return false }
            guard let onScreen, let id = windowID(of: window) else { return true }
            return !isNeverShown(id, isOnScreen: onScreen.contains(id),
                                 isMinimized: isMinimized(window), spaces: spaces)
        }
    }

    /// A window that AppKit lists in kAXWindows but that is ordered out: not
    /// on screen, not minimized, and on no Space at all. Such a window is a
    /// helper, such as the borderless 64x64 dialog that cmux keeps, and
    /// there is nothing to switch to. A real window always has a Space, also
    /// while its app is hidden or when it is on another Space, so this
    /// works for hidden apps too. Only minimized windows lose their Space,
    /// and they are excluded. `spaces` is this pass's Space snapshot: when
    /// it is empty the Space API does not answer and nothing matches.
    static func isNeverShown(_ id: CGWindowID, isOnScreen: Bool, isMinimized: Bool,
                             spaces: [PrivateCGS.SpaceID: PrivateCGS.SpaceInfo]) -> Bool {
        guard PrivateCGS.available, !spaces.isEmpty, !isOnScreen, !isMinimized
        else { return false }
        return PrivateCGS.spaceIDs(of: id).isEmpty
    }

    /// Ids of every window the window server shows right now. (Not
    /// CGWindowListCreateDescriptionFromArray: it wants raw window-id values
    /// in the array, and a Swift [CGWindowID] bridges to numbers, so it
    /// silently finds nothing.) nil when the window server doesn't answer.
    static func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]]
        else { return nil }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
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

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, name as CFString, &value) == .success,
              let flag = value as? Bool
        else { return false }
        return flag
    }

    /// An attribute holding another element, such as the focused element or
    /// the window a button belongs to.
    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
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
        let subrole = stringAttribute(window, kAXSubroleAttribute)
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

    /// Position, size, position: moving first lets the size fit a smaller
    /// display, and the second move fixes the origin of a window that
    /// couldn't take the full size. Accessibility coordinates: origin at the
    /// top left of the primary screen, y down.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        setPosition(window, frame.origin)
        var size = frame.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        setPosition(window, frame.origin)
    }

    private static func setPosition(_ window: AXUIElement, _ origin: CGPoint) {
        var origin = origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func setFullscreen(_ window: AXUIElement, _ fullscreen: Bool) {
        AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString,
            fullscreen ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
