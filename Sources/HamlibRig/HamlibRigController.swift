import CHamlib
import FT8808Engine
import Foundation

/// Errors surfaced by the Hamlib backend.
public enum HamlibError: Error, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case operationFailed(op: String, code: Int32, message: String)
    case notOpen

    public var description: String {
        switch self {
        case let .openFailed(code, message):
            return "rig open failed (\(code)): \(message)"
        case let .operationFailed(op, code, message):
            return "\(op) failed (\(code)): \(message)"
        case .notOpen:
            return "rig is not open"
        }
    }
}

/// Well-known Hamlib model numbers worth naming.
public enum HamlibModel {
    /// Software-simulated rig — no hardware. Ideal for development and tests.
    public static let dummy = Int(FT8808_RIG_MODEL_DUMMY)
    /// Talk to a remote `rigctld` over TCP.
    public static let netRigctl = Int(FT8808_RIG_MODEL_NETRIGCTL)
}

/// Owns the Hamlib `RIG*` so it is closed deterministically when released,
/// keeping the C cleanup out of the actor's (nonisolated) deinit.
private final class RigHandle: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ ptr: OpaquePointer) { self.ptr = ptr }
    deinit { ft8808_rig_close(ptr) }
}

/// `RigController` backed by bundled Hamlib. Serialised through an actor because
/// Hamlib's per-rig state is not thread-safe.
public actor HamlibRigController: RigController {
    private let model: Int
    private let device: String?
    private let serialSpeed: Int
    private var handle: RigHandle?

    /// - Parameters:
    ///   - model: Hamlib rig model number (see `HamlibModel`).
    ///   - device: Serial path (e.g. `/dev/cu.usbserial-1410`), `host:port` for
    ///     `netRigctl`, or `nil` for the dummy rig.
    ///   - serialSpeed: Baud rate, or `0` for the backend default.
    public init(model: Int = HamlibModel.dummy, device: String? = nil, serialSpeed: Int = 0) {
        self.model = model
        self.device = device
        self.serialSpeed = serialSpeed
    }

    /// Open the rig. Must be called before any other operation.
    public func open() throws {
        var err: Int32 = 0
        let h = device.withCStringOrNil { cDevice in
            ft8808_rig_open(Int32(model), cDevice, Int32(serialSpeed), &err)
        }
        guard let h else {
            throw HamlibError.openFailed(code: err, message: Self.message(err))
        }
        handle = RigHandle(h)
    }

    /// Closes the rig. Releasing the controller also closes it automatically.
    public func close() {
        handle = nil // RigHandle.deinit performs the C close
    }

    // MARK: RigController

    public func state() async -> RigState {
        guard let handle else {
            return RigState(frequencyHz: 0, mode: .usb, transmitting: false, connected: false)
        }
        var s = ft8808_rig_state()
        let rc = ft8808_rig_get_state(handle.ptr, &s)
        guard rc == 0 else {
            return RigState(frequencyHz: 0, mode: .usb, transmitting: false, connected: false)
        }
        return RigState(
            frequencyHz: Int(s.freq_hz.rounded()),
            mode: RigMode(s.mode),
            transmitting: s.ptt != 0,
            connected: true)
    }

    public func setFrequency(_ hz: Int) async throws {
        guard let handle else { throw HamlibError.notOpen }
        try check("set frequency", ft8808_rig_set_freq(handle.ptr, Double(hz)))
    }

    public func setMode(_ mode: RigMode) async throws {
        guard let handle else { throw HamlibError.notOpen }
        try check("set mode", ft8808_rig_set_mode(handle.ptr, mode.ft8808Mode))
    }

    public func setPTT(_ on: Bool) async throws {
        guard let handle else { throw HamlibError.notOpen }
        try check("set PTT", ft8808_rig_set_ptt(handle.ptr, on ? 1 : 0))
    }

    // MARK: Helpers

    private func check(_ op: String, _ rc: Int32) throws {
        if rc != 0 {
            throw HamlibError.operationFailed(op: op, code: rc, message: Self.message(rc))
        }
    }

    private static func message(_ code: Int32) -> String {
        String(cString: ft8808_rig_strerror(code))
    }
}

// MARK: - Mode bridging

private extension RigMode {
    var ft8808Mode: ft8808_mode {
        switch self {
        case .usb:  return FT8808_MODE_USB
        case .lsb:  return FT8808_MODE_LSB
        case .cw:   return FT8808_MODE_CW
        case .data: return FT8808_MODE_DATA
        }
    }

    init(_ m: ft8808_mode) {
        switch m {
        case FT8808_MODE_LSB:  self = .lsb
        case FT8808_MODE_CW:   self = .cw
        case FT8808_MODE_DATA: self = .data
        default:               self = .usb
        }
    }
}

private extension Optional where Wrapped == String {
    func withCStringOrNil<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case let .some(s): return s.withCString { body($0) }
        case .none:        return body(nil)
        }
    }
}
