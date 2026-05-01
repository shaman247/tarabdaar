import CoreMotion
import SwiftUI

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()

    @Published var pitch: Double = 0.0  // tilt forward/back (radians)
    @Published var roll: Double = 0.0   // tilt left/right (radians)
    @Published var yaw: Double = 0.0    // rotation around vertical axis (radians)

    // User acceleration (gravity removed), in g's
    @Published var userAccelX: Double = 0.0
    @Published var userAccelY: Double = 0.0
    @Published var userAccelZ: Double = 0.0

    // Peak acceleration magnitude detected recently
    @Published var accelMagnitude: Double = 0.0
    @Published var recentPeakAccel: Double = 0.0

    // Most recent touch velocity estimate (for display)
    @Published var lastTouchVelocity: Double = 0.0

    // Rolling history for display (last ~1 second at 200Hz = 200 samples)
    @Published var accelHistory: [Double] = []
    private let historyLength = Config.accelHistoryLength

    // Timestamped accelerometer buffer for touch correlation
    private struct AccelSample {
        let timestamp: TimeInterval
        let magnitude: Double
    }
    private var accelBuffer: [AccelSample] = []
    private let bufferDuration: TimeInterval = Config.accelBufferDuration

    // Peak detection for display
    private var peakDecay: Double = 0.0

    @Published var calibration: CalibrationData? = CalibrationData.load()

    var pitchDegrees: Double { pitch * 180.0 / .pi }
    var rollDegrees: Double { roll * 180.0 / .pi }
    var yawDegrees: Double { yaw * 180.0 / .pi }

    /// Normalized tilt values for all 3 calibrated axes.
    /// Each value ranges from -1 (negative endpoint) to +1 (positive endpoint), 0 = rest.
    /// Returns nil if not calibrated.
    var normalizedTilts: [Double]? {
        guard let calibration else { return nil }
        return calibration.normalize(pitch: pitch, roll: roll, yaw: yaw)
    }

    var isCalibrated: Bool { calibration != nil }

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

            let accel = motion.userAcceleration
            self.userAccelX = accel.x
            self.userAccelY = accel.y
            self.userAccelZ = accel.z

            let mag = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
            self.accelMagnitude = mag

            // Track peak with fast attack, slow decay
            if mag > self.peakDecay {
                self.peakDecay = mag
            } else {
                self.peakDecay *= Config.peakDecayRate
            }
            self.recentPeakAccel = self.peakDecay

            // Append to timestamped buffer for touch correlation
            let sample = AccelSample(timestamp: motion.timestamp, magnitude: mag)
            self.accelBuffer.append(sample)
            // Trim old samples
            let cutoff = motion.timestamp - self.bufferDuration
            self.accelBuffer.removeAll { $0.timestamp < cutoff }

            // Append to display history
            self.accelHistory.append(mag)
            if self.accelHistory.count > self.historyLength {
                self.accelHistory.removeFirst(self.accelHistory.count - self.historyLength)
            }
        }
    }

    struct PeakResult {
        let magnitude: Double
        let timestamp: TimeInterval
    }

    /// Returns the peak accelerometer magnitude since a given timestamp,
    /// along with the timestamp when the peak occurred.
    func peakAccelSince(timestamp: TimeInterval) -> PeakResult {
        let samplesInWindow = accelBuffer.filter {
            $0.timestamp >= timestamp
        }
        guard let peak = samplesInWindow.max(by: { $0.magnitude < $1.magnitude }) else {
            return PeakResult(magnitude: 0.0, timestamp: timestamp)
        }
        return PeakResult(magnitude: peak.magnitude, timestamp: peak.timestamp)
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }

    deinit {
        stopUpdates()
    }
}
