import CoreAudio
import Foundation

/// The Mac's audio devices: microphones to choose from for voice input, and the volume of the sound output.
enum AudioDevices {
    struct Microphone: Hashable {
        let uid: String
        let name: String
    }

    /// Every device that can record, as macOS names it.
    static func microphones() -> [Microphone] {
        allDevices().compactMap { id in
            guard hasStreams(id, scope: kAudioObjectPropertyScopeInput),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(uid: uid, name: name)
        }
    }

    /// The device with this UID, if it is connected.
    static func deviceID(uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static var defaultOutput: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInput: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else {
            return nil
        }
        return id
    }

    /// The output volume, 0…1, per channel element that has one (the main element, or left and right).
    static func volume(of device: AudioDeviceID) -> [UInt32: Float32] {
        var result: [UInt32: Float32] = [:]
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { result[element] = value }
            if element == kAudioObjectPropertyElementMain, result[element] != nil { break }
        }
        return result
    }

    static func setVolume(_ volumes: [UInt32: Float32], of device: AudioDeviceID) {
        for (element, value) in volumes {
            var address = volumeAddress(element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var volume = min(max(value, 0), 1)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        }
    }

    // MARK: - Private

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Turns the sound output down while dictating (music, videos) and back to where it was afterwards.
@MainActor
final class SoundDucker {
    private var saved: (device: AudioDeviceID, volumes: [UInt32: Float32])?

    /// `level`: the share of the current volume to keep, 0…1 (0 mutes).
    func duck(to level: Double) {
        guard saved == nil, let device = AudioDevices.defaultOutput else { return }
        let volumes = AudioDevices.volume(of: device)
        guard !volumes.isEmpty else { return }
        saved = (device, volumes)
        AudioDevices.setVolume(volumes.mapValues { $0 * Float32(level) }, of: device)
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        AudioDevices.setVolume(saved.volumes, of: saved.device)
    }
}
