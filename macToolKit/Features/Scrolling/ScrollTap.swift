import AppKit
import CoreGraphics
import Combine
import Synchronization

/// The scroll pipeline behind Scroll Reverser and Smooth Scrolling: one
/// modifying event tap for both, so the order is fixed - an event is
/// reversed first, then smoothed. With two taps the order would be up to the
/// window server, and a reversed glide could come out reversed twice or not
/// at all. The tap runs while either feature is on. Requires Accessibility
/// permission.
@MainActor
final class ScrollTap: ObservableObject {
    // MARK: Scroll Reverser

    @Published var reverseTrackpad: Bool {
        didSet {
            UserDefaults.standard.set(reverseTrackpad, forKey: "scrollReverseTrackpad")
            reversal.update(reversalConfig)
        }
    }
    @Published var reverseMouse: Bool {
        didSet {
            UserDefaults.standard.set(reverseMouse, forKey: "scrollReverseMouse")
            reversal.update(reversalConfig)
        }
    }
    @Published var reverseVertical: Bool {
        didSet {
            UserDefaults.standard.set(reverseVertical, forKey: "scrollReverseVertical")
            reversal.update(reversalConfig)
        }
    }
    @Published var reverseHorizontal: Bool {
        didSet {
            UserDefaults.standard.set(reverseHorizontal, forKey: "scrollReverseHorizontal")
            reversal.update(reversalConfig)
        }
    }

    // MARK: Smooth Scrolling

    @Published var smoothness: ScrollSmoothness {
        didSet {
            UserDefaults.standard.set(smoothness.rawValue, forKey: "smoothScrollSmoothness")
            smoother.update(smootherConfig)
        }
    }
    /// Distance multiplier; 1× scrolls 40 pt per wheel line.
    @Published var smoothSpeed: Double {
        didSet {
            UserDefaults.standard.set(smoothSpeed, forKey: "smoothScrollSpeed")
            smoother.update(smootherConfig)
        }
    }
    /// Apps that get the wheel unsmoothed, matched against the app under the
    /// pointer - the one the scroll goes to.
    let smoothExceptions = AppListStore(key: "smoothScrollExceptions")
    private var exceptionIDs: Set<String> = []

    static let speedRange: ClosedRange<Double> = 0.5...2

    // MARK: Which features need the tap (set by AppState)

    var reverserEnabled = false {
        didSet {
            guard reverserEnabled != oldValue else { return }
            reversal.update(reversalConfig)
            updateTap()
        }
    }
    var smoothingEnabled = false {
        didSet {
            guard smoothingEnabled != oldValue else { return }
            if smoothingEnabled { attachClock() }
            smoother.update(smootherConfig)
            updateTap()
        }
    }

    @Published private(set) var tapActive = false

    private let reversal: ScrollReversal
    private let smoother: ScrollSmoother
    private let tap: EventTap
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "scrollReverseTrackpad": true,
            "scrollReverseMouse": true,
            "scrollReverseVertical": true,
            "scrollReverseHorizontal": false,
            "smoothScrollSmoothness": ScrollSmoothness.medium.rawValue,
            "smoothScrollSpeed": 1.0,
        ])
        reverseTrackpad = defaults.bool(forKey: "scrollReverseTrackpad")
        reverseMouse = defaults.bool(forKey: "scrollReverseMouse")
        reverseVertical = defaults.bool(forKey: "scrollReverseVertical")
        reverseHorizontal = defaults.bool(forKey: "scrollReverseHorizontal")
        smoothness = ScrollSmoothness(
            rawValue: defaults.string(forKey: "smoothScrollSmoothness") ?? "") ?? .medium
        smoothSpeed = min(max(defaults.double(forKey: "smoothScrollSpeed"),
                              Self.speedRange.lowerBound), Self.speedRange.upperBound)

        let reversal = ScrollReversal()
        let smoother = ScrollSmoother()
        self.reversal = reversal
        self.smoother = smoother
        tap = EventTap(name: "ScrollTap", events: [.scrollWheel]) { _, event in
            reversal.apply(to: event)
            return smoother.handle(event)
        }
        reversal.update(reversalConfig)
        smoother.update(smootherConfig)
        tap.$isActive.assign(to: &$tapActive)

        // @Published sends before the property changes, so the new list
        // comes from the value sent, not from the store.
        smoothExceptions.$apps
            .sink { [weak self] apps in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.exceptionIDs = Set(apps.map(\.bundleID))
                    self.smoother.update(self.smootherConfig)
                }
            }
            .store(in: &subscriptions)
        // The clock ticks with one display; follow displays coming and going.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.smoothingEnabled else { return }
                    self.attachClock()
                }
            }
            .store(in: &subscriptions)
        smoother.setStallHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.smoothingEnabled else { return }
                    self.attachClock()
                }
            }
        }
    }

    private func updateTap() {
        if reverserEnabled || smoothingEnabled {
            tap.start()
        } else {
            tap.stop()
        }
    }

    /// The fastest display sets the pace: a glide posted at 120 Hz looks
    /// fine on a 60 Hz display, the other way round it does not.
    private func attachClock() {
        guard let screen = NSScreen.screens.max(by: {
            $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        }) else { return }
        smoother.attachClock(to: screen)
    }

    private var reversalConfig: ScrollReversal.Config {
        ScrollReversal.Config(enabled: reverserEnabled,
                              reverseTrackpad: reverseTrackpad,
                              reverseMouse: reverseMouse,
                              reverseVertical: reverseVertical,
                              reverseHorizontal: reverseHorizontal)
    }

    private var smootherConfig: ScrollSmoother.Config {
        ScrollSmoother.Config(enabled: smoothingEnabled,
                              smoothness: smoothness,
                              speed: smoothSpeed,
                              exceptions: exceptionIDs)
    }
}

/// The reversal itself. Runs on the tap thread; the config is pushed from
/// the main actor whenever a setting changes.
private final class ScrollReversal: Sendable {
    struct Config {
        var enabled = false
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
        guard event.type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != ScrollSmoother.marker
        else { return }
        let config = self.config.withLock { $0 }
        guard config.enabled else { return }
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
