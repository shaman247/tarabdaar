import Foundation

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

    /// Latest raw user acceleration [x, y, z] in g (gravity removed) —
    /// streamed to the Mac for the received-acceleration diagnostic.
    /// Default: zeros (the Mac's mock source has no accelerometer).
    var rawAccel: [Double] { get }

    /// STRIKE-SCALE ENVELOPE 0…1 — the continuous form of
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

    /// The strike LAW as a pure map: acceleration magnitude (g) → 0…1,
    /// log-scale across [`strikeMinG`, `strikeMaxG`], 0 at or below
    /// the floor. The iPad envelope, its scope and Joy-Con acceleration
    /// share this law.
    static func strikeScale01(_ g: Double) -> Double {
        StrikeLaw.scale01(g)
    }
}

/// The strike law as a type-free entry point : the Mac's
/// Joy-Con acceleration dimension runs the same log-scale map + the
/// same fast-attack/150 ms-decay envelope over the Joy-Con's
/// gravity-removed acceleration, and it has no `MotionSource` to hang
/// the static on.
public enum StrikeLaw {
    /// Acceleration magnitude (g) → 0…1, log-scale across
    /// [`strikeMinG`, `strikeMaxG`], 0 at or below the floor.
    public static func scale01(_ g: Double) -> Double {
        guard g > Config.strikeMinG else { return 0.0 }
        let clamped = min(g, Config.strikeMaxG)
        return log(clamped / Config.strikeMinG)
            / log(Config.strikeMaxG / Config.strikeMinG)
    }
    /// The envelope's decay time constant (s) — the iPad tracker's.
    public static let envelopeTau = 0.15
}
