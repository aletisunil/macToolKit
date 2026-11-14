import AppKit
import QuartzCore
import Synchronization
import os

/// How long one notch takes to glide to a stop.
enum ScrollSmoothness: String, CaseIterable, Identifiable, Sendable {
    case short, medium, long

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Time constant of the exponential ease-out, in seconds. A glide covers
    /// 63% of what is left in one constant and settles after about five.
    var timeConstant: Double {
        switch self {
        case .short: 0.035
        case .medium: 0.055
        case .long: 0.085
        }
    }
}

/// Smooth Scrolling: a notched mouse wheel moves the content in one jump per
/// notch. This turns each notch into a glide - a stream of small pixel
/// scrolls, one per display frame, that eases out to a stop.
///
/// How it fits together:
/// - The scroll tap (`ScrollTap`, HID level) hands every wheel event to
///   `handle(_:)` after Scroll Reverser has had its say, so a reversed notch
///   glides in the reversed direction and nothing is reversed twice.
/// - Only plain notched-wheel events glide. Trackpad and Magic Mouse scrolls,
///   momentum, and any event with a modifier key pass through untouched:
///   ⌘/⌃ + wheel zoom, and AppKit only turns ⇧ + wheel into a sideways scroll
///   for line-based events, not for the pixel events a glide is made of.
/// - A glide is posted at the session level as pixel events with no gesture
///   phase. Phased events make AppKit add its own momentum after the "ended"
///   event, so the distance would no longer be exact. Session-level events
///   never reach the HID-level tap again, and carry `marker` besides.
/// - Distance is wheel lines × 40 pt × speed. 40 pt is what Safari, Chrome
///   and Electron apps scroll per line, so at 1× those feel the same as
///   before; AppKit apps (10 pt per line) scroll farther than before.
/// - Apps that count lines rather than points get one line per 40 pt
///   posted, so at 1× they see exactly the lines of the notch.
///
/// Threading: `handle(_:)` runs on the tap thread, `tick(_:)` on the display
/// clock's thread. State is shared under a mutex; the event is posted
/// outside it.
final class ScrollSmoother: Sendable {
    struct Config: Sendable {
        var enabled = false
        var smoothness = ScrollSmoothness.medium
        var speed = 1.0
        var exceptions: Set<String> = []
    }

    /// Points per wheel line at 1× speed.
    static let pointsPerLine = 40.0
    /// `eventSourceUserData` of every event a glide posts.
    static let marker: Int64 = 0x6D74_6B53 // "mtkS"

    private static let log = Logger.feature("SmoothScrolling")

    /// What is left of the current glide, per axis, in points. `carry` holds
    /// the fraction rounding has not posted yet, so the posted whole points
    /// always add up to the distance asked for.
    private struct Glide {
        var remainingX = 0.0
        var remainingY = 0.0
        var carryX = 0.0
        var carryY = 0.0
        /// Lines posted so far lag the points posted by this much, per axis:
        /// whole lines go out as soon as the points add up to one.
        var lineCarryX = 0.0
        var lineCarryY = 0.0
        /// The window being scrolled. A glide never moves on to another one.
        var window: CGWindowID?
        /// Pointer location at the last window check.
        var pointer = CGPoint.zero
        var lastTick: CFTimeInterval = 0
        /// The clock is ticking for this glide.
        var running = false

        var isFinished: Bool { remainingX == 0 && remainingY == 0 }

        mutating func clear() {
            remainingX = 0
            remainingY = 0
            carryX = 0
            carryY = 0
            lineCarryX = 0
            lineCarryY = 0
        }

        /// The whole lines `x` and `y` points complete, for apps that count
        /// lines instead of points.
        mutating func lines(x: Int32, y: Int32) -> (x: Int32, y: Int32) {
            (Self.lines(x, &lineCarryX), Self.lines(y, &lineCarryY))
        }

        private static func lines(_ points: Int32, _ carry: inout Double) -> Int32 {
            carry += Double(points) / ScrollSmoother.pointsPerLine
            let whole = carry.rounded()
            carry -= whole
            return Int32(whole)
        }
    }

    private let config = Mutex(Config())
    private let glide = Mutex(Glide())
    /// Window id -> owning app's bundle id, for the exception list. Window ids
    /// are not reused within a login session, so entries never go stale.
    private let owners = Mutex([CGWindowID: String]())
    private let clock = DisplayClock()
    private let onStall = Mutex<(@Sendable () -> Void)?>(nil)

    init() {
        clock.setHandler { [weak self] time in self?.tick(time) }
    }

