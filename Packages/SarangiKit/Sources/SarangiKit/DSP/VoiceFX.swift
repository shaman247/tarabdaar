import Foundation

/// One FX stage of the per-voice rack: a low-pass filter → 3-band parametric EQ →
/// reverb (mono in, stereo out). A composition of the existing `Biquad` /
/// `BiquadChain` / `Reverb` primitives — no new DSP. `enabled`, the reverb `mix`
/// and `width` are live (set every buffer); the filter/EQ coefficients + reverb
/// RT60 are baked at init (a structural change rebuilds the engine).
/// **Starpad-local** — not part of the upstream standalone model.
public struct VoiceFX: Sendable {
    public var enabled: Bool
    var lp: Biquad
    var eq: BiquadChain
    var reverb: Reverb

    public init(_ p: VoiceFXParams, sr: Double) {
        enabled = p.enabled
        // resonance 0..1 → Q 0.707 (Butterworth) .. ~8 (resonant peak)
        let q = 0.70710678 + max(0, min(1, p.filterResonance)) * (8.0 - 0.70710678)
        lp = Biquad.lowpass(fc: min(max(20, p.filterCutoff), 0.49 * sr), sr: sr, q: q)
        eq = BiquadChain(p.eq.map { Biquad.peaking(f0: $0.freq, gainDB: $0.gainDB, q: $0.q, sr: sr) })
        reverb = Reverb(rt60: p.reverbRT60, predelayMs: 20, mix: p.reverbMix, width: p.reverbWidth, sr: sr)
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
