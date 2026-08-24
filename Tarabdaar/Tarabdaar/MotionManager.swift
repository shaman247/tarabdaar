import CoreMotion
import TarabdaarCore
import SwiftUI

class MotionManager: ObservableObject, MotionSource {
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

    /// STRIKE-SCALE ENVELOPE (2026-08-23, MotionSource requirement): the
    /// continuous 0…1 strike measure the `.strike` control dimension
    /// rides — `strikeScale01(magnitude)` through a fast-attack /
    /// slow-decay tracker, evolved HERE at the full 200 Hz so a tap
    /// between 60 Hz report ticks still registers at height. Decay in the
    /// log-mapped domain (≈ linear-in-dB fall, τ 150 ms): fast enough to
    /// articulate repeated taps, slow enough that a sustained shake reads
    /// as a plateau. Not @Published — read by the 60 Hz tick.
    private(set) var strikeLevel: Double = 0.0
    private let strikeLevelDecay =
        exp(-1.0 / (Config.motionUpdateRate * 0.15))

    /// Strike-ENVELOPE history (~8 s at 200 Hz) for the scope's overlay —
    /// the smoothed control signal the `.strike`/`.acceleration`
    /// dimensions actually see, drawn over the raw trace. Same
    /// ring/polling contract as `accelHistory3D`: not @Published.
    private(set) var strikeHistory: [(t: TimeInterval, level: Double)] = []

    /// Raw attitude history (last ~8 s at 200 Hz) for the on-device
    /// raw-motion overlay — the sensor's own values BEFORE the yaw
    /// high-pass, the 14-bit quantization and the MIDI wire, so
    /// sensor noise and transmission artifacts can be told apart.
    /// Deliberately NOT @Published: appended at 200 Hz, readers sample
    /// it on their own clock (the overlay polls at 30 Hz).
    private(set) var attitudeHistory: [(t: TimeInterval, p: Double, r: Double, y: Double)] = []

    /// Raw per-axis userAcceleration history (last ~8 s at 200 Hz) for
    /// the accel half of the raw-motion overlay — same contract as
    /// `attitudeHistory`: not @Published, readers poll on their own
    /// clock. (`accelHistory` above is the older magnitude-only strike
    /// display; this one keeps the vector.)
    private(set) var accelHistory3D: [(t: TimeInterval, x: Double, y: Double, z: Double)] = []

    /// Latest raw user acceleration for the wire (MotionSource).
    var rawAccel: [Double] { [userAccelX, userAccelY, userAccelZ] }

    /// Raw attitude scaled to [-1, +1] at a FIXED full scale of ±90°
    /// (tilt 1 = pitch, 2 = roll, 3 = high-passed yaw). The iPad
    /// performs no calibration of its own (the 7-point capture was
    /// removed 2026-08-13): the Mac's guided ARM calibration — the
    /// app's single tilt calibration — learns its own map from these
    /// raw axes, and without one they pass through to the Mac's
    /// control axes as-is (uncentered).
    var normalizedTilts: [Double] {
        let s = 2.0 / Double.pi
        return [max(-1, min(1, pitch * s)),
                max(-1, min(1, roll * s)),
                max(-1, min(1, yawRelative * s))]
    }

    /// HIGH-PASSED yaw (2026-08-14). Pitch and roll are anchored by
    /// gravity; yaw is pure gyro integration with NO reference (no
    /// magnetometer frame), so it drifts unboundedly — a resting iPad
    /// wandered tens of degrees on tilt 3 over minutes. This
    /// integrates wrap-safe yaw increments and leaks toward zero with
    /// a 60 s time constant: drift cancels continuously, playing
    /// gestures (seconds) pass through untouched, and a twist held
    /// motionless re-centres over ~a minute (the Mac's ZL re-zero
    /// stays instant). Also immune to the ±π wrap, which used to rail
    /// the raw value when the resting heading sat near it.
    private var yawRelative: Double = 0
    private var lastRawYaw: Double?
    private var lastYawTime: TimeInterval?
    private let yawLeakTau: Double = 60
    /// Learned yaw drift RATE (rad/s). The leak alone cannot cancel a
    /// constant drift rate — it passes through and plateaus at
    /// rate × τ (measured ~0.08°/s → ~5°, a visible slow crawl on
    /// tilt 3). So the rate itself is estimated while the device is
    /// quiescent (observed rate under ~0.57°/s — real gestures are far
    /// above, drift far below) with a slow ~10 s constant, and
    /// subtracted from every increment. Same idea as `JoyConInput`'s
    /// gyro-bias learner.
    private var yawBias: Double = 0

