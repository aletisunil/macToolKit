import Foundation

/// One ranked list of remembered devices, persisted as JSON in the app's
/// standard defaults. Two instances exist — outputs and inputs — which is why
/// the defaults key is an init parameter.
@MainActor
final class AudioPriorityStore: ObservableObject {
    @Published var entries: [AudioDeviceRef] {
        didSet {
            guard entries != oldValue else { return }
            save()
            if !suppressChangeNotification { onChange?() }
        }
    }

    /// Fired after an edit so the controller can re-evaluate. Reordering the
    /// list is an explicit ask, so it switches devices immediately.
    var onChange: (() -> Void)?

    private let key: String
    private let defaults: UserDefaults
    private var suppressChangeNotification = false

    /// `defaults` is injectable so tests can round-trip a list without writing
    /// to the app's real preferences.
    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([AudioDeviceRef].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    func contains(uid: String) -> Bool {
        entries.contains { $0.uid == uid }
    }

    func add(_ device: LiveAudioDevice) {
        guard !contains(uid: device.uid) else { return }
        entries.append(device.reference)
    }

    func remove(uid: String) {
        entries.removeAll { $0.uid == uid }
    }

    /// Devices get renamed in Audio MIDI Setup; refresh the cached labels of
    /// remembered entries whenever we see them connected. Silent: a label
    /// changing underneath us is not a user edit and must not switch devices.
    func refreshNames(from connected: [LiveAudioDevice]) {
        let refreshed = AudioPriorityController.refreshingNames(entries, from: connected)
        guard refreshed != entries else { return }
        suppressChangeNotification = true
        entries = refreshed
        suppressChangeNotification = false
    }
}
