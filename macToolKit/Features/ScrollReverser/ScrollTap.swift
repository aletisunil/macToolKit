import AppKit
import CoreGraphics
import Combine
import Synchronization

/// Reverses scroll direction with a modifying event tap. Continuous scroll
/// events (trackpad / Magic Mouse) and discrete wheel events are toggled
/// independently. Deltas are negated; scroll/momentum phases are left intact
/// so inertial scrolling stays smooth. Requires Accessibility permission.
@MainActor
final class ScrollTap: ObservableObject {
    @Published var reverseTrackpad: Bool {
        didSet {
            UserDefaults.standard.set(reverseTrackpad, forKey: "scrollReverseTrackpad")
            reversal.update(config)
        }
    }
    @Published var reverseMouse: Bool {
        didSet {
            UserDefaults.standard.set(reverseMouse, forKey: "scrollReverseMouse")
            reversal.update(config)
        }
    }
    @Published var reverseVertical: Bool {
        didSet {
            UserDefaults.standard.set(reverseVertical, forKey: "scrollReverseVertical")
            reversal.update(config)
        }
    }
    @Published var reverseHorizontal: Bool {
        didSet {
            UserDefaults.standard.set(reverseHorizontal, forKey: "scrollReverseHorizontal")
            reversal.update(config)
        }
    }

    @Published private(set) var tapActive = false

    private let reversal: ScrollReversal
    private let tap: EventTap

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

        let reversal = ScrollReversal()
        self.reversal = reversal
        tap = EventTap(name: "ScrollTap", events: [.scrollWheel]) { _, event in
            reversal.apply(to: event)
            return true
        }
        reversal.update(config)
        tap.$isActive.assign(to: &$tapActive)
    }

    func start() { tap.start() }
    func stop() { tap.stop() }

    private var config: ScrollReversal.Config {
        ScrollReversal.Config(reverseTrackpad: reverseTrackpad,
                              reverseMouse: reverseMouse,
                              reverseVertical: reverseVertical,
                              reverseHorizontal: reverseHorizontal)
    }
}

/// The reversal itself. Runs on the tap thread; the config is pushed from
/// the main actor whenever a setting changes.
private final class ScrollReversal: Sendable {
    struct Config {
        var reverseTrackpad = true
        var reverseMouse = true
        var reverseVertical = true
        var reverseHorizontal = false
    }

    private let config = Mutex(Config())

    func update(_ config: Config) {
        self.config.withLock { $0 = config }
    }

    /// Mutates the event in place.
    func apply(to event: CGEvent) {
        guard event.type == .scrollWheel else { return }
        let config = self.config.withLock { $0 }
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
