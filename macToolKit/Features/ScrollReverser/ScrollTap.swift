import AppKit
import CoreGraphics
import Combine

/// Reverses scroll direction with a modifying CGEventTap. Continuous scroll
/// events (trackpad / Magic Mouse) and discrete wheel events are toggled
/// independently. Deltas are negated; scroll/momentum phases are left intact
/// so inertial scrolling stays smooth. Requires Accessibility permission.
@MainActor
final class ScrollTap: ObservableObject {
    @Published var reverseTrackpad: Bool {
        didSet { UserDefaults.standard.set(reverseTrackpad, forKey: "scrollReverseTrackpad") }
    }
    @Published var reverseMouse: Bool {
        didSet { UserDefaults.standard.set(reverseMouse, forKey: "scrollReverseMouse") }
    }
    @Published var reverseVertical: Bool {
        didSet { UserDefaults.standard.set(reverseVertical, forKey: "scrollReverseVertical") }
    }
    @Published var reverseHorizontal: Bool {
        didSet { UserDefaults.standard.set(reverseHorizontal, forKey: "scrollReverseHorizontal") }
    }

    @Published private(set) var tapActive = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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

    func start() {
        guard tap == nil else { return }
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
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
    }

    func cancelPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func stop() {
        cancelPermissionPoll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapActive = false
    }

    func reenableAfterTimeout() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Mutates the event in place.
    func handle(_ event: CGEvent) {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let shouldReverse = continuous ? reverseTrackpad : reverseMouse
        guard shouldReverse else { return }

        if reverseVertical {
            negate(event, .scrollWheelEventDeltaAxis1,
                   .scrollWheelEventPointDeltaAxis1,
                   .scrollWheelEventFixedPtDeltaAxis1)
        }
        if reverseHorizontal {
            negate(event, .scrollWheelEventDeltaAxis2,
                   .scrollWheelEventPointDeltaAxis2,
                   .scrollWheelEventFixedPtDeltaAxis2)
        }
    }

    private func negate(_ event: CGEvent,
                        _ delta: CGEventField,
                        _ pointDelta: CGEventField,
                        _ fixedDelta: CGEventField) {
        event.setIntegerValueField(delta, value: -event.getIntegerValueField(delta))
        event.setIntegerValueField(pointDelta, value: -event.getIntegerValueField(pointDelta))
        event.setDoubleValueField(fixedDelta, value: -event.getDoubleValueField(fixedDelta))
    }
}

/// C callback — runs on the main run loop (the tap source is scheduled there),
/// so hopping to MainActor state via assumeIsolated is safe.
private func scrollTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenableAfterTimeout() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // The tap source is scheduled on the main run loop, so this callback is on
    // the main thread; CGEvent itself is not Sendable, hence the unsafe marker.
    nonisolated(unsafe) let unsafeEvent = event
    MainActor.assumeIsolated { tap.handle(unsafeEvent) }
    return Unmanaged.passUnretained(event)
}
