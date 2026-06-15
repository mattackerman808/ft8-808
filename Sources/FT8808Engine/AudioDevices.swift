import Foundation
import CoreAudio

/// A CoreAudio input device (e.g. the rig's USB codec).
public struct AudioInputDevice: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let channels: Int
}

/// Enumeration + lookup of CoreAudio devices, so the user can pick the rig's
/// audio interface for capture (input) and transmit (output).
public enum AudioDevices {

    public enum Scope {
        case input, output
        var coreAudio: AudioObjectPropertyScope {
            self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        }
    }

    /// All devices that have at least one channel in the given scope.
    public static func devices(scope: Scope) -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            let ch = channelCount(id, scope: scope)
            guard ch > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                channels: ch)
        }
    }

    /// All devices with at least one input channel.
    public static func inputDevices() -> [AudioInputDevice] { devices(scope: .input) }

    /// All devices with at least one output channel.
    public static func outputDevices() -> [AudioInputDevice] { devices(scope: .output) }

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

    /// Find a device by exact UID, or case-insensitive name substring, in the
    /// given scope (default input).
    public static func find(_ query: String, scope: Scope = .input) -> AudioInputDevice? {
        let list = devices(scope: scope)
        if let exact = list.first(where: { $0.uid == query }) { return exact }
        let q = query.lowercased()
        return list.first { $0.name.lowercased().contains(q) }
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

    private static func channelCount(_ id: AudioDeviceID, scope: Scope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope.coreAudio,
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
