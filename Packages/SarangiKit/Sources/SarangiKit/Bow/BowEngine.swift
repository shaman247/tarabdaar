import Foundation
import CBowKernel

/// The LIVE bow-physics instrument: one streaming C friction kernel
/// (CBowKernel `bow_init`/`bow_process` — the SAME source as the offline
/// render, so the physics is byte-identical) at 96 kHz, decimated to the
/// 48 kHz engine rate and radiated through the offline post-chain order
/// (`render_bow_pair`): radiation FIR (N_rfir_48k, the 48 kHz redesign of the
/// pooled transfer) → E_lp radiation low-pass → room reverb. The kernel
/// output is ONE mono stream (taraf direct radiation is fused in-kernel);
/// stereo is an equal split so the L+R sum is pan-invariant like every other
/// mode. No capture curve live (live is its own neutral capture) and no
/// pre-roll/pre-charge (start from silence).
///
/// POLYPHONY (2026-07-16): `maxPoly` > 1 renders through the POLY kernel
/// (`bow_poly_*`, bow_kernel_poly.c): every mapper slot is its own gut
/// string with its own friction/delay-line state, all connected to the SAME
/// bridge — one taraf web, one modal body, one radiation/post chain; in the
/// passive junction each string's -Z·V loading is folded delay-free into
/// the bridge solve (structural stability at any polyphony). `maxPoly` 1
/// keeps the byte-parity MONO kernel and the exact legacy path — the
/// fixture/e2e confirm and all offline-parity goldens run there.
///
/// RT-safe: every buffer (control arrays, kernel scratch, decimator history,
/// FIR ring) is preallocated at init; `render` allocates nothing and takes
/// no locks (the mapper snapshot uses a brief unfair lock on the CONTROL
/// data only, the same pattern as ViolinVoiceControl). Structural changes
/// (tonic/raga/params) build a fresh BowEngine off the render thread and
/// swap it in with the SarangiEngine — the long-lived BowControlMapper keeps
/// held notes/axes across the swap.
public final class BowEngine {
    public let sr: Double                 // engine rate (48 kHz)
    public let osFactor: Int              // kernel oversampling (bow_os)
    public let srk: Double                // kernel rate
    public let tables: BowKernelTables
    /// Polyphony: number of gut strings on the shared bridge (1 = the
    /// byte-parity mono kernel; > 1 = the poly kernel, one string per
    /// mapper slot).
    public let maxPoly: Int

    /// Long-lived control mapper (owned by the host, shared across rebuilds).
    public let mapper: BowControlMapper
    var filter: BowControlFilter

    /// Live output level trim. The offline pipeline RMS-normalizes every
    /// render AFTER the chain; live has no normalizer, and the raw post-chain
    /// measures RMS ≈ 0.75 on melodic material at the 2026-07-14 Pilu bow
    /// operating point (bow_w 1.196, taraf_gain 3.435) — untrimmed it parks
    /// in the clipper. Recalibrated so the bow lands at the v57 instrument's
    /// live playing level (scale-probe RMS ≈ 0.03): switching instruments
    /// must not jump in loudness. 1.0 (neutral) for the fixture/e2e path.
    public static let liveLevelTrim = 0.04
    public var outGain = 1.0

    private var kernel: UnsafeMutableRawPointer?      // mono (maxPoly == 1)
    private var pkernel: UnsafeMutableRawPointer?     // poly (maxPoly > 1)
    private var dec: HalfBandDecimator
    private var radFIR: FIRFilter?
    private var radLp: Biquad?
    private var radHill: Biquad?
    /// Membrane radiation-efficiency LF rolloff (`bow_rad_hp`, ord/2 butter-2
    /// sections): a small unbaffled body cannot radiate far below its first
    /// skin mode — without it the joda fundamental accumulates +28 dB.
    private var radHP: [Biquad] = []
    /// Live twin of the offline fingerprint mask (nil = identity, dev
    /// checkout without the artifact). Applied POST-reverb like
    /// `render_bow_final` (the mask rides the full mix on the f0 timeline).
    var fpMask: BowFpMask?
    var reverb: Reverb

    // preallocated per-buffer scratch. Control arrays are SLOT-MAJOR at a
    // fixed allocation stride (maxFrames·osFactor); the mono path uses
    // slot 0's rows.
    private let maxFrames: Int
    private let slotStride: Int
    private var cF0: [Double], cVb: [Double], cFb: [Double]
    private var cBeta: [Double], cGate: [Double], cXv: [Double]
    private var cF0Snd: [Double]      // sounding pitch (pre-correction) — mask
    private var y96: [Double], y48: [Double]
    // poly per-slot state
    private var filters: [BowControlFilter] = []
    private var lastSerial: [UInt32] = []
    private var slotSilent: [Bool] = []
    private var polySnap: BowControlMapper.PolySnapshot

