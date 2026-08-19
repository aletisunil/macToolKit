import CoreAudio
import Foundation

/// Thin wrapper over the CoreAudio HAL property API.
///
/// Stateless and nonisolated on purpose: HAL property reads are served from
/// the client-side cache, so a full pass over a dozen devices is sub-millisecond
/// and safe to do on the main actor.
enum AudioDevices {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The one property we listen to: the set of devices attached to the system.
    static var devicesAddress: AudioObjectPropertyAddress {
        address(kAudioHardwarePropertyDevices)
    }

    // MARK: Enumeration

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let stride = MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size,
                                       buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        // The HAL writes back how many bytes it actually filled, which can be
        // fewer than the size it quoted a moment ago.
        return Array(ids.prefix(Int(size) / stride))
    }

    /// Total channels on `scope`. Zero means the device can't act in that
    /// direction at all, which is how output-only and input-only devices are
    /// told apart (many devices are both).
    static func channelCount(_ device: AudioDeviceID,
                             scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        // AudioBufferList is a variable-length struct: a stack instance holds
        // exactly one buffer and would overflow for any multi-stream device.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Identity

    /// Stable across replug and reboot — this is what gets persisted.
    /// `AudioDeviceID` is an ephemeral token and must never be stored.
    static func uid(_ device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    /// Display name. Can change: devices are renameable in Audio MIDI Setup.
    static func name(_ device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioObjectPropertyName)
    }

    static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
        else { return 0 }
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        // The HAL hands back a +1 reference; takeRetainedValue consumes it.
        // Reading into a plain `CFString?` leaks it.
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Defaults

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultDevice(_ selector: AudioObjectPropertySelector,
                                 to device: AudioDeviceID) -> OSStatus {
        var addr = address(selector)
        var id = device
        return AudioObjectSetPropertyData(
            systemObject, &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    // MARK: Snapshot

    /// One HAL pass: every device plus the current default output and input.
    static func snapshot() -> AudioSnapshot {
        let devices = allDeviceIDs().compactMap { id -> LiveAudioDevice? in
            guard let uid = uid(id) else { return nil }
            return LiveAudioDevice(
                deviceID: id,
                uid: uid,
                name: name(id) ?? uid,
                transport: AudioTransport(hal: transportType(id)),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput))
        }
        let byID = { (id: AudioDeviceID?) -> String? in
            guard let id else { return nil }
            return devices.first { $0.deviceID == id }?.uid
        }
        return AudioSnapshot(
            devices: devices,
            defaultOutputUID: byID(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
            defaultInputUID: byID(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)))
    }
}
