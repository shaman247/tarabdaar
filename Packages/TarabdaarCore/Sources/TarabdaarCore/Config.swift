import Foundation
import CoreGraphics

/// Central configuration for all tunable parameters.
public enum Config {
    // MARK: - Timing
    // `var` rather than `let` so the Mac app can raise it (e.g. to 50 ms)
    // when running off the iPad's UDP motion stream — absorbs network
    // jitter so `peakAccelSince` sees the full accel spike. iOS leaves
    // it at the default.
    public static var velocityDelay: TimeInterval = 0.020       // 20ms — accelerometer capture window

    // MARK: - Glide
    public static let glideDistanceExponent: Double = 0.6    // sublinear: larger intervals grow slower (1.0 = linear, 0.5 = sqrt)
    public static let releaseGracePeriod: Double = 0.050   // 50ms window to connect consecutive notes
    public static let glideMidpoint: Double = 0.6   // sigmoid midpoint — shifted left for faster onset

    // MARK: - Drag glide
    public static let dragSnapDelay: Double = 0.060        // 60ms after finger stops, start snapping

    // MARK: - MIDI
    public static let midiPitchBendRange: Double = 48  // ±48 semitones — must match receiving synth

    // MARK: - Audio
    public static let sampleRate: Double = 44100
    /// Requested output IO buffer size (frames) on macOS — the play-latency
    /// floor. 128 frames ≈ 2.7 ms; the inline sarangi model needs <1 ms of a
    /// buffer, so this leaves comfortable headroom below the 512-frame default.
    /// Applied at engine start; clamped to the device's allowed range.
    public static let preferredOutputBufferFrames: UInt32 = 128
    public static let frequencySmoothing: Double = 0.002  // per-sample coefficient (~11ms smoothing)
    public static let attackCoefficient: Double = 0.05    // envelope attack (~2ms)
    public static let releaseCoefficient: Double = 0.9993 // envelope release (~50ms)
    public static let maxAmplitude: Double = 0.3          // velocity=127 amplitude (avoid clipping)

    // MARK: - Motion
    public static let motionUpdateRate: Double = 200      // Hz
    public static let accelHistoryLength: Int = 200       // ~1 second at 200Hz
    public static let accelBufferDuration: TimeInterval = 0.1  // 100ms ring buffer for velocity capture
    public static let peakDecayRate: Double = 0.95        // peak indicator decay per sample

    // MARK: - Velocity mapping
    public static let velocityMinG: Double = 0.01  // softest tap acceleration
    public static let velocityMaxG: Double = 0.5   // hardest tap acceleration


    // MARK: - Sliders
    public static let sliderWidth: CGFloat = 150    // ~1.5 inches on iPad
    public static let sliderHeight: CGFloat = 66   // 1.5× finger-width
    public static let slider1Default: Double = 0.5  // value when not touched
    public static let slider2Default: Double = 0.5

    // MARK: - Polyphonic Mode
    /// Concurrent played voices. MPE forwarding round-robins channels
    /// 1-15 (channel 0 is the MPE master), so when more than 15 voices
    /// sound at once one MIDI channel ends up shared. Audio is fine —
    /// the modal renderer scales linearly to dozens of voices.
    public static let maxPolyVoices: Int = 16

    // MARK: - Display
    public static let pitchHistoryLength: Int = 120  // ~2 seconds at 60Hz
    public static let peakDelayHistory: Int = 20     // rolling window for delay instrumentation

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
}
