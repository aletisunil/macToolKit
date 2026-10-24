import AppKit
import ApplicationServices
import Synchronization
import os

/// Makes the green traffic-light button fill the screen instead of entering
/// full screen. A second click puts the window back where it was; holding ⌥
/// enters full screen the old way.
///
/// The work is done by the system's own Fill and Return to Previous Size
/// commands (Window > Move & Resize), so the window animates exactly like a
/// tile from the green button's own menu. Apps without those commands get
/// their frame set directly, which jumps without animation.
///
/// A click is only examined further when it lands in the top-left corner of
/// the window under the pointer. That pre-filter keeps Accessibility hit
/// tests off ordinary clicks - a hit test inside Chrome or an Electron app
/// switches on its whole accessibility tree, which is slow.
@MainActor
final class MaximizeController: ObservableObject {
    @Published private(set) var tapActive = false

    private let maximizer = WindowMaximizer()
    private let tap: EventTap

    init() {
        let maximizer = maximizer
        tap = EventTap(name: "MaximizeTap", events: [.leftMouseDown, .leftMouseUp]) { type, event in
            maximizer.handle(type, event)
        }
        tap.$isActive.assign(to: &$tapActive)
    }

    func start() { tap.start() }
    func stop() { tap.stop() }
}

/// Tap-thread decision plus the window work, which runs on its own serial
/// queue: Accessibility calls block for as long as the target app takes to
/// answer, and calls into this app's own windows from the main thread would
/// deadlock. Unchecked because AXUIElement, a thread-safe CF object, isn't
/// marked Sendable; all mutable state is behind mutexes or on the queue.
private final class WindowMaximizer: @unchecked Sendable {
    private static let log = Logger.feature("Maximize")

    /// Traffic lights sit within this distance of a window's top-left corner,
    /// toolbar windows included.
    private static let buttonZone = CGSize(width: 120, height: 64)
    /// The hit test runs on the tap thread while the click waits.
    private static let hitTestTimeout: Float = 0.15
    /// Fill and Return to Previous Size animate for about 350 ms.
    private static let animationTime: TimeInterval = 0.6

    /// A mouse-down this tap swallowed; its mouse-up must go too, or the app
    /// sees an unpaired release.
    private let swallowingClick = Mutex(false)
    private let queue = DispatchQueue(label: "com.sunilaleti.mactoolkit.maximize",
                                      qos: .userInteractive)

    // Queue-confined, by window id.
    /// Where the window was before it was maximized.
    private var savedFrames: [CGWindowID: CGRect] = [:]
    /// The frame maximizing produced. A window that can't grow to the full
    /// screen ends up smaller than it, and only this tells the second click
    /// that the window is maximized all the same.
    private var maximizedFrames: [CGWindowID: CGRect] = [:]
    private var menus: [pid_t: TilingMenu] = [:]

