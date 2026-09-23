import Foundation
import SarangiKit

/// THE PITCH ACCENT (`ctl_fret_accent`): the played expression dips as the
/// finger moves BETWEEN FRETS and returns as it lands on one, so a glided
/// run keeps its notes distinct — the sounded counterpart of the pitch
/// warp's plateaus. The grid is the pitches of the frets ON THE PAD (the
/// arrangement's enabled segments, in every octave), not the whole scale:
/// dragging D → E → F♯ across three frets dips once per gap and never
/// spikes at a D♯ or F the scale holds but the pad does not show. The Mac
/// evaluates it on every touch onset and move and folds it into the
/// per-slot expression scale the strum chord already uses; nothing
/// crosses the wire.
///
/// The law: the pitch's position `t` (0…1) in the gap between its two
/// neighbouring fret pitches (the pad's OWN gaps, in any octave — never a
/// 12-TET grid) gives a between-ness `sin²(π·t)`: 0 on a fret, 1 midway,
/// flat at both ends so a vibrato around a note barely dips. The
/// expression scale is `1 − amount · between-ness`, so a note played ON a
/// fret sounds exactly as commanded at every amount and the axis never
/// boosts past the player's expression.
public struct FretPitchGrid: Equatable, Sendable {
    /// The tonic as fractional MIDI (69 = A440).
    public let tonicSemis: Double
    /// The fret pitches folded into one octave, as octave fractions in
    /// `[0, 1)`, sorted, deduplicated.
    public let degrees: [Double]

    /// The pitches of an arrangement's enabled frets against the ONE
    /// scale's `degrees` (a segment whose degree the scale no longer holds
    /// is skipped, as on the pad).
    public init(tonicHz: Double, arrangement: FretArrangement,
                degrees: [(ratio: Double, label: String)]) {
        let ratios = arrangement.segments.filter(\.enabled)
            .compactMap { fretRatio($0, degrees: degrees) }
        self.init(tonicHz: tonicHz, ratios: ratios)
    }

    /// `ratios` are fret pitches over the tonic; any octave, any order.
    public init(tonicHz: Double, ratios: [Double]) {
        tonicSemis = Pitch.fractionalMidi(hz: max(tonicHz, 1e-3))
        var folded: [Double] = []
        for r in ratios where r > 0 {
            let x = log2(r)
            let f = x - floor(x)
            if !folded.contains(where: { abs($0 - f) < 1e-9 }) { folded.append(f) }
        }
        degrees = folded.sorted()
    }

    /// 0 on a fret, 1 midway between two neighbouring frets (`sin²(π·t)`
    /// of the gap fraction). An empty grid is 0 everywhere (null).
    public func betweenness(atSemis semis: Double) -> Double {
        guard !degrees.isEmpty else { return 0 }
        let x = (semis - tonicSemis) / 12.0
        let f = x - floor(x)
        // the count of frets at or below f: its predecessor is the lower
        // neighbour, itself the upper; both wrap across the octave
        var idx = 0
        while idx < degrees.count, degrees[idx] <= f { idx += 1 }
        let lo = idx > 0 ? degrees[idx - 1] : degrees[degrees.count - 1] - 1.0
        let hi = idx < degrees.count ? degrees[idx] : degrees[0] + 1.0
        let gap = hi - lo
        guard gap > 1e-9 else { return 0 }
        let t = (f - lo) / gap
        return 0.5 - 0.5 * cos(2.0 * Double.pi * t)
    }

    /// The expression scale at a pitch for an accent `amount` (0…1):
    /// `1 − amount · betweenness`. Exactly 1.0 at amount 0.
    public func exprScale(atSemis semis: Double, amount: Double) -> Double {
        guard amount > 0 else { return 1.0 }
        return 1.0 - min(amount, 1.0) * betweenness(atSemis: semis)
    }
}
