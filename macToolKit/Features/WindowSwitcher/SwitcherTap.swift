import AppKit
import CoreGraphics

/// Semantic commands decoded from raw key events on the tap thread and
/// delivered to the controller on the main queue, in order.
enum SwitcherKeyEvent: Sendable {
    case show(slot: Int, reverse: Bool)
    case cycle(Int)
    case commit
    case cancel
    case action(WindowAction)
}

/// Actions on the selected window while the switcher is open.
enum WindowAction: Sendable {
    case close, minimize, hide, quit
}

/// What the tap thread needs to know about the current preferences. Pushed
/// from the controller under the core's lock whenever settings change.
struct SwitcherTapConfig: Sendable {
    struct Trigger: Sendable {
        let slot: Int
        let holdFlag: CGEventFlags
        let keyCode: Int64
    }

    var triggers: [Trigger] = []
    /// Frontmost app is on the don't-intercept blacklist: let every trigger
    /// chord through (VMs, remote desktops).
    var suppressTrigger = false
}

/// Intercepts the trigger chords (⌥Tab, ⌘Tab, … — up to nine slots) with a
/// modifying CGEventTap and, while the switcher is visible, swallows
/// keyboard input and turns it into `SwitcherKeyEvent`s. `flagsChanged`
/// (the modifier release that commits) is always passed through so modifier
/// state stays consistent system-wide. A ⌘Tab slot swallows the chord at
/// `.headInsertEventTap` before the Dock's switcher sees it.
///
/// Same threading model as `ScrollTap`: the tap lives on a dedicated thread
/// with its own run loop, a watchdog re-enables it if macOS disables it, and
/// the callback does near-zero work. Requires Accessibility permission.
@MainActor
final class SwitcherTap {
    private var core: SwitcherTapCore?
    private var watchdog: Timer?

    private(set) var tapActive = false

    /// Whether the tap is currently swallowing keys. Driven by the tap
    /// itself for the keyboard flow; the controller overrides it when the
    /// switcher hides for another reason (mouse click, feature disabled).
    var switcherVisible: Bool {
        get { core?.isActive ?? false }
        set { core?.setActive(newValue) }
    }

    func setConfig(_ config: SwitcherTapConfig) {
        pendingConfig = config
        core?.setConfig(config)
    }

    /// Config survives a stop/start cycle (permission poll, toggle).
    private var pendingConfig = SwitcherTapConfig()

    /// Retained so the watchdog can rebuild the tap after a failed creation.
    private var handler: (@MainActor (SwitcherKeyEvent) -> Void)?
    private var completion: (@MainActor (Bool) -> Void)?

    func start(handler: @escaping @MainActor (SwitcherKeyEvent) -> Void,
               completion: @escaping @MainActor (Bool) -> Void) {
        guard core == nil else { return }
        self.handler = handler
        self.completion = completion
        attachCore()
        startWatchdog()
    }

    /// One attempt at creating the tap. `CGEvent.tapCreate` can fail even with
    /// Accessibility granted — most often right after login, while the
    /// window server and TCC are still settling — and a failure here used to
    /// be terminal: the core was dropped, the watchdog bailed on the nil core,
    /// and the controller's `running` flag kept `start()` from being called
    /// again. The trigger chord then fell through to the system switcher until
    /// the feature was toggled or the app relaunched. The watchdog retries
    /// this every 2 s instead.
    private func attachCore() {
        guard core == nil, let handler else { return }
        let core = SwitcherTapCore { event in
            // main-queue dispatch keeps events FIFO; Task {} would not.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(event) }
            }
        }
        core.setConfig(pendingConfig)
        self.core = core
        core.start { ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.core === core else { return }
                    self.tapActive = ok
                    if !ok { self.core = nil }
                    self.completion?(ok)
                }
            }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        core?.shutdown()
        core = nil
        handler = nil
        completion = nil
        tapActive = false
    }

    /// Backstop for `tapDisabledByTimeout` disables whose notification never
    /// reaches the callback. Also drops the swallow state if the tap died so
    /// the keyboard can never get stuck.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let core = self.core else {
                    // Tap creation failed earlier; keep trying rather than
                    // leaving the chord to the system switcher forever.
                    self.attachCore()
                    return
                }
                self.tapActive = core.ensureEnabled()
                if !self.tapActive { core.setActive(false) }
                // Backstop for a modifier-release lost entirely, with no
                // follow-up event to trigger the per-event recovery above.
                core.commitIfHoldReleased()
            }
        }
    }
}