    /// `rfir` = the 48 kHz radiation FIR taps (empty ⇒ flat), `eLp` = the
    /// shared radiation low-pass corner (Hz; ≥ 0.44·sr ⇒ bypass) — the ONE
    /// body transfer every excitation radiates through.
    public init(tables: BowKernelTables, mapper: BowControlMapper,
                bp: BowParams, sr: Double = 48000.0,
                rfir: [Double], eLp: Double,
                reverbRT60: Double, reverbPredelayMs: Double,
                reverbMix: Double, reverbWidth: Double,
                fpMask: BowFpMask? = nil,
                maxFrames: Int = 4096,
                maxPoly: Int = 1) {
        self.sr = sr
        osFactor = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        // the decimation stage is the 2:1 HalfBandDecimator — at os 1 it
        // would leave the upper half of y48 stale, at os 4 it would decimate
        // at the wrong ratio (the python twin's resample_poly(1, os) takes
        // any factor). Both shipped artifacts run bow_os 2.
        precondition(osFactor == 2,
                     "bow_os \(osFactor) unsupported: the live decimator is 2:1")
        srk = sr * Double(osFactor)
        self.tables = tables
        self.mapper = mapper
        self.maxPoly = min(max(maxPoly, 1), BowControlMapper.maxSlots)
        // scalars[44] = f0Open = the tuning tonic (the nail-termination
        // reference; also the register-force reference in the filter)
        filter = BowControlFilter(bp: bp, srk: srk,
                                  tonic: tables.scalars.count > 44
                                      ? tables.scalars[44] : 261.63)
        dec = HalfBandDecimator()
        if !rfir.isEmpty { radFIR = FIRFilter(taps: rfir) }
        // bow_rad_lp_ord < 2 selects the one-pole rolloff (the generic
        // string's formula radiation); key absent → 2nd order (sarangi
        // path unchanged)
        if eLp > 0, eLp < 0.44 * sr {
            radLp = bp.v("bow_rad_lp_ord", 2.0) < 1.5
                ? Biquad.onePoleLowpass(fc: eLp, sr: sr)
                : Biquad.lowpass(fc: eLp, sr: sr)
        }
        let fHp = bp.v("bow_rad_hp", 0.0)
        if fHp > 1.0 {
            let nSec = max(1, Int(bp.v("bow_rad_hp_ord", 4.0)) / 2)
            radHP = (0..<nSec).map { _ in Biquad.highpass(fc: fHp, sr: sr) }
        }
        // BRIDGE HILL (2026-07-16h, the generic string): the bridge's own
        // rocking resonance — presence emphasis in the radiation path.
        // Key absent / 0 dB = off (sarangi path unchanged).
        let hillDb = bp.v("bow_hill_db", 0.0)
        if abs(hillDb) > 0.01 {
            radHill = Biquad.peaking(f0: bp.v("bow_hill_f", 2400.0),
                                     gainDB: hillDb,
                                     q: bp.v("bow_hill_q", 1.1), sr: sr)
        }
        self.fpMask = fpMask
        reverb = Reverb(rt60: reverbRT60, predelayMs: reverbPredelayMs,
                        mix: reverbMix, width: reverbWidth, sr: sr)
        self.maxFrames = maxFrames
        let nk = maxFrames * osFactor
        slotStride = nk
        let nPoly = self.maxPoly
        cF0 = [Double](repeating: 440.0, count: nk * nPoly)
        cVb = [Double](repeating: 0, count: nk * nPoly)
        cFb = [Double](repeating: 0, count: nk * nPoly)
        cBeta = [Double](repeating: 0.1, count: nk * nPoly)
        cGate = [Double](repeating: 0, count: nk * nPoly)
        cXv = [Double](repeating: 0, count: nk)   // additive voice force: zeros
        cF0Snd = [Double](repeating: 440.0, count: nk)
        y96 = [Double](repeating: 0, count: nk)
        y48 = [Double](repeating: 0, count: maxFrames)
        polySnap = BowControlMapper.PolySnapshot(count: nPoly)
        filters = [BowControlFilter](repeating: filter, count: nPoly)
        lastSerial = [UInt32](repeating: 0, count: nPoly)
        slotSilent = [Bool](repeating: false, count: nPoly)
        mapper.setSlotLimit(nPoly)

        let t = tables
        let s = t.scalars
        precondition(s.count == 61, "bow tables: expected 61 scalars, got \(s.count)")
        if nPoly > 1 {
            pkernel = bow_poly_init(
                Int32(nPoly), t.sr,
                Int32(t.L.count), t.L,
                t.cs, t.cp, t.w0, t.w1, t.w2, t.w3, t.w4, t.g, t.lpA, t.wout,
                t.kap, t.alphaw, t.jw, t.jl, t.jn, t.chg, t.zdrv, t.zi, t.twt,
                Int32(t.ba1.count), t.ba1, t.ba2, t.bn0, t.bA, t.bC,
                s[0], s[1], s[2],
                s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
                s[12], s[13], s[14],
                s[15], s[16], s[17], s[18], s[19], s[20], s[21],
                s[22], s[23], s[24], s[25],
                s[26], s[27], s[28], s[29],
                s[30], s[31], s[32],
                s[33], s[34], s[35], s[36], s[37],
                s[38], s[39], s[40],
                s[41], s[42], s[43], s[44], s[45], s[46],
                s[47], s[48], s[49],
                s[50], s[51],
                s[52], s[53],
                s[54], s[55],
                s[56], s[57],
                s[58], s[59], s[60])
        } else {
            kernel = bow_init(
                t.sr,
                Int32(t.L.count), t.L,
                t.cs, t.cp, t.w0, t.w1, t.w2, t.w3, t.w4, t.g, t.lpA, t.wout,
                t.kap, t.alphaw, t.jw, t.jl, t.jn, t.chg, t.zdrv, t.zi, t.twt,
                Int32(t.ba1.count), t.ba1, t.ba2, t.bn0, t.bA, t.bC,
                s[0], s[1], s[2],
                s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
                s[12], s[13], s[14],
                s[15], s[16], s[17], s[18], s[19], s[20], s[21],
                s[22], s[23], s[24], s[25],
                s[26], s[27], s[28], s[29],
                s[30], s[31], s[32],
                s[33], s[34], s[35], s[36], s[37],
                s[38], s[39], s[40],
                s[41], s[42], s[43], s[44], s[45], s[46],
                s[47], s[48], s[49],
                s[50], s[51],
                s[52], s[53],
                s[54], s[55],
                s[56], s[57],
                s[58], s[59], s[60])
        }
        // MODAL-JAWARI block (2026-07-21): loaded AFTER init — never
        // loading it keeps the kernel byte-null. ONE jt web at the
        // poly level (the hand-ported twin), the mono twin for tests.
        if let jt = t.jt, !jt.M.isEmpty {
            if let pk = pkernel {
                bow_poly_jt_load(pk, Int32(jt.M.count), jt.J, jt.M,
                                 jt.ca, jt.cb, jt.ca4, jt.cb4, jt.wd,
                                 jt.phiO, jt.phiD, jt.phiU, jt.phiF,
                                 jt.b, jt.G, jt.G4, jt.gd, jt.gd4,
                                 jt.phys, jt.q0)
                // pool spawn happens HERE (engine build) — never on
                // the audio thread; < 2 keeps the serial bit-exact path
                if jt.threads >= 2 {
                    bow_poly_jt_set_threads(pk, jt.threads)
                }
                // async live mode: callback never waits (dispatcher
                // thread + web FIFO; wash flat-fills under overload)
                if jt.async >= 1 {
                    bow_poly_jt_set_async(pk, 1)
                }
            } else if let k = kernel {
                bow_jt_load(k, Int32(jt.M.count), jt.J, jt.M,
                            jt.ca, jt.cb, jt.ca4, jt.cb4, jt.wd,
                            jt.phiO, jt.phiD, jt.phiU, jt.phiF,
                            jt.b, jt.G, jt.G4, jt.gd, jt.gd4,
                            jt.phys, jt.q0)
                if jt.threads >= 2 {
                    bow_jt_set_threads(k, jt.threads)
                }
            }
        }
    }

