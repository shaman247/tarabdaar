import Foundation

/// SCALE-SHAPED OVERTONES (2026-08-05): the "altered tanpura" — a
/// per-mode transform applied at table build that bends the overtone
/// cascade toward the configured scale, beyond what a physical
/// tanpura's string can do. Two axes, both 0 = physical:
///
///  - `align` retunes each partial toward the nearest scale pitch
///    class (log-space, any octave). The pull is FULL inside the
///    capture window and smoothsteps to zero by twice the window, so
///    a partial far from every scale tone (a pentatonic gap) is left
///    at its harmonic position instead of being dragged a semitone —
///    the flagship corrections (harmonic 5 → komal ga, ~71 ¢;
///    harmonic 7 → n, ~30–50 ¢) sit inside the window.
///  - `focus` tilts sustain toward scale-aligned partials: t60 is
///    scaled by the POST-retune proximity, so the jawari cascade —
///    which keeps re-pumping every mode — evolves toward the scale
///    over the note's life rather than being statically filtered.
///  - `quiet` drops the RADIATED level of misaligned partials (the
///    per-mode output projection φ_o): unlike `focus` it changes no
///    dynamics — those modes still ring, feed the jawari and trade
///    energy through the contact; they are just heard less. All the
///    way up, an off-scale partial is silent at the readout.
///  - `spread` decorrelates the retune per string (a deterministic
///    per-slot/per-mode jitter of the pull fraction), so shared
///    partials across drone strings don't lock to exact 0-beat
///    sterility.
///
/// Modes 1–2 are NEVER touched (the caller skips them): they pin the
/// perceived pitch, and the artifact's `pitchCents` wrap calibration
/// (RECAL LAW) was secanted with them at their fitted places.
public struct TanpuraShaping: Sendable {
    /// Scale pitch classes as fractional log2 offsets from the tonic,
    /// each in [0, 1).
    public let scalePCs: [Double]
    public let tonicHz: Double
    public let align: Double     // 0…1 retune blend
    public let focus: Double     // 0…1 sustain tilt
    public let spread: Double    // 0…1 per-string pull decorrelation
    public let quiet: Double     // 0…1 misaligned-partial output cut

    /// Full-pull capture half-width, cents. Corrections up to this
    /// size apply in full at align = 1; beyond 2× nothing moves.
    public static let captureCents = 80.0
    /// `focus`'s proximity kernel σ, cents — deliberately TIGHTER than
    /// the capture window: "aligned" for sustain means genuinely on the
    /// scale tone (a 71 ¢-off partial thins to ~0.06 at focus 1, not a
    /// barely-audible 0.68 the capture width would give).
    public static let focusSigmaCents = 30.0
    /// t60 multiplier floor — focus thins, it never hard-kills.
    public static let t60Floor = 0.05

    public init(tonicHz: Double, scaleRatios: [Double],
                align: Double, focus: Double, spread: Double,
                quiet: Double = 0) {
        self.tonicHz = tonicHz
        self.scalePCs = scaleRatios.filter { $0 > 0 }.map {
            let l = log2($0)
            return l - l.rounded(.down)
        }.sorted()
        self.align = min(max(align, 0), 1)
        self.focus = min(max(focus, 0), 1)
        self.spread = min(max(spread, 0), 1)
        self.quiet = min(max(quiet, 0), 1)
    }

    /// Anything to do at all? (spread alone is inert by design.)
    public var isActive: Bool {
        (align > 0 || focus > 0 || quiet > 0)
            && !scalePCs.isEmpty && tonicHz > 0
    }

    /// Signed cents from `pc` (fractional log2) to the nearest scale
    /// pitch class, octave-circular.
    func centsToNearestPC(_ pc: Double) -> Double {
        var best = Double.greatestFiniteMagnitude
        for s in scalePCs {
            var d = s - pc
            d -= d.rounded()          // wrap to [-0.5, 0.5]
            if abs(d) < abs(best) { best = d }
        }
        return best * 1200.0
    }

    /// The capture law: pull fraction for a correction of `dc` cents —
    /// 1 inside the window, smoothstep to 0 by twice the window. A
    /// partial pulled PARTWAY toward a distant target would land in
    /// the maximally-dissonant no-man's-land, so the taper reaches
    /// zero rather than plateauing.
    static func captureWeight(_ dc: Double) -> Double {
        let a = abs(dc)
        let w = captureCents
        if a <= w { return 1.0 }
        if a >= 2.0 * w { return 0.0 }
        let t = (a - w) / w
        return 1.0 - t * t * (3.0 - 2.0 * t)
    }

    /// splitmix64 → [0, 1): the deterministic per-(slot, mode) jitter
    /// source for `spread` (no RNG state — rebuilds are reproducible).
    static func hash01(_ seed: UInt64, _ k: Int) -> Double {
        var z = seed &+ 0x9E3779B97F4A7C15 &* UInt64(k + 1)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }

    /// The per-mode adjustment for a partial at SOUNDING frequency
    /// `fSounding`: (retune ratio for w0, t60 multiplier, output-gain
    /// multiplier for φ_o). `mode` is 1-based; `slotSeed` decorrelates
    /// strings for `spread`.
    public func modeAdjust(fSounding: Double, mode: Int,
                           slotSeed: UInt64) -> (ratio: Double,
                                                 t60Mul: Double,
                                                 outMul: Double) {
        guard isActive, fSounding > 0 else { return (1.0, 1.0, 1.0) }
        let l = log2(fSounding / tonicHz)
        let pc = l - l.rounded(.down)
        let dc = centsToNearestPC(pc)
        let w = Self.captureWeight(dc)
        let jitter = spread > 0
            ? 1.0 - spread * Self.hash01(slotSeed, mode) : 1.0
        let pull = align * w * jitter
        let ratio = pow(2.0, pull * dc / 1200.0)
        // both remaining axes key off the post-retune residual:
        // partials the retune landed on-scale ring/radiate free
        let residual = dc * (1.0 - pull)
        let sigma = Self.focusSigmaCents
        let p = exp(-0.5 * (residual / sigma) * (residual / sigma))
        // focus thins DECAY (floored — the cascade must keep breathing
        // through those modes); quiet cuts RADIATION only, so it may
        // reach full silence
        let t60Mul = max(Self.t60Floor, 1.0 - focus * (1.0 - p))
        let outMul = 1.0 - quiet * (1.0 - p)
        return (ratio, t60Mul, outMul)
    }
}
