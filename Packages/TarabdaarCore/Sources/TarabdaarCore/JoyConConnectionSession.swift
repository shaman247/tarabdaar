import Foundation

/// Main-queue BLE attempt deadlines and generation guards, independent of CoreBluetooth.
public struct JoyConConnectionSession {
    public enum Phase: String {
        case idle, connecting, settingUp, streaming
    }

    public static let timeout: TimeInterval = 8
    public private(set) var generation: UInt64 = 0
    public private(set) var phase: Phase = .idle
    public private(set) var deadline: TimeInterval?

    public init() {}

    public mutating func begin(at now: TimeInterval) {
        generation &+= 1
        phase = .connecting
        deadline = now + Self.timeout
    }

    public func accepts(_ token: UInt64) -> Bool {
        token == generation && phase != .idle
    }

    /// Link completion starts a separate, bounded service/initialization window.
    public mutating func didConnect(at now: TimeInterval) {
        guard phase == .connecting else { return }
        phase = .settingUp
        deadline = now + Self.timeout
    }

    /// Only input ends the setup watchdog; command acknowledgements do not.
    public mutating func didReceiveInput() {
        guard phase == .settingUp else { return }
        phase = .streaming
        deadline = nil
    }

    /// Returns the stalled phase once, invalidating every delayed job from that attempt.
    public mutating func expire(at now: TimeInterval, token: UInt64) -> Phase? {
        guard accepts(token), let deadline, now >= deadline else { return nil }
        let stalled = phase
        end()
        return stalled
    }

    public mutating func end() {
        generation &+= 1
        phase = .idle
        deadline = nil
    }
}
