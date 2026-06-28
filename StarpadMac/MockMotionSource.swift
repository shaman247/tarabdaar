import Foundation
import StarpadCore

/// `MotionSource` shim for the Mac iPad-simulator. The Mac has no
/// accelerometer/gyroscope; tilts come from on-screen sliders and the
/// "strike force" knob feeds `peakAccelSince` so the note-on velocity
/// pipeline produces sensible values without a real accel spike.
///
/// All state is ObservableObject-tracked so the simulator UI can mirror
/// the values back into the view (e.g. resetting a slider re-centers
/// the corresponding tilt).
final class MockMotionSource: ObservableObject, MotionSource {
    /// Three tilt axes, each in [-1, +1]. Match `MotionManager.normalizedTilts`.
    @Published var tilt1: Double = 0
    @Published var tilt2: Double = 0
    @Published var tilt3: Double = 0

    /// Simulated peak acceleration magnitude in g's, returned by
    /// `peakAccelSince`. Drives velocity mapping (Config.velocityMinG ..
    /// velocityMaxG, log-scaled). Default 0.1g lands around v=75.
    @Published var strikeForce: Double = 0.1

    var normalizedTilts: [Double]? { [tilt1, tilt2, tilt3] }
    var recentPeakAccel: Double { strikeForce }
    var lastTouchVelocity: Double = 0

    func peakAccelSince(timestamp: TimeInterval) -> PeakResult {
        PeakResult(magnitude: strikeForce, timestamp: timestamp)
    }
}
