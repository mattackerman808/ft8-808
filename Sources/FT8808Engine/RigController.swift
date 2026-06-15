import Foundation

public enum RigMode: String, Sendable {
    case usb = "USB"
    case lsb = "LSB"
    case cw = "CW"
    case data = "DATA"
}

/// State of the connected transceiver, as the UI needs it.
public struct RigState: Sendable, Equatable {
    public var frequencyHz: Int      // dial / VFO frequency
    public var mode: RigMode
    public var transmitting: Bool
    public var connected: Bool

    public init(frequencyHz: Int, mode: RigMode, transmitting: Bool, connected: Bool) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.transmitting = transmitting
        self.connected = connected
    }
}

/// Abstraction over rig control (CAT + PTT). The real implementation will wrap
/// Hamlib; this protocol keeps the engine and TUI independent of it so the app
/// runs against a mock today and a radio later.
public protocol RigController: Sendable {
    func state() async -> RigState
    func setFrequency(_ hz: Int) async throws
    func setMode(_ mode: RigMode) async throws
    func setPTT(_ on: Bool) async throws
}

/// A stand-in rig for development: fixed on the 20 m FT8 watering hole.
public actor MockRigController: RigController {
    private var current: RigState

    public init(frequencyHz: Int = 14_074_000, mode: RigMode = .usb) {
        current = RigState(frequencyHz: frequencyHz, mode: mode,
                           transmitting: false, connected: true)
    }

    public func state() async -> RigState { current }
    public func setFrequency(_ hz: Int) async throws { current.frequencyHz = hz }
    public func setMode(_ mode: RigMode) async throws { current.mode = mode }
    public func setPTT(_ on: Bool) async throws { current.transmitting = on }
}