    /// async-jt telemetry: (dropped drive blocks, flat-filled samples,
    /// web-FIFO fill, async flag) — poly kernel only
    public func jtAsyncStats() -> (drops: Double, flat: Double,
                                   fill: Double, on: Double) {
        var s = [Double](repeating: 0, count: 4)
        if let pk = pkernel { bow_poly_jt_async_stats(pk, &s) }
        return (s[0], s[1], s[2], s[3])
    }

    deinit {
        if let k = kernel { bow_free(k) }
        if let pk = pkernel { bow_poly_free(pk) }
    }

    /// One render buffer: live controls → kernel chunk → decimate →
    /// radiation FIR → E_lp → reverb. Mono result split equally into (l, r)
    /// BEFORE the wet mix (matching the coupled path's channel plumbing).
    public func render(frames: Int, outL: UnsafeMutablePointer<Double>,
                       outR: UnsafeMutablePointer<Double>) {
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            if maxPoly > 1 {
                renderPolyChunk(n, outL: outL + done, outR: outR + done)
            } else {
                renderChunk(n, outL: outL + done, outR: outR + done)
            }
            done += n
        }
    }

    private func renderChunk(_ n: Int, outL: UnsafeMutablePointer<Double>,
                             outR: UnsafeMutablePointer<Double>) {
        let nk = n * osFactor
        cF0.withUnsafeMutableBufferPointer { f0 in
            cVb.withUnsafeMutableBufferPointer { vb in
                cFb.withUnsafeMutableBufferPointer { fb in
                    cBeta.withUnsafeMutableBufferPointer { be in
                        cGate.withUnsafeMutableBufferPointer { ga in
                            cF0Snd.withUnsafeMutableBufferPointer { fs in
                                filter.fill(from: mapper, n: nk,
                                            f0: f0.baseAddress!, vb: vb.baseAddress!,
                                            fb: fb.baseAddress!, beta: be.baseAddress!,
                                            gate: ga.baseAddress!,
                                            f0Snd: fs.baseAddress!)
                            }
                        }
                    }
                }
            }
        }
        renderControlChunk(nk: nk, n48: n, outL: outL, outR: outR)
    }

    /// Poly chunk: one mapper snapshot → per-slot control fills (fresh
    /// strings reset + pitch-snap; silent slots skipped) → the poly kernel →
    /// the same post-chain. The fingerprint mask rides the LEAD slot's
    /// sounding pitch (the melody string — newest gated note).
    private func renderPolyChunk(_ n: Int, outL: UnsafeMutablePointer<Double>,
                                 outR: UnsafeMutablePointer<Double>) {
        let nk = n * osFactor
        guard let pk = pkernel else {
            for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            return
        }
        mapper.snapshotPoly(into: &polySnap)
        let lead = polySnap.lead
        cF0.withUnsafeMutableBufferPointer { f0 in
            cVb.withUnsafeMutableBufferPointer { vb in
                cFb.withUnsafeMutableBufferPointer { fb in
                    cBeta.withUnsafeMutableBufferPointer { be in
                        cGate.withUnsafeMutableBufferPointer { ga in
                            cF0Snd.withUnsafeMutableBufferPointer { fs in
                                for s in 0..<maxPoly {
                                    let slot = polySnap.slots[s]
                                    if slot.serial != lastSerial[s] {
                                        lastSerial[s] = slot.serial
                                        bow_poly_reset_string(pk, Int32(s))
                                        filters[s].notePrime(f0Target: slot.f0Target)
                                    }
                                    let ringing = bow_poly_active(pk, Int32(s)) != 0
                                    if slot.gate <= 0.0, !ringing,
                                       filters[s].gateState < 1e-6 {
                                        // idle string: rows stay zeroed — the
                                        // kernel skips it whole
                                        if !slotSilent[s] {
                                            let o = s * slotStride
                                            for i in 0..<slotStride {
                                                fb.baseAddress![o + i] = 0
                                                ga.baseAddress![o + i] = 0
                                            }
                                            slotSilent[s] = true
                                        }
                                        continue
                                    }
                                    slotSilent[s] = false
                                    let snap = BowControlMapper.Snapshot(
                                        f0Target: slot.f0Target, gate: slot.gate,
                                        expr: polySnap.expr, press: polySnap.press,
                                        pos: polySnap.pos, tiltDb: polySnap.tiltDb,
                                        vib: polySnap.vib)
                                    let o = s * slotStride
                                    filters[s].fill(
                                        snapshot: snap, n: nk,
                                        f0: f0.baseAddress! + o,
                                        vb: vb.baseAddress! + o,
                                        fb: fb.baseAddress! + o,
                                        beta: be.baseAddress! + o,
                                        gate: ga.baseAddress! + o,
                                        f0Snd: s == lead ? fs.baseAddress! : nil)
                                }
                            }
                        }
                    }
                }
            }
        }
        y96.withUnsafeMutableBufferPointer { yb in
            bow_poly_process(pk, Int32(nk), Int32(slotStride),
                             cF0, cVb, cFb, cBeta, cGate, cXv,
                             yb.baseAddress!)
            y48.withUnsafeMutableBufferPointer { ob in
                dec.process(yb.baseAddress!, count: nk, into: ob.baseAddress!)
            }
        }
        postChain(n48: n, outL: outL, outR: outR)
    }

    /// Kernel + post-chain over already-filled control scratch (mono
    /// kernel). Also the fixture entry (`renderFixture`) so the end-to-end
    /// confirm exercises EXACTLY the live buffer path.
    private func renderControlChunk(nk: Int, n48: Int,
                                    outL: UnsafeMutablePointer<Double>,
                                    outR: UnsafeMutablePointer<Double>) {
        guard let k = kernel else {
            for i in 0..<n48 { outL[i] = 0; outR[i] = 0 }
            return
        }
        y96.withUnsafeMutableBufferPointer { yb in
            bow_process(k, Int32(nk), cF0, cVb, cFb, cBeta, cGate, cXv,
                        yb.baseAddress!)
            y48.withUnsafeMutableBufferPointer { ob in
                dec.process(yb.baseAddress!, count: nk, into: ob.baseAddress!)
            }
        }
        postChain(n48: n48, outL: outL, outR: outR)
    }

    /// The shared 48 kHz post-chain over y48: radiation FIR → E_lp →
    /// bow_rad_hp sections → reverb → fingerprint mask → equal L/R split.
    private func postChain(n48: Int, outL: UnsafeMutablePointer<Double>,
                           outR: UnsafeMutablePointer<Double>) {
        for i in 0..<n48 {
            var x = y48[i]
            if radFIR != nil { x = radFIR!.process(x) }
            if radLp != nil { x = radLp!.process(x) }
            for s in radHP.indices { x = radHP[s].process(x) }
            if radHill != nil { x = radHill!.process(x) }
            let wet = reverb.processMono(x)
            y48[i] = x + wet
        }
        // fingerprint mask rides the FULL mix post-reverb (offline order),
        // tracking the SOUNDING pitch (pre-correction — the knot correction
        // cancels the friction pull, so the string sounds at lf0B)
        if fpMask != nil {
            y48.withUnsafeMutableBufferPointer { yb in
                cF0Snd.withUnsafeBufferPointer { fb in
                    fpMask!.process(yb.baseAddress!, n: n48,
                                    f0: fb.baseAddress!, f0Stride: osFactor)
                }
            }
        }
        for i in 0..<n48 {
            let half = 0.5 * outGain * y48[i]
            outL[i] = half
            outR[i] = half
        }
    }

    /// Fixture/e2e entry: render EXPLICIT kernel-rate control arrays through
    /// the same buffer path the live render uses (kernel → decimate → FIR →
    /// E_lp → reverb). `n96` must be `2·frames` and ≤ the preallocated
    /// scratch per call — the caller chunks (1024-sample engine buffers).
    /// With `maxPoly` > 1 the controls drive string 0 of the poly kernel
    /// (the other strings stay silent/skipped).
    public func renderFixture(f0: [Double], vb: [Double], fb: [Double],
                              beta: [Double], gate: [Double],
                              outL: UnsafeMutablePointer<Double>,
                              outR: UnsafeMutablePointer<Double>) {
        let nk = f0.count
        precondition(nk % osFactor == 0 && nk <= maxFrames * osFactor)
        for i in 0..<nk {
            cF0[i] = f0[i]; cVb[i] = vb[i]; cFb[i] = fb[i]
            cBeta[i] = beta[i]; cGate[i] = gate[i]
            cF0Snd[i] = f0[i]     // explicit controls: mask rides the input
        }
        if let pk = pkernel {
            y96.withUnsafeMutableBufferPointer { yb in
                bow_poly_process(pk, Int32(nk), Int32(slotStride),
                                 cF0, cVb, cFb, cBeta, cGate, cXv,
                                 yb.baseAddress!)
                y48.withUnsafeMutableBufferPointer { ob in
                    dec.process(yb.baseAddress!, count: nk, into: ob.baseAddress!)
                }
            }
            postChain(n48: nk / osFactor, outL: outL, outR: outR)
        } else {
            renderControlChunk(nk: nk, n48: nk / osFactor, outL: outL, outR: outR)
        }
    }

    public func reset() {
        // The kernel state (string charge, rosin temperatures) is the
        // INSTRUMENT's physical state — a reset rebuilds it from silence.
        dec.reset()
        radFIR?.reset()
        radLp?.reset()
        radHill?.reset()
        for i in radHP.indices { radHP[i].reset() }
        fpMask?.reset()
        reverb.reset()
        filter.reset()
        for i in filters.indices { filters[i].reset() }
        for i in slotSilent.indices { slotSilent[i] = false }
    }
}
