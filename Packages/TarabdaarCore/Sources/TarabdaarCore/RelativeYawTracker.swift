import Foundation

/// THE leaky relative-yaw law, for any yaw that is unreferenced gyro
/// integration (the iPad's attitude, the Joy-Con's fusion): wrap-safe
/// increments are integrated and leaked toward zero with a 60 s constant,
/// so gestures pass through and a held twist re-centres over ~a minute. A
/// constant drift rate would pass the leak and plateau at rate × τ, so the
/// rate is learned while quiescent (observed rate within 0.01 rad/s of the
/// estimate, ~10 s constant) and subtracted from every increment.
public struct RelativeYawTracker {
    public static let leakTau = 60.0

    /// The relative yaw, radians.
    public private(set) var yaw = 0.0
    private var bias = 0.0
    private var last: Double?

    public init() {}

    /// One sample; `dt` in seconds since the previous one.
    public mutating func update(rawYaw: Double, dt: Double) {
        if let last {
            var dy = rawYaw - last
            if dy > .pi { dy -= 2 * .pi } else if dy < -.pi { dy += 2 * .pi }
            let rate = dy / dt
            if abs(rate - bias) < 0.01 {
                bias += (rate - bias) * min(1, dt / 10)
            }
            yaw += dy - bias * dt
            yaw -= yaw * (dt / Self.leakTau)
        }
        last = rawYaw
    }

    public mutating func reset() {
        yaw = 0
        bias = 0
        last = nil
    }
}