    /// Runs on the tap thread. Returns false to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .leftMouseUp {
            return !swallowingClick.withLock { swallowed in
                defer { swallowed = false }
                return swallowed
            }
        }
        guard type == .leftMouseDown else { return true }

        // ⇧, ⌃ and ⌘ clicks keep their own meanings.
        let flags = event.flags
        guard flags.isDisjoint(with: [.maskShift, .maskControl, .maskCommand]) else { return true }
        let point = event.location
        guard let hit = WindowHitTest.window(at: point), hit.layer == 0,
              point.x - hit.bounds.minX < Self.buttonZone.width,
              point.y - hit.bounds.minY < Self.buttonZone.height,
              let window = Self.greenButtonWindow(at: point, pid: hit.pid)
        else { return true }

        // A full-screen window's green button is the way back out.
        if AXWindow.isFullscreen(window) { return true }

        swallowingClick.withLock { $0 = true }
        let enterFullScreen = flags.contains(.maskAlternate)
        let pid = hit.pid
        nonisolated(unsafe) let target = window
        queue.async { [self] in
            Self.closeButtonMenu(near: point)
            if enterFullScreen {
                AXWindow.setFullscreen(target, true)
            } else {
                toggleMaximized(target, pid: pid)
            }
        }
        return false
    }

    /// The window whose green full-screen button is under the pointer. The
    /// hit test goes to the app that owns the window under the pointer, on
    /// an element with its own short timeout.
    private static func greenButtonWindow(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        let app = AXWindow.appElement(for: pid, timeout: hitTestTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y),
                                               &hit) == .success,
              let hit,
              AXWindow.stringAttribute(hit, kAXSubroleAttribute)
                  == kAXFullScreenButtonSubrole as String
        else { return nil }
        return AXWindow.elementAttribute(hit, kAXWindowAttribute)
    }

    // MARK: Window work (serial queue)

    /// Resting the pointer on the green button opens the system's Move &
    /// Resize menu, and only a click that reaches the button closes it.
    /// This click never does, so the menu would stay open, following the
    /// button around, until the app loses focus.
    private static func closeButtonMenu(near click: CGPoint) {
        // The window list is cheap; the hit test only runs when a menu is
        // actually open next to the button.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                  as? [[String: Any]],
              let menuFrame = list.lazy.compactMap({ entry -> CGRect? in
                  guard entry[kCGWindowOwnerName as String] as? String
                            == "ThemeWidgetControlViewService",
                        let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                            .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                        bounds.insetBy(dx: -40, dy: -40).contains(click)
                  else { return nil }
                  return bounds
              }).first
        else { return }
        // The menu is hosted by another process but reported as part of
        // the app, so only the system-wide element finds it. No timeout is
        // set on it; that would change every element's.
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(menuFrame.midX), Float(menuFrame.midY),
                                               &element) == .success
        else { return }
        for _ in 0..<6 {
            guard let current = element else { return }
            if AXWindow.stringAttribute(current, kAXRoleAttribute) == kAXMenuRole as String {
                AXUIElementPerformAction(current, kAXCancelAction as CFString)
                return
            }
            element = AXWindow.elementAttribute(current, kAXParentAttribute)
        }
    }

    private func toggleMaximized(_ window: AXUIElement, pid: pid_t) {
        let current = AXWindow.frame(of: window)
        guard current.width > 0, let screen = Self.visibleFrame(for: current),
              let id = AXWindow.windowID(of: window)
        else { return }
        let app = AXWindow.appElement(for: pid)
        let menu = tilingMenu(pid: pid, app: app)
        let isMaximized = Self.roughlyEqual(current, screen)
            || maximizedFrames[id].map { Self.roughlyEqual(current, $0) } == true

        if isMaximized {
            maximizedFrames[id] = nil
            let saved = savedFrames.removeValue(forKey: id)
            // Return to Previous Size only knows windows the system tiled.
            if let untile = menu?.untile, bringForward(window, id: id, pid: pid, of: app),
               AXWindow.boolAttribute(untile, kAXEnabledAttribute),
               AXUIElementPerformAction(untile, kAXPressAction as CFString) == .success {
                Self.log.log("restored window \(id) (system)")
                // The system's restore lands a point or so off, and the error
                // adds up over repeated toggles. Settle on the exact frame.
                if let saved {
                    nonisolated(unsafe) let window = window
                    queue.asyncAfter(deadline: .now() + Self.animationTime) {
                        let landed = AXWindow.frame(of: window)
                        if landed != saved, Self.roughlyEqual(landed, saved) {
                            AXWindow.setFrame(window, saved)
                        }
                    }
                }
            } else {
                AXWindow.setFrame(window, saved ?? Self.restoredFrame(in: screen))
                Self.log.log("restored window \(id)")
            }
            return
        }

        savedFrames[id] = current
        if let fill = menu?.fill, bringForward(window, id: id, pid: pid, of: app),
           AXUIElementPerformAction(fill, kAXPressAction as CFString) == .success {
            Self.log.log("maximized window \(id) (system)")
            nonisolated(unsafe) let window = window
            queue.asyncAfter(deadline: .now() + Self.animationTime) { [self] in
                // Unless the window was clicked again meanwhile.
                if savedFrames[id] != nil { maximizedFrames[id] = AXWindow.frame(of: window) }
            }
        } else {
            AXWindow.setFrame(window, screen)
            maximizedFrames[id] = AXWindow.frame(of: window)
            Self.log.log("maximized window \(id)")
        }
    }

    /// The tiling commands act on the active app's main window, so the
    /// clicked window has to be both. Activation can be turned down for a
    /// request from a background app like this one; the window server's own
    /// front-process call is the fallback, as in Focus Follows Mouse.
    /// Returns false when the app didn't come forward in time.
    private func bringForward(_ window: AXUIElement, id: CGWindowID, pid: pid_t,
                              of app: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard !AXWindow.boolAttribute(app, kAXFrontmostAttribute) else { return true }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for attempt in 0..<30 {
            usleep(10_000)
            if AXWindow.boolAttribute(app, kAXFrontmostAttribute) { return true }
            if attempt == 14 { _ = PrivateCGS.setFrontProcess(pid: pid, windowID: id) }
        }
        return false
    }

    /// Cached per app; a cached menu is checked before use, since apps can
    /// rebuild their menus at any time.
    private func tilingMenu(pid: pid_t, app: AXUIElement) -> TilingMenu? {
        if let cached = menus[pid], cached.isValid { return cached }
        menus = menus.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        let menu = TilingMenu(app: app)
        menus[pid] = menu
        return menu
    }

    /// The visible frame (no menu bar, no Dock) of the screen holding most of
    /// the window, in Accessibility coordinates - origin at the top left of
    /// the primary screen, y down.
    private static func visibleFrame(for window: CGRect) -> CGRect? {
        let (screens, primaryHeight) = DispatchQueue.main.sync {
            (NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
             NSScreen.screens.first?.frame.height ?? 0)
        }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        let best = screens.max { a, b in
            flipped(a.0).intersection(window).area < flipped(b.0).intersection(window).area
        }
        return best.map { flipped($0.1) }
    }

    /// For a window that was already maximized when first clicked, with no
    /// earlier frame to go back to.
    private static func restoredFrame(in screen: CGRect) -> CGRect {
        screen.insetBy(dx: screen.width * 0.15, dy: screen.height * 0.1)
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4
            && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }
}

