import Foundation

/// The iPad's 60 Hz sensor tick. Its ONE job is `sendTiltReport`: sampling
/// the motion source's tilts, raw acceleration and strike envelope into
/// `OutboundPlayState`, the wire state the link paces. The iPad evaluates
/// no parameter mappings — it streams raw axes and the Mac interprets them.
///
/// Pitch does not pass through here: touches go `PitchPadEngine` →
/// `OutboundPlayState` directly, atomic with the tilts on the wire.
public class NoteManager: ObservableObject {

    private var uiUpdateCounter: Int = 0
    private let uiUpdateInterval: Int = 4  // publish every 4th tick (~15Hz)

    /// Pauses the tick (sensor sampling included).
    public var paused: Bool = false

    /// Raw tilt values cached each tick (3 axes, −1…+1) — the iPad
    /// toolbar's arm square reads this.
    public var currentTilt: [Double] = [0, 0, 0]

    public var motionSource: MotionSource?

    /// The outbound play state the tick writes raw tilt (uncalibrated
    /// attitude), acceleration and strike into — change-gated there, atomic
    /// with pitch on the wire.
    public weak var playState: OutboundPlayState?

    private var tickTimer: Timer?

    public init() {
        startTickLoop()
    }

    /// Starts the 60 Hz timer.
    private func startTickLoop() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !paused else { return }

        if let tilts = motionSource?.normalizedTilts {
            for i in 0..<min(tilts.count, 3) {
                currentTilt[i] = max(-1, min(1, tilts[i]))
            }
        }
        // The raw tilt report streams CONTINUOUSLY, not just while a note
        // sounds — the Mac's body fusion consumes it as its arm sensor,
        // including during calibration with no note down.
        sendTiltReport()

        uiUpdateCounter += 1
        if uiUpdateCounter >= uiUpdateInterval {
            uiUpdateCounter = 0
            objectWillChange.send()
        }
    }

    private func sendTiltReport() {
        guard let playState else { return }
        for i in 0..<3 {
            playState.setTilt(i, i < currentTilt.count ? currentTilt[i] : 0)
        }
        if let a = motionSource?.rawAccel, a.count >= 3 {
            playState.setAccel(a[0], a[1], a[2])
        }
        if let s = motionSource?.strikeLevel {
            playState.setStrike(s)
        }
    }

    deinit {
        tickTimer?.invalidate()
    }
}
