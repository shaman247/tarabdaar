import CoreMotion
import TarabdaarCore
import SwiftUI

class MotionManager: ObservableObject, MotionSource {
    private let motionManager = CMMotionManager()

    // The latest raw sample, written at 200 Hz. Not @Published: the
    // 60 Hz tilt sampler polls, and publishing at sample
    // rate would invalidate the root view 200 times a second.
    private(set) var pitch: Double = 0.0  // tilt forward/back (radians)
    private(set) var roll: Double = 0.0   // tilt left/right (radians)
    private(set) var yaw: Double = 0.0    // rotation around vertical axis (radians)

    // User acceleration (gravity removed), in g's
    private(set) var userAccelX: Double = 0.0
    private(set) var userAccelY: Double = 0.0
    private(set) var userAccelZ: Double = 0.0

    /// Strike-scale envelope (MotionSource): `strikeScale01(magnitude)`
    /// through a fast-attack / slow-decay tracker (τ 150 ms), evolved at
    /// 200 Hz so a tap between 60 Hz ticks registers. Not @Published.
    private(set) var strikeLevel: Double = 0.0
    private let strikeLevelDecay =
        exp(-1.0 / (Config.motionUpdateRate * 0.15))

    /// Latest raw user acceleration for the wire (MotionSource).
    var rawAccel: [Double] { [userAccelX, userAccelY, userAccelZ] }

    /// Raw attitude scaled to [-1, +1] at a fixed ±90° full scale (tilt 1 =
    /// pitch, 2 = roll, 3 = high-passed yaw). The iPad performs no
    /// calibration: the Mac's arm calibration maps these raw axes, and
    /// without one they pass through uncentered.
    var normalizedTilts: [Double] {
        let s = 2.0 / Double.pi
        return [max(-1, min(1, pitch * s)),
                max(-1, min(1, roll * s)),
                max(-1, min(1, relYaw.yaw * s))]
    }

    /// High-passed yaw (`RelativeYawTracker`): attitude yaw is unreferenced
    /// gyro integration and drifts.
    private var relYaw = RelativeYawTracker()
    private var lastYawTime: TimeInterval?

    private func updateYaw(_ rawYaw: Double, timestamp: TimeInterval) {
        let dt = lastYawTime.map { min(max(timestamp - $0, 0.0001), 0.1) } ?? 0.005
        relYaw.update(rawYaw: rawYaw, dt: dt)
        lastYawTime = timestamp
    }

    init() {
        startUpdates()
    }

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }

        // 200Hz for high-fidelity accelerometer capture
        motionManager.deviceMotionUpdateInterval = 1.0 / Config.motionUpdateRate

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self, let motion else { return }

            self.pitch = motion.attitude.pitch
            self.roll = motion.attitude.roll
            self.yaw = motion.attitude.yaw
            self.updateYaw(motion.attitude.yaw, timestamp: motion.timestamp)
            let accel = motion.userAcceleration
            self.userAccelX = accel.x
            self.userAccelY = accel.y
            self.userAccelZ = accel.z
            let mag = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

            // Strike-scale envelope for the `.strike`/`.acceleration`
            // dimensions.
            self.strikeLevel = max(Self.strikeScale01(mag),
                                   self.strikeLevel * self.strikeLevelDecay)

        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }

    deinit {
        stopUpdates()
    }
}
