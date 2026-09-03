import Foundation

/// Result of `peakAccelSince(timestamp:)`. The peak's magnitude is in g's
/// (matches `CMDeviceMotion.userAcceleration` magnitude); the timestamp
/// is in `CMMotionManager`'s clock domain.
public struct PeakResult {
    public let magnitude: Double
    public let timestamp: TimeInterval

    public init(magnitude: Double, timestamp: TimeInterval) {
        self.magnitude = magnitude
        self.timestamp = timestamp
    }
}

/// Abstraction over the source of motion data feeding `NoteManager`.
///
/// On iOS, `MotionManager` (wrapping `CMMotionManager`) conforms.
/// `NoteManager` reads through this protocol so the package itself
/// doesn't link against CoreMotion.
public protocol MotionSource: AnyObject {
    /// Latest raw tilt values, each `[-1, +1]` at the source's fixed
    /// scaling (on iPad: attitude / 90°). There is no device-side
    /// calibration — the Mac's arm calibration is the app's single
    /// tilt calibration, learning its own map from these raw axes.
    var normalizedTilts: [Double] { get }

    /// Most recent peak acceleration magnitude (with fast attack / slow
    /// decay tracking). Used for the on-screen accelerometer indicator.
    var recentPeakAccel: Double { get }

    /// Latest raw user acceleration [x, y, z] in g (gravity removed) —
    /// streamed to the Mac for the received-acceleration diagnostic.
    /// Default: zeros (the Mac's mock source has no accelerometer).
    var rawAccel: [Double] { get }

    /// Most recent touch velocity estimate (0..1), written by
    /// `NoteManager` after each note-on for display.
    var lastTouchVelocity: Double { get set }

    /// Peak accelerometer magnitude in the buffered window since the
    /// given motion-clock timestamp. Called ~20ms after a touch begins
    /// to map the accelerometer spike to a MIDI velocity.
    func peakAccelSince(timestamp: TimeInterval) -> PeakResult

    /// STRIKE-SCALE ENVELOPE 0…1 (2026-08-23) — the continuous form of
    /// the strike measure: `strikeScale01` of the accel magnitude through
    /// a fast-attack / slow-decay tracker, maintained at the source's own
    /// sample rate so taps between report ticks are never missed. The 60
    /// Hz tick streams it as the PERF_STATE `strike` byte → the Mac's
    /// `.strike` control dimension. A real protocol requirement (not just
    /// an extension member) so existential access reaches the concrete
    /// tracker; sources without an accelerometer inherit the 0 default.
    var strikeLevel: Double { get }
}

public extension MotionSource {
    var rawAccel: [Double] { [0, 0, 0] }
    var strikeLevel: Double { 0 }   // sources without an accelerometer

    /// ONSET STRIKE VELOCITY 0…1 at a touch onset (2026-08-19 — the
    /// revived accelerometer estimate, now consumed by the String voice's
    /// `bow_attack_vel` velocity→sharpness law): the peak acceleration
    /// magnitude over the TRAILING `Config.velocityLookback` window,
    /// mapped log-scale across [`velocityMinG`, `velocityMaxG`] — the
    /// same law the deleted 2026-07-24 capture used, but backward-looking:
    /// UIKit delivers a touch ~10–25 ms after the physical impact, so the
    /// chassis spike is usually already in the 200 Hz ring buffer and the
    /// onset never waits (the old design delayed note-on 20 ms instead).
    /// `now` must be in the motion clock's domain (seconds since boot —
    /// `CACurrentMediaTime()` matches). Below `velocityMinG` (a gentle
    /// placement, or no motion data at all) this reads 0 = legato.
    func strikeVelocity01(at now: TimeInterval) -> Double {
        Self.strikeScale01(
            peakAccelSince(timestamp: now - Config.velocityLookback)
                .magnitude)
    }

    /// The strike LAW as a pure map: acceleration magnitude (g) → 0…1,
    /// log-scale across [`velocityMinG`, `velocityMaxG`], 0 at or below
    /// the floor. Shared by the onset estimate above and the iPad's
    /// persistent strike scope (2026-08-23), so the scope's 0–127 trace
    /// always reads exactly what a tap at that magnitude would send.
    static func strikeScale01(_ g: Double) -> Double {
        StrikeLaw.scale01(g)
    }
}

/// The strike law as a type-free entry point (2026-09-02): the Mac's
/// Joy-Con acceleration dimension runs the same log-scale map + the
/// same fast-attack/150 ms-decay envelope over the Joy-Con's
/// gravity-removed acceleration, and it has no `MotionSource` to hang
/// the static on.
public enum StrikeLaw {
    /// Acceleration magnitude (g) → 0…1, log-scale across
    /// [`velocityMinG`, `velocityMaxG`], 0 at or below the floor.
    public static func scale01(_ g: Double) -> Double {
        guard g > Config.velocityMinG else { return 0.0 }
        let clamped = min(g, Config.velocityMaxG)
        return log(clamped / Config.velocityMinG)
            / log(Config.velocityMaxG / Config.velocityMinG)
    }
    /// The envelope's decay time constant (s) — the iPad tracker's.
    public static let envelopeTau = 0.15
}
