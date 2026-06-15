import Foundation
import CoreAudio

/// A CoreAudio input device (e.g. the rig's USB codec).
public struct AudioInputDevice: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let channels: Int
}

/// Enumeration + lookup of CoreAudio input devices, so the user can pick the
/// rig's audio interface rather than the Mac's built-in microphone.
public enum AudioDevices {

    /// All devices that have at least one input channel.
    public static func inputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            let ch = inputChannelCount(id)
            guard ch > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                channels: ch)
        }
    }

    /// The system default input device, if any.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (st == noErr && dev != 0) ? dev : nil
    }

    /// Find an input device by exact UID, or case-insensitive name substring.
    public static func find(_ query: String) -> AudioInputDevice? {
        let devices = inputDevices()
        if let exact = devices.first(where: { $0.uid == query }) { return exact }
        let q = query.lowercased()
        return devices.first { $0.name.lowercased().contains(q) }
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, data) == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard st == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
