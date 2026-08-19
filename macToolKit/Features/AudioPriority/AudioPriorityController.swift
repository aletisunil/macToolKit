import AppKit
import Combine
import CoreAudio

/// Keeps the system default output and input on the highest-ranked device that
/// is actually plugged in.
///
/// The contract is "respect manual picks": we react to the *set of devices*
/// changing, never to the *default device* changing. That is why there is no
/// listener on `kAudioHardwarePropertyDefaultOutputDevice` here — adding one
/// looks like an obvious improvement and would silently break the feature,
/// because every manual change in System Settings would be snapped back.
@MainActor
final class AudioPriorityController: NSObject, ObservableObject {
    /// A single hardware event fires several device-list notifications (a dock
    /// enumerating output then input, AirPods appearing as separate HFP/A2DP
    /// entries before collapsing). Coalesce so we don't land on a transient.
    nonisolated static let debounce: Duration = .milliseconds(400)

    let outputs = AudioPriorityStore(key: "audioPriorityOutputs")
    let inputs = AudioPriorityStore(key: "audioPriorityInputs")

    /// Alert sounds and volume-key feedback follow their own default device.
    /// Left alone, they keep playing out of the previous device — a split that
    /// reads as a bug — so mirror it unless the user opts out.
    @Published var alertSounds: Bool {
        didSet { UserDefaults.standard.set(alertSounds, forKey: "audioPriorityAlertSounds") }
    }

    @Published private(set) var snapshot = AudioSnapshot()

    private(set) var running = false

    /// In-memory only. A relaunch goes through `.featureStart`, which asserts
    /// against the live default, so persisting this would only go stale.
    private var lastApplied: [AudioDirection: String] = [:]

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(
        label: "com.sunilaleti.mactoolkit.audiopriority.listener")
    private var pendingEvaluation: Task<Void, Never>?
    private var wakeObserverRegistered = false

