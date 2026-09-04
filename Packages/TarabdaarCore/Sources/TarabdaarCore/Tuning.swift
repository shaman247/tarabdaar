import Combine
import Foundation
import SarangiKit

/// THE ONE SCALE, THE ONE TONIC — owned once per device and shared by
/// every pad engine on it (the Mac's scale engine and its Fret Pad engine
/// hold the same instance, so nothing mirrors). The tonic is an integer
/// note anchor plus a ±50 ¢ refinement — the range the sync blob encodes —
/// set in Hz from the Fret Pad tab. Not persisted: every launch opens on
/// D4 (a stale restored tonic would silently retune the whole instrument).
public final class Tuning: ObservableObject {
    /// The active scale, seeded from the bundled `Default.json` (fallback
    /// `PitchScale.defaultJI`).
    @Published public var scale: PitchScale = ScaleStore.loadDefault()
    /// The tonic's integer note anchor.
    @Published public var tonicMidi: Int = Tuning.defaultTonicMidi
    /// Fractional tonic refinement in CENTS (±50) on `tonicMidi`.
    @Published public var tonicCents: Double = 0

    /// The MIDI notes the tonic anchor may take (C1…B7).
    public static let tonicNoteRange = 24...107
    /// The tonic every launch opens on: **D4** (293.665 Hz).
    public static let defaultTonicMidi = 62

    public init() {}

    /// The tonic as an absolute frequency — the ONE Hz value everything
    /// else is relative to.
    public var tonicHz: Double { Pitch.hz(fractionalMidi: tonicFractionalMidi) }

    public var tonicFractionalMidi: Double { Double(tonicMidi) + tonicCents / 100.0 }

    /// Set the tonic from a frequency.
    public func setTonic(hz: Double) {
        guard hz > 20, hz < 4000 else { return }
        setTonic(fractionalMidi: Pitch.fractionalMidi(hz: hz))
    }

    /// Set the tonic from a fractional MIDI note: integer anchor + ±50¢
    /// remainder.
    public func setTonic(fractionalMidi: Double) {
        let clamped = max(Double(Self.tonicNoteRange.lowerBound),
                          min(Double(Self.tonicNoteRange.upperBound), fractionalMidi))
        let note = Int(clamped.rounded())
        tonicMidi = note
        tonicCents = (clamped - Double(note)) * 100.0
    }

    /// Set the integer note anchor, KEEPING the cents offset (the Fret
    /// Pad's note menu).
    public func setTonic(midi: Int) {
        tonicMidi = max(Self.tonicNoteRange.lowerBound,
                        min(Self.tonicNoteRange.upperBound, midi))
    }

    /// "The tuning moved" — the scale or the tonic. Every follower (the
    /// tarab document, the tanpura grid, the drone-button ratios, the iPad
    /// sync) hangs off this one publisher with its own debounce.
    public var didChange: AnyPublisher<Void, Never> {
        Publishers.Merge3(
            $scale.map { _ in () },
            $tonicMidi.removeDuplicates().map { _ in () },
            $tonicCents.removeDuplicates().map { _ in () })
            .eraseToAnyPublisher()
    }
}
