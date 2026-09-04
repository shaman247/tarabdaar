import Foundation

/// THE fractional-MIDI carrier: 69 = A4 = 440 Hz, one semitone per unit.
/// It is the wire's pitch unit and the reference every absolute-Hz readout
/// is named against — scale degrees never pass through it (they are
/// ratios of the one tonic), so this is the only 12-TET formula.
public enum Pitch {
    public static func hz(fractionalMidi m: Double) -> Double {
        440.0 * pow(2.0, (m - 69.0) / 12.0)
    }

    public static func fractionalMidi(hz: Double) -> Double {
        69.0 + 12.0 * log2(hz / 440.0)
    }

    /// The nearest MIDI note to `hz` — for a concert note name.
    public static func nearestMidi(hz: Double) -> Int {
        Int(fractionalMidi(hz: hz).rounded())
    }
}