    override init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["audioPriorityAlertSounds": true])
        alertSounds = defaults.bool(forKey: "audioPriorityAlertSounds")
        super.init()

        outputs.onChange = { [weak self] in self?.evaluate(trigger: .featureStart) }
        inputs.onChange = { [weak self] in self?.evaluate(trigger: .featureStart) }
        refreshSnapshot()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        registerForWake()
        registerListener()
        evaluate(trigger: .featureStart)
    }

    func stop() {
        guard running else { return }
        running = false
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        removeListener()
        lastApplied.removeAll()
        // Deliberately no restore: the current default is the user's audio
        // route now, not app-owned global state like a gamma table.
    }

    // MARK: Snapshot

    /// Re-read devices and defaults. Never applies anything, so the settings
    /// pane can poll this while the feature is switched off.
    func refreshSnapshot() {
        let fresh = AudioDevices.snapshot()
        if fresh != snapshot { snapshot = fresh }
        outputs.refreshNames(from: fresh.devices)
        inputs.refreshNames(from: fresh.devices)
    }

    func store(for direction: AudioDirection) -> AudioPriorityStore {
        direction == .output ? outputs : inputs
    }

    // MARK: Events

    private func registerListener() {
        guard listenerBlock == nil else { return }
        var addr = AudioDevices.devicesAddress
        // Materialise the block once and keep it: the HAL matches listeners by
        // block identity, so add and remove have to see the same instance.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Fires on listenerQueue — hop before touching controller state.
            Task { @MainActor in self?.deviceListChanged() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioDevices.systemObject, &addr,
                                            listenerQueue, block)
    }

    private func removeListener() {
        guard let listenerBlock else { return }
        var addr = AudioDevices.devicesAddress
        AudioObjectRemovePropertyListenerBlock(AudioDevices.systemObject, &addr,
                                               listenerQueue, listenerBlock)
        self.listenerBlock = nil
    }

    private func registerForWake() {
        // Registered once for the controller's lifetime; the handler is gated
        // on `running`, so it is harmless while the feature is off.
        guard !wakeObserverRegistered else { return }
        wakeObserverRegistered = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemDidWake() {
        guard running else { return }
        // Bluetooth and USB re-enumeration after wake takes a moment, and any
        // device that actually came back fires the listener anyway. This is the
        // safety net for a silent reassignment during sleep.
        schedule(trigger: .deviceSetChanged, after: .seconds(2))
    }

    private func deviceListChanged() {
        refreshSnapshot()
        guard running else { return }
        schedule(trigger: .deviceSetChanged, after: Self.debounce)
    }

    private func schedule(trigger: AudioTrigger, after delay: Duration) {
        pendingEvaluation?.cancel()
        pendingEvaluation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.evaluate(trigger: trigger)
        }
    }

    // MARK: Evaluation

    func evaluate(trigger: AudioTrigger) {
        guard running else { return }
        refreshSnapshot()
        for direction in AudioDirection.allCases {
            let outcome = Self.decide(
                ranked: store(for: direction).entries,
                connected: snapshot.devices,
                direction: direction,
                currentDefaultUID: snapshot.defaultUID(for: direction),
                lastAppliedUID: lastApplied[direction],
                trigger: trigger)
            guard let uid = outcome.apply else {
                lastApplied[direction] = outcome.winner
                continue
            }
            // A device that refuses the role leaves `lastApplied` untouched, so
            // the next device event sees a winner it has not applied yet and
            // tries again instead of assuming the route took.
            if apply(uid: uid, direction: direction) {
                lastApplied[direction] = outcome.winner
            }
        }
    }

    private func apply(uid: String, direction: AudioDirection) -> Bool {
        guard let device = snapshot.devices.first(where: { $0.uid == uid }) else { return false }
        let selector = direction == .output
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice
        guard AudioDevices.setDefaultDevice(selector, to: device.deviceID) == noErr
        else { return false }

        if direction == .output, alertSounds {
            // Best effort: some devices refuse the system-output role, and the
            // main output change still stands if this one fails.
            AudioDevices.setDefaultDevice(
                kAudioHardwarePropertyDefaultSystemOutputDevice, to: device.deviceID)
        }
        refreshSnapshot()
        return true
    }

    // MARK: Policy, free of controller state

    /// Highest-ranked entry that is connected and can actually work in this
    /// direction. nil when none of the ranked devices are present.
    nonisolated static func winner(ranked: [AudioDeviceRef],
                                   connected: [LiveAudioDevice],
                                   direction: AudioDirection) -> String? {
        let usable = Set(connected.filter { $0.supports(direction) }.map(\.uid))
        return ranked.first { usable.contains($0.uid) }?.uid
    }

    /// The whole switching policy.
    ///
    /// On `.deviceSetChanged` the comparison is against `lastAppliedUID`, not
    /// against the current default, and that is deliberate: it means an
    /// unrelated device-list event never undoes a manual pick. The manual pick
    /// only loses when a *ranked* device comes or goes and the winner actually
    /// moves.
    nonisolated static func decide(ranked: [AudioDeviceRef],
                                   connected: [LiveAudioDevice],
                                   direction: AudioDirection,
                                   currentDefaultUID: String?,
                                   lastAppliedUID: String?,
                                   trigger: AudioTrigger) -> AudioOutcome {
        let top = winner(ranked: ranked, connected: connected, direction: direction)

        // Nothing ranked is plugged in: leave whatever macOS chose alone.
        guard let top else { return AudioOutcome(apply: nil, winner: nil) }

        // Already there. A redundant set glitches some USB interfaces.
        guard top != currentDefaultUID else { return AudioOutcome(apply: nil, winner: top) }

        switch trigger {
        case .featureStart:
            return AudioOutcome(apply: top, winner: top)
        case .deviceSetChanged:
            return top == lastAppliedUID
                ? AudioOutcome(apply: nil, winner: top)
                : AudioOutcome(apply: top, winner: top)
        }
    }

    nonisolated static func refreshingNames(_ ranked: [AudioDeviceRef],
                                            from connected: [LiveAudioDevice])
        -> [AudioDeviceRef] {
        let live = Dictionary(connected.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.map { entry in
            guard let device = live[entry.uid] else { return entry }
            return AudioDeviceRef(uid: entry.uid, name: device.name,
                                  transport: device.transport)
        }
    }
}
