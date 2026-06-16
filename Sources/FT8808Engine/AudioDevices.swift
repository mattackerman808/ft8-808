import Foundation
import CoreAudio

/// A CoreAudio input device (e.g. the rig's USB codec).
public struct AudioInputDevice: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let channels: Int
    public let manufacturer: String
    public let transport: String   // "USB", "Built-in", "Bluetooth", …
}

/// Full picture of a device (both directions) for the device picker / list.
public struct AudioDeviceInfo: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let manufacturer: String
    public let transport: String
    public let inputChannels: Int
    public let outputChannels: Int

    /// Heuristic: a USB device that isn't Apple's — very likely a transceiver's
    /// audio codec (Yaesu/Icom/Kenwood use TI/BurrBrown chips). Note many rigs
    /// expose the codec as TWO devices with the same name — an input-only (RX)
    /// half and an output-only (TX) half — so this can match both.
    public var likelyRig: Bool {
        transport == "USB" && !manufacturer.lowercased().contains("apple")
            && (inputChannels > 0 || outputChannels > 0)
    }
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
                channels: ch,
                manufacturer: stringProperty(id, kAudioObjectPropertyManufacturer) ?? "",
                transport: transportName(id))
        }
    }

    /// Every device with audio in either direction, with full detail for listing.
    public static func allDevices() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { id in
            let inCh = channelCount(id, scope: .input)
            let outCh = channelCount(id, scope: .output)
            guard inCh > 0 || outCh > 0 else { return nil }
            return AudioDeviceInfo(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                manufacturer: stringProperty(id, kAudioObjectPropertyManufacturer) ?? "",
                transport: transportName(id),
                inputChannels: inCh,
                outputChannels: outCh)
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

    private static func transportName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return "?" }
        switch t {
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeBuiltIn:     return "Built-in"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAggregate:   return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:     return "Virtual"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
        case kAudioDeviceTransportTypePCI:         return "PCI"
        default:                                   return "?"
        }
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
