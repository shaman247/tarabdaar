import Foundation
import CoreGraphics

/// Central configuration for all tunable parameters.
public enum Config {
    // MARK: - Audio
    public static let sampleRate: Double = 44100
    /// Requested output IO buffer size (frames) on macOS — the play-latency
    /// floor. 128 frames ≈ 2.7 ms; the inline sarangi model needs <1 ms of a
    /// buffer, so this leaves comfortable headroom below the 512-frame default.
    /// Applied at engine start; clamped to the device's allowed range.
    /// Used on SOLID transports only (built-in, USB, Thunderbolt, …) — see
    /// `jitterProneOutputBufferFrames`.
    public static let preferredOutputBufferFrames: UInt32 = 128
    /// Output IO buffer for JITTER-PRONE transports — monitor audio over the
    /// video link (DisplayPort/HDMI: packetized, clock recovered monitor-side),
    /// Bluetooth, AirPlay. Those cannot sustain the ~3 ms callback cadence of
    /// the low buffer: measured on an AORUS FO32U2P over DisplayPort,
    /// every voice crackled at 128 frames while the same render was clean on
    /// the headphone DAC. 512 frames ≈ 11.6 ms — fine for monitor speakers,
    /// which are not a performance monitor.
    public static let jitterProneOutputBufferFrames: UInt32 = 512

    // MARK: - Motion
    public static let motionUpdateRate: Double = 200      // Hz
    public static let accelHistoryLength: Int = 200       // ~1 second at 200Hz
    public static let accelBufferDuration: TimeInterval = 0.1  // 100ms ring buffer for velocity capture

    // MARK: - Velocity mapping
    public static let velocityMinG: Double = 0.01  // softest tap acceleration
    public static let velocityMaxG: Double = 0.5   // hardest tap acceleration
    /// TRAILING accel window a fret-pad onset scans for its strike spike
    /// (`MotionSource.strikeVelocity01`). Backward-looking:
    /// UIKit touch delivery lags the physical impact ~10–25 ms, so the
    /// spike is usually already buffered and the onset never waits.
    /// Must stay under `accelBufferDuration`.
    public static let velocityLookback: TimeInterval = 0.05


    // MARK: - Reference geometry (iPad)
    /// Logical landscape size of the development iPad (Air 13" M3),
    /// locked to landscape-right in TarabdaarApp.
    public static let iPadScreenSize = CGSize(width: 1366, height: 1024)
    /// Approx. height of PadToolbarIOS + landscape safe-area subtracted from
    /// the iPad screen to get the actual playing-surface height (~34pt).
    public static let iPadToolbarHeight: CGFloat = 34
    /// Aspect ratio (w/h) of the iPad *playing surface* — screen minus the pad
    /// toolbar. The Mac pads letterbox their drawing surface to this so shapes
    /// match the iPad's relative size and position. ≈ 1366 / 990 ≈ 1.38.
    public static let iPadSurfaceAspect: CGFloat =
        iPadScreenSize.width / (iPadScreenSize.height - iPadToolbarHeight)
    /// The Fret Pad's playable **band**: a full-width strip spanning this
    /// fraction of the surface height, vertically centered
    /// (`fretPadBandRect`). Both platforms draw the full surface — the Mac
    /// tab letterboxes to `iPadSurfaceAspect` and mirrors the iPad exactly:
    /// the bordered band, the dead space above/below it, and the drone
    /// buttons at their full-surface position.
    public static let fretPadHeightFraction: CGFloat = 0.5

    // MARK: - Fingertip flatten → vibrato

    /// ONE Apple touch-size step, in points. `UITouch.majorRadius` is far
    /// too coarse for a continuous axis — every finger reads one size and
    /// deliberately FLATTENING the fingertip moves it up a single step —
    /// so it is used as a BINARY signal: a touch reads flattened once its
    /// radius sits this far above its own onset baseline, and unflattened
    /// again below half of it (`TouchFlattenDetector`). The iPad's per-touch
    /// indicator prints the raw radius, so 3 pt can be re-judged by eye.
    public static let touchFlattenStepPt: Double = 3.0

    /// Flatten → vibrato ease-in time: 0 → 100 % depth while flattened.
    public static let flattenVibratoEaseInS: TimeInterval = 2.0
    /// Ease-out time back to 0 once the fingertip un-flattens (or lifts).
    public static let flattenVibratoEaseOutS: TimeInterval = 0.5
}
