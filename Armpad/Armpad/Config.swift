import Foundation

/// Central configuration for all tunable parameters.
enum Config {
    // MARK: - Timing
    static let velocityDelay: TimeInterval = 0.020       // 20ms — accelerometer capture window

    // MARK: - Glide
    static let glideDistanceExponent: Double = 0.6    // sublinear: larger intervals grow slower (1.0 = linear, 0.5 = sqrt)
    static let releaseGracePeriod: Double = 0.050   // 50ms window to connect consecutive notes
    static let glideMidpoint: Double = 0.6   // sigmoid midpoint — shifted left for faster onset

    // MARK: - Drag glide
    static let dragSnapDelay: Double = 0.060        // 60ms after finger stops, start snapping

    // MARK: - MIDI
    static let midiPitchBendRange: Double = 48  // ±48 semitones — must match receiving synth

    // MARK: - Audio
    static let sampleRate: Double = 44100
    static let frequencySmoothing: Double = 0.002  // per-sample coefficient (~11ms smoothing)
    static let attackCoefficient: Double = 0.05    // envelope attack (~2ms)
    static let releaseCoefficient: Double = 0.9993 // envelope release (~50ms)
    static let maxAmplitude: Double = 0.3          // velocity=127 amplitude (avoid clipping)

    // MARK: - Motion
    static let motionUpdateRate: Double = 200      // Hz
    static let accelHistoryLength: Int = 200       // ~1 second at 200Hz
    static let accelBufferDuration: TimeInterval = 0.1  // 100ms ring buffer for velocity capture
    static let peakDecayRate: Double = 0.95        // peak indicator decay per sample

    // MARK: - Velocity mapping
    static let velocityMinG: Double = 0.01  // softest tap acceleration
    static let velocityMaxG: Double = 0.5   // hardest tap acceleration


    // MARK: - Sliders
    static let sliderWidth: CGFloat = 150    // ~1.5 inches on iPad
    static let sliderHeight: CGFloat = 66   // 1.5× finger-width
    static let slider1Default: Double = 0.5  // value when not touched
    static let slider2Default: Double = 0.5

    // MARK: - Polyphonic Mode
    static let maxPolyVoices: Int = 6

    // MARK: - Display
    static let pitchHistoryLength: Int = 120  // ~2 seconds at 60Hz
    static let peakDelayHistory: Int = 20     // rolling window for delay instrumentation
}