    func update(_ config: Config) {
        self.config.withLock { $0 = config }
        if !config.enabled { cancel() }
    }

    /// Called when the clock stopped ticking mid-glide, so the owner can
    /// attach it to a display again.
    func setStallHandler(_ handler: @escaping @Sendable () -> Void) {
        onStall.withLock { $0 = handler }
    }

    @MainActor
    func attachClock(to screen: NSScreen) {
        clock.attach(to: screen)
    }

    /// Drops the rest of the current glide.
    func cancel() {
        glide.withLock { $0.clear() }
    }

    // MARK: Tap thread

    /// Returns false when the event was taken over by a glide (swallow it).
    func handle(_ event: CGEvent) -> Bool {
        let config = self.config.withLock { $0 }
        guard config.enabled,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker
        else { return true }

        let notched = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
            && event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
            && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
        let modifiers = event.flags.intersection(
            [.maskShift, .maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn])
        guard notched, modifiers.isEmpty else {
            // The trackpad, or a modifier: the person is doing something
            // else now, so the glide stops where it is.
            cancel()
            return true
        }

        let linesY = Self.lines(event, .scrollWheelEventFixedPtDeltaAxis1,
                                .scrollWheelEventDeltaAxis1)
        let linesX = Self.lines(event, .scrollWheelEventFixedPtDeltaAxis2,
                                .scrollWheelEventDeltaAxis2)
        guard linesY != 0 || linesX != 0 else { return true }

        let location = event.location
        let window = Self.windowID(at: location)
        if !config.exceptions.isEmpty, let window,
           let owner = owner(of: window), config.exceptions.contains(owner) {
            cancel()
            return true
        }

        let scale = Self.pointsPerLine * config.speed
        let now = CACurrentMediaTime()
        enum Start { case none, clock, flush(Int32, Int32, Int32, Int32) }
        let start: Start = glide.withLock { glide in
            if glide.window != window { glide.clear() }
            glide.window = window
            glide.pointer = location
            glide.remainingY = Self.add(linesY * scale, to: glide.remainingY)
            glide.remainingX = Self.add(linesX * scale, to: glide.remainingX)
            if !glide.running {
                glide.running = true
                glide.lastTick = now
                return .clock
            }
            // Ticking, supposedly - but no frame for a quarter second means
            // the clock's display went away. Scroll the rest in one go
            // rather than leave it hanging.
            guard now - glide.lastTick > 0.25 else { return .none }
            let x = Int32((glide.remainingX + glide.carryX).rounded())
            let y = Int32((glide.remainingY + glide.carryY).rounded())
            let lines = glide.lines(x: x, y: y)
            glide.clear()
            glide.running = false
            return .flush(x, y, lines.x, lines.y)
        }

        switch start {
        case .none: break
        case .clock: clock.resume()
        case .flush(let x, let y, let linesX, let linesY):
            Self.log.error("display clock stalled; flushed the glide")
            Self.post(x: x, y: y, linesX: linesX, linesY: linesY)
            onStall.withLock { $0 }?()
        }
        return false
    }

    /// Wheel lines in an event, fractional and accelerated by macOS.
    private static func lines(_ event: CGEvent, _ fixed: CGEventField,
                              _ whole: CGEventField) -> Double {
        let value = event.getDoubleValueField(fixed)
        return value != 0 ? value : Double(event.getIntegerValueField(whole))
    }

    /// A notch in the same direction adds to the glide, so a quick spin
    /// speeds it up. One in the other direction replaces it: the content
    /// turns around at once instead of first finishing the old glide.
    private static func add(_ distance: Double, to remaining: Double) -> Double {
        guard distance != 0 else { return remaining }
        if remaining != 0, (remaining > 0) != (distance > 0) { return distance }
        return remaining + distance
    }

