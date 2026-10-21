import AppKit
import Combine
import Synchronization
import os

/// Side mouse buttons (buttons 4 and 5) go back and forward.
///
/// Each press becomes a synthetic three-finger navigation swipe, the same
/// event a trackpad sends. That works wherever swiping between pages does -
/// Finder, Safari, Chrome, App Store, System Settings - without the
/// collisions of a keyboard shortcut: ⌘[ means "back" in a browser but
/// "outdent" in a code editor. The swipe goes to the window under the
/// pointer, like the click it replaces.
///
/// Apps on the exception list get the raw button events instead, for apps
/// that handle side buttons themselves or use them for something else.
@MainActor
final class SideButtonsController: ObservableObject {
    /// Apps that receive the side buttons untouched. Seeded with editors that
    /// map the buttons to their own code navigation and ignore swipes.
    let exceptions = AppListStore(key: "sideButtonsExceptions", initial: [
        AppRef(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
    ])

    @Published private(set) var tapActive = false

    private let navigator = SideButtonNavigator()
    private let tap: EventTap
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        let navigator = navigator
        tap = EventTap(name: "SideButtonsTap",
                       events: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { type, event in
            navigator.handle(type, event)
        }
        tap.$isActive.assign(to: &$tapActive)
        exceptions.$apps
            .sink { apps in navigator.setExceptions(Set(apps.map(\.bundleID))) }
            .store(in: &subscriptions)
    }

    func start() { tap.start() }
    func stop() {
        tap.stop()
        navigator.reset()
    }
}

private final class SideButtonNavigator: Sendable {
    private static let log = Logger.feature("SideButtons")

    /// Zero-based button numbers as CGEvent reports them.
    private static let backButton: Int64 = 3
    private static let forwardButton: Int64 = 4

    private let exceptions = Mutex(Set<String>())
    /// Buttons whose press was turned into a swipe; their drags and release
    /// are swallowed too, so no app sees half a click.
    private let consumed = Mutex(Set<Int64>())
    private let queue = DispatchQueue(label: "com.sunilaleti.mactoolkit.side-buttons",
                                      qos: .userInteractive)

    func setExceptions(_ bundleIDs: Set<String>) {
        exceptions.withLock { $0 = bundleIDs }
    }

    /// With the tap gone, the release of a button held right now is never
    /// seen; a stale entry would swallow that button's next click.
    func reset() {
        consumed.withLock { $0.removeAll() }
    }

    /// Tap thread. Returns false to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == Self.backButton || button == Self.forwardButton else { return true }

        switch type {
        case .otherMouseDown:
            if let owner = Self.bundleIDOfWindow(at: event.location),
               exceptions.withLock({ $0.contains(owner) }) {
                return true
            }
            consumed.withLock { _ = $0.insert(button) }
            let back = button == Self.backButton
            queue.async { Self.postSwipe(back: back) }
            return false
        case .otherMouseUp:
            return consumed.withLock { $0.remove(button) == nil }
        default:
            return !consumed.withLock { $0.contains(button) }
        }
    }

    /// Owner of the window the click would have gone to.
    private static func bundleIDOfWindow(at point: CGPoint) -> String? {
        WindowHitTest.window(at: point).flatMap {
            NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier
        }
    }

    // MARK: Synthetic swipe

    // Undocumented CGEvent gesture fields, as used by trackpad drivers. A
    // navigation swipe is a gesture-begin event, the swipe, and a
    // gesture-end event, all of event type 29 (NSEventTypeGesture).
    private static let gestureEventType: Int64 = 29
    private static let eventTypeField = CGEventField(rawValue: 55)!
    private static let hidGestureTypeField = CGEventField(rawValue: 110)!
    private static let swipeDirectionField = CGEventField(rawValue: 115)!
    private static let gestureBegan: Int64 = 61
    private static let gestureEnded: Int64 = 62
    private static let navigationSwipe: Int64 = 16
    /// IOHIDSwipeMask: left swipe = back, right swipe = forward.
    private static let swipeLeft: Int64 = 1 << 2
    private static let swipeRight: Int64 = 1 << 3

    private static func postSwipe(back: Bool) {
        postGesture(hidType: gestureBegan)
        postGesture(hidType: navigationSwipe, direction: back ? swipeLeft : swipeRight)
        postGesture(hidType: gestureEnded)
        log.log("\(back ? "back" : "forward", privacy: .public)")
    }

    private static func postGesture(hidType: Int64, direction: Int64? = nil) {
        // A sourceless event carries the current pointer location, which is
        // what routes the gesture to the window under it.
        guard let event = CGEvent(source: nil),
              let type = CGEventType(rawValue: UInt32(gestureEventType))
        else { return }
        event.type = type
        event.setIntegerValueField(eventTypeField, value: gestureEventType)
        event.setIntegerValueField(hidGestureTypeField, value: hidType)
        if let direction {
            event.setIntegerValueField(swipeDirectionField, value: direction)
        }
        event.post(tap: .cgSessionEventTap)
    }
}
