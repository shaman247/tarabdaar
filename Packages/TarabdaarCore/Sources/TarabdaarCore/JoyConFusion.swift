import Foundation
import simd

/// One fused IMU step's outputs.
public struct JoyConFusionStep {
    /// Attitude in radians, yaw CONTINUOUS (no jump at ±180°):
    /// pitch = atan2(−gx, √(gy²+gz²)), roll = atan2(gy, gz), yaw.
    public var attitude: SIMD3<Double>
    /// Acceleration with the gravity estimate subtracted, in g — rests
    /// at the origin.
    public var linearAccel: SIMD3<Double>
    /// THE WRIST FEATURE: gravity pitch/roll plus the RELATIVE yaw, all
    /// at ±90° full scale, clamped −1…+1 — the wrist calibrator's input.
    public var wristFeature: SIMD3<Double>
    /// The acceleration axis: 0…1, quantized at 1/256.
    public var accelEnvelope: Double
    /// True when `accelEnvelope` moved past its change gate.
    public var accelChanged: Bool
    /// True while yaw is being corrected toward magnetic heading.
    public var yawPinned: Bool
    public var dt: Double
}

/// ORIENTATION FUSION, complementary filter: the body-frame gravity
/// estimate `gHat` integrates the gyro (ġ = g × ω) and is pulled slowly
/// toward the accelerometer; yaw integrates the gyro about gravity.
///
/// 9-AXIS (Joy-Con 2 only). The mag pins yaw: hard-iron offset = the
/// running min/max midpoint, IGNORED until the seen extremes span most
/// of the field sphere; the corrected horizontal field drives a north
/// estimate `nHat` (ṅ = n × ω) that pulls yaw gently toward heading.
///
/// Pure state machine — no device, no publishing. The host feeds it
/// whatever its bearer produced and draws the panels from the result.
public final class JoyConFusion {

    private var gHat: SIMD3<Double>?
    private var gyroBias = SIMD3<Double>.zero
    private var yaw = 0.0
    private var lastIMUTime: CFAbsoluteTime = 0
    private var nHat: SIMD3<Double>?
    private var magMin: SIMD3<Double>?
    private var magMax: SIMD3<Double>?
    /// The wrist feature's RELATIVE yaw (`RelativeYawTracker`), so gyro
    /// drift can't rail the axis.
    private var relYaw = RelativeYawTracker()
    /// The Joy-Con acceleration envelope (0…1) + its change gate.
    private var accelEnv = 0.0
    private var lastAccelSent = 0.0

    public init() {}

    /// One fused IMU step (accel g; gyro rad/s; mag raw, Joy-Con 2 only).
    /// Returns nil on the free-fall / degenerate guard — no usable
    /// gravity direction, so nothing downstream may move.
    public func ingest(accelG: SIMD3<Double>,
                       gyroRadPerSec: SIMD3<Double>,
                       mag: SIMD3<Double>? = nil,
                       at now: CFAbsoluteTime) -> JoyConFusionStep? {
        let dt = min(max(now - lastIMUTime, 0.001), 0.1)
        lastIMUTime = now
        guard simd_length(accelG) > 0.25 else { return nil }
        // Gyro-bias learner: converge on the reading while still.
        if simd_length(gyroRadPerSec - gyroBias) < 0.05 {
            gyroBias += (gyroRadPerSec - gyroBias) * 0.02
        }
        let w = gyroRadPerSec - gyroBias
        let aN = simd_normalize(accelG)
        var g = gHat ?? aN
        g = simd_normalize(g + simd_cross(g, w) * dt)   // ġ = g × ω
        g = simd_normalize(g + (aN - g) * 0.02)         // accel pull
        gHat = g
        yaw += simd_dot(w, g) * dt
        var pinned = false
        if let mag, mag != .zero {
            magMin = magMin.map { simd_min($0, mag) } ?? mag
            magMax = magMax.map { simd_max($0, mag) } ?? mag
            let lo = magMin!, hi = magMax!
            let m = mag - (lo + hi) * 0.5
            let fieldMag = simd_length(m)
            // Trust the hard-iron midpoint only after broad rotation coverage.
            if fieldMag > 1e-6, simd_length(hi - lo) > fieldMag * 0.7 {
                let h = m - g * simd_dot(m, g)      // horizontal field
                if simd_length(h) > fieldMag * 0.2 {  // usable unless the
                    let hN = simd_normalize(h)        // field is near-vertical
                    var n = nHat ?? hN
                    n += simd_cross(n, w) * dt        // ṅ = n × ω
                    n += (hN - n) * 0.02              // mag pull
                    n -= g * simd_dot(n, g)           // keep n ⊥ gravity
                    if simd_length(n) > 1e-6 {
                        n = simd_normalize(n)
                        nHat = n
                        // Mag yaw: device x-axis heading from north, wrap-aware.
                        var xh = SIMD3(1.0, 0, 0)
                        xh -= g * simd_dot(xh, g)
                        if simd_length(xh) > 0.2 {    // near-vertical x:
                            xh = simd_normalize(xh)   // keep integrating
                            let yawMag = atan2(
                                simd_dot(simd_cross(n, xh), g),
                                simd_dot(n, xh))
                            var e = (yawMag - yaw)
                                .truncatingRemainder(dividingBy: 2 * .pi)
                            if e > .pi { e -= 2 * .pi }
                            if e < -.pi { e += 2 * .pi }
                            yaw += e * 0.02
                            pinned = true
                        }
                    }
                }
            }
        }
        let att = SIMD3(atan2(-g.x, (g.y * g.y + g.z * g.z).squareRoot()),
                        atan2(g.y, g.z),
                        yaw)
        let lin = accelG - g
        relYaw.update(rawYaw: att.z, dt: dt)
        let wristF = SIMD3(att.x, att.y, relYaw.yaw) / (.pi / 2)
        // THE JOY-CON ACCELERATION AXIS: |accel − ĝ| through the strike
        // law and its fast-attack / 150 ms-decay envelope, 0…1, change-
        // gated at 1/256.
        accelEnv = max(StrikeLaw.scale01(simd_length(lin)),
                       accelEnv * exp(-dt / StrikeLaw.envelopeTau))
        let qa = (accelEnv * 256).rounded() / 256
        let changed = qa != lastAccelSent
        if changed { lastAccelSent = qa }
        return JoyConFusionStep(
            attitude: att,
            linearAccel: lin,
            wristFeature: simd_clamp(wristF, SIMD3(repeating: -1),
                                     SIMD3(repeating: 1)),
            accelEnvelope: qa,
            accelChanged: changed,
            yawPinned: pinned,
            dt: dt)
    }

    /// A reconnected Joy-Con re-earns its hard-iron estimate and its
    /// relative yaw. Returns true when the acceleration axis had a
    /// non-zero value out, so the host must send one last 0.
    @discardableResult
    public func reset() -> Bool {
        nHat = nil
        magMin = nil
        magMax = nil
        relYaw.reset()
        accelEnv = 0
        let wasSending = lastAccelSent != 0
        lastAccelSent = 0
        return wasSending
    }

    /// Drop the gravity estimate itself (a bearer disconnecting mid-run
    /// — the next packet re-seeds it from the accelerometer).
    public func resetGravity() { gHat = nil }
}