/// Owns the CGEventTap and its thread. Shared with the C callback across
/// threads, so state is guarded by a lock rather than an actor.
private final class SwitcherTapCore: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var cancelled = false
    private var active = false
    /// The hold modifier and cycle key of the trigger that opened the
    /// switcher; release of this modifier commits.
    private var activeHoldFlag = CGEventFlags.maskAlternate
    private var activeKeyCode: Int64 = KeyCode.tab
    private var config = SwitcherTapConfig()

    private let emit: @Sendable (SwitcherKeyEvent) -> Void

    init(emit: @escaping @Sendable (SwitcherKeyEvent) -> Void) {
        self.emit = emit
    }

    var isActive: Bool { lock.withLock { active } }

    func setActive(_ value: Bool) {
        lock.withLock { active = value }
    }

    func setConfig(_ value: SwitcherTapConfig) {
        lock.withLock { config = value }
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        let thread = Thread { [self] in
            let mask = CGEventMask(
                1 << CGEventType.keyDown.rawValue
                    | 1 << CGEventType.keyUp.rawValue
                    | 1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: switcherTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                completion(false)
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            // shutdown() may have raced ahead of tap creation; if so, tear
            // the tap down here instead of leaving it running unowned.
            let abort = lock.withLock {
                if cancelled { return true }
                self.tap = tap
                self.runLoop = CFRunLoopGetCurrent()
                return false
            }
            if abort {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                completion(false)
                return
            }

            completion(true)
            CFRunLoopRun() // until shutdown() stops it
        }
        thread.name = "SwitcherTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func shutdown() {
        let (tap, runLoop): (CFMachPort?, CFRunLoop?) = lock.withLock {
            cancelled = true
            active = false
            defer {
                self.tap = nil
                self.runLoop = nil
            }
            return (self.tap, self.runLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without this the server-side tap leaks (stays registered,
            // disabled) every time the feature is toggled off.
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    /// Re-enables the tap if the system disabled it. Returns whether the tap
    /// is live afterwards.
    func ensureEnabled() -> Bool {
        guard let tap = lock.withLock({ self.tap }) else { return false }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func reenableAfterTimeout() {
        if let tap = lock.withLock({ self.tap }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Safety net for the AltTab lesson that keyboard events are unreliable —
    /// the modifier-release that commits can be dropped or reordered, most
    /// notably when the tap is disabled by timeout and the release lands
    /// during the dead window. If we still think we're swallowing but the
    /// hold modifier is physically up, commit now from the live session
    /// state so the keyboard can never get stuck swallowed. No-op while the
    /// modifier is genuinely held, so it's cheap to call on every event.
    func commitIfHoldReleased() {
        let holdFlag: CGEventFlags? = lock.withLock { active ? activeHoldFlag : nil }
        guard let holdFlag, Self.liveModifierReleased(holdFlag) else { return }
        setActive(false)
        emit(.commit)
    }

    /// Whether `holdFlag` is physically up right now, read from the live
    /// combined session state rather than the droppable flagsChanged stream.
    /// fn (`maskSecondaryFn`) isn't reliably reported by `flagsState`, so it
    /// never counts as released here — the event-driven flagsChanged commit
    /// still covers fn holds.
    private static func liveModifierReleased(_ holdFlag: CGEventFlags) -> Bool {
        guard holdFlag != .maskSecondaryFn else { return false }
        return !CGEventSource.flagsState(.combinedSessionState).contains(holdFlag)
    }

    private enum KeyCode {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let delete: Int64 = 51
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126
    }

    /// All modifiers any slot can use as a hold trigger — a chord only
    /// matches a slot when none of the *other* hold modifiers are down.
    private static let holdFlags: [CGEventFlags] =
        [.maskAlternate, .maskCommand, .maskControl, .maskSecondaryFn]

    /// Runs on the tap thread. Returns whether the event should be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let (active, holdFlag, keyCode, config) = lock.withLock {
            (self.active, self.activeHoldFlag, self.activeKeyCode, self.config)
        }
        let flags = event.flags

        switch type {
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if active {
                handleWhileOpen(code: code, flags: flags,
                                cycleKey: keyCode, event: event)
                return true // switcher owns the keyboard while visible
            }
            guard !config.suppressTrigger else { return false }
            for trigger in config.triggers where trigger.keyCode == code {
                guard flags.contains(trigger.holdFlag) else { continue }
                // No other hold modifier may be down (shift is the reverse
                // key and always allowed).
                let others = Self.holdFlags.filter { $0 != trigger.holdFlag }
                guard !others.contains(where: flags.contains) else { continue }
                lock.withLock {
                    self.active = true
                    self.activeHoldFlag = trigger.holdFlag
                    self.activeKeyCode = trigger.keyCode
                }
                emit(.show(slot: trigger.slot, reverse: flags.contains(.maskShift)))
                return true
            }
            return false

        case .keyUp:
            // A key-up can arrive after the hold modifier was already
            // released (reordered/dropped flagsChanged); recover here.
            if active { commitIfHoldReleased() }
            // Swallow the key-ups matching swallowed key-downs.
            return active

        case .flagsChanged:
            if active, !flags.contains(holdFlag) {
                setActive(false)
                emit(.commit)
            }
            return false // modifier state must reach the rest of the system

        default:
            return false
        }
    }

    /// Keyboard handling while the switcher is up. Everything is swallowed;
    /// this only decides which semantic event to emit.
    private func handleWhileOpen(code: Int64, flags: CGEventFlags,
                                 cycleKey: Int64, event: CGEvent) {
        switch code {
        case cycleKey, KeyCode.tab:
            emit(.cycle(flags.contains(.maskShift) ? -1 : 1))
        case KeyCode.rightArrow, KeyCode.downArrow:
            emit(.cycle(1))
        case KeyCode.leftArrow, KeyCode.upArrow:
            emit(.cycle(-1))
        case KeyCode.escape:
            setActive(false)
            emit(.cancel)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            setActive(false)
            emit(.commit)
        default:
            guard let text = Self.typedText(for: event, flags: flags) else { return }
            switch text.lowercased() {
            case "w": emit(.action(.close))
            case "m": emit(.action(.minimize))
            case "h": emit(.action(.hide))
            case "q": emit(.action(.quit))
            default: break
            }
        }
    }

    /// The character a key press would type with only Shift applied —
    /// layout-aware, with the hold modifier's ⌥/⌘ effects stripped so the
    /// W/M/H/Q action keys match while ⌥ is held (no "å" instead of "a").
    private static func typedText(for event: CGEvent, flags: CGEventFlags) -> String? {
        guard let copy = event.copy() else { return nil }
        copy.flags = flags.intersection(.maskShift)
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        copy.keyboardGetUnicodeString(maxStringLength: 4,
                                      actualStringLength: &length,
                                      unicodeString: &chars)
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        guard let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return text
    }
}

/// C callback — runs on the dedicated tap thread. SwitcherTapCore is kept
/// alive by the thread's closure for as long as the run loop (and thus this
/// callback) can fire, so the unretained reference is safe.
private func switcherTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let core = Unmanaged<SwitcherTapCore>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        core.reenableAfterTimeout()
        // The modifier-release that commits may have landed during the dead
        // window; recover it from live modifier state instead of hanging.
        core.commitIfHoldReleased()
        return Unmanaged.passUnretained(event)
    }

    return core.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
