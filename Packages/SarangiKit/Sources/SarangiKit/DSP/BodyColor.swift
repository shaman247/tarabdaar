import Foundation

/// Block E (live): a low shelf on the **dry** violin branch, and the modal body
/// **ring** added to the **generated supplement** (bank+jaw+drone) — per the
/// current `chain.process` (`body_resonance`). The offline model convolves a
/// short modal IR `h(t)=Σ a_k e^{−π f_k t/Q_k} sin(2π f_k t)`; that IR is exactly
/// the impulse response of a bank of 2-pole resonators, so we realise it as the
/// modes (cheap, real-time) excited by the supplement, energy-matched to it and
/// mixed in at `wet = E_body`. The offline FIR body transfer is on the dry
/// branch (applied in `SarangiEngine`).
public struct BodyColor: Sendable {
    public var lowShelf: Biquad?
    var ring: [Resonator]
    var rmsRing: RunningRMS
    var rmsSupp: RunningRMS
    public var wet: Double          // E_body (live scalar)

    public init(eModes: [BodyMode], eBody: Double, lowShelfF: Double, lowShelfDB: Double, sr: Double) {
        wet = eBody
        lowShelf = lowShelfDB != 0 ? Biquad.lowShelf(f0: lowShelfF, gainDB: lowShelfDB, sr: sr) : nil
        // modal IR decay e^{−π f t/Q} ⇒ t60 = 3ln10·Q/(π f) (matches Resonator's R).
        // The offline `_body_ir` mode is a_k·e^{−π f t/Q}·sin(2π f t) — peak
        // amplitude a_k. A resonator's impulse-response envelope is b0/sinθ, so to
        // reproduce that mode we set **b0 = a_k·sinθ** (NOT the unity-resonance-gain
        // b0, which over-weighted the HF modes by b0/sinθ — +9 dB at 2–4 kHz,
        // +13 dB at 4–8 kHz). Verified against `_body_ir` to 0.5 dB.
        ring = eModes.map { m in
            var r = Resonator(f0: m.f, t60: max(0.02, 6.90775528 * m.q / (.pi * m.f)), sr: sr)
            r.b0 = pow(10.0, m.gainDB / 20.0) * sin(2 * .pi * m.f / sr)
            return r
        }
        // long window so the energy match is quasi-constant (doesn't cut the ring tail)
        rmsRing = RunningRMS(tauMs: 1500, sr: sr)
        rmsSupp = RunningRMS(tauMs: 1500, sr: sr)
    }

    /// Add the body ring to the generated supplement.
    public mutating func colorSupplement(_ supp: Double) -> Double {
        if wet <= 0 || ring.isEmpty { _ = rmsSupp.process(supp); return supp }
        var r = 0.0
        for i in ring.indices { r += ring[i].process(supp) }
        let rR = rmsRing.process(r)
        let sR = rmsSupp.process(supp)
        let ringNorm = r / (rR + 1e-12) * sR        // energy-match ring to supp
        return supp + wet * ringNorm
    }

    /// Color the dry violin branch (low shelf only; FIR is applied upstream).
    public mutating func colorDry(_ x: Double) -> Double {
        lowShelf != nil ? lowShelf!.process(x) : x
    }

    public mutating func reset() {
        lowShelf?.reset(); for i in ring.indices { ring[i].reset() }
        rmsRing.reset(); rmsSupp.reset()
    }
}
