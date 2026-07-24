import Foundation
import CBowKernel

/// The LIVE bow-physics instrument: one streaming C friction kernel
/// (CBowKernel `bow_init`/`bow_process` — the SAME source as the offline
/// render, so the physics is byte-identical) at 96 kHz, decimated to the
/// 48 kHz engine rate and radiated through the offline post-chain order
/// (`render_bow_pair`): radiation FIR (N_rfir_48k, the 48 kHz redesign of the
/// pooled transfer) → E_lp radiation low-pass → room reverb. The kernel
/// output is ONE mono stream (taraf direct radiation is fused in-kernel);
/// by default stereo is an equal split so the L+R sum is pan-invariant like
/// every other mode. With `bow_st_spread`/`bow_st_played` armed (Starpad
/// live, 2026-07-23) the POLY kernel adds a physically-derived SIDE stream
/// — per-source pans across the bridge — and L/R = mid ± side; the L+R
/// fold-down still equals the mono output exactly. No capture curve live
/// (live is its own neutral capture) and no pre-roll/pre-charge (start
/// from silence).
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
    public var outGain = 1.0 {
        didSet { if !gainPrimed { gainPrev = outGain; gainPrimed = true } }
    }
    /// Output gain at the END of the previous chunk — `postChain`
    /// interpolates from it so a gain change never steps the waveform.
    private var gainPrev = 1.0
    private var gainPrimed = false

    private var kernel: UnsafeMutableRawPointer?      // mono (maxPoly == 1)
    private var pkernel: UnsafeMutableRawPointer?     // poly (maxPoly > 1)
    private var dec: HalfBandDecimator
    private var radFIR: FIRFilter?
    private var radLp: Biquad?
    private var radHill: Biquad?
    /// STARPAD STEREO SIDE PATH (2026-07-23): the poly kernel renders a
    /// second SIDE stream carrying only the DIRECT radiation — the taraf
    /// strings' direct tap, the modal-jawari rows' own radiation (drones
    /// included), and the bow-contact noise — each panned by PITCH CLASS
    /// around the tonic (spread·sin(2π·pc): tonic centre-stage, svaras
    /// at fixed symmetric places, octaves share a place — see the pan
    /// rationale at the arming site). Bridge-borne energy (played force,
    /// driven web resonance) radiates from the one central body and stays
    /// mid-only, so the image is a spread halo around a centred voice.
    /// The side rides its own decimator + radiation-chain twins here, then
    /// L = mid + side, R = mid − side — the L+R fold-down is bit-identical
    /// to the legacy mono output. Armed only when `bow_st_spread` /
    /// `bow_st_played` are present and nonzero (keys absent from the
    /// artifact ⇒ every golden/parity test keeps the exact mono path);
    /// Starpad's live build seeds them in `buildEngine`.
    private var stereoOn = false
    private var decS = HalfBandDecimator()
    private var radFIRS: FIRFilter?
    private var radLpS: Biquad?
    private var radHillS: Biquad?
    private var radHPS: [Biquad] = []
    /// Membrane radiation-efficiency LF rolloff (`bow_rad_hp`, ord/2 butter-2
    /// sections): a small unbaffled body cannot radiate far below its first
    /// skin mode — without it the joda fundamental accumulates +28 dB.
    private var radHP: [Biquad] = []
    /// Live twin of the offline fingerprint mask (nil = identity, dev
    /// checkout without the artifact). Applied POST-reverb like
    /// `render_bow_final` (the mask rides the full mix on the f0 timeline).
    var fpMask: BowFpMask?
    var reverb: Reverb

    // ---- Tilt performance axes (2026-07-23 evening) ----
    // Three iPad-tilt-driven runtime controls (CC71/73/72 through the
    // host): taraf PURITY (jawari bone lift — kernel), taraf DECAY
    // (extra momentum damping — kernel), and TONE TILT (complementary
    // shelf pair on the whole voice output — here). The kernel axes are
    // plain control-thread scalar writes (the drone-setter contract);
    // the tone tilt smooths per render chunk and swaps shelf
    // coefficients IN PLACE (state kept — the VoiceFX click-free
    // pattern). All three are off by default (byte-null).
    private let tiltPureLiftMax: Double     // bow_tilt_pure_lift
    private var tiltPureLpHiHz = 16000.0    // axis-0 corner (build LP or open)
    private var jtLpBaseA = 0.0             // build-time jt LP coeff (≤0 bypass)
    private var jtTickRate = 48000.0        // jt tick rate (srk / bow_jt_div)
    private let tiltDampMinT60: Double      // bow_tilt_damp_min_t60
    private let tiltDampMaxT60: Double      // bow_tilt_damp_max_t60
    private let tiltEqDbMax: Double         // bow_tilt_eq_db
    private let tiltEqLoHz: Double          // bow_tilt_eq_lo
    private let tiltEqHiHz: Double          // bow_tilt_eq_hi
    private var tiltLock = os_unfair_lock()
    // kernel-axis smoothers (2026-07-23 night, the mid-tilt click fix):
    // targets are control-thread writes; the render thread smooths at
    // chunk rate and pushes the kernel scalars only when they move
    private var jawGainTarget = 1.0         // bow_jaw_gain (1 = fitted buzz)
    private var jawGainCur = 1.0
    private var jawGainPushed = 1.0
    private var jtLpHzTarget = 0.0          // bow_jt_lp runtime (0 = build)
    private var jtLpHzCur = 16000.0         // synced to tiltPureLpHiHz at load
    private var jtLpHzPushed = 16000.0
    private var jtLpEngaged = false
    private var dampAmtTarget = 0.0         // bow_jt_damp (0 = natural ring)
    private var dampAmtCur = 0.0
    private var dampAmtPushed = 0.0
    private var toneTiltTarget = 0.0        // control-thread write
    private var toneTiltCur = 0.0           // render-thread smoother
    private var toneTiltApplied = 0.0       // shelves built for this value
    private var tiltEqActive = false
    private var tiltLoShelf: Biquad
    private var tiltHiShelf: Biquad
    /// Side twins of the tilt shelves (same coefficients, independent
    /// state — the radiation-twin pattern): the stereo post-chain EQs
    /// mid AND side identically, which by linearity equals EQing L/R,
    /// so the tilt never collapses the image toward the middle.
    private var tiltLoShelfS: Biquad
    private var tiltHiShelfS: Biquad

    // preallocated per-buffer scratch. Control arrays are SLOT-MAJOR at a
    // fixed allocation stride (maxFrames·osFactor); the mono path uses
    // slot 0's rows.
    private let maxFrames: Int
    private let slotStride: Int
    private var cF0: [Double], cVb: [Double], cFb: [Double]
    private var cBeta: [Double], cGate: [Double], cXv: [Double]
    private var cF0Snd: [Double]      // sounding pitch (pre-correction) — mask
    private var y96: [Double], y48: [Double]
    private var y96S: [Double], y48S: [Double]   // stereo side scratch
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
        y96S = [Double](repeating: 0, count: nk)
        y48S = [Double](repeating: 0, count: maxFrames)
        polySnap = BowControlMapper.PolySnapshot(count: nPoly)
        filters = [BowControlFilter](repeating: filter, count: nPoly)
        lastSerial = [UInt32](repeating: 0, count: nPoly)
        slotSilent = [Bool](repeating: false, count: nPoly)
        mapper.setSlotLimit(nPoly)

        let t = tables
        let s = t.scalars
        precondition(s.count == 61, "bow tables: expected 61 scalars, got \(s.count)")
        // Starting point for the live-parameter ramp (see applyPendingLive).
        liveScalarsCur = s
        liveScalarsTarget = s
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
        // Drone-row excitation scalars (Starpad drone buttons; not in
        // the artifact — bp defaults, overridable via `string.<key>`).
        droneLevel = bp.v("bow_drone_level", 0.08)
        droneOnset = bp.v("bow_drone_onset", 0.3)
        droneAttackSec = bp.v("bow_drone_attack_ms", 40.0) / 1000.0
        droneReleaseSec = bp.v("bow_drone_release_ms", 60.0) / 1000.0
        droneOnsetDecaySec = bp.v("bow_drone_onset_decay_ms", 200.0) / 1000.0
        droneCompCents = bp.v("bow_drone_comp_cents", 15.5)
        // Tilt-axis ranges (not in the artifact — bp defaults,
        // overridable via `string.<key>` like the drone scalars).
        tiltPureLiftMax = bp.v("bow_tilt_pure_lift", 8.0)
        tiltDampMinT60 = bp.v("bow_tilt_damp_min_t60", 0.25)
        tiltDampMaxT60 = bp.v("bow_tilt_damp_max_t60", 20.0)
        tiltEqDbMax = bp.v("bow_tilt_eq_db", 9.0)
        tiltEqLoHz = bp.v("bow_tilt_eq_lo", 300.0)
        tiltEqHiHz = bp.v("bow_tilt_eq_hi", 2400.0)
        tiltLoShelf = Biquad.lowShelf(f0: bp.v("bow_tilt_eq_lo", 300.0),
                                      gainDB: 0.0, sr: sr)
        tiltHiShelf = Biquad.highShelf(f0: bp.v("bow_tilt_eq_hi", 2400.0),
                                       gainDB: 0.0, sr: sr)
        tiltLoShelfS = tiltLoShelf
        tiltHiShelfS = tiltHiShelf
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
                // jt tone LP (bow_jt_lp): unarmed = bit-exact legacy
                if jt.lpA > 0 {
                    bow_poly_jt_set_lp(pk, jt.lpA)
                }
                // drone-row envelope times (gradual attack — the whole
                // excitation is a slewed noise drive, no impulse)
                bow_poly_jt_drone_env(pk, droneAttackSec, droneReleaseSec,
                                      droneOnsetDecaySec)
            } else if let k = kernel {
                bow_jt_load(k, Int32(jt.M.count), jt.J, jt.M,
                            jt.ca, jt.cb, jt.ca4, jt.cb4, jt.wd,
                            jt.phiO, jt.phiD, jt.phiU, jt.phiF,
                            jt.b, jt.G, jt.G4, jt.gd, jt.gd4,
                            jt.phys, jt.q0)
                if jt.threads >= 2 {
                    bow_jt_set_threads(k, jt.threads)
                }
                if jt.lpA > 0 {
                    bow_jt_set_lp(k, jt.lpA)
                }
                bow_jt_drone_env(k, droneAttackSec, droneReleaseSec,
                                 droneOnsetDecaySec)
            }
            // purity LP-sweep references (2026-07-23 night): the axis
            // sweeps the radiated-jt tone LP corner from the build
            // corner (or open) down to bow_tilt_pure_lp
            let div = jt.phys.count > 6 ? max(1.0, jt.phys[6].rounded()) : 1.0
            jtTickRate = srk / div
            jtLpBaseA = jt.lpA
            tiltPureLpHiHz = jt.lpA > 0
                ? -log(1.0 - min(jt.lpA, 0.999999)) * jtTickRate
                    / (2.0 * Double.pi)
                : min(16000.0, 0.45 * jtTickRate)
            jtLpHzCur = tiltPureLpHiHz
            jtLpHzPushed = tiltPureLpHiHz
        }
        // STARPAD STEREO SIDE PATH (2026-07-23): arm the poly kernel's
        // side stream with per-source pans by PITCH CLASS around the
        // tonic — pan = spread·sin(2π·pc). The tonic (and every octave
        // of it) rings centre-stage; the other svaras take fixed places
        // symmetrically around it (the ascending scale sweeps left then
        // right, Ma ↔ Pa mirrored), and octave rows share a place. A
        // plain low→high rank map was tried first and REJECTED: the
        // audible ring concentrates in the playing register + the low
        // drone rows, so the energy centroid parks 6–10 dB off-centre
        // (measured stereo_on2/3 auditions) — the class circle balances
        // around the tonal centre by construction while every string
        // keeps one stable position. Must run AFTER the jt load (row
        // pans need njt). Keys absent / 0 (the artifact ships neither)
        // ⇒ never armed — the exact legacy mono path.
        let stSpread = bp.v("bow_st_spread", 0.0)
        let stPlayed = bp.v("bow_st_played", 0.0)
        if let pk = pkernel, fpMask == nil,
           stSpread > 1e-6 || stPlayed > 1e-6 {
            let tonic = tables.scalars.count > 44 ? tables.scalars[44]
                                                  : 261.63
            func pcPans(_ freqs: [Double], spread: Double) -> [Double] {
                freqs.map { f in
                    guard f > 0, tonic > 0 else { return 0.0 }
                    var pc = log2(f / tonic)
                        .truncatingRemainder(dividingBy: 1.0)
                    if pc < 0 { pc += 1.0 }
                    return spread * sin(2.0 * Double.pi * pc)
                }
            }
            let webPan = pcPans(t.L.map { srk / Double(max(Int($0), 2)) },
                                spread: stSpread)
            let jtPan = pcPans(t.jt?.rowFreqs ?? [], spread: stSpread)
            // played strings: small symmetric per-slot spread (a hand's
            // width on the bridge — the melody stays anchored near centre)
            var slotPan = [Double](repeating: 0, count: nPoly)
            if nPoly > 1 {
                for s in 0..<nPoly {
                    slotPan[s] = stPlayed
                        * (2.0 * Double(s) / Double(nPoly - 1) - 1.0)
                }
            }
            bow_poly_set_stereo(pk, webPan, Int32(webPan.count),
                                jtPan.isEmpty ? nil : jtPan,
                                Int32(jtPan.count),
                                slotPan, Int32(nPoly))
            // side twins of the radiation chain (same coefficients,
            // independent state — linearity keeps mid/side consistent)
            if !rfir.isEmpty { radFIRS = FIRFilter(taps: rfir) }
            if eLp > 0, eLp < 0.44 * sr {
                radLpS = bp.v("bow_rad_lp_ord", 2.0) < 1.5
                    ? Biquad.onePoleLowpass(fc: eLp, sr: sr)
                    : Biquad.lowpass(fc: eLp, sr: sr)
            }
            if fHp > 1.0 {
                let nSec = max(1, Int(bp.v("bow_rad_hp_ord", 4.0)) / 2)
                radHPS = (0..<nSec).map { _ in
                    Biquad.highpass(fc: fHp, sr: sr)
                }
            }
            if abs(hillDb) > 0.01 {
                radHillS = Biquad.peaking(f0: bp.v("bow_hill_f", 2400.0),
                                          gainDB: hillDb,
                                          q: bp.v("bow_hill_q", 1.1),
                                          sr: sr)
            }
            stereoOn = true
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

    // MARK: - Drone rows (2026-07-23)

    /// The jawari-taraf row fundamentals (Hz) in kernel order — empty when
    /// the jt block is off.
    public var jtRowFreqs: [Double] { tables.jt?.rowFreqs ?? [] }

    /// The tuning tonic (scalars[44] = f0Open — the open-string reference).
    public var tonicHz: Double {
        tables.scalars.count > 44 ? tables.scalars[44] : 261.63
    }

    /// Drone excitation scalars — set by the host from the
    /// artifact/overrides at build, applied per press. The whole
    /// excitation is a slewed filtered-noise drive (gradual-attack rev,
    /// no impulse): the envelope swells toward `droneLevel + droneOnset`
    /// over `droneAttackSec`, the onset boost decays over
    /// `droneOnsetDecaySec`, and release falls over `droneReleaseSec`
    /// (then the row rings out on its own t60). Level calibrated
    /// 2026-07-23 (audition drone_cal3): sustain RMS ≈ 0.02, just under
    /// the played voice's ≈ 0.03.
    public var droneLevel = 0.08
    /// Onset-boost drive amplitude (`bow_drone_onset`) — the swell peaks
    /// near level+onset before relaxing into the sustain.
    public var droneOnset = 0.3
    /// Envelope times (`bow_drone_attack_ms` / `_release_ms` /
    /// `_onset_decay_ms`); pushed to the kernel at build (jt load).
    public var droneAttackSec = 0.04
    public var droneReleaseSec = 0.06
    public var droneOnsetDecaySec = 0.20
    /// Jawari-contact detuning compensation (`bow_drone_comp_cents`): a jt
    /// row RINGS ~15.5 c sharp of its nominal table frequency — the grazing
    /// bone stiffens the termination (measured 2026-07-23: +13.5…+16.1 c,
    /// uniform across rows). Drone rows are tuned nominal = requested ÷
    /// this shift so the SOUNDING pitch lands on the request.
    public var droneCompCents = 15.5

    /// The jt row for a requested SOUNDING pitch: the target nominal is
    /// `hz` compensated for the jawari-contact sharpening, then matched
    /// pitch-class first (see `droneRow(nearestToHz:)`). The engine build
    /// guarantees a row exists at the target (`buildEngine(droneHz:)`).
    public func droneRow(forRequestedHz hz: Double) -> Int? {
        droneRow(nearestToHz: hz * pow(2.0, -droneCompCents / 1200.0))
    }

    /// The jt row for a requested pitch — **always an existing modal-jawari
    /// string**, matched PITCH-CLASS FIRST: rows within ±60 cents of the
    /// requested pitch class (octave-folded) are preferred, and among them
    /// the one nearest the requested octave wins; with no class match the
    /// plain nearest row (log pitch) is used. So a drone set to ,m sounds
    /// the Ma string even when the taraf carries no low-octave Ma row.
    public func droneRow(nearestToHz hz: Double) -> Int? {
        let freqs = jtRowFreqs
        guard hz > 0, !freqs.isEmpty else { return nil }
        func pcCents(_ f: Double) -> Double {
            var c = (1200.0 * log2(f / hz)).truncatingRemainder(dividingBy: 1200.0)
            if c < -600 { c += 1200 } else if c > 600 { c -= 1200 }
            return abs(c)
        }
        let classMatch = freqs.indices.filter { pcCents(freqs[$0]) < 60 }
        let pool = classMatch.isEmpty ? Array(freqs.indices) : classMatch
        return pool.min {
            abs(log2(freqs[$0] / hz)) < abs(log2(freqs[$1] / hz))
        }
    }

    /// Press a drone: swell the row's sustain drive (attack slew + the
    /// decaying onset boost). Safe from the control thread while the
    /// audio/jt threads render.
    public func dronePress(row: Int) {
        if let pk = pkernel {
            bow_poly_jt_pluck(pk, Int32(row), droneOnset)
            bow_poly_jt_drone(pk, Int32(row), droneLevel)
        } else if let k = kernel {
            bow_jt_pluck(k, Int32(row), droneOnset)
            bow_jt_drone(k, Int32(row), droneLevel)
        }
    }

    /// Release a drone: drop the sustain drive; the row rings out on its
    /// own t60.
    public func droneRelease(row: Int) {
        if let pk = pkernel {
            bow_poly_jt_drone(pk, Int32(row), 0.0)
        } else if let k = kernel {
            bow_jt_drone(k, Int32(row), 0.0)
        }
    }

    // MARK: - Runtime base parameters (2026-07-24 composite rework)

    /// WEB BUZZ AMOUNT 0..1 (base parameter `bow_jaw_gain`): scales the
    /// formula-taraf web's buzz sources (jn contact/fold + jw grazing).
    /// 1 = the fitted buzz (byte-exact), 0 = none. The jl in-loop loss
    /// stays full (self-limits hot rings). Smoothed at chunk rate on the
    /// render thread; safe from the control thread while rendering.
    public func setJawGain(_ g01: Double) {
        os_unfair_lock_lock(&tiltLock)
        jawGainTarget = min(max(g01, 0.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// RADIATED-JT TONE LP corner in Hz (base parameter `bow_jt_lp`,
    /// runtime path): brightness of the modal-jawari buzz. <= 0 restores
    /// the exact build-time state (bypass when unarmed). The filter is
    /// state-preserving (click-free coefficient moves; warm bypass).
    /// The jt bones NEVER move at runtime — releasing the static wrap
    /// is an unavoidable jawari strum (`bow_jt_set_lift` stays
    /// offline-only). Smoothed at chunk rate.
    public func setJtToneLp(hz: Double) {
        os_unfair_lock_lock(&tiltLock)
        jtLpHzTarget = hz > 0
            ? min(max(hz, 40.0), tiltPureLpHiHz) : 0.0
        os_unfair_lock_unlock(&tiltLock)
    }

    /// TARAF DAMPING amount 0..1 (base parameter `bow_jt_damp`): 0 = the
    /// natural ring (off, byte-exact), rising = extra momentum damping,
    /// t60 log-interpolated `bow_tilt_damp_max_t60` (20 s) down to
    /// `bow_tilt_damp_min_t60` (0.25 s — choked within a second).
    /// Smoothed at chunk rate.
    public func setTarafDamp(_ amt01: Double) {
        os_unfair_lock_lock(&tiltLock)
        dampAmtTarget = min(max(amt01, 0.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    // MARK: - Live parameters (Starpad 2026-07-24)

    /// A parameter edit staged by the control thread, applied at the next
    /// chunk boundary on the render thread. `scalars` is the freshly built
    /// 61-element kernel vector; `bp` re-seeds the Swift-side mapping
    /// constants (playing ranges, articulation, vibrato) and the
    /// output/radiation/room settings. Guarded by `tiltLock`.
    private var pendingLive: (bp: BowParams, scalars: [Double],
                              tables: BowKernelTables?)?

    /// Apply a parameter edit WITHOUT rebuilding: the kernel's per-sample
    /// scalars are overwritten in place and the Swift-side constants
    /// re-read, leaving every piece of running state (string histories,
    /// taraf ring, jawari web, room tail, note articulation) intact.
    /// Control-thread safe; takes effect at the next chunk.
    ///
    /// Only covers what does not resize a table — the caller
    /// (`ParamRegistry`) owns that classification; anything structural
    /// still needs a fresh engine.
    /// Seed the gain ramp from the engine's current output settings.
    /// `buildEngine` assigns `outGain` after init, so this is called once
    /// the engine is fully configured.
    public func seedLiveGains() {
        liveGainCur = (trim: outGain, mix: reverb.mix, width: reverb.width)
        liveGainTarget = liveGainCur
    }

    /// `tables` (stage 3) additionally reloads the BODY modal bank and the
    /// modal-jawari coefficients in place. Pass nil to move scalars only.
    /// The kernel refuses a reload whose shape moved, in which case the
    /// engine keeps its current tables — the caller must rebuild, and
    /// `ParamRegistry.inPlaceKeys` is what guarantees that never happens.
    public func setLiveParams(bp: BowParams, scalars: [Double],
                              tables: BowKernelTables? = nil) {
        guard scalars.count == 61 else { return }
        // Arm the RAMP only when a ramped quantity actually moved. The
        // ramp caps `render`'s chunk to 256 frames, and chunk size is NOT
        // neutral: it sets the control-interpolation grid and the jt
        // block boundaries, so splitting a 4096-frame offline render
        // perturbs a chaotic friction loop (measured 41% of peak for a
        // no-op push before this check). Coefficient reloads need no ramp
        // — swapping filter coefficients while keeping state is
        // click-free — so a tables-only edit does not arm it either.
        let gains = (trim: bp.v("bow_live_trim", outGain),
                     mix: bp.v("bow_rev_mix", reverb.mix),
                     width: bp.v("bow_rev_width", reverb.width))
        os_unfair_lock_lock(&tiltLock)
        let ramped = scalars != liveScalarsTarget
            || abs(gains.trim - liveGainTarget.trim) > 1e-12
            || abs(gains.mix - liveGainTarget.mix) > 1e-12
            || abs(gains.width - liveGainTarget.width) > 1e-12
        if !ramped, tables == nil, pendingLive == nil {
            os_unfair_lock_unlock(&tiltLock)
            return                                   // nothing to do
        }
        pendingLive = (bp, scalars, tables)
        // Armed HERE, not when the render thread picks the edit up: the
        // chunk cap in `render` has to apply to the FIRST chunk after the
        // push, or that chunk resolves most of the glide in one step.
        if ramped { liveRampArmed = true }
        os_unfair_lock_unlock(&tiltLock)
    }

    /// STAGE 3: swap the body-modal and jawari coefficient arrays on the
    /// running kernel. Histories are kept on both (the resonator states
    /// and the jawari wrap), so this is click-free for the body and a
    /// physically-correct relaxation for the web. Not ramped: these are
    /// filter coefficients, not gains — the same reasoning as the
    /// radiation biquads.
    private func reloadCoefficients(_ t: BowKernelTables) {
        let target: UnsafeMutableRawPointer? = pkernel ?? kernel
        guard let st = target else { return }
        let poly = pkernel != nil
        t.ba1.withUnsafeBufferPointer { a1 in
            t.ba2.withUnsafeBufferPointer { a2 in
                t.bn0.withUnsafeBufferPointer { n0 in
                    t.bA.withUnsafeBufferPointer { bA in
                        t.bC.withUnsafeBufferPointer { bC in
                            let k = Int32(t.ba1.count)
                            _ = poly
                                ? bow_poly_set_body(st, k, a1.baseAddress,
                                                    a2.baseAddress,
                                                    n0.baseAddress,
                                                    bA.baseAddress,
                                                    bC.baseAddress)
                                : bow_set_body(st, k, a1.baseAddress,
                                               a2.baseAddress, n0.baseAddress,
                                               bA.baseAddress, bC.baseAddress)
                        }
                    }
                }
            }
        }
        guard let jt = t.jt, jt.M.count > 0 else { return }
        jt.M.withUnsafeBufferPointer { M in
        jt.ca.withUnsafeBufferPointer { ca in
        jt.cb.withUnsafeBufferPointer { cb in
        jt.ca4.withUnsafeBufferPointer { ca4 in
        jt.cb4.withUnsafeBufferPointer { cb4 in
        jt.wd.withUnsafeBufferPointer { wd in
        jt.phiO.withUnsafeBufferPointer { phiO in
        jt.phiD.withUnsafeBufferPointer { phiD in
        jt.phiU.withUnsafeBufferPointer { phiU in
        jt.phiF.withUnsafeBufferPointer { phiF in
        jt.b.withUnsafeBufferPointer { b in
        jt.G.withUnsafeBufferPointer { G in
        jt.G4.withUnsafeBufferPointer { G4 in
        jt.gd.withUnsafeBufferPointer { gd in
        jt.gd4.withUnsafeBufferPointer { gd4 in
        jt.phys.withUnsafeBufferPointer { phys in
            let n = Int32(jt.M.count), J = jt.J
            if poly {
                _ = bow_poly_jt_set_coeffs(st, n, J, M.baseAddress,
                    ca.baseAddress, cb.baseAddress, ca4.baseAddress,
                    cb4.baseAddress, wd.baseAddress, phiO.baseAddress,
                    phiD.baseAddress, phiU.baseAddress, phiF.baseAddress,
                    b.baseAddress, G.baseAddress, G4.baseAddress,
                    gd.baseAddress, gd4.baseAddress, phys.baseAddress)
            } else {
                _ = bow_jt_set_coeffs(st, n, J, M.baseAddress,
                    ca.baseAddress, cb.baseAddress, ca4.baseAddress,
                    cb4.baseAddress, wd.baseAddress, phiO.baseAddress,
                    phiD.baseAddress, phiU.baseAddress, phiF.baseAddress,
                    b.baseAddress, G.baseAddress, G4.baseAddress,
                    gd.baseAddress, gd4.baseAddress, phys.baseAddress)
            }
        }}}}}}}}}}}}}}}}
    }

    /// Current / target kernel scalar vectors. The push is RAMPED rather
    /// than applied in one step: several of the 61 scalars multiply the
    /// signal (`bowW` drive weight, `c0` radiation floor, `tdirect` taraf
    /// tap), so an instantaneous change lands as a step in the waveform.
    /// Measured before this ramp existed: a +17 dB `bow_live_trim` jump
    /// produced a seam 17.9x the signal's own largest sample-to-sample
    /// motion — an audible click. Friction coefficients (`mu_s`, `v0`, …)
    /// do NOT need this — they change how the string evolves, not the
    /// current sample — but ramping everything together is simpler than
    /// classifying, and 25 ms is inaudible on the rest.
    private var liveScalarsCur: [Double] = []
    private var liveScalarsTarget: [Double] = []
    private var liveGainCur = (trim: 1.0, mix: 0.0, width: 0.0)
    private var liveGainTarget = (trim: 1.0, mix: 0.0, width: 0.0)
    private var liveRamping = false
    /// Set by `setLiveParams` under `tiltLock`, cleared when the glide
    /// settles. Read by `render` to cap its chunk size.
    private var liveRampArmed = false

    /// Render-thread half of `setLiveParams`: adopt a new target, then
    /// glide toward it at chunk rate.
    private func applyPendingLive(n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let pending = pendingLive
        pendingLive = nil
        os_unfair_lock_unlock(&tiltLock)

        if let (bp, scalars, tables) = pending {
            liveScalarsTarget = scalars
            if liveScalarsCur.count != scalars.count {
                liveScalarsCur = scalars          // first push: no history
            }
            // Control-side constants step immediately: they shape the
            // mapping into the friction loop, which absorbs a step (a
            // 60 Hz staircase on `bow_mu_s` measured +0.06 dB of HF).
            for i in filters.indices { filters[i].updateLiveParams(bp: bp) }
            filter.updateLiveParams(bp: bp)
            if let t = tables { reloadCoefficients(t) }
            liveGainTarget = (trim: bp.v("bow_live_trim", outGain),
                              mix: bp.v("bow_rev_mix", reverb.mix),
                              width: bp.v("bow_rev_width", reverb.width))
            // Radiation corners: coefficients move, filter STATE stays, so
            // these are click-free without a ramp.
            let lp = bp.v("bow_rad_lp", 0.0)
            if lp > 0, lp < 0.44 * sr {
                let ord2 = bp.v("bow_rad_lp_ord", 2.0) >= 1.5
                let fresh = ord2 ? Biquad.lowpass(fc: lp, sr: sr)
                                 : Biquad.onePoleLowpass(fc: lp, sr: sr)
                radLp?.copyCoefficients(from: fresh)
                radLpS?.copyCoefficients(from: fresh)
            }
            let hp = bp.v("bow_rad_hp", 0.0)
            if hp > 0, hp < 0.44 * sr {
                let fresh = Biquad.highpass(fc: hp, sr: sr)
                for i in radHP.indices { radHP[i].copyCoefficients(from: fresh) }
                for i in radHPS.indices { radHPS[i].copyCoefficients(from: fresh) }
            }
            liveRamping = true
        }

        guard liveRamping, !liveScalarsTarget.isEmpty else { return }
        // ~25 ms one-pole glide, same shape as the taraf-axis smoother.
        let a = 1.0 - exp(-Double(n48) / (0.025 * sr))
        var settled = true
        for i in liveScalarsCur.indices {
            let d = liveScalarsTarget[i] - liveScalarsCur[i]
            if abs(d) > 1e-12 {
                liveScalarsCur[i] += a * d
                if abs(liveScalarsTarget[i] - liveScalarsCur[i])
                    > 1e-9 * max(abs(liveScalarsTarget[i]), 1.0) {
                    settled = false
                } else {
                    liveScalarsCur[i] = liveScalarsTarget[i]
                }
            }
        }
        liveGainCur.trim += a * (liveGainTarget.trim - liveGainCur.trim)
        liveGainCur.mix += a * (liveGainTarget.mix - liveGainCur.mix)
        liveGainCur.width += a * (liveGainTarget.width - liveGainCur.width)
        if abs(liveGainTarget.trim - liveGainCur.trim) > 1e-9
            || abs(liveGainTarget.mix - liveGainCur.mix) > 1e-9
            || abs(liveGainTarget.width - liveGainCur.width) > 1e-9 {
            settled = false
        } else {
            liveGainCur = liveGainTarget
        }
        outGain = liveGainCur.trim
        reverb.mix = liveGainCur.mix
        reverb.width = liveGainCur.width
        liveScalarsCur.withUnsafeBufferPointer { sp in
            if let pk = pkernel {
                bow_poly_set_scalars(pk, sp.baseAddress!, Int32(sp.count))
            } else if let k = kernel {
                bow_set_scalars(k, sp.baseAddress!, Int32(sp.count))
            }
        }
        if settled {
            liveRamping = false
            os_unfair_lock_lock(&tiltLock)
            liveRampArmed = false
            os_unfair_lock_unlock(&tiltLock)
        }
    }

    /// Per-chunk runtime-parameter update (render thread): smooth each
    /// target (~40 ms) and push the kernel scalars only when they moved —
    /// the kernel setters are plain scalar writes, audio-thread safe.
    private func updateTarafAxes(n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let gT = jawGainTarget
        let lT = jtLpHzTarget
        let dT = dampAmtTarget
        os_unfair_lock_unlock(&tiltLock)
        if gT == 1.0, jawGainCur == 1.0, lT == 0.0, !jtLpEngaged,
           dT == 0.0, dampAmtCur == 0.0 { return }
        let a = 1.0 - exp(-Double(n48) / (0.04 * sr))
        // web buzz
        jawGainCur += a * (gT - jawGainCur)
        if gT == 1.0, abs(jawGainCur - 1.0) < 1e-3 { jawGainCur = 1.0 }
        if abs(jawGainCur - jawGainPushed) > 1e-3 {
            jawGainPushed = jawGainCur
            if let pk = pkernel { bow_poly_set_jaw_gain(pk, jawGainCur) }
            else if let k = kernel { bow_set_jaw_gain(k, jawGainCur) }
        }
        // jt tone LP (smoothed in Hz; target 0 eases back to the build
        // corner then restores the exact build coefficient)
        let lpGoal = lT > 0 ? lT : tiltPureLpHiHz
        jtLpHzCur += a * (lpGoal - jtLpHzCur)
        if lT == 0.0, abs(jtLpHzCur - tiltPureLpHiHz) < 1.0 {
            jtLpHzCur = tiltPureLpHiHz
            if jtLpEngaged {
                jtLpEngaged = false
                if let pk = pkernel { bow_poly_jt_set_lp(pk, jtLpBaseA) }
                else if let k = kernel { bow_jt_set_lp(k, jtLpBaseA) }
            }
        } else if abs(jtLpHzCur - jtLpHzPushed) > 1.0 || (lT > 0 && !jtLpEngaged) {
            jtLpHzPushed = jtLpHzCur
            jtLpEngaged = true
            let lpA = 1.0 - exp(-2.0 * Double.pi * jtLpHzCur / jtTickRate)
            if let pk = pkernel { bow_poly_jt_set_lp(pk, lpA) }
            else if let k = kernel { bow_jt_set_lp(k, lpA) }
        }
        // taraf damping
        dampAmtCur += a * (dT - dampAmtCur)
        if dT == 0.0, dampAmtCur < 1e-3 { dampAmtCur = 0.0 }
        if abs(dampAmtCur - dampAmtPushed) > 1e-3 {
            dampAmtPushed = dampAmtCur
            let t60 = dampAmtCur <= 1e-3 ? 0.0
                : tiltDampMaxT60
                    * pow(tiltDampMinT60 / tiltDampMaxT60, dampAmtCur)
            if let pk = pkernel { bow_poly_jt_set_damp_t60(pk, t60) }
            else if let k = kernel { bow_jt_set_damp_t60(k, t60) }
        }
    }

    /// TONE TILT axis -1..1 (iPad tilt → CC72): -1 = bass bias, 0 =
    /// flat (bypass — byte-exact), +1 = treble bias. A complementary
    /// low/high shelf pair (∓/± `bow_tilt_eq_db`) on the whole voice
    /// before the room. Smoothed on the render thread (~50 ms).
    public func setToneTilt(_ t: Double) {
        os_unfair_lock_lock(&tiltLock)
        toneTiltTarget = min(max(t, -1.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Per-chunk tone-tilt update (render thread): smooth toward the
    /// target and swap shelf coefficients in place (state kept).
    private func updateToneTilt(n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let target = toneTiltTarget
        os_unfair_lock_unlock(&tiltLock)
        if !tiltEqActive, target == 0.0, toneTiltCur == 0.0 { return }
        let a = 1.0 - exp(-Double(n48) / (0.05 * sr))
        toneTiltCur += a * (target - toneTiltCur)
        if target == 0.0, abs(toneTiltCur) < 1e-3 {
            toneTiltCur = 0.0
            toneTiltApplied = 0.0
            tiltEqActive = false
            tiltLoShelf.reset()
            tiltHiShelf.reset()
            tiltLoShelfS.reset()
            tiltHiShelfS.reset()
            return
        }
        tiltEqActive = true
        if abs(toneTiltCur - toneTiltApplied) > 2e-3 {
            toneTiltApplied = toneTiltCur
            // in-place coefficient swaps, state kept; the side twins get
            // the same coefficients (independent state)
            func copyCoeffs(_ from: Biquad, _ into: inout Biquad) {
                into.b0 = from.b0; into.b1 = from.b1; into.b2 = from.b2
                into.a1 = from.a1; into.a2 = from.a2
            }
            let lo = Biquad.lowShelf(f0: tiltEqLoHz,
                                     gainDB: -toneTiltCur * tiltEqDbMax,
                                     sr: sr)
            copyCoeffs(lo, &tiltLoShelf)
            copyCoeffs(lo, &tiltLoShelfS)
            let hi = Biquad.highShelf(f0: tiltEqHiHz,
                                      gainDB: toneTiltCur * tiltEqDbMax,
                                      sr: sr)
            copyCoeffs(hi, &tiltHiShelf)
            copyCoeffs(hi, &tiltHiShelfS)
        }
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
            // While a live-parameter ramp is running, cap the chunk so the
            // ~25 ms glide is actually RESOLVED. The ramp advances once per
            // chunk, so a 4096-frame call (the offline/audition path) would
            // otherwise collapse it into a single 97% step — exactly the
            // click the ramp exists to prevent. The device path already
            // uses 128-frame buffers; this makes the behavior identical
            // whatever the caller's block size.
            os_unfair_lock_lock(&tiltLock)
            let ramping = liveRampArmed
            os_unfair_lock_unlock(&tiltLock)
            let cap = ramping ? min(maxFrames, 256) : maxFrames
            let n = min(cap, frames - done)
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
        if stereoOn {
            y96.withUnsafeMutableBufferPointer { yb in
                y96S.withUnsafeMutableBufferPointer { sb in
                    bow_poly_process2(pk, Int32(nk), Int32(slotStride),
                                      cF0, cVb, cFb, cBeta, cGate, cXv,
                                      yb.baseAddress!, sb.baseAddress!)
                    y48.withUnsafeMutableBufferPointer { ob in
                        dec.process(yb.baseAddress!, count: nk,
                                    into: ob.baseAddress!)
                    }
                    y48S.withUnsafeMutableBufferPointer { ob in
                        decS.process(sb.baseAddress!, count: nk,
                                     into: ob.baseAddress!)
                    }
                }
            }
            postChainStereo(n48: n, outL: outL, outR: outR)
        } else {
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
        applyPendingLive(n48: n48)
        updateToneTilt(n48: n48)
        updateTarafAxes(n48: n48)
        for i in 0..<n48 {
            var x = y48[i]
            if radFIR != nil { x = radFIR!.process(x) }
            if radLp != nil { x = radLp!.process(x) }
            for s in radHP.indices { x = radHP[s].process(x) }
            if radHill != nil { x = radHill!.process(x) }
            // tone tilt-EQ (before the room, so the wet follows)
            if tiltEqActive {
                x = tiltLoShelf.process(x)
                x = tiltHiShelf.process(x)
            }
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
        // outGain is interpolated ACROSS the chunk: it is a pure output
        // multiplier with a 7x range, so a chunk-rate step is a step in
        // the waveform (a +17 dB jump measured 17.9x the signal's own
        // sample-to-sample motion before this). `gainFrom` is where the
        // previous chunk left off.
        let gTo = 0.5 * outGain, gFrom = 0.5 * gainPrev
        let dg = (gTo - gFrom) / Double(max(n48, 1))
        for i in 0..<n48 {
            let half = (gFrom + dg * Double(i)) * y48[i]
            outL[i] = half
            outR[i] = half
        }
        gainPrev = outGain
    }

    /// Stereo post-chain (Starpad 2026-07-23): the mid (y48) and side
    /// (y48S) streams each run their own radiation-chain state (same
    /// coefficients), the room adds a width-decorrelated wet pair, and
    /// L = mid + side, R = mid − side. The side and the reverb's side
    /// tank both cancel in L+R, so the mono fold-down — including the
    /// 0.5·outGain split — is identical to `postChain`'s. No fingerprint
    /// mask here (stereo is armed only when `fpMask` is nil — live).
    private func postChainStereo(n48: Int,
                                 outL: UnsafeMutablePointer<Double>,
                                 outR: UnsafeMutablePointer<Double>) {
        applyPendingLive(n48: n48)
        updateToneTilt(n48: n48)
        updateTarafAxes(n48: n48)
        let gTo = 0.5 * outGain, gFrom = 0.5 * gainPrev
        let dg = (gTo - gFrom) / Double(max(n48, 1))
        for i in 0..<n48 {
            var m = y48[i]
            if radFIR != nil { m = radFIR!.process(m) }
            if radLp != nil { m = radLp!.process(m) }
            for s in radHP.indices { m = radHP[s].process(m) }
            if radHill != nil { m = radHill!.process(m) }
            var s = y48S[i]
            if radFIRS != nil { s = radFIRS!.process(s) }
            if radLpS != nil { s = radLpS!.process(s) }
            for k in radHPS.indices { s = radHPS[k].process(s) }
            if radHillS != nil { s = radHillS!.process(s) }
            // tone tilt-EQ on mid AND side (same coefficients = EQing
            // L/R by linearity — the image doesn't narrow), pre-room so
            // the wet follows
            if tiltEqActive {
                m = tiltLoShelf.process(m)
                m = tiltHiShelf.process(m)
                s = tiltLoShelfS.process(s)
                s = tiltHiShelfS.process(s)
            }
            let (wl, wr) = reverb.processMonoStereo(m)
            let g = gFrom + dg * Double(i)      // see postChain
            outL[i] = g * (m + s + wl)
            outR[i] = g * (m - s + wr)
        }
        gainPrev = outGain
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
        decS.reset()
        radFIRS?.reset()
        radLpS?.reset()
        radHillS?.reset()
        for i in radHPS.indices { radHPS[i].reset() }
        fpMask?.reset()
        reverb.reset()
        tiltLoShelf.reset()
        tiltHiShelf.reset()
        tiltLoShelfS.reset()
        tiltHiShelfS.reset()
        filter.reset()
        for i in filters.indices { filters[i].reset() }
        for i in slotSilent.indices { slotSilent[i] = false }
    }
}
