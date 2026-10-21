import AppKit
import CoreGraphics

/// A CGEventTap with the lifecycle every input feature in this app needs.
///
/// - The tap runs on a dedicated thread with its own run loop. A tap on the
///   main run loop stalls whenever the main thread does, and macOS disables
///   taps that hold events too long (`tapDisabledByTimeout`).
/// - A 2 s watchdog re-enables the tap when the disable notification never
///   reaches the callback, and retries creation when `CGEvent.tapCreate`
///   failed - it can, even with Accessibility granted, right after login.
/// - Without Accessibility, `start()` prompts once and then polls, so the tap
///   comes up as soon as access is granted, with no need to toggle the
///   feature off and on again.
///
/// The handler runs on the tap thread for every event in the mask. It mutates
/// the event in place to change it and returns false to swallow it. It must
/// be fast; anything slow belongs on another queue.
@MainActor
final class EventTap: ObservableObject {
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Bool

    /// The tap exists and is enabled. False while waiting for permission,
    /// after a failed creation, and while macOS has the tap disabled.
    @Published private(set) var isActive = false

    private let name: String
    private let mask: CGEventMask
    private let options: CGEventTapOptions
    private let handler: Handler

    private var running = false
    private var core: EventTapCore?
    private var watchdog: Timer?
    private var permissionPoll: Timer?

    init(name: String, events: [CGEventType],
         options: CGEventTapOptions = .defaultTap, handler: @escaping Handler) {
        self.name = name
        self.mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        self.options = options
        self.handler = handler
    }

    func start() {
        guard !running else { return }
        running = true
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            waitForPermission()
            return
        }
        attachCore()
        // Started even if the creation above failed, so it can retry.
        startWatchdog()
    }

    func stop() {
        running = false
        permissionPoll?.invalidate()
        permissionPoll = nil
        watchdog?.invalidate()
        watchdog = nil
        core?.shutdown()
        core = nil
        isActive = false
    }

    private func waitForPermission() {
        guard permissionPoll == nil else { return }
        permissionPoll = Permissions.whenAccessibilityGranted { [weak self] in
            guard let self, self.running else { return }
            self.permissionPoll = nil
            self.attachCore()
            self.startWatchdog()
        }
    }

    private func attachCore() {
        guard core == nil else { return }
        let core = EventTapCore(handler: handler)
        self.core = core
        core.start(name: name, mask: mask, options: options) { [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.core === core else { return }
                    self.isActive = ok
                    if !ok { self.core = nil }
                }
            }
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let core = self.core else {
                    self.attachCore()
                    return
                }
                let enabled = core.ensureEnabled()
                if self.isActive != enabled { self.isActive = enabled }
            }
        }
    }
}

/// Owns the CGEventTap and the thread it runs on. Shared with the C callback
/// across threads, so state is guarded by a lock rather than an actor.
private final class EventTapCore: @unchecked Sendable {
    let handler: EventTap.Handler

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var cancelled = false

    init(handler: @escaping EventTap.Handler) {
        self.handler = handler
    }

    func start(name: String, mask: CGEventMask, options: CGEventTapOptions,
               completion: @escaping @Sendable (Bool) -> Void) {
        let thread = Thread { [self] in
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: eventTapCallback,
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
        thread.name = name
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

    func reenable() {
        if let tap = lock.withLock({ self.tap }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

/// C callback - runs on the dedicated tap thread. The core is kept alive by
/// the thread's closure for as long as the run loop (and so this callback)
/// can fire, which makes the unretained reference safe.
private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let core = Unmanaged<EventTapCore>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        core.reenable()
        return Unmanaged.passUnretained(event)
    }
    return core.handler(type, event) ? Unmanaged.passUnretained(event) : nil
}