    private func owner(of window: CGWindowID) -> String? {
        if let cached = owners.withLock({ $0[window] }) { return cached }
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window)
                  as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return nil }
        owners.withLock { owners in
            if owners.count > 512 { owners.removeAll() }
            owners[window] = bundleID
        }
        return bundleID
    }

    private static func windowID(at point: CGPoint) -> CGWindowID? {
        PrivateCGS.windowID(at: point) ?? WindowHitTest.window(at: point)?.windowID
    }

    // MARK: Clock thread

    private func tick(_ time: CFTimeInterval) {
        let timeConstant = config.withLock { $0.smoothness.timeConstant }

        // The pointer moved on to another window: the rest of the glide
        // would scroll that one, which the person never aimed at.
        var leftWindow = false
        if let pointer = CGEvent(source: nil)?.location {
            let (moved, window) = glide.withLock { glide in
                (hypot(pointer.x - glide.pointer.x, pointer.y - glide.pointer.y) > 2,
                 glide.window)
            }
            if moved {
                leftWindow = Self.windowID(at: pointer) != window
                glide.withLock { $0.pointer = pointer }
            }
        }

        let (x, y, lines, finished) = glide.withLock { glide in
            if leftWindow { glide.clear() }
            let dt = min(max(time - glide.lastTick, 0), 0.05)
            glide.lastTick = time
            let fraction = 1 - exp(-dt / timeConstant)
            let y = Self.step(&glide.remainingY, &glide.carryY, fraction)
            let x = Self.step(&glide.remainingX, &glide.carryX, fraction)
            let lines = glide.lines(x: x, y: y)
            if glide.isFinished {
                glide.clear()
                glide.running = false
                return (x, y, lines, true)
            }
            return (x, y, lines, false)
        }
        if x != 0 || y != 0 { Self.post(x: x, y: y, linesX: lines.x, linesY: lines.y) }
        // A notch landing between the unlock above and this pause sets
        // `running` and queues a resume, which the clock runs after this
        // tick - so the pause can never strand it.
        if finished { clock.pause() }
    }

    /// One frame of an axis: an exponential share of what is left, the last
    /// point in one go, rounded to whole points with the remainder carried.
    private static func step(_ remaining: inout Double, _ carry: inout Double,
                             _ fraction: Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        let move = abs(remaining) <= 1 ? remaining : remaining * fraction
        remaining -= move
        let total = move + carry
        let whole = total.rounded()
        carry = total - whole
        return Int32(whole)
    }

    private static func post(x: Int32, y: Int32, linesX: Int32, linesY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        else { return }
        // Left alone, a pixel event claims at least one line whenever it
        // moves at all, so an app that counts lines - Terminal turning the
        // wheel into reports for tmux or vim, games, Carbon and Java apps -
        // saw one line per frame: 26 for a 3-line notch. Each event carries
        // only the whole lines its points complete instead, in the integer
        // field and in the fractional one (NSEvent.deltaX/Y). The integer
        // write makes macOS recompute the other two, so it goes first.
        setLines(event, linesY, y, .scrollWheelEventDeltaAxis1,
                 .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        setLines(event, linesX, x, .scrollWheelEventDeltaAxis2,
                 .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        // A sourceless event carries the current pointer location, which
        // routes it to the window under the pointer, like the notch itself.
        event.post(tap: .cgSessionEventTap)
    }

    private static func setLines(_ event: CGEvent, _ lines: Int32, _ points: Int32,
                                 _ whole: CGEventField, _ fixed: CGEventField,
                                 _ point: CGEventField) {
        event.setIntegerValueField(whole, value: Int64(lines))
        event.setIntegerValueField(point, value: Int64(points))
        event.setDoubleValueField(fixed, value: Double(lines))
    }
}

/// A display-synced tick on a thread of its own, paused while nothing
/// glides. A timer on the main thread would stutter whenever the main thread
/// is busy; a free-running timer drifts against the display and posts two
/// events in some frames and none in others.
private final class DisplayClock: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var handler: (@Sendable (CFTimeInterval) -> Void)?
    /// Clock thread only.
    private var link: CADisplayLink?

    override init() {
        super.init()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            lock.withLock { runLoop = CFRunLoopGetCurrent() }
            // A run loop with nothing in it returns at once; the port keeps
            // it waiting for the display link and for queued blocks.
            RunLoop.current.add(NSMachPort(), forMode: .common)
            started.signal()
            while true {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "SmoothScrollClock"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    func setHandler(_ handler: @escaping @Sendable (CFTimeInterval) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Ticks at `screen`'s refresh rate from now on. A glide in progress
    /// carries on with the new link.
    @MainActor
    func attach(to screen: NSScreen) {
        nonisolated(unsafe) let link = screen.displayLink(target: self,
                                                          selector: #selector(tick(_:)))
        link.isPaused = true
        perform { [self] in
            let ticking = self.link.map { !$0.isPaused } ?? false
            self.link?.invalidate()
            link.isPaused = !ticking
            link.add(to: .current, forMode: .common)
            self.link = link
        }
    }

    func resume() {
        perform { [self] in link?.isPaused = false }
    }

    /// Clock thread only - called from within a tick.
    func pause() {
        link?.isPaused = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.withLock { handler }?(link.timestamp)
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop = lock.withLock({ runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
