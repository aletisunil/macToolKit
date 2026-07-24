import AppKit
import CoreGraphics
import Combine

/// Reverses scroll direction with a modifying CGEventTap. Continuous scroll
/// events (trackpad / Magic Mouse) and discrete wheel events are toggled
/// independently. Deltas are negated; scroll/momentum phases are left intact
/// so inertial scrolling stays smooth. Requires Accessibility permission.
///
/// The tap runs on a dedicated thread with its own run loop: a modifying tap
/// scheduled on the main run loop stalls whenever the main thread does, and
/// macOS permanently disables taps that hold events too long
/// (`tapDisabledByTimeout`). A watchdog timer re-enables the tap if the
/// system disables it anyway.
@MainActor
final class ScrollTap: ObservableObject {
    @Published var reverseTrackpad: Bool {
        didSet {
            UserDefaults.standard.set(reverseTrackpad, forKey: "scrollReverseTrackpad")
            core?.update(config)
        }
    }
    @Published var reverseMouse: Bool {
        didSet {
            UserDefaults.standard.set(reverseMouse, forKey: "scrollReverseMouse")
            core?.update(config)
        }
    }
    @Published var reverseVertical: Bool {
        didSet {
            UserDefaults.standard.set(reverseVertical, forKey: "scrollReverseVertical")
            core?.update(config)
        }
    }
    @Published var reverseHorizontal: Bool {
        didSet {
            UserDefaults.standard.set(reverseHorizontal, forKey: "scrollReverseHorizontal")
            core?.update(config)
        }
    }

    @Published private(set) var tapActive = false

    private var core: TapCore?
    private var watchdog: Timer?
    private var permissionPoll: Timer?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "scrollReverseTrackpad": true,
            "scrollReverseMouse": true,
            "scrollReverseVertical": true,
            "scrollReverseHorizontal": false,
        ])
        reverseTrackpad = defaults.bool(forKey: "scrollReverseTrackpad")
        reverseMouse = defaults.bool(forKey: "scrollReverseMouse")
        reverseVertical = defaults.bool(forKey: "scrollReverseVertical")
        reverseHorizontal = defaults.bool(forKey: "scrollReverseHorizontal")
    }

    private var config: TapCore.Config {
        TapCore.Config(reverseTrackpad: reverseTrackpad,
                       reverseMouse: reverseMouse,
                       reverseVertical: reverseVertical,
                       reverseHorizontal: reverseHorizontal)
    }

    func start() {
        guard core == nil else { return }
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            // Keep checking so the tap comes up as soon as the user grants
            // access — no need to toggle the feature off and on again.
            if permissionPoll == nil {
                permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    Task { @MainActor in
                        let reverser = AppState.shared.scrollReverser
                        guard AppState.shared.scrollReverserEnabled else {
                            reverser.cancelPermissionPoll()
                            return
                        }
                        if Permissions.accessibilityGranted {
                            reverser.cancelPermissionPoll()
                            reverser.start()
                        }
                    }
                }
            }
            return
        }
        cancelPermissionPoll()

        let core = TapCore(config: config)
        self.core = core
        core.start { [weak self] ok in
            Task { @MainActor in
                guard let self, self.core === core else { return }
                self.tapActive = ok
                if !ok { self.core = nil }
            }
        }
        startWatchdog()
    }

    func cancelPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func stop() {
        cancelPermissionPoll()
        watchdog?.invalidate()
        watchdog = nil
        core?.shutdown()
        core = nil
        tapActive = false
    }

    /// macOS disables taps it considers too slow; the in-callback re-enable
    /// only fires if the disable notification is actually delivered, so poll
    /// as a backstop and keep `tapActive` honest for the UI.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let core = self.core else {
                    // Tap creation failed (it can, even with Accessibility
                    // granted, while things settle after login). `start()`
                    // guards on a nil core, so this simply retries it rather
                    // than leaving the feature dead until the next toggle.
                    self.start()
                    return
                }
                self.tapActive = core.ensureEnabled()
            }
        }
    }
}

/// Owns the CGEventTap and the thread it runs on. Shared with the C callback
/// across threads, so state is guarded by a lock rather than an actor.
private final class TapCore: @unchecked Sendable {
    struct Config {
        var reverseTrackpad: Bool
        var reverseMouse: Bool
        var reverseVertical: Bool
        var reverseHorizontal: Bool
    }

    private let lock = NSLock()
    private var config: Config
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var cancelled = false

    init(config: Config) {
        self.config = config
    }

    func update(_ config: Config) {
        lock.withLock { self.config = config }
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        let thread = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: scrollTapCallback,
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
        thread.name = "ScrollTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func shutdown() {
        let (tap, runLoop): (CFMachPort?, CFRunLoop?) = lock.withLock {
            cancelled = true
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

    /// Mutates the event in place. Runs on the tap thread.
    func handle(_ event: CGEvent) {
        let config = lock.withLock { self.config }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let shouldReverse = continuous ? config.reverseTrackpad : config.reverseMouse
        guard shouldReverse else { return }

        if config.reverseVertical {
            negate(event, .scrollWheelEventDeltaAxis1,
                   .scrollWheelEventPointDeltaAxis1,
                   .scrollWheelEventFixedPtDeltaAxis1)
        }
        if config.reverseHorizontal {
            negate(event, .scrollWheelEventDeltaAxis2,
                   .scrollWheelEventPointDeltaAxis2,
                   .scrollWheelEventFixedPtDeltaAxis2)
        }
    }

    private func negate(_ event: CGEvent,
                        _ delta: CGEventField,
                        _ pointDelta: CGEventField,
                        _ fixedDelta: CGEventField) {
        // Read all originals before any write: setting the integer delta makes
        // macOS recompute the point/fixed fields, clobbering the fine-grained
        // pixel values and causing jitter at slow scroll speeds.
        let d = event.getIntegerValueField(delta)
        let pd = event.getIntegerValueField(pointDelta)
        let fd = event.getDoubleValueField(fixedDelta)
        event.setIntegerValueField(delta, value: -d)
        event.setIntegerValueField(pointDelta, value: -pd)
        event.setDoubleValueField(fixedDelta, value: -fd)
    }
}

/// C callback — runs on the dedicated tap thread. TapCore is kept alive by
/// the thread's closure for as long as the run loop (and thus this callback)
/// can fire, so the unretained reference is safe.
private func scrollTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let core = Unmanaged<TapCore>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        core.reenableAfterTimeout()
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    core.handle(event)
    return Unmanaged.passUnretained(event)
}
