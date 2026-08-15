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
}

public extension MotionSource {
    var rawAccel: [Double] { [0, 0, 0] }
}