/// An app's Fill and Return to Previous Size menu items. AppKit adds them to
/// every app's Window menu, Electron and Chromium apps included, and names
/// them by their action, so they're found the same way in every language.
private struct TilingMenu {
    private static let fillID = "_zoomFill:"
    private static let untileID = "_zoomUntile:"

    let fill: AXUIElement?
    let untile: AXUIElement?

    var isValid: Bool {
        fill.map { AXWindow.stringAttribute($0, kAXIdentifierAttribute) == Self.fillID } ?? false
    }

    /// Window > Fill, and Window > Move & Resize > Return to Previous Size.
    /// The Window menu sits near the end of the menu bar, so the search
    /// starts there.
    init(app: AXUIElement) {
        var fill: AXUIElement?
        var untile: AXUIElement?
        let bar = AXWindow.elementAttribute(app, kAXMenuBarAttribute)
        search: for top in bar.map(Self.children)?.reversed() ?? [] {
            for menu in Self.children(top) {
                let items = Self.children(menu)
                guard items.contains(where: {
                    AXWindow.stringAttribute($0, kAXIdentifierAttribute) == Self.fillID
                }) else { continue }
                fill = items.first {
                    AXWindow.stringAttribute($0, kAXIdentifierAttribute) == Self.fillID
                }
                untile = items.lazy.flatMap(Self.children).flatMap(Self.children).first {
                    AXWindow.stringAttribute($0, kAXIdentifierAttribute) == Self.untileID
                }
                break search
            }
        }
        self.fill = fill
        self.untile = untile
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
