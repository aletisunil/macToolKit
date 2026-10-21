import AppKit
import ApplicationServices
import Synchronization
import os

/// The window under the pointer takes focus and comes to the front once the
/// pointer has rested on it for `delay`.
///
/// A listen-only tap watches pointer movement; lookups run on a serial
/// queue at most every 40 ms, plus one where the pointer comes to rest. Focus only moves on pointer movement - a window
/// that appears under a still pointer, or the pointer resting over the
/// desktop, never steals focus. Nothing happens while a mouse button is held
/// (drags), while a menu is open, while a non-Dock app such as Spotlight is
/// frontmost, or after a key press that came after the pointer moved.
@MainActor
final class FocusFollowsMouseController: ObservableObject {
    static let delayChoices: [Double] = [0, 0.1, 0.2, 0.4, 0.8]

    @Published var delay: Double {
        didSet {
            UserDefaults.standard.set(delay, forKey: "focusFollowsMouseDelay")
            tracker.setDelay(delay)
        }
    }

    @Published private(set) var tapActive = false

    private let tracker = PointerFocusTracker()
    private let tap: EventTap

    init() {
        UserDefaults.standard.register(defaults: ["focusFollowsMouseDelay": 0.2])
        // Snapped to a choice so the picker always shows a selection, even
        // for a value written from outside (a float 0.2 isn't the double).
        let stored = UserDefaults.standard.double(forKey: "focusFollowsMouseDelay")
        delay = Self.delayChoices.min { abs($0 - stored) < abs($1 - stored) } ?? 0.2
        let tracker = tracker
        tap = EventTap(name: "FocusFollowsMouseTap", events: [.mouseMoved],
                       options: .listenOnly) { _, event in
            tracker.pointerMoved(to: event.location)
            return true
        }
        tracker.setDelay(delay)
        tap.$isActive.assign(to: &$tapActive)
    }

    func start() { tap.start() }
    func stop() {
        tap.stop()
        tracker.reset()
    }
}

/// Window lookups and focus changes. The tap callback only records the
/// pointer and, at most once per lookup interval, hands a lookup to `queue`.
private final class PointerFocusTracker: @unchecked Sendable {
    private static let log = Logger.feature("FocusFollowsMouse")
    private static let lookupInterval: TimeInterval = 0.04

    private struct Pointer {
        var location = CGPoint.zero
        var lastMove: TimeInterval = 0
        var lastLookup: TimeInterval = 0
        /// A lookup is queued for the end of the current interval; it reads
        /// `location` when it runs, so it sees where the pointer stopped.
        var trailingLookupQueued = false
    }

    private let queue = DispatchQueue(label: "com.sunilaleti.mactoolkit.focus-follows-mouse",
                                      qos: .userInteractive)
    private let delay = Mutex<TimeInterval>(0.2)
    private let pointer = Mutex(Pointer())

    // Queue-confined.
    /// The window the pointer is over, when focusing it is wanted.
    private var candidate: CGWindowID?
    private var pendingFocus: DispatchWorkItem?

    func setDelay(_ seconds: TimeInterval) {
        delay.withLock { $0 = seconds }
    }

    func reset() {
        queue.async { [self] in
            pendingFocus?.cancel()
            pendingFocus = nil
            candidate = nil
        }
    }

    /// Tap thread. Movement inside an interval only updates the location;
    /// the first such move queues one lookup for the end of the interval.
    func pointerMoved(to point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        enum Action { case none, now, trailing(after: TimeInterval) }
        let action: Action = pointer.withLock { pointer in
            pointer.location = point
            pointer.lastMove = now
            let sinceLookup = now - pointer.lastLookup
            if sinceLookup >= Self.lookupInterval {
                pointer.lastLookup = now
                return .now
            }
            guard !pointer.trailingLookupQueued else { return .none }
            pointer.trailingLookupQueued = true
            return .trailing(after: Self.lookupInterval - sinceLookup)
        }
        switch action {
        case .none:
            break
        case .now:
            queue.async { [self] in evaluate(at: point) }
        case .trailing(let wait):
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                let point = pointer.withLock { pointer in
                    pointer.trailingLookupQueued = false
                    pointer.lastLookup = ProcessInfo.processInfo.systemUptime
                    return pointer.location
                }
                evaluate(at: point)
            }
        }
    }

    // MARK: Queue

    private func evaluate(at point: CGPoint) {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) == false,
              CGEventSource.buttonState(.combinedSessionState, button: .right) == false,
              let target = Self.focusTarget(at: point)
        else {
            dropCandidate()
            return
        }
        // Still counting down for this window. A countdown that was turned
        // down (a key press) re-arms on the next movement instead.
        if candidate == target.windowID, pendingFocus != nil { return }
        candidate = target.windowID
        pendingFocus?.cancel()
        let work = DispatchWorkItem { [self] in fireIfStillWanted(target.windowID) }
        pendingFocus = work
        queue.asyncAfter(deadline: .now() + delay.withLock { $0 }, execute: work)
    }

    private func dropCandidate() {
        candidate = nil
        pendingFocus?.cancel()
        pendingFocus = nil
    }

    private func fireIfStillWanted(_ windowID: CGWindowID) {
        guard candidate == windowID else { return }
        pendingFocus = nil
        // A key press after the pointer settled means the user is typing
        // where they already are; the pointer drifting must not move that.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                               eventType: .keyDown)
        let sinceMove = ProcessInfo.processInfo.systemUptime - pointer.withLock { $0.lastMove }
        guard sinceKey > sinceMove else { return }
        // Re-check against the live pointer: it may have left during the delay.
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let target = Self.focusTarget(at: pointer), target.windowID == windowID else { return }
        focus(target)
    }

    private struct Target {
        let windowID: CGWindowID
        let pid: pid_t
    }

    /// The standard window under `point`, when focusing it is wanted - nil
    /// over anything else, and for the window already in front.
    private static func focusTarget(at point: CGPoint) -> Target? {
        // Whatever would take a click decides: a panel, the Dock or the menu
        // bar above a window shields it. The hit test reads one window, so it
        // goes before the full window list.
        guard let hit = WindowHitTest.window(at: point), hit.layer == 0,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]]
        else { return nil }

        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var frontmostStandard: CGWindowID?
        for entry in list {
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            // An open menu (app menus, menu bar extras, context menus) means
            // the user is in the middle of choosing something.
            if layer == menuLevel { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            if layer == 0, alpha > 0, frontmostStandard == nil {
                frontmostStandard = entry[kCGWindowNumber as String] as? CGWindowID
            }
        }
        guard hit.windowID != frontmostStandard,
              let front = NSWorkspace.shared.frontmostApplication,
              isFocusable(front)
        else { return nil }
        return Target(windowID: hit.windowID, pid: hit.pid)
    }

    /// Dock apps, plus this app's own windows (Settings), which run under
    /// the accessory policy while the Dock icon is off.
    private static func isFocusable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular || app.processIdentifier == getpid()
    }

    private func focus(_ target: Target) {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              Self.isFocusable(app)
        else { return }
        let fronted = PrivateCGS.setFrontProcess(pid: target.pid, windowID: target.windowID)
        _ = PrivateCGS.makeKeyWindow(pid: target.pid, windowID: target.windowID)
        let axApp = AXWindow.appElement(for: target.pid)
        if let window = AXWindow.windows(of: axApp)
            .first(where: { AXWindow.windowID(of: $0) == target.windowID }) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if !fronted {
            DispatchQueue.main.async { app.activate() }
        }
        Self.log.log("focused window \(target.windowID) of \(app.bundleIdentifier ?? "?", privacy: .public)")
    }
}
