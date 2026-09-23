import Foundation
import CoreGraphics

/// Central configuration for all tunable parameters.
public enum Config {
    // MARK: - Audio
    /// The whole graph runs at the artifacts' native rate: the String
    /// kernel decimates 96 → 48 kHz into it, the plucked voices render at
    /// it, and the output device is matched to it (no converter).
    public static let sampleRate: Double = 48000
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

    // MARK: - Link
    /// The wire rate: `TarabLink` paces sends at this rate, and the Mac's
    /// wire-rate samplers (the glide queue, the finger-accel scope) tick
    /// in step with it.
    public static let linkTickHz: Double = 120

    // MARK: - Motion
    public static let motionUpdateRate: Double = 200      // Hz
    // MARK: - Strike mapping
    public static let strikeMinG: Double = 0.01
    public static let strikeMaxG: Double = 0.5

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
    /// fraction of the surface height, its top at `fretPadBandTopFraction`
    /// (`fretPadBandRect`). Both platforms draw the full surface — the Mac
    /// tab letterboxes to `iPadSurfaceAspect` and mirrors the iPad exactly:
    /// the bordered band, the dead space above/below it, and the drone
    /// buttons at their full-surface position.
    public static let fretPadHeightFraction: CGFloat = 0.5
    /// The band's top edge as a fraction of the surface height. 0.25 is
    /// centred, 0.5 flush with the bottom; 0.3 sits it a little below
    /// centre (dead space 0.3 above, 0.2 below).
    public static let fretPadBandTopFraction: CGFloat = 0.3
    /// Whether the chord bar (the strip under the band) is laid out at all.
    /// Off: `chordBarCells` resolves to no cells, so neither surface draws
    /// it nor hit-tests it. Hidden for now.
    public static let chordBarShown = false

    // MARK: - Touch size (the `.touchSize` dimension)

    /// The fingertip-radius window the `.touchSize` axis spans, in POINTS
    /// (`UITouch.majorRadius`, the PERF_STATE `radius` byte).
    /// **Measured on the instrument**: a normally curled fingertip reads
    /// 20.8 or 31.3 pt, and a deliberately FLATTENED finger reaches 73.0
    /// controllably (sometimes higher). `lo` therefore sits at the top of
    /// the normal band — ordinary playing rests the axis at 0 — and `hi`
    /// at the flattened reach; both ends clamp (`TouchSizeTracker`).
    public static let touchSizeLoPt: Double = 31.3
    public static let touchSizeHiPt: Double = 73.0

    /// How long a deliberate flatten takes: seconds for the finger to
    /// cross the whole `lo…hi` window. **Measured on the instrument** —
    /// it is the source of `touchSizeDefaultVelPtS`, the speed the
    /// estimator assumes for a gesture's FIRST level crossing, before two
    /// crossings have measured the real one.
    public static let touchSizeRampS: TimeInterval = 0.5

    /// The `majorRadius` QUANTUM in points. **Measured on the instrument**:
    /// Apple reports the radius only at multiples of ≈10.42 pt (20.8, 31.3,
    /// 41.7, 52.1, 62.5, 73.0 = 2…7 quanta), so a level's true radius lies
    /// within ±half a quantum of it — the default bin half-width before a
    /// transition has measured one.
    public static let touchRadiusQuantumPt: Double = 10.42

    /// The estimator's default finger speed (points/second) for the first
    /// crossing of a gesture: the whole window in `touchSizeRampS`.
    public static let touchSizeDefaultVelPtS: Double =
        (touchSizeHiPt - touchSizeLoPt) / touchSizeRampS

    /// Longest gap between two level crossings that still counts as ONE
    /// continuous gesture. Beyond it the previous crossing is stale, so
    /// its velocity is not carried over and a still finger has stopped.
    public static let touchSizeGestureGapS: TimeInterval = 0.4

    /// Time constant for the velocity estimate to decay to 0 once the
    /// finger has stopped (pinned against a bin edge, or no crossing
    /// inside `touchSizeGestureGapS`).
    public static let touchSizeVelDecayS: TimeInterval = 0.1

    /// Time constant for a stopped estimate to relax to the CENTRE of the
    /// current level — the best static guess once motion tells us nothing.
    public static let touchSizeSettleS: TimeInterval = 0.25

    /// The output tracker's ~2 % settle time: a CRITICALLY DAMPED
    /// second-order spring–damper on the position estimate, so the axis
    /// has continuous velocity (an S-shaped start and stop, no kink at a
    /// crossing) rather than the estimator's cornered ramp.
    public static let touchSizeSmoothS: TimeInterval = 0.08
}