    private func updateYaw(_ rawYaw: Double, timestamp: TimeInterval) {
        if let last = lastRawYaw, let lastT = lastYawTime {
            var dy = rawYaw - last
            if dy > .pi { dy -= 2 * .pi } else if dy < -.pi { dy += 2 * .pi }
            let dt = min(max(timestamp - lastT, 0.0001), 0.1)
            let rate = dy / dt
            if abs(rate - yawBias) < 0.01 {
                yawBias += (rate - yawBias) * min(1, dt / 10)
            }
            yawRelative += dy - yawBias * dt
            yawRelative -= yawRelative * (dt / yawLeakTau)
        }
        lastRawYaw = rawYaw
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
            self.attitudeHistory.append((motion.timestamp,
                                         motion.attitude.pitch,
                                         motion.attitude.roll,
                                         motion.attitude.yaw))
            if self.attitudeHistory.count > 1700 {
                self.attitudeHistory.removeFirst(self.attitudeHistory.count - 1600)
            }

            let accel = motion.userAcceleration
            self.userAccelX = accel.x
            self.userAccelY = accel.y
            self.userAccelZ = accel.z
            self.accelHistory3D.append((motion.timestamp,
                                        accel.x, accel.y, accel.z))
            if self.accelHistory3D.count > 1700 {
                self.accelHistory3D.removeFirst(self.accelHistory3D.count - 1600)
            }

            let mag = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
            self.accelMagnitude = mag

            // Track peak with fast attack, slow decay
            if mag > self.peakDecay {
                self.peakDecay = mag
            } else {
                self.peakDecay *= Config.peakDecayRate
            }
            self.recentPeakAccel = self.peakDecay

            // Strike-scale envelope for the `.strike`/`.acceleration`
            // dimensions, historied for the scope's overlay.
            self.strikeLevel = max(Self.strikeScale01(mag),
                                   self.strikeLevel * self.strikeLevelDecay)
            self.strikeHistory.append((motion.timestamp, self.strikeLevel))
            if self.strikeHistory.count > 1700 {
                self.strikeHistory.removeFirst(self.strikeHistory.count - 1600)
            }

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

    // MARK: - Note activity (strike-scope coloring, 2026-08-23)

    /// Melody-note activity timeline for the toolbar strike scope: the
    /// fret-pad surface reports each sounding touch's begin/end, and the
    /// scope colors every trace bin by whether a note sounded THEN and how
    /// recently the last onset fired (white at onset → cyan over ~1 s;
    /// gray while silent). Id-keyed so a touch that never became a note
    /// (out-of-band, drones) can't unbalance the count. Deliberately NOT
    /// @Published — the scope polls at 30 Hz like `accelHistory3D`.
    /// Main-thread only (touch handlers + the poll).
    private(set) var noteActivity: [(t: TimeInterval, active: Int)] = []
    private(set) var noteOnsets: [TimeInterval] = []
    private var soundingNoteIds: Set<Int> = []

    func noteBegan(_ id: Int, at t: TimeInterval) {
        guard soundingNoteIds.insert(id).inserted else { return }
        noteActivity.append((t, soundingNoteIds.count))
        noteOnsets.append(t)
        trimNoteActivity(now: t)
    }

    func noteEnded(_ id: Int, at t: TimeInterval) {
        guard soundingNoteIds.remove(id) != nil else { return }
        noteActivity.append((t, soundingNoteIds.count))
        trimNoteActivity(now: t)
    }

    private func trimNoteActivity(now: TimeInterval) {
        let cutoff = now - 12.0        // scope window + fade + slack
        // Keep one event at/before the cutoff as the baseline state for
        // bins older than the newest surviving event.
        while noteActivity.count > 1, noteActivity[1].t <= cutoff {
            noteActivity.removeFirst()
        }
        noteOnsets.removeAll { $0 < cutoff }
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
