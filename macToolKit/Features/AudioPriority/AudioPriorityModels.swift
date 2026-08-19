import CoreAudio
import Foundation

enum AudioDirection: String, Codable, CaseIterable, Sendable {
    case output, input

    var title: String {
        switch self {
        case .output: "Output"
        case .input: "Input"
        }
    }
}

/// Persisted alongside the device so a remembered-but-unplugged entry still
/// draws the right icon.
enum AudioTransport: String, Codable, Sendable {
    case builtIn, usb, bluetooth, hdmi, displayPort, thunderbolt, airPlay
    case firewire, pci, avb, aggregate, virtual, continuity, other

    init(hal code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeFireWire: self = .firewire
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        default: self = .other
        }
    }

    func symbol(for direction: AudioDirection) -> String {
        switch self {
        case .bluetooth, .airPlay:
            return direction == .output ? "airpodspro" : "wave.3.right"
        case .usb, .firewire, .thunderbolt, .avb, .pci:
            return direction == .output ? "hifispeaker" : "mic"
        case .hdmi, .displayPort:
            return "display"
        case .aggregate, .virtual:
            return "square.stack.3d.up"
        case .continuity:
            return "iphone"
        case .builtIn, .other:
            return direction == .output ? "speaker.wave.2" : "mic"
        }
    }
}

/// A remembered device. `uid` is the identity; `name` and `transport` are
/// last-seen caches so an unplugged entry stays recognisable in the list.
struct AudioDeviceRef: Codable, Identifiable, Equatable, Sendable {
    var uid: String
    var name: String
    var transport: AudioTransport

    var id: String { uid }
}

/// A device as it exists right now. Never persisted.
struct LiveAudioDevice: Identifiable, Equatable, Sendable {
    var deviceID: AudioDeviceID
    var uid: String
    var name: String
    var transport: AudioTransport
    var outputChannels: Int
    var inputChannels: Int

    var id: String { uid }

    func supports(_ direction: AudioDirection) -> Bool {
        direction == .output ? outputChannels > 0 : inputChannels > 0
    }

    var reference: AudioDeviceRef {
        AudioDeviceRef(uid: uid, name: name, transport: transport)
    }
}

/// Everything one evaluation needs, captured in a single HAL pass.
struct AudioSnapshot: Equatable, Sendable {
    var devices: [LiveAudioDevice] = []
    var defaultOutputUID: String?
    var defaultInputUID: String?

    func defaultUID(for direction: AudioDirection) -> String? {
        direction == .output ? defaultOutputUID : defaultInputUID
    }

    func devices(for direction: AudioDirection) -> [LiveAudioDevice] {
        devices.filter { $0.supports(direction) }
    }
}

/// Why an evaluation is running. The distinction is the whole of the
/// respect-manual-picks policy — see `AudioPriorityController.decide`.
enum AudioTrigger: Equatable, Sendable {
    /// The set of attached devices changed, or the machine woke.
    case deviceSetChanged
    /// The feature was switched on, the app launched with it on, or the
    /// ranked list was edited. All explicit asks.
    case featureStart
}

/// What one evaluation concluded.
struct AudioOutcome: Equatable, Sendable {
    /// UID to make default, or nil to leave the system alone.
    var apply: String?
    /// Highest-ranked connected device; recorded as `lastApplied` either way.
    var winner: String?
}
