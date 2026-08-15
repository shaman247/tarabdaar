import Foundation

/// Monotonic µs timestamps for TLP frames plus the ping/pong RTT and
/// clock-offset estimate that lets the Mac display real link latency for
/// the first time.
///
/// Timestamps are u32 µs of the sender's own monotonic clock and wrap
/// every ~71.6 min; all arithmetic is wrap-safe u32 subtraction, so the
/// wrap is a non-event.
public enum LinkClock {
    /// Monotonic microseconds, truncated to u32.
    public static func nowUs() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000)
    }

    /// Wrap-safe elapsed µs from `earlier` to `later` (0 if later wrapped
    /// more than ~35.8 min — callers only measure short spans).
    public static func elapsedUs(from earlier: UInt32, to later: UInt32) -> UInt32 {
        later &- earlier
    }
}

/// Ping/pong link estimator. Keeps an EWMA over MINIMUM-RTT samples —
/// the minimum filters connection-interval phase jitter, the EWMA tracks
/// slow drift. Also estimates the remote-clock offset so per-frame age
/// (`now − (frame.timestampUs + offset)`) is meaningful.
///
/// Not thread-safe — confine to the link queue.
public struct LinkClockSync {
    /// Smoothed round-trip in µs (nil until the first pong).
    public private(set) var rttUs: Double?
    /// remoteClock − localClock in µs, wrap-aware (nil until first pong).
    public private(set) var offsetUs: Int64?

    private var windowMinUs: UInt32 = .max
    private var windowCount = 0
    private let windowSize: Int
    private let alpha: Double

    public init(windowSize: Int = 8, alpha: Double = 0.25) {
        self.windowSize = windowSize
        self.alpha = alpha
    }

    public var rttMs: Double? { rttUs.map { $0 / 1000.0 } }

    /// Feed one pong: t1 = our clock at ping send (echoed), t2 = remote
    /// clock when it replied, t3 = our clock now.
    public mutating func addPong(t1: UInt32, t2: UInt32, t3: UInt32) {
        let rtt = LinkClock.elapsedUs(from: t1, to: t3)
        // Offset from the midpoint assumption, computed wrap-safely in u32
        // then interpreted as a signed µs delta.
        let mid = t1 &+ (rtt / 2)
        offsetUs = Int64(Int32(bitPattern: t2 &- mid))

        windowMinUs = min(windowMinUs, rtt)
        windowCount += 1
        if windowCount >= windowSize {
            let sample = Double(windowMinUs)
            rttUs = rttUs.map { $0 + alpha * (sample - $0) } ?? sample
            windowMinUs = .max
            windowCount = 0
        } else if rttUs == nil {
            // Show something sensible before the first window closes.
            rttUs = Double(rtt)
        }
    }

    /// Age of a remote-stamped frame in µs, given the current offset.
    public func frameAgeUs(timestampUs: UInt32, nowUs: UInt32) -> UInt32? {
        guard let off = offsetUs else { return nil }
        let localizedSend = UInt32(truncatingIfNeeded:
            Int64(timestampUs) &- off)
        return LinkClock.elapsedUs(from: localizedSend, to: nowUs)
    }
}
