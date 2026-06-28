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
    /// Latest calibrated tilt values, each `[-1, +1]`. `nil` if not yet
    /// calibrated (iPad never sent a calibration, or no frames received).
    var normalizedTilts: [Double]? { get }

    /// Most recent peak acceleration magnitude (with fast attack / slow
    /// decay tracking). Used for the on-screen accelerometer indicator.
    var recentPeakAccel: Double { get }

    /// Most recent touch velocity estimate (0..1), written by
    /// `NoteManager` after each note-on for display.
    var lastTouchVelocity: Double { get set }

    /// Peak accelerometer magnitude in the buffered window since the
    /// given motion-clock timestamp. Called ~20ms after a touch begins
    /// to map the accelerometer spike to a MIDI velocity.
    func peakAccelSince(timestamp: TimeInterval) -> PeakResult
}
