import Foundation

/// Which of the two interleaved 15 s sequences a station transmits in.
/// `even` = slots starting at :00 / :30 (WSJT-X "1st"); `odd` = :15 / :45.
public enum SlotParity: Int, Sendable, CaseIterable {
    case even = 0
    case odd = 1

    public var label: String { self == .even ? "even (:00/:30)" : "odd (:15/:45)" }
    public var toggled: SlotParity { self == .even ? .odd : .even }
}

/// Pure UTC slot-boundary math for scheduling transmissions, mirroring the
/// receive-side `SlotAccumulator`: FT8 slots start on 15 s UTC boundaries
/// (…:00, :15, :30, :45) and a slot's index parity selects even/odd.
public enum SlotClock {
    public static let slotSeconds: Double = 15

    /// Index of the UTC slot containing `time` (epoch / 15, floored).
    public static func slotIndex(at time: Date) -> Int {
        Int((time.timeIntervalSince1970 / slotSeconds).rounded(.down))
    }

    public static func parity(at time: Date) -> SlotParity {
        slotIndex(at: time).isMultiple(of: 2) ? .even : .odd
    }

    /// Start `Date` of the next slot of `parity` strictly after `time`.
    public static func nextSlotStart(parity: SlotParity, after time: Date) -> Date {
        var idx = slotIndex(at: time) + 1
        while idx % 2 != parity.rawValue { idx += 1 }
        return Date(timeIntervalSince1970: Double(idx) * slotSeconds)
    }

    /// Seconds from `time` until the next slot of `parity` begins (> 0).
    public static func secondsUntilNextSlot(parity: SlotParity, after time: Date) -> Double {
        nextSlotStart(parity: parity, after: time).timeIntervalSince(time)
    }
}
