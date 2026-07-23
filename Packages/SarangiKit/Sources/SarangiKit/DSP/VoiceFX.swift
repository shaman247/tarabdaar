import Foundation

/// One FX stage of the per-voice rack: a low-pass filter → variable-length
/// graphical parametric EQ → reverb (mono in, stereo out). A composition of the
/// existing `Biquad` / `BiquadChain` / `Reverb` primitives — no new DSP.
/// `enabled`, the reverb `mix` and `width` are live (set every buffer); the
/// filter + EQ coefficients are **live filter** (`updateFilters` swaps them in
/// place without resetting state → click-free); only reverb RT60 is structural.
/// **Starpad-local** — not part of the upstream standalone model.
public struct VoiceFX: Sendable {
    public var enabled: Bool
    var lp: Biquad
    var eq: BiquadChain
    var reverb: Reverb

    /// The stage low-pass biquad. Resonance 0..1 → Q 0.707..8 (via `stageLowpass`).
    static func makeLP(_ p: VoiceFXParams, sr: Double) -> Biquad {
        Biquad.stageLowpass(cutoff: p.filterCutoff, resonance: p.filterResonance, sr: sr)
    }
    /// The EQ chain: one biquad per enabled band, via the shared `Biquad.forBand`
    /// (so the curve drawn in the UI is the exact running response). Disabled
    /// bands are skipped; an empty result is a no-op passthrough.
    static func makeEQChain(_ bands: [EQBand], sr: Double) -> BiquadChain {
        BiquadChain(bands.compactMap { $0.enabled ? Biquad.forBand($0, sr: sr) : nil })
    }

    public init(_ p: VoiceFXParams, sr: Double) {
        enabled = p.enabled
        lp = Self.makeLP(p, sr: sr)
        eq = Self.makeEQChain(p.eq, sr: sr)
        reverb = Reverb(rt60: p.reverbRT60, predelayMs: 20, mix: p.reverbMix, width: p.reverbWidth, sr: sr)
    }

    /// Live filter/EQ coefficient swap — recompute `lp`+`eq` from `p` WITHOUT
    /// resetting biquad state (`z1/z2`), so a coefficient-only edit (a point drag)
    /// is click-free. When the band COUNT changes, new sections start at zero
    /// state (a fresh filter ramps in continuously) and removed sections are
    /// dropped. Reverb is untouched (RT60 owns delay-line state → stays
    /// structural). Call under the host audio lock.
    public mutating func updateFilters(_ p: VoiceFXParams, sr: Double) {
        let newLP = Self.makeLP(p, sr: sr)
        lp.b0 = newLP.b0; lp.b1 = newLP.b1; lp.b2 = newLP.b2; lp.a1 = newLP.a1; lp.a2 = newLP.a2
        let desired = Self.makeEQChain(p.eq, sr: sr).sections
        let keep = min(eq.sections.count, desired.count)
        for i in 0..<keep {
            eq.sections[i].b0 = desired[i].b0; eq.sections[i].b1 = desired[i].b1
            eq.sections[i].b2 = desired[i].b2; eq.sections[i].a1 = desired[i].a1
            eq.sections[i].a2 = desired[i].a2     // z1/z2 deliberately preserved → no click
        }
        if desired.count > eq.sections.count {
            eq.sections.append(contentsOf: desired[keep...])     // new bands: zero state
        } else if desired.count < eq.sections.count {
            eq.sections.removeLast(eq.sections.count - desired.count)
        }
    }

    /// Mono `x` → stereo. Disabled = exact passthrough (`(x, x)`) with no state
    /// advance, so toggling is glitch-free and costs nothing when off.
    @inline(__always)
    public mutating func process(_ x: Double) -> (Double, Double) {
        if !enabled { return (x, x) }
        var y = lp.process(x)
        y = eq.process(y)
        return reverb.process(y)
    }

    public mutating func reset() { lp.reset(); eq.reset(); reverb.reset() }
}
