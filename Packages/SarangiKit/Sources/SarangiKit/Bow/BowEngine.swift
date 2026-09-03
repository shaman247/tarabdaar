import Foundation
import CBowKernel

/// The LIVE bow-physics instrument: the streaming C friction kernel
/// (CBowKernel `bow_poly_init`/`bow_poly_process`) at 96 kHz, decimated to
/// the 48 kHz engine rate and radiated through the post-chain: radiation FIR
/// → E_lp radiation low-pass → room reverb. The kernel
/// output is ONE mono stream (taraf direct radiation is fused in-kernel);
/// by default stereo is an equal split so the L+R sum is pan-invariant like
/// every other mode. With `bow_st_width` armed (2026-08-01 unifying rev;
/// the legacy `bow_st_spread`/`bow_st_played` pans still arm too) the
/// POLY kernel adds a physically-derived SIDE stream — the whole
/// instrument heard from two observation points — and L/R = mid ± side;
/// the L+R fold-down still equals the mono output exactly. No capture curve live
/// (live is its own neutral capture) and no pre-roll/pre-charge (start
/// from silence).
///
/// POLYPHONY (2026-07-16): every mapper slot is its own gut string with its
/// own friction/delay-line state, all connected to the SAME bridge — one
/// jawari web, one modal body, one radiation/post chain; each string's -Z·V
/// loading is folded delay-free into the bridge solve, so stability is
/// structural at any polyphony. There used to be a second, MONO kernel
/// (`bow_kernel.c`) taken at `maxPoly` 1: it existed only as the byte-parity
/// twin of the offline Python render's C source, and went with the rest of
/// the upstream-parity machinery (2026-07-24). `maxPoly` 1 is now simply the
/// poly kernel with one string.
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
    /// Polyphony: number of gut strings on the shared bridge, one per
    /// mapper slot.
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

    private var pkernel: UnsafeMutableRawPointer?     // bow_kernel_poly.c
    private var dec: HalfBandDecimator
    private var radFIR: FIRFilter?
    private var radLp: Biquad?
    private var radHill: Biquad?
    /// TARABDAAR STEREO SIDE PATH (2026-07-23): the poly kernel renders a
    /// second SIDE stream carrying only the DIRECT radiation — the taraf
    /// strings' direct tap, the modal-jawari rows' own radiation (drones
    /// included), and the bow-contact noise — each panned by PITCH CLASS
    /// around the tonic (spread·sin(2π·pc): tonic centre-stage, svaras
    /// at fixed symmetric places, octaves share a place — see the pan
    /// rationale at the arming site — LEGACY, seeded 0 since the width
    /// unification). The shipping law is `bow_st_width` (2026-08-01):
    /// the whole instrument HEARD from two observation points — the
    /// kernel's diffuse-field difference bank on the complete radiated
    /// output — so the centred image gains width without leaning. The
    /// side rides its own decimator + radiation-chain twins here, then
    /// L = mid + side, R = mid − side — the L+R fold-down is
    /// bit-identical to the legacy mono output. Armed only when
    /// `bow_st_width` (or a legacy pan spread) is present and nonzero
    /// (keys absent from the artifact ⇒ every golden/parity test keeps
    /// the exact mono path); Tarabdaar's live build seeds `bow_st_width`
    /// in `buildEngine`.
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

    // ---- TARABDAAR FX RACK (2026-08-01): four insert points, all off by
    // default (byte-null). drive/voice/taraf run at the KERNEL rate
    // (pre-decimation — summing the split buses there keeps the no-FX
    // path bit-exact); global runs at the engine rate after the whole
    // fitted post-chain. Settings are staged under `tiltLock` and picked
    // up at chunk boundaries (the tone-tilt pattern). ----
    private var fxUnits: [FXChainUnit]
    private var fxPending: [FXSettings]
    private var fxDirty = false

    // ---- Tilt performance axes (2026-07-23 evening) ----
    // Three iPad-tilt-driven runtime controls (CC71/73/72 through the
    // host): taraf PURITY (the radiated-jt tone LP — kernel; the web-buzz
    // half of this axis went away with the linear taraf on 2026-07-24),
    // taraf DECAY (extra momentum damping — kernel), and TONE TILT
    // (complementary shelf pair on the whole voice output — here). The
    // kernel axes are
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
    private var jtLpHzTarget = 0.0          // bow_jt_lp runtime (0 = build)
    private var jtLpHzCur = 16000.0         // synced to tiltPureLpHiHz at load
    private var jtLpHzPushed = 16000.0
    private var jtLpEngaged = false
    private var jtHpHzTarget = 0.0          // bow_jt_hp runtime (0 = off)
    private var jtHpHzCur = 0.0
    private var jtHpHzPushed = 0.0
    private var dampAmtTarget = 0.0         // bow_jt_damp (0 = natural ring)
    private var dampAmtCur = 0.0
    private var dampAmtPushed = 0.0
    // MELODY FOLLOWER (2026-07-25): true when the jt tables carry a
    // tracked row; the render thread pushes the highest gated note's
    // pitch as its target once per chunk (plain kernel scalar write).
    private var trackArmed = false
    private var trackHzPushed = 0.0
    // RECRUITMENT / contribution profile (2026-07-26; PROFILE rework
    // 2026-08-01 — the first bipolar axis' top half was a pure loudness
    // boost and the whole knob read as a taraf volume; the interim
    // monotone-breadth cut topped out at the fitted response, still
    // note-dependent): `bow_jt_sel` sweeps each jawari row's BRIDGE
    // drive across the contribution PROFILE — 0 = kin-only, 0.5 =
    // fitted (natural resonance), 1 = every row contributing EQUALLY,
    // note-independent — with the radiated jt gain compensating so the
    // taraf's LOUDNESS holds across the throw. The target is a
    // control-thread write; the render thread rescores the rows per
    // chunk and pushes per-row weights the kernel slews (~30 ms). Kin
    // falloff width / strength law are bp scalars (`bow_jt_sel_width`,
    // `bow_jt_sel_kin`).
    private var selTarget = 0.5               // bow_jt_sel runtime (0.5 = fitted)
    private var selEngaged = false            // render thread: axis in effect
    private var selWidthCents = 30.0          // bow_jt_sel_width
    private var selComp = 4.0                 // bow_jt_sel_comp (loudness-comp cap)
    private var selGMulPushed = 1.0           // last pushed radiated-gain mul
    private var selKinCents: [Double] = []    // kin offsets (cents)
    private var selKinStrength: [Double] = [] // (p·q)^-kinExp per kin
    private var selRowFreqs: [Double] = []     // row f0s (builder)
    private var jtTrackRowIdx = -1            // follower row: always weight 1
    // TWO BRIDGES (2026-09-02): per-row bridge membership + apex (the
    // builder's), for the per-bridge evolve map and the Scope tab.
    private var jtRowChromatic: [Bool] = []
    private var jtRowApex: [Double] = []
    private var jtHasChromatic = false
    private var jtEvOfsArmed = false          // offsets ever pushed
    private var jtDwTargets: [Double] = []    // scratch: weights to push
    private var jtDwPushed: [Double] = []     // last pushed (skip no-ops)
    private var selPitches: [Double] = []     // scratch: gated pitches
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

    // ---- OUTPUT SAFETY LIMITER (2026-08-01) ----
    // Linked-stereo peak limiter at the VERY END of both post-chains
    // (after the global FX insert): instant-attack peak detector,
    // exponential release (`bow_lim_rel_ms`), gain smoothed ~0.2 ms,
    // and a hard clamp at min(1, 1.25×ceiling) for the few attack
    // samples the smoothing lets through. BELOW the ceiling it
    // multiplies nothing — bit-exact passthrough (the parity phrase
    // peaks ~0.06 against the 0.8 default, so every golden is
    // untouched). It exists for the kin peaks (a hard-struck unison
    // Sa/Pa adds the voice, the jt ring and the coupling return
    // coherently) and the ±16 dB expression axis.
    private var limThresh = 0.8       // bow_lim_thresh (1.0 ≈ FS safety)
    private var limRelCoef = 0.000139 // bow_lim_rel_ms (150 ms at 48 k)
    private let limAttCoef = 0.1      // ~0.2 ms gain smoothing
    private var limEnv = 0.0
    private var limGain = 1.0

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
    private var y96Jt: [Double], y96JtS: [Double] // FX split taraf bus
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
        y96Jt = [Double](repeating: 0, count: nk)
        y96JtS = [Double](repeating: 0, count: nk)
        fxUnits = [FXChainUnit(sr: sr * Double(osFactor)),  // drive
                   FXChainUnit(sr: sr * Double(osFactor)),  // voice
                   FXChainUnit(sr: sr * Double(osFactor)),  // taraf
                   FXChainUnit(sr: sr)]                     // global
        fxPending = [FXSettings(), FXSettings(), FXSettings(), FXSettings()]
        polySnap = BowControlMapper.PolySnapshot(count: nPoly)
        filters = [BowControlFilter](repeating: filter, count: nPoly)
        for i in filters.indices { filters[i].seedDrift(UInt64(i)) }
        lastSerial = [UInt32](repeating: 0, count: nPoly)
        slotSilent = [Bool](repeating: false, count: nPoly)
        mapper.setSlotLimit(nPoly)

        let t = tables
        let s = t.scalars
        precondition(s.count == 66, "bow tables: expected 66 scalars, got \(s.count)")
        // Starting point for the live-parameter ramp (see applyPendingLive).
        liveScalarsCur = s
        liveScalarsTarget = s
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
            s[58], s[59], s[60],
            s[61], s[62], s[63], s[64], s[65])
        // Drone-row excitation scalars (Tarabdaar drone buttons; not in
        // the artifact — bp defaults, overridable via `string.<key>`).
        droneLevel = bp.v("bow_drone_level", 0.026)
        droneOnset = bp.v("bow_drone_onset", 0.052)
        droneAttackSec = bp.v("bow_drone_attack_ms", 150.0) / 1000.0
        droneReleaseSec = bp.v("bow_drone_release_ms", 350.0) / 1000.0
        droneOnsetDecaySec = bp.v("bow_drone_onset_decay_ms", 500.0) / 1000.0
        droneLpHz = bp.v("bow_drone_lp_hz", 1600.0)
        droneHpHz = bp.v("bow_drone_hp_hz", 25.0)
        droneToneMix = bp.v("bow_drone_tone_mix", 0.5)
        droneSpread = bp.v("bow_drone_spread", 1.0)
        // (bow_drone_comp_cents is retired: the buttons pluck existing
        // rows by identity, so there is no requested-pitch compensation.)
        // Tilt-axis ranges (not in the artifact — bp defaults,
        // overridable via `string.<key>` like the drone scalars).
        tiltPureLiftMax = bp.v("bow_tilt_pure_lift", 8.0)
        tiltDampMinT60 = bp.v("bow_tilt_damp_min_t60", 0.25)
        tiltDampMaxT60 = bp.v("bow_tilt_damp_max_t60", 20.0)
        tiltEqDbMax = bp.v("bow_tilt_eq_db", 9.0)
        tiltEqLoHz = bp.v("bow_tilt_eq_lo", 300.0)
        tiltEqHiHz = bp.v("bow_tilt_eq_hi", 2400.0)
        // output safety limiter (2026-08-01) — bp resting values; live
        // edits arrive via applyPendingLive (the same reads)
        limThresh = min(max(bp.v("bow_lim_thresh", 0.8), 0.1), 1.0)
        limRelCoef = 1.0 - exp(-1.0 /
            (max(bp.v("bow_lim_rel_ms", 150.0), 5.0) * 0.001 * sr))
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
            // RECRUITMENT tables + buffers: precompute the kin lattice
            // once (per-chunk scoring does no transcendental setup) and
            // size the per-row scratch. Separate allocations — sharing
            // storage would COW-copy on the render thread's first write.
            selWidthCents = bp.v("bow_jt_sel_width", 30.0)
            // the kernel's gain_mul clamps at 4 — the cap can't exceed it
            selComp = min(max(bp.v("bow_jt_sel_comp", 4.0), 1.0), 4.0)
            let kinExp = bp.v("bow_jt_sel_kin", 0.7)
            selKinCents = Self.recruitKin.map { 1200.0 * log2($0.ratio) }
            selKinStrength = Self.recruitKin.map { pow($0.pq, -kinExp) }
            selRowFreqs = jt.rowFreqs
            jtTrackRowIdx = Int(jt.trackRow)
            jtRowChromatic = jt.rowChromatic
            jtRowApex = jt.rowApex
            jtHasChromatic = jt.hasChromatic
            jtDwTargets = [Double](repeating: 1.0, count: jt.rowFreqs.count)
            jtDwPushed = [Double](repeating: 1.0, count: jt.rowFreqs.count)
            droneHeldMask = [Bool](repeating: false, count: jt.rowFreqs.count)
            selPitches = [Double](repeating: 0.0, count: self.maxPoly)
            if let pk = pkernel {
                bow_poly_jt_load(pk, Int32(jt.M.count), jt.J, jt.M,
                                 jt.ca, jt.cb, jt.ca4, jt.cb4, jt.wd,
                                 jt.rowForceScale, jt.phiD, jt.phiU, jt.phiF,
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
                // excitation is a slewed noise drive, no impulse) + the
                // drive band-pass corners (mellow-drone rev)
                bow_poly_jt_drone_env(pk, droneAttackSec, droneReleaseSec,
                                      droneOnsetDecaySec)
                bow_poly_jt_drone_tone(pk, droneLpHz, droneHpHz,
                                       droneToneMix)
                // HARMONIC EVOLUTION (2026-07-26): the graze-margin
                // reference for the 0…1 → meters map; a non-neutral
                // resting value is pushed here so the slew (~40 ms)
                // completes inside the settle pre-roll.
                jtApexRef = jt.apexRef
                let ev = min(max(bp.v("bow_jt_evolve", 0.5), 0.0), 1.0)
                if ev != 0.5 {
                    bow_poly_jt_set_evolve(
                        pk, jtApexRef * (1.0 - pow(4.0, 1.0 - 2.0 * ev)))
                }
                jtEvolveApplied = ev   // dead-band reference (setJtEvolve)
                // TWO BRIDGES (2026-09-02): the chromatic bridge's own
                // contact law (per row) and its own evolve axis — both
                // inert without chromatic rows.
                pushJtRowContact(jt)
                jtEvolveChromaticApplied = min(max(
                    bp.v("bow_jtc_evolve",
                         BowTables.chromaticBridgeDefaults["bow_jtc_evolve"] ?? 0.5),
                    0.0), 1.0)
                // EVOLUTION REGISTER TILT (2026-08-27): a resting bp
                // value arms the per-row bone offsets at build (the
                // audition/test `string.bow_jt_ev_reg` route; the app's
                // live push arrives on top). 0 = byte-null. The chromatic
                // bridge rides the same offsets (its own apex / evolve).
                jtEvolveRegApplied =
                    min(max(bp.v("bow_jt_ev_reg", 0.0), -1.0), 1.0)
                pushJtEvolveOffsets()
                // CHARGE GOVERNOR (2026-08-15): the graze target in
                // apex units (`bow_jt_gov_ref`, bp scalar like the tilt
                // range keys); a bp resting value arms it at build (the
                // audition/test `string.bow_jt_gov` route; the app's
                // live push arrives on top). 0 = byte-null. Default 48
                // = the calibrated knee (TarafVarianceBench gov sweep):
                // a resting-level solo strike renders bit-identically
                // (env never crosses ref) while the hot phrase pile-up
                // sheds 14-16 dB and its buzz share falls 16% -> ~1.5%.
                // TRAP: ~96 holds the ring AT the buzz-maximal graze
                // band (buzz share WORSE than ungoverned) - if this is
                // retuned, re-run the sweep, don't interpolate.
                jtGovRefDisp = jtApexRef * bp.v("bow_jt_gov_ref", 48.0)
                let gov = bp.v("bow_jt_gov", 0.0)
                if gov > 0 {
                    bow_poly_jt_set_gov(pk, min(gov, 1.0), jtGovRefDisp)
                }
                // QUIESCENCE GATE (2026-08-17): sleep floor in dB below
                // the graze apex — rows resting sub-floor freeze in
                // place and skip their modal tick (the idle-CPU gate;
                // idle burned ~350% CPU across the jt workers without
                // it). ALWAYS ON, not a user parameter. Default 40:
                // a PRESSED resting bone (bow_jt_evolve toward 0 —
                // negative lift) sustains a steady LOW-mode limit
                // cycle at rest — measured stock rig at evolve 0:
                // x3.34 of the 60 dB floor, never closes; the user's
                // hot-gain rig: x6.6 (= -43.6 dB re apex velocity,
                // reported inaudible). 40 sleeps both with >=2x
                // margin and truncates ~3.6 dB above that inaudible
                // level. Deeper floors (>~75) sit under even the
                // neutral-bone resting baseline and never close.
                // `bow_jt_gate` stays a bp scalar (gov_ref style) so
                // tests/auditions can override; 0 = the bit-exact
                // raw-physics escape hatch.
                let gate = bp.v("bow_jt_gate", 40.0)
                if gate > 0 {
                    bow_poly_jt_set_gate(
                        pk, jtApexRef * pow(10.0, -gate / 20.0))
                }
                // MELODY FOLLOWER (2026-07-25): arm the tracked row and
                // send it to the tonic; renderPolyChunk retargets it to
                // the highest gated note every chunk. The glide from the
                // build pitch is absorbed by the settle pre-roll.
                if jt.trackRow >= 0 {
                    let row = Int(jt.trackRow)
                    bow_poly_jt_track_config(pk, jt.trackRow,
                                             jt.rowFreqs[row], jt.trackT60,
                                             jt.trackFhf, jt.trackBst)
                    let tonic = tables.scalars.count > 44
                        ? tables.scalars[44] : 261.63
                    bow_poly_jt_track_target(pk, tonic)
                    trackHzPushed = tonic
                    trackArmed = true
                }
            }
            // purity LP-sweep references (2026-07-23 night): the axis
            // sweeps the radiated-jt tone LP corner from the build
            // corner (or open) down to bow_tilt_pure_lp
            let div = jt.phys.count > 6 ? max(1.0, jt.phys[6].rounded()) : 1.0
            jtTickRate = srk / div
            jtLpBaseA = jt.lpA
            // jt tone HP (2026-07-26): a bp resting value arms it at
            // build (the audition/test `string.bow_jt_hp` route; the
            // app's live push arrives on top). 0 = byte-null.
            let hpHz = bp.v("bow_jt_hp", 0.0)
            if hpHz > 0, let pk = pkernel {
                let hz = min(max(hpHz, 20.0), 8000.0)
                bow_poly_jt_set_hp(
                    pk, 1.0 - exp(-2.0 * Double.pi * hz / jtTickRate))
            }
            // jt body radiation (2026-08-01): a bp resting value arms it
            // at build (the audition/test `string.bow_jt_body` route; the
            // app's live push arrives on top). 0 = byte-null.
            let bodyMix = bp.v("bow_jt_body", 0.0)
            if bodyMix > 0, let pk = pkernel {
                bow_poly_jt_set_body(pk, min(bodyMix, 1.0))
            }
            tiltPureLpHiHz = jt.lpA > 0
                ? -log(1.0 - min(jt.lpA, 0.999999)) * jtTickRate
                    / (2.0 * Double.pi)
                : min(16000.0, 0.45 * jtTickRate)
            jtLpHzCur = tiltPureLpHiHz
            jtLpHzPushed = tiltPureLpHiHz
        }
        // TARABDAAR STEREO SIDE PATH (2026-07-23): arm the poly kernel's
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
        // INSTRUMENT WIDTH (2026-08-01 unifying rev): the whole
        // instrument heard from two observation points — the kernel's
        // diffuse-field difference bank on the complete radiated output
        // (voice bus + jt wash, one instance each by linearity). The
        // image stays centred; its upper spectrum stops being
        // interaurally identical. This is the ONE shipping width law —
        // the per-source pans above it are legacy staging, seeded 0
        // (disarmed) pending removal. Mono fold-down invariant as ever.
        let stWidth = bp.v("bow_st_width", 0.0)
        if let pk = pkernel, fpMask == nil,
           stSpread > 1e-6 || stPlayed > 1e-6 || stWidth > 1e-6 {
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
            // The linear web is gone (2026-07-24), so its pan family is
            // always empty — the kernel leaves that source centred.
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
            bow_poly_set_stereo(pk, nil, 0,
                                jtPan.isEmpty ? nil : jtPan,
                                Int32(jtPan.count),
                                slotPan, Int32(nPoly))
            if stWidth > 1e-6 { bow_poly_set_stereo_width(pk, stWidth) }
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
        // SITAR TWANG (2026-08-01): a bp resting value arms the played
        // strings' grazing bridge fold at build (the audition/test
        // `string.bow_twang` route; the app's live push arrives on
        // top). 0 = byte-null.
        if let pk = pkernel {
            let tw = min(max(bp.v("bow_twang", 0.0), 0.0), 1.0)
            if tw > 1e-9 { bow_poly_set_twang(pk, tw) }
        }
        // TARABDAAR FX (2026-08-01): install the voice→taraf drive hook.
        // Installed unconditionally (init, off the audio thread); the
        // unit's own `isEngaged` gate keeps it byte-null while the drive
        // point is off. `passUnretained` is safe — deinit frees the
        // kernel before self dies, so the kernel never outlives us.
        if let pk = pkernel {
            bow_poly_set_drive_fx(pk, bowEngineDriveFXHook,
                                  Unmanaged.passUnretained(self).toOpaque())
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
    /// (then the row rings out on its own t60). Mellow-drone rev
    /// 2026-07-26: slower swell/fall, a ~700 Hz drive top, and the press
    /// spreads to the held row's KIN rows (same lattice as `bow_jt_sel`)
    /// so a drone tap wakes the taraf the way playing that note does.
    public var droneLevel = 0.026
    /// Onset-boost drive amplitude (`bow_drone_onset`) — the swell peaks
    /// near level+onset before relaxing into the sustain.
    public var droneOnset = 0.052
    /// Envelope times (`bow_drone_attack_ms` / `_release_ms` /
    /// `_onset_decay_ms`); pushed to the kernel at build (jt load).
    public var droneAttackSec = 0.15
    public var droneReleaseSec = 0.35
    public var droneOnsetDecaySec = 0.50
    /// Drive band-pass corners (`bow_drone_lp_hz` / `bow_drone_hp_hz`,
    /// pushed at build): the top corner is the drive's brightness — the
    /// old fixed 2 kHz band was the harsh edge of the first rev.
    public var droneLpHz = 1600.0
    public var droneHpHz = 25.0
    /// Pitched fraction of the drive 0..1 (`bow_drone_tone_mix`): each
    /// row is driven by a sine at its own mode-1 frequency mixed with
    /// the band-passed noise. Pure noise (0) rings the row's high modes
    /// far above their played-note balance (measured H4 ≈ H1 vs the
    /// played tap's H4 −29 dB) — the pitched drive is what makes a
    /// drone ring like the taraf under a played note.
    public var droneToneMix = 0.5
    /// Kin-row drive scale 0..1 (`bow_drone_spread`): how strongly a
    /// press recruits the held row's kin (octave/fifth/twelfth) rows
    /// relative to the row itself. 0 = the old single-row behaviour.
    public var droneSpread = 1.0
    /// Held drone rows (button presses via `dronePress`/`droneRelease`);
    /// guarded by `droneLock` — presses arrive on the MIDI thread while
    /// remaps run on main.
    private var droneHeldRows: Set<Int> = []
    private var droneLock = os_unfair_lock()
    /// Render-readable shadow of `droneHeldRows` (element stores under
    /// `droneLock`; the render thread reads it lock-free — the
    /// drone-setter contract): the recruitment loudness compensation
    /// counts a held row as fully ringing, so a drone is never pumped.
    private var droneHeldMask: [Bool] = []

    /// Per-row drone drive weights for a set of held rows: a held row is
    /// 1, every other row takes its best kin affinity to the held set
    /// (soft-OR across drones, same lattice + width as the recruitment
    /// axis) scaled by `droneSpread`. The melody-follower row never takes
    /// SPREAD drive (it retunes under the drive to the played pitch) —
    /// an explicit press of it is honored (test harnesses drone-excite
    /// it; app presses only ever target tarab rows).
    private func droneDriveWeights(rows: Set<Int>) -> [Double] {
        var w = [Double](repeating: 0.0, count: selRowFreqs.count)
        guard !rows.isEmpty else { return w }
        for i in 0..<selRowFreqs.count {
            if rows.contains(i) { w[i] = 1.0; continue }
            if i == jtTrackRowIdx { continue }
            guard droneSpread > 0.0, selRowFreqs[i] > 0.0 else { continue }
            var miss = 1.0
            for h in rows where selRowFreqs[h] > 0.0 {
                let c = 1200.0 * log2(selRowFreqs[i] / selRowFreqs[h])
                miss *= 1.0 - Self.recruitAffinity(
                    centsFromPlayed: c, kinCents: selKinCents,
                    kinStrength: selKinStrength,
                    widthCents: selWidthCents)
            }
            w[i] = droneSpread * (1.0 - miss)
        }
        return w
    }
    /// The jt row holding EXACTLY this nominal frequency, or nil if the
    /// jawari selection didn't pick the string up (the row is then inert —
    /// same rule as any tarab row). The drone buttons reference tarab
    /// strings directly (2026-07-25), so this is a plain identity lookup;
    /// the old requested-pitch machinery (pitch-class-nearest match + the
    /// `droneCompCents` sounding-pitch compensation, which existed for the
    /// deleted dedicated drone rows) is gone.
    /// Rows are ordered raga bridge first (2026-09-02), so a pitch on both
    /// bridges resolves to its raga row — the drone anchors' bridge.
    public func droneRow(forExactHz hz: Double) -> Int? {
        jtRowFreqs.firstIndex(of: hz)
    }

    /// Press a drone: swell the sustain drive of the row AND its kin
    /// rows (weights from `droneDriveWeights` — the taraf responds like
    /// it does to playing that note), plus the decaying onset boost on
    /// the new press's own spread. Safe from the control thread while
    /// the audio/jt threads render (kernel setters are plain per-row
    /// scalar stores).
    public func dronePress(row: Int) {
        guard let pk = pkernel, row >= 0, row < selRowFreqs.count
        else { return }
        os_unfair_lock_lock(&droneLock)
        droneHeldRows.insert(row)
        if row < droneHeldMask.count { droneHeldMask[row] = true }
        let w = droneDriveWeights(rows: droneHeldRows)
        let wNew = droneDriveWeights(rows: [row])
        for i in 0..<w.count {
            // pluck only where THIS press lands — a zero write would
            // cancel another drone's still-decaying onset
            if wNew[i] > 1e-3 {
                bow_poly_jt_pluck(pk, Int32(i), droneOnset * wNew[i])
            }
            bow_poly_jt_drone(pk, Int32(i), droneLevel * w[i])
        }
        os_unfair_lock_unlock(&droneLock)
    }

    /// Release a drone: recompute the drive profile from the remaining
    /// held set (a shared kin row keeps the survivors' weight); every
    /// row that loses its drive rings out on its own t60.
    public func droneRelease(row: Int) {
        guard let pk = pkernel, row >= 0, row < selRowFreqs.count
        else { return }
        os_unfair_lock_lock(&droneLock)
        droneHeldRows.remove(row)
        if row < droneHeldMask.count { droneHeldMask[row] = false }
        let w = droneDriveWeights(rows: droneHeldRows)
        for i in 0..<w.count {
            bow_poly_jt_drone(pk, Int32(i), droneLevel * w[i])
        }
        os_unfair_lock_unlock(&droneLock)
    }

    // MARK: - Runtime base parameters (2026-07-24 composite rework)

    /// RADIATED-JT TONE LP corner in Hz (base parameter `bow_jt_lp`,
    /// runtime path): brightness of the modal-jawari buzz. <= 0 restores
    /// the exact build-time state (bypass when unarmed). The filter is
    /// state-preserving (click-free coefficient moves; warm bypass).
    /// The jt bones NEVER move at runtime — releasing the static wrap
    /// is an unavoidable jawari strum (`bow_jt_set_lift` stays
    /// offline-only). Smoothed at chunk rate.
    public func setJtToneLp(hz: Double) {
        os_unfair_lock_lock(&tiltLock)
        // ≥ 20 kHz = bypass, the builder's law and the registry's promise
        // (`bow_jt_lp` default 20000 "bit-exact legacy") — the live setter
        // used to arm a 20 kHz one-pole for the default, which
        // ByteNullContractTests caught on 2026-09-03.
        jtLpHzTarget = (hz > 0 && hz < 19999.0)
            ? min(max(hz, 40.0), tiltPureLpHiHz) : 0.0
        os_unfair_lock_unlock(&tiltLock)
    }

    /// RADIATED-JT TONE HP corner in Hz (base parameter `bow_jt_hp`):
    /// the jawari-formant voicing — quiets the taraf's fundamental band
    /// under the high-harmonic cluster.
    /// <= 0 = bypass (byte-exact legacy). Smoothed at chunk rate.
    public func setJtToneHp(hz: Double) {
        os_unfair_lock_lock(&tiltLock)
        jtHpHzTarget = hz > 0 ? min(max(hz, 20.0), 8000.0) : 0.0
        os_unfair_lock_unlock(&tiltLock)
    }

    /// JT BODY RADIATION mix 0…1 (base parameter `bow_jt_body`): blends
    /// the radiated jawari sum through the SAME formula-body radiation
    /// bank the played strings radiate through (shared coefficients, own
    /// filter state) — the coherence lever: the taraf rings from the
    /// instrument's body instead of beside it. 0 = bypass (byte-exact
    /// legacy). Plain kernel scalar write (the drone-setter contract);
    /// the kernel slews ~30 ms.
    /// SITAR→TARAF INJECT gain (2026-08-19): scales another voice's
    /// rendered output into this kernel's jt drive — the sitar main
    /// instrument's sympathetic halo rides the same modal-jawari web
    /// the played gut strings charge. Control thread only (the first
    /// non-zero call allocates the kernel-side ring); 0 with nothing
    /// ever written is byte-null (the parity guarantee holds).
    public func setJtInjectGain(_ g: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_inject_gain(pk, g)
    }

    /// SITAR→TARAF INJECT write (2026-08-19): append the other voice's
    /// mono block to the kernel's SPSC inject ring. Call from that
    /// voice's render callback (this is the ONE BowEngine entry point
    /// meant for a foreign render thread); a full ring drops the block.
    public func jtInjectWrite(_ x: UnsafePointer<Double>, _ n: Int) {
        guard let pk = pkernel else { return }
        bow_poly_jt_inject_write(pk, x, Int32(n))
    }

    public func setJtBody(_ mix01: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_body(pk, min(max(mix01, 0.0), 1.0))
    }

    /// HARMONIC EVOLUTION 0…1 (base parameter `bow_jt_evolve`): the
    /// tanpura/sitar twang axis. Converted here to a SIGNED bone offset
    /// (graze margin × 4 … × ¼: lift = apex · (1 − 4^(1−2e)), 0.5 → 0 =
    /// byte-null) and slewed INSIDE the kernel (~40 ms per jt sample) —
    /// the bone glides, so driving this from a tilt is a slow jawari
    /// adjustment, not the strum a stepped bone move causes. This is the
    /// ONE sanctioned runtime bone move; `bow_jt_set_lift` (the purity
    /// experiments' step lift) stays offline-only.
    public func setJtEvolve(_ e01: Double) {
        guard let pk = pkernel else { return }
        let e = min(max(e01, 0.0), 1.0)
        // Cumulative DEAD-BAND (2026-08-17): a live tilt/stick binding
        // streams this setter at sensor rate, and every applied change
        // MOVES THE BONE — zero-mean sensor jitter mechanically pumps
        // the resting taraf's low modes above the quiescence-gate floor
        // and holds the whole web awake at idle (measured: a Joy-Con
        // stick-Y → bow_jt_evolve binding, ±0.4% jitter → 0 rows ever
        // slept). Compare against the last APPLIED value, not the last
        // push: jitter never accumulates past the band, a real sweep
        // does — its ≤0.5% staircase is smoothed by the kernel's ~40 ms
        // slew (JtEvolveSweepTests still pins the click-free sweep).
        if abs(e - jtEvolveApplied) < 0.005 { return }
        jtEvolveApplied = e
        bow_poly_jt_set_evolve(pk, jtApexRef * (1.0 - pow(4.0, 1.0 - 2.0 * e)))
        // a non-zero register tilt (or a chromatic bridge) rides the
        // global axis: the per-row offsets are differences ON the margin
        // map, so they move with e
        pushJtEvolveOffsets()
    }
    /// Last evolve 0…1 actually forwarded to the kernel (dead-band ref).
    private var jtEvolveApplied = 0.5

    /// THE CHROMATIC BRIDGE'S EVOLUTION 0…1 (`bow_jtc_evolve`, 2026-09-02):
    /// the same margin map as `setJtEvolve`, evaluated on the chromatic
    /// bridge's own apex for its rows only, delivered as per-row bone
    /// offsets against the raga bridge's global lift (the kernel slews
    /// them ~40 ms like the axis itself). Same cumulative dead-band. A
    /// rig without chromatic rows ignores it (no row to offset).
    public func setJtEvolveChromatic(_ e01: Double) {
        let e = min(max(e01, 0.0), 1.0)
        if abs(e - jtEvolveChromaticApplied) < 0.005 { return }
        jtEvolveChromaticApplied = e
        pushJtEvolveOffsets()
    }
    private var jtEvolveChromaticApplied = 0.5

    /// TWO BRIDGES: push every row's contact law (alpha / hcB / deep
    /// threshold) — only when a chromatic row exists; an all-raga rig
    /// never calls the kernel (byte-null), and a chromatic bridge resting
    /// at the raga bridge's values writes the identical constants.
    private func pushJtRowContact(_ jt: JtTables) {
        guard let pk = pkernel, jt.hasChromatic,
              jt.rowAlpha.count == jt.M.count,
              jt.rowHcB.count == jt.M.count,
              jt.rowApex.count == jt.M.count else { return }
        let deep = jt.rowApex.map { 2.5 * $0 }
        jt.rowAlpha.withUnsafeBufferPointer { a in
        jt.rowHcB.withUnsafeBufferPointer { h in
        deep.withUnsafeBufferPointer { d in
            bow_poly_jt_set_row_contact(pk, a.baseAddress, h.baseAddress,
                                        d.baseAddress, Int32(jt.M.count))
        }}}
    }
    /// Graze-margin reference (`bow_jt_apex` at build) for the evolution
    /// map above.
    private var jtApexRef = 1.0e-5

    /// EVOLUTION REGISTER TILT (base parameter `bow_jt_ev_reg`): evolve
    /// units per OCTAVE from the tonic, applied per jt row as a SIGNED
    /// bone offset ADDED to the global evolution lift (kernel-slewed
    /// ~40 ms per row — the same glide as the evolve axis itself).
    /// + = below-tonic rows open toward the grazing band (the low
    /// Sa/Pa "sarod drone" bloom — the long-t60 anchor rows sit in the
    /// cascading band for their whole ring) while above-tonic rows
    /// press closed; − = reversed; 0 = the uniform bone, byte-null.
    /// Cumulative dead-band like setJtEvolve — a bound tilt streaming
    /// sensor jitter must not move bones (quiescence-gate lesson).
    public func setJtEvolveRegister(_ reg: Double) {
        let r = min(max(reg, -1.0), 1.0)
        if abs(r - jtEvolveRegApplied) < 0.005 { return }
        jtEvolveRegApplied = r
        pushJtEvolveOffsets()
    }
    /// Last register tilt actually forwarded (dead-band ref).
    private var jtEvolveRegApplied = 0.0

    /// Recompute + push the per-row offsets for the current (evolve,
    /// register) pair: each row evaluates the SHARED margin map at its
    /// own register-shifted evolve, e_row = clamp(e + reg·log2(tonic /
    /// f_row), 0, 1), and its offset is lift(e_row) − lift(e) with
    /// lift(e) = apex·(1 − 4^(1−2e)) — so every row stays on the
    /// calibrated margin span (×4 … ×¼) instead of scaling meters past
    /// it. The follower row keeps its build-pitch offset (its retunes
    /// are transient and it re-anchors on the next push).
    /// TWO BRIDGES (2026-09-02): a chromatic row evaluates the map on ITS
    /// bridge's apex at ITS bridge's evolve (`bow_jtc_evolve`), register
    /// tilt included, and its offset is that lift minus the raga
    /// bridge's global lift — so each bridge glides on its own calibrated
    /// margin span. Nothing is pushed until some offset is non-zero (an
    /// all-raga rig at reg 0, or a chromatic bridge resting at the raga
    /// bridge's apex and evolve, never arms the kernel — byte-null);
    /// once armed, every recompute is pushed (zeros included).
    private func pushJtEvolveOffsets() {
        guard let pk = pkernel, !selRowFreqs.isEmpty else { return }
        let tonic = tonicHz
        guard tonic > 0 else { return }
        let e = jtEvolveApplied
        let eC = jtEvolveChromaticApplied
        let reg = jtEvolveRegApplied
        func lift(_ x: Double, apex: Double) -> Double {
            apex * (1.0 - pow(4.0, 1.0 - 2.0 * x))
        }
        let base = lift(e, apex: jtApexRef)
        var ofs = [Double](repeating: 0.0, count: selRowFreqs.count)
        var any = false
        for i in 0..<selRowFreqs.count where selRowFreqs[i] > 0 {
            let chrom = jtHasChromatic && i < jtRowChromatic.count
                && jtRowChromatic[i]
            if !chrom && reg == 0.0 { continue }     // exact legacy: 0
            let e0 = chrom ? eC : e
            let apex = (chrom && i < jtRowApex.count) ? jtRowApex[i] : jtApexRef
            let er = min(max(e0 + reg * log2(tonic / selRowFreqs[i]),
                             0.0), 1.0)
            ofs[i] = lift(er, apex: apex) - base
            if ofs[i] != 0.0 { any = true }
        }
        guard any || jtEvOfsArmed else { return }
        jtEvOfsArmed = true
        ofs.withUnsafeBufferPointer {
            bow_poly_jt_set_evolve_ofs(pk, $0.baseAddress!, Int32($0.count))
        }
    }

    /// CHARGE GOVERNOR 0…1 (base parameter `bow_jt_gov`): per-row AGC on
    /// the bridge drive into the jt strings — a row ringing above the
    /// graze target (`bow_jt_gov_ref` × apex, resolved at build) sheds
    /// incoming drive, so the long-t60 anchor rows saturate at their
    /// single-strike ring instead of accumulating a whole phrase (the
    /// Pa / high-Sa loud-buzz pile-up). 0 = bypass (byte-exact legacy).
    /// Plain kernel scalar write (the drone-setter contract).
    public func setJtGov(_ amt01: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_gov(pk, min(max(amt01, 0.0), 1.0), jtGovRefDisp)
    }
    /// Graze-target displacement (meters) resolved at build from
    /// `bow_jt_gov_ref` × `bow_jt_apex` (48 × 1e-5 at the shipped fit).
    private var jtGovRefDisp = 4.8e-4

    /// Rows currently asleep under the quiescence gate (`bow_jt_gate`
    /// bp scalar, ALWAYS ON at 40 dB below the graze apex — not a user
    /// parameter; 0 override = the bit-exact escape hatch) —
    /// telemetry/tests.
    public func jtGateAsleep() -> Int {
        guard let pk = pkernel else { return 0 }
        return Int(bow_poly_jt_gate_asleep(pk))
    }
    /// Gate probe telemetry — (asleep rows, max ring/floor ratio, max
    /// drive/wake-bound ratio, drone-hot) since the last read. A ratio
    /// > 1 names the condition currently blocking sleep.
    public func jtGateProbe() -> (asleep: Int, total: Int, ringR: Double,
                                  driveR: Double, droneHot: Bool) {
        guard let pk = pkernel else { return (0, 0, 0, 0, false) }
        var o = [Double](repeating: 0, count: 5)
        bow_poly_jt_gate_probe(pk, &o)
        return (Int(o[0]), Int(o[1]), o[2], o[3], o[4] > 0.5)
    }

    // MARK: - Scope telemetry (2026-09-01)

    /// One modal-jawari taraf row as the Mac Scope tab reads it.
    public struct ScopeRow: Sendable {
        /// The row's CURRENT fundamental (the follower's live retune).
        public var f0Hz: Double
        /// Radiated peak envelope in display (output) units — voice-bus
        /// units × the current output gain, so rows compare with the
        /// played strings' bus meter.
        public var level: Double
        /// Frozen under the quiescence gate (reads silent).
        public var asleep: Bool
        public var isFollower: Bool
        /// On the chromatic bridge (2026-09-02).
        public var isChromatic: Bool
        /// Per-mode MODAL velocity envelopes |p_k|, modes 1…`scopeModeCount`
        /// (zero past the row's mode count) — the string's own energy per
        /// mode (∝ p_k²); with the flat bridge-force radiation this is also
        /// the row's radiated spectrum up to a constant.
        public var modes: [Float]
    }

    /// One played-string slot as the Scope tab reads it (slot index =
    /// the mapper's).
    public struct ScopeSlot: Sendable {
        public var f0Hz: Double
        /// Bow down (gated) — released strings keep ringing (level > 0).
        public var gated: Bool
        /// The string's ring envelope (string units — relative; 0 =
        /// the kernel skips it as silent).
        public var level: Double
        public var serial: UInt32
    }

    /// Per-mode envelopes kept per row by the kernel's scope meters.
    public static let scopeModeCount = 16

    /// SCOPE TELEMETRY (2026-09-01): arm/disarm the kernel's display-only
    /// per-row meters (a fresh arm starts from cleared meters). Disarmed
    /// = the exact legacy tick. Control thread.
    public func setScopeArmed(_ on: Bool) {
        guard let pk = pkernel else { return }
        bow_poly_scope_arm(pk, on ? 1 : 0)
    }

    /// The taraf rows' scope read (kernel row order; empty unarmed or
    /// without a jt block). Racy telemetry reads; poll at UI rate.
    public func scopeRows() -> [ScopeRow] {
        guard let pk = pkernel else { return [] }
        let n = selRowFreqs.count
        guard n > 0 else { return [] }
        let K = Self.scopeModeCount
        var f0 = [Double](repeating: 0, count: n)
        var lv = [Double](repeating: 0, count: n)
        var slp = [UInt8](repeating: 0, count: n)
        var modes = [Float](repeating: 0, count: n * K)
        let got = Int(bow_poly_scope_jt(pk, Int32(n), &f0, &lv, &slp,
                                        &modes, Int32(K)))
        guard got > 0 else { return [] }
        let g = outGain
        return (0..<min(n, got)).map { s in
            ScopeRow(f0Hz: f0[s], level: lv[s] * g, asleep: slp[s] != 0,
                     isFollower: s == jtTrackRowIdx,
                     isChromatic: s < jtRowChromatic.count && jtRowChromatic[s],
                     modes: Array(modes[(s * K)..<((s + 1) * K)]))
        }
    }

    /// The played strings' scope read: every slot's target pitch + bow
    /// gate (mapper) and ring envelope (kernel). Allocates (UI rate only).
    public func scopeSlots() -> [ScopeSlot] {
        guard let pk = pkernel else { return [] }
        var lv = [Double](repeating: 0, count: maxPoly)
        let nb = Int(bow_poly_scope_slots(pk, &lv, Int32(maxPoly)))
        var snap = BowControlMapper.PolySnapshot(count: maxPoly)
        mapper.snapshotPoly(into: &snap)
        let m = min(maxPoly, nb, snap.slots.count)
        return (0..<m).map { i in
            ScopeSlot(f0Hz: snap.slots[i].f0Target,
                      gated: snap.slots[i].gate > 0.5,
                      level: lv[i], serial: snap.slots[i].serial)
        }
    }

    // MARK: - Bus volume meter (2026-08-24)

    /// BUS VOLUME METER: the VOICE and TARAF buses' levels, for the
    /// iPad's volume readout. Armed, the render always takes the
    /// split-bus path (`bow_poly_process3`) so the two levels exist
    /// separately even with the FX inserts idle — the kernel documents
    /// host-side `out + outJt` as BIT-EXACT against the fused path
    /// (`BusMeterTests` pins it), so parity renders are untouched.
    /// Levels are kernel-rate RMS × the current output gain (trim ×
    /// `bow_gain`) — display units that track the master volume; the
    /// radiation FIR/room after the merge are shared O(1) coloration.
    /// INTEGRATE-AND-DUMP, deliberately NO smoothing (2026-08-24 second
    /// rev — the first cut's fast-attack/250 ms-release envelope imposed
    /// its OWN ~1.7 s/60 dB decay on the display: a staccato cut, a
    /// choked taraf and the natural ring all fell at the meter's rate,
    /// and the peak-hold read voice ≈ taraf): each `busLevels()` call
    /// returns the EXACT RMS of the audio rendered since the previous
    /// call and resets the accumulator, so the reading has the poller's
    /// resolution and no memory — decay rates on the scope are the
    /// buses' true rates. Default OFF = the exact legacy render path.
    public func setBusMeter(_ on: Bool) {
        os_unfair_lock_lock(&tiltLock)
        meterArmed = on
        if !on {
            meterSumV = 0; meterSumT = 0; meterFrames = 0
            meterLast = (0, 0)
        }
        os_unfair_lock_unlock(&tiltLock)
    }

    /// (voice, taraf) RMS of everything rendered since the previous call
    /// — (0, 0) unarmed. If nothing rendered in between (poller faster
    /// than the device callback), the previous reading is repeated.
    /// Safe from any thread; poll at UI rate.
    public func busLevels() -> (voice: Double, taraf: Double) {
        os_unfair_lock_lock(&tiltLock)
        defer { os_unfair_lock_unlock(&tiltLock) }
        if meterFrames > 0 {
            let n = Double(meterFrames)
            meterLast = ((meterSumV / n).squareRoot(),
                         (meterSumT / n).squareRoot())
            meterSumV = 0; meterSumT = 0; meterFrames = 0
        }
        return meterLast
    }

    // All under tiltLock.
    private var meterArmed = false
    private var meterSumV = 0.0          // Σ (outGain·x)² since last read
    private var meterSumT = 0.0
    private var meterFrames = 0
    private var meterLast = (0.0, 0.0)

    /// Render thread: fold one split-bus chunk (kernel rate, mid streams)
    /// into the interval accumulators. Called AFTER the bus FX inserts,
    /// the taraf comp and the balance, and BEFORE
    /// the buses merge, so the meter shows what each bus actually
    /// contributes to the mix.
    private func meterBuses(voice: UnsafePointer<Double>,
                            taraf: UnsafePointer<Double>, nk: Int) {
        var sv = 0.0, st = 0.0
        for i in 0..<nk {
            sv += voice[i] * voice[i]
            st += taraf[i] * taraf[i]
        }
        let g2 = outGain * outGain
        os_unfair_lock_lock(&tiltLock)
        meterSumV += sv * g2
        meterSumT += st * g2
        meterFrames += nk
        os_unfair_lock_unlock(&tiltLock)
    }

    // MARK: - Voice↔taraf balance + taraf compressor (2026-08-24)

    /// VOICE↔TARAF BALANCE (`bow_bal`, .live): −1…+1, 0 = neutral
    /// (bit-exact byte-null). A pure attenuator pair at the bus merge —
    /// positive turns the VOICE down (gain 1−b), negative turns the
    /// TARAF down (gain 1+b… mirrored), so neither side is ever boosted
    /// past its calibrated level and no new headroom appears. Slewed
    /// ~30 ms and interpolated across the chunk (an offline 4096-frame
    /// chunk must not step). Needs the split-bus render — armed, the
    /// chunk takes the `bow_poly_process3` path (bit-exact when the
    /// balance is byte-null; the meter/FX already share it).
    public func setBusBalance(_ b: Double) {
        os_unfair_lock_lock(&tiltLock)
        balTarget = min(max(b, -1.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// TARAF COMPRESSOR (`bow_jt_comp_*`, .live): feed-forward dynamics
    /// on the sympathetic jt bus ONLY — the played voice is untouched.
    /// Threshold in CALIBRATED OUTPUT units (the bus × the build-time
    /// trim, so it speaks the same ≈dBFS scale as the master limiter and
    /// the iPad volume readout, and does NOT move with `bow_gain`);
    /// 0 = off, bit-exact byte-null. Ratio 1 = off too (unity slope).
    /// Instant-attack envelope with `relMs` release; the GAIN slews with
    /// `atkMs` toward reduction and `relMs` back — atkMs > 0 lets a
    /// strike's first milliseconds through before the ring is held.
    /// Linked mid/side (one gain from the mid bus), so the stereo law's
    /// fold-down stays consistent.
    public func setJtComp(thresh: Double, ratio: Double,
                          atkMs: Double, relMs: Double) {
        os_unfair_lock_lock(&tiltLock)
        compThresh = max(thresh, 0.0)
        compInvRatioM1 = 1.0 / min(max(ratio, 1.0), 40.0) - 1.0
        // Per-sample (kernel-rate) coefficients. Attack 0 = instant.
        compAtkCoef = atkMs <= 0 ? 1.0
            : 1.0 - exp(-1.0 / (srk * atkMs * 0.001))
        let rel = min(max(relMs, 1.0), 5000.0)
        compRelCoef = 1.0 - exp(-1.0 / (srk * rel * 0.001))
        os_unfair_lock_unlock(&tiltLock)
    }

    /// PER-STRING VOICE-RELATIVE TARAF CAP (`bow_jt_cap*`, .live;
    /// 2026-08-31 as a bus stage, PER STRING since 2026-09-01): every
    /// sympathetic row's radiated output held AT OR BELOW the played
    /// voice's own level — the runaway-bloom lever (high
    /// `bow_jt_evolve` lets the web feed itself past the voice; the
    /// fixed-threshold comp can't follow a phrase's dynamics, this cap
    /// does). Side-chain: an instant-attack peak envelope of the VOICE
    /// bus with a slow ~1.2 s-τ release — the ceiling a note leaves
    /// behind decays ~7 dB/s, so a string may ring on after the note
    /// (decay slower than the voice) but never PEAK above what the
    /// voice reached. Ceiling = voice peak × `ratio` (1 = parity,
    /// 0.5 = each string −6 dB under the voice…); `hard` 0…1 is the
    /// knee: the applied reduction is `hard` × the full dB overshoot
    /// — 0 = off (bit-exact byte-null), 1 = a hard relative limiter,
    /// between = a soft proportional lean. Dimensionless ratio law, so
    /// it rides `bow_gain`/expression untouched. Applied INSIDE the
    /// kernel's jt tick, row by row (`bow_poly_jt_set_cap`): one
    /// blooming anchor row is held on its own while its neighbours
    /// stand — the summed-bus version ducked the whole web for one hot
    /// string. With the voice silent from launch the ceiling is
    /// ~zero: armed hard, the cap holds down anything charged by other
    /// sources (drones, `tp_taraf`) until the voice first sounds —
    /// that IS the contract; leave it off (default) to keep an
    /// autonomous taraf. Fixed clocks (row env release 150 ms; gain
    /// slew 3 ms toward reduction / 120 ms recovery). Pre-FX, pre-trim
    /// (both buses share the trim, so the ratio is the same as at the
    /// calibrated merge); the balance stays a manual mix move after it.
    /// `bus` 0…1 (`bow_jt_cap_bus`, 2026-09-02) blends the SCOPE: 0 =
    /// per string (above); 1 = per taraf — the rows stand and the
    /// summed web is held against the same ceiling in the kernel's
    /// hold walk (the 2026-08-31 bus limiter); between, the rows remove
    /// hard·(1−bus) of their own overshoot and the sum removes hard·bus
    /// of what remains. Plain kernel scalar write (the drone-setter
    /// contract).
    public func setJtCap(hard: Double, ratio: Double, bus: Double = 0) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_cap(pk, min(max(hard, 0.0), 1.0),
                            min(max(ratio, 0.01), 4.0),
                            min(max(bus, 0.0), 1.0))
    }

    // Staged under tiltLock (targets/coefs); *Cur/env/gain are render
    // thread only.
    private var balTarget = 0.0
    private var balCur = 0.0
    private var compThresh = 0.0          // 0 = off
    private var compInvRatioM1 = -0.75    // 1/ratio − 1 (ratio 4)
    private var compAtkCoef = 1.0         // per-sample gain slew, attack
    private var compRelCoef = 0.000069    // per-sample, release (150 ms @ 96k)
    private var compEnv = 0.0
    private var compGain = 1.0

    /// Render thread: compress the taraf bus in place (kernel rate).
    /// One gain from the mid stream, applied to mid and side alike.
    private func applyJtComp(taraf: UnsafeMutablePointer<Double>,
                             tarafS: UnsafeMutablePointer<Double>?,
                             nk: Int, thresh: Double, invRatioM1: Double,
                             atkCoef: Double, relCoef: Double) {
        let scale = trimBase              // calibrated-output units
        var env = compEnv, gain = compGain
        for i in 0..<nk {
            let a = abs(taraf[i]) * scale
            if a > env { env = a }                       // instant attack
            else { env += relCoef * (a - env) }          // smooth release
            let gT = env > thresh
                ? pow(env / thresh, invRatioM1) : 1.0
            if gT < gain { gain += atkCoef * (gT - gain) }
            else { gain += relCoef * (gT - gain) }
            taraf[i] *= gain
            if let s = tarafS { s[i] *= gain }
        }
        compEnv = env
        compGain = gain
    }

    /// Render thread: the balance attenuator pair, slewed across the
    /// chunk (piecewise-linear per sample — no steps at any chunk size).
    private func applyBusBalance(voice: UnsafeMutablePointer<Double>,
                                 voiceS: UnsafeMutablePointer<Double>?,
                                 taraf: UnsafeMutablePointer<Double>,
                                 tarafS: UnsafeMutablePointer<Double>?,
                                 nk: Int, target: Double) {
        let bFrom = balCur
        let dt = Double(nk) / srk
        balCur += (1.0 - exp(-dt / 0.03)) * (target - balCur)
        if target == 0.0, abs(balCur) < 1e-5 { balCur = 0.0 }
        let db = (balCur - bFrom) / Double(max(nk, 1))
        for i in 0..<nk {
            let b = bFrom + db * Double(i)
            let gV = min(1.0, 1.0 - b)
            let gT = min(1.0, 1.0 + b)
            voice[i] *= gV
            taraf[i] *= gT
            if let s = voiceS { s[i] *= gV }
            if let s = tarafS { s[i] *= gT }
        }
    }

    /// SITAR TWANG 0…1 (base parameter `bow_twang`): the played strings'
    /// grazing bridge fold — 0 = the plain bridge (byte-exact legacy),
    /// 1 = the fitted sitar-jawari wrap (even-harmonic flattening + the
    /// delayed high-harmonic bloom). The knee rides each string's own
    /// peak envelope in-kernel, so the twang engages at any strike
    /// level. Plain kernel scalar write (the drone-setter contract); the
    /// kernel slews the amount ~30 ms.
    public func setTwang(_ amt01: Double) {
        guard let pk = pkernel else { return }
        bow_poly_set_twang(pk, min(max(amt01, 0.0), 1.0))
    }

    /// OFFLINE fitting hook for the twang fold's shape (the
    /// `bow_jt_set_lift` precedent — no registry parameter drives this;
    /// internal so only tests/tools reach it). Non-positive keeps the
    /// kernel's fitted default.
    func setTwangShape(kneeR: Double, depth: Double, relMs: Double,
                       rollSmp: Double, bright: Double = 0,
                       ring: Double = 0, gut: Double = 0) {
        guard let pk = pkernel else { return }
        bow_poly_set_twang_shape(pk, kneeR, depth, relMs, rollSmp,
                                 bright, ring, gut)
    }

    /// SETTLE DAMP (2026-08-18): direct, unsmoothed taraf t60 override,
    /// used ONLY inside the build-time settle pre-roll — chokes the q0
    /// relax chime inside the discarded blocks so the engine publishes
    /// silent (the anchors' natural 7–9 s tails would otherwise ride out
    /// audibly for ~10 s). t60 <= 0 restores the natural ring EXACTLY
    /// (`jtDampMul` is a pure per-tick momentum scalar; 0 = byte-null —
    /// the wrap's static q settles under contact regardless, damping
    /// only kills the oscillation faster). Never call on a published
    /// engine — the runtime axis is `setTarafDamp` (smoothed), and its
    /// chunk-rate smoother only pushes on CHANGE, so it cannot fight
    /// this inside the pre-roll while the axis rests at 0.
    public func setJtSettleDamp(t60: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_damp_t60(pk, t60)
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

    /// TARAF RECRUITMENT PROFILE 0..1 (base parameter `bow_jt_sel`;
    /// 2026-08-01 PROFILE rework — the first bipolar axis' top half was
    /// a pure uniform boost, so the knob read as a taraf VOLUME; the
    /// interim monotone-breadth cut topped out at the fitted response,
    /// which is still note-dependent. The knob now sweeps each row's
    /// CONTRIBUTION to the taraf, loudness held):
    ///  * **0.5 = the fitted taraf** (all weights 1, bit-exact) — the
    ///    natural resonance profile: unison rows dominate, octaves a
    ///    few dB down, fifths faint, unrelated rows only haze.
    ///  * **below 0.5** rows lose bridge drive by harmonic DISTANCE
    ///    from the played pitches until at 0 only kin rows ring — the
    ///    kin score is SQUARED at the endpoint so octaves sit clearly
    ///    below the unison and the fifth family is faint (the lattice
    ///    stays `bow_jt_sel_kin`, shared with the drone spread).
    ///  * **above 0.5** the profile FLATTENS: resonant rows are cut
    ///    toward the common haze level (`w → √(haze/(haze+kin²))` — the
    ///    cut direction is the lever that works; extra drive is drained
    ///    by the graze contact) until at 1 every row contributes
    ///    EQUALLY and the taraf's response no longer depends on what
    ///    the voice plays.
    ///  * **loudness compensation**: the RADIATED jt gain
    ///    (`bow_poly_jt_set_gain_mul`) holds the level — below 0.5 at
    ///    the note's own fitted power, above 0.5 blending to ONE fixed
    ///    common level (rows·haze + `recruitKinNominal`, a tonic-like
    ///    note's kin power) so the flat end is note-independent in
    ///    level too. Capped ×`bow_jt_sel_comp` (4, the kernel clamp).
    ///    Held-drone rows and the melody follower count as fully
    ///    ringing in the model, so the compensation never pumps a held
    ///    drone.
    /// Chords recruit additively (soft-OR — gentler than a max, still
    /// bounded). Weights gate the DRIVE only: rings already sounding
    /// decay naturally, and a held drone's own noise drive is never
    /// ducked. Per-row slew in the kernel (~30 ms); rescored per chunk
    /// on the render thread.
    public func setTarafSelectivity(_ s01: Double) {
        os_unfair_lock_lock(&tiltLock)
        selTarget = min(max(s01, 0.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// The kin lattice of the recruitment axis: frequency ratios through
    /// which a LINEARLY driven sympathetic string still resonates (shared
    /// low-order partials), each with p·q — the order of the shared
    /// partial (the row's q-th harmonic is the played note's p-th).
    /// Kinship strength = (p·q)^-`bow_jt_sel_kin`, so one exponent sets
    /// how fast octaves/fifths fade below the unison.
    static let recruitKin: [(ratio: Double, pq: Double)] = [
        (1.0, 1),                       // unison
        (2.0, 2), (0.5, 2),             // octave
        (4.0, 4), (0.25, 4),            // double octave
        (3.0, 3), (1.0 / 3.0, 3),       // twelfth
        (1.5, 6), (2.0 / 3.0, 6),       // fifth
        (0.75, 12), (4.0 / 3.0, 12),    // fourth
    ]

    /// Kinship 0..1 of a row `c` cents away from a played pitch: the
    /// best kin interval's strength through a Gaussian cents falloff.
    /// The ONE scoring core — the render path and the public helper
    /// both call it.
    static func recruitAffinity(centsFromPlayed c: Double,
                                kinCents: [Double], kinStrength: [Double],
                                widthCents: Double) -> Double {
        var best = 0.0
        for j in 0..<kinCents.count {
            let d = abs(c - kinCents[j])
            guard d < 4.0 * widthCents else { continue }
            let a = kinStrength[j]
                * exp(-0.5 * (d / widthCents) * (d / widthCents))
            if a > best { best = a }
        }
        return min(best, 1.0)
    }

    /// One row's kin score 0..1 (soft-OR across the chord: misses
    /// multiply, so two half-kin notes recruit more than either alone
    /// but never past 1). The shared core of `recruitWeight` and
    /// `recruitGainMul`.
    static func recruitKinScore(rowHz: Double, playedHz: [Double],
                                widthCents: Double,
                                kinExp: Double) -> Double {
        let kc = recruitKin.map { 1200.0 * log2($0.ratio) }
        let ks = recruitKin.map { pow($0.pq, -kinExp) }
        var miss = 1.0
        for p in playedHz where p > 0 && rowHz > 0 {
            let c = 1200.0 * log2(rowHz / p)
            miss *= 1.0 - recruitAffinity(centsFromPlayed: c, kinCents: kc,
                                          kinStrength: ks,
                                          widthCents: widthCents)
        }
        return 1.0 - miss
    }

    /// One row's bridge-drive weight for a set of played pitches at a
    /// given profile position — the exact math the render thread pushes
    /// into the kernel (minus the follower/drone exemptions). 0.5 = 1
    /// everywhere (fitted); 0 = squared kin score (kin-only); 1 = the
    /// EQUAL-contribution cut `√(haze/(haze+kin²))` (a unison row falls
    /// to ~0.22, a non-kin row stays 1 — the whole bank levels at the
    /// haze). Public for tests and offline tuning; the render path uses
    /// precomputed tables.
    public static func recruitWeight(rowHz: Double, playedHz: [Double],
                                     selectivity: Double,
                                     widthCents: Double = 30.0,
                                     kinExp: Double = 0.7) -> Double {
        let s = min(max(selectivity, 0.0), 1.0)
        if abs(s - 0.5) <= 1e-12 { return 1.0 }
        let kin = recruitKinScore(rowHz: rowHz, playedHz: playedHz,
                                  widthCents: widthCents, kinExp: kinExp)
        let kin2 = kin * kin
        if s < 0.5 {
            let t = s * 2.0
            return t + (1.0 - t) * kin2
        }
        let u = (s - 0.5) * 2.0
        let flat = (recruitHazeFloor / (recruitHazeFloor + kin2)).squareRoot()
        return 1.0 + u * (flat - 1.0)
    }

    /// Non-resonant response floor of a jawari row relative to a unison
    /// row (power): the haze a row rings with under full drive even when
    /// it shares no kin interval with the played note. The model's ONE
    /// texture constant: it sets both the flat end's per-row level (all
    /// rows cut to it) and the compensation's smoothness on non-kin
    /// notes (with no floor a non-kin note's model power is ~0 and the
    /// gain would jump straight to the cap).
    static let recruitHazeFloor = 0.05

    /// The flat end's common loudness anchor: the modeled kin power of a
    /// tonic-like note (unison + two octave rows ≈ 1 + 2·0.38). At
    /// profile 1 every note's taraf is leveled to rows·hazeFloor + THIS
    /// — a fixed reference, so neither the per-row contributions nor the
    /// overall level depend on the played note.
    static let recruitKinNominal = 1.75

    /// The loudness-consistency gain for a whole bank at a given profile
    /// position: the radiated-gain multiplier that holds the taraf's
    /// power (incoherent model — row ring power ∝ weight² ×
    /// (hazeFloor + kin²)), clamped [1, cap]. Below 0.5 the reference is
    /// the note's own fitted power; above 0.5 it blends to the FIXED
    /// common level (rows·hazeFloor + `recruitKinNominal`) so the flat
    /// end is note-independent. The exact math the render thread pushes
    /// through `bow_poly_jt_set_gain_mul` (minus the follower/held-drone
    /// rows, which count as fully ringing). 1 at 0.5.
    public static func recruitGainMul(rowsHz: [Double], playedHz: [Double],
                                      selectivity: Double,
                                      widthCents: Double = 30.0,
                                      kinExp: Double = 0.7,
                                      cap: Double = 4.0) -> Double {
        let s = min(max(selectivity, 0.0), 1.0)
        if abs(s - 0.5) <= 1e-12 { return 1.0 }
        let u = max(0.0, (s - 0.5) * 2.0)
        var pFit = 0.0, pNow = 0.0
        var n = 0
        for r in rowsHz where r > 0 {
            let kin = recruitKinScore(rowHz: r, playedHz: playedHz,
                                      widthCents: widthCents, kinExp: kinExp)
            let kin2 = kin * kin
            let w = recruitWeight(rowHz: r, playedHz: playedHz,
                                  selectivity: s, widthCents: widthCents,
                                  kinExp: kinExp)
            pFit += recruitHazeFloor + kin2
            pNow += w * w * (recruitHazeFloor + kin2)
            n += 1
        }
        let refTop = Double(n) * recruitHazeFloor + recruitKinNominal
        let pRef = (1.0 - u) * pFit + u * refTop
        guard pNow > 1e-12 else { return cap }
        return min(max((pRef / pNow).squareRoot(), 1.0), cap)
    }

    /// Per-chunk RECRUITMENT update (render thread), the contribution-
    /// profile axis with the loudness held: every row's kinship to the
    /// gated pitches is scored (soft-OR across the chord), its bridge-
    /// drive weight moved toward kin² (below 0.5, the kin-only strip)
    /// or toward the equal-contribution cut √(haze/(haze+kin²)) (above
    /// 0.5, the flat end), and the per-row weights pushed for the
    /// kernel to slew (~30 ms). The radiated jt gain simultaneously
    /// holds the taraf's power (the incoherent model of
    /// `recruitGainMul`: below 0.5 at the note's own fitted level,
    /// above 0.5 blending to the fixed common level so the flat end is
    /// note-independent; cap ×`bow_jt_sel_comp` — the RADIATED gain
    /// because extra drive is drained by the graze contact). The
    /// follower row keeps weight 1 on the selective half (it tracks the
    /// melody) but flattens like a unison row on the flat half (nothing
    /// should be pitch-tracking there); it and held-drone rows count as
    /// fully ringing in the model, so the compensation never pumps a
    /// drone. A chunk with no gated note holds the last weights + gain,
    /// so a ring keeps the recruit pattern of the note that excited it.
    /// Back at 0.5 one all-ones push restores the fitted taraf and the
    /// path goes quiet. No allocation.
    private func updateRecruitment(_ pk: UnsafeMutableRawPointer) {
        guard !selRowFreqs.isEmpty else { return }
        os_unfair_lock_lock(&tiltLock)
        let sel = selTarget
        os_unfair_lock_unlock(&tiltLock)
        let neutral = abs(sel - 0.5) <= 1e-4
        if neutral, !selEngaged { return }
        var np = 0
        if !neutral {
            for s in 0..<maxPoly {
                let slot = polySnap.slots[s]
                if slot.gate > 0.0, slot.f0Target > 0.0 {
                    selPitches[np] = slot.f0Target
                    np += 1
                }
            }
            if np == 0 { return }
        }
        let eps = Self.recruitHazeFloor
        let t = min(sel, 0.5) * 2.0          // selective half: 0 = kin-only
        let u = max(0.0, (sel - 0.5) * 2.0)  // flat half: 1 = equal
        var changed = false
        // pInv: rows whose ring does not follow the weights (follower,
        // held drones) — they enter BOTH sides of the ratio unchanged,
        // so with a drone held the compensation relaxes toward 1
        // instead of boosting the drone.
        var pNow = 0.0, pFit = 0.0, pInv = 0.0
        var nFree = 0
        for i in 0..<selRowFreqs.count {
            var kin2 = 1.0
            if !neutral, i != jtTrackRowIdx {
                let fr = selRowFreqs[i]
                var miss = 1.0
                for k in 0..<np {
                    let c = 1200.0 * log2(fr / selPitches[k])
                    miss *= 1.0 - Self.recruitAffinity(
                        centsFromPlayed: c, kinCents: selKinCents,
                        kinStrength: selKinStrength,
                        widthCents: selWidthCents)
                }
                let kin = 1.0 - miss
                kin2 = kin * kin
            }
            var w = 1.0
            if !neutral {
                if u > 0.0 {
                    let flat = (eps / (eps + kin2)).squareRoot()
                    w = 1.0 + u * (flat - 1.0)
                } else {
                    w = t + (1.0 - t) * kin2
                }
            }
            let invariant = i == jtTrackRowIdx
                || (i < droneHeldMask.count && droneHeldMask[i])
            if invariant {
                pInv += eps + 1.0
            } else {
                nFree += 1
                pFit += eps + kin2
                pNow += w * w * (eps + kin2)
            }
            jtDwTargets[i] = w
            if abs(w - jtDwPushed[i]) > 1e-4 { changed = true }
        }
        var gMul = 1.0
        if !neutral {
            let refTop = Double(nFree) * eps + Self.recruitKinNominal
            let pRef = pInv + (1.0 - u) * pFit + u * refTop
            let pAll = pInv + pNow
            gMul = pAll > 1e-12
                ? min(max((pRef / pAll).squareRoot(), 1.0), selComp)
                : selComp
        }
        if abs(gMul - selGMulPushed) > 1e-4 {
            selGMulPushed = gMul
            bow_poly_jt_set_gain_mul(pk, gMul)
        }
        if changed {
            jtDwTargets.withUnsafeBufferPointer {
                bow_poly_jt_drive_weights(pk, $0.baseAddress!,
                                          Int32($0.count))
            }
            for i in 0..<jtDwTargets.count { jtDwPushed[i] = jtDwTargets[i] }
        }
        selEngaged = !neutral
    }

    // MARK: - Live parameters (Tarabdaar 2026-07-24)

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
        os_unfair_lock_lock(&tiltLock)
        trimBase = outGain            // build-time trim = the fitted base
        os_unfair_lock_unlock(&tiltLock)
    }

    /// MASTER GAIN (`bow_gain`, .live 2026-08-23): the performance volume
    /// of the WHOLE radiated instrument — multiplies the fitted trim at
    /// the same ramped output gain (~25 ms glide, chunk-capped), with NO
    /// bp push, NO rebuild and NO debounce, so a tilt/strike binding
    /// sweeps it in real time. Runtime playing state (the bow_jt_damp
    /// pattern): `StringVoiceSource` caches it and re-applies across
    /// rebuilds; the bp dict never carries the key. Control-thread safe —
    /// the render thread picks the change up at the next chunk
    /// (`applyPendingLive`).
    public func setMasterGain(_ g: Double) {
        let gg = max(g, 0.0)
        os_unfair_lock_lock(&tiltLock)
        if abs(gg - masterGain) > 1e-12 {
            masterGain = gg
            masterGainDirty = true
            liveRampArmed = true      // first chunk after the change ramps
        }
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Master-gain state, all under `tiltLock`: the current factor, the
    /// render-thread pickup flag, and the FITTED trim base (bp's
    /// bow_live_trim, pre-gain) — kept separate so gain moves need no bp
    /// and bp pushes compare in BASE terms (the no-op-push chunk-cap
    /// guard must not fire just because gain ≠ 1).
    private var masterGain = 1.0
    private var masterGainDirty = false
    private var trimBase = 1.0

    /// `tables` (stage 3) additionally reloads the BODY modal bank and the
    /// modal-jawari coefficients in place. Pass nil to move scalars only.
    /// The kernel refuses a reload whose shape moved, in which case the
    /// engine keeps its current tables — the caller must rebuild, and
    /// `ParamRegistry.inPlaceKeys` is what guarantees that never happens.
    public func setLiveParams(bp: BowParams, scalars: [Double],
                              tables: BowKernelTables? = nil) {
        guard scalars.count == 66 else { return }
        // Arm the RAMP only when a ramped quantity actually moved. The
        // ramp caps `render`'s chunk to 256 frames, and chunk size is NOT
        // neutral: it sets the control-interpolation grid and the jt
        // block boundaries, so splitting a 4096-frame offline render
        // perturbs a chaotic friction loop (measured 41% of peak for a
        // no-op push before this check). Coefficient reloads need no ramp
        // — swapping filter coefficients while keeping state is
        // click-free — so a tables-only edit does not arm it either.
        // The trim is compared in BASE terms (pre master-gain) against
        // `trimBase` — the applied trim is base × masterGain, but gain
        // moves travel their own path (`setMasterGain`) and must not make
        // every bp push look like a trim change.
        let gains = (mix: bp.v("bow_rev_mix", reverb.mix),
                     width: bp.v("bow_rev_width", reverb.width))
        os_unfair_lock_lock(&tiltLock)
        let baseTrim = bp.v("bow_live_trim", trimBase)
        let ramped = scalars != liveScalarsTarget
            || abs(baseTrim - trimBase) > 1e-12
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
        guard let st = pkernel else { return }
        t.ba1.withUnsafeBufferPointer { a1 in
            t.ba2.withUnsafeBufferPointer { a2 in
                t.bn0.withUnsafeBufferPointer { n0 in
                    t.bA.withUnsafeBufferPointer { bA in
                        t.bC.withUnsafeBufferPointer { bC in
                            let k = Int32(t.ba1.count)
                            _ = bow_poly_set_body(st, k, a1.baseAddress,
                                                  a2.baseAddress,
                                                  n0.baseAddress,
                                                  bA.baseAddress,
                                                  bC.baseAddress)
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
        jt.rowForceScale.withUnsafeBufferPointer { radScale in
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
            let ok = bow_poly_jt_set_coeffs(st, n, J, M.baseAddress,
                ca.baseAddress, cb.baseAddress, ca4.baseAddress,
                cb4.baseAddress, wd.baseAddress, radScale.baseAddress,
                phiD.baseAddress, phiU.baseAddress, phiF.baseAddress,
                b.baseAddress, G.baseAddress, G4.baseAddress,
                gd.baseAddress, gd4.baseAddress, phys.baseAddress)
            if ok == 1 {
                // TWO BRIDGES: the per-row contact law and the per-bridge
                // evolve map follow the reloaded tables (a `bow_jtc_*`
                // or `bow_jt_apex` edit lands here)
                jtRowChromatic = jt.rowChromatic
                jtRowApex = jt.rowApex
                jtHasChromatic = jt.hasChromatic
                jtApexRef = jt.apexRef
                pushJtRowContact(jt)
                pushJtEvolveOffsets()
            }
        }}}}}}}}}}}}}}}}
        // Melody follower: refresh the retune-law constants (t60 / fhf /
        // bst may have moved with the edit). Re-arming the SAME row keeps
        // its current pitch — the kernel just recomputes at the next tick.
        if jt.trackRow >= 0, Int(jt.trackRow) < jt.rowFreqs.count {
            bow_poly_jt_track_config(st, jt.trackRow,
                                     jt.rowFreqs[Int(jt.trackRow)],
                                     jt.trackT60, jt.trackFhf, jt.trackBst)
        }
    }

    /// Current / target kernel scalar vectors. The push is RAMPED rather
    /// than applied in one step: several of the 62 scalars multiply the
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
        let gainDirty = masterGainDirty
        masterGainDirty = false
        let gain = masterGain
        let base = trimBase
        os_unfair_lock_unlock(&tiltLock)

        // Master-gain-only change (a bound axis moving): retarget the
        // trim glide without any bp push.
        if gainDirty, pending == nil {
            liveGainTarget.trim = base * gain
            liveRamping = true
        }

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
            let newBase = bp.v("bow_live_trim", base)
            os_unfair_lock_lock(&tiltLock)
            trimBase = newBase
            os_unfair_lock_unlock(&tiltLock)
            liveGainTarget = (trim: newBase * gain,
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
            // output safety limiter: plain scalar adoption (the limiter's
            // own gain smoothing makes threshold moves click-free)
            limThresh = min(max(bp.v("bow_lim_thresh", 0.8), 0.1), 1.0)
            limRelCoef = 1.0 - exp(-1.0 /
                (max(bp.v("bow_lim_rel_ms", 150.0), 5.0) * 0.001 * sr))
            liveRamping = true
        }

        // (Gains can ramp before any scalar push has ever happened — a
        // master-gain move on a fresh engine — so empty scalar history no
        // longer blocks the glide; the kernel push below stays guarded.)
        guard liveRamping else { return }
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
        if !liveScalarsCur.isEmpty {
            liveScalarsCur.withUnsafeBufferPointer { sp in
                if let pk = pkernel {
                    bow_poly_set_scalars(pk, sp.baseAddress!, Int32(sp.count))
                }
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
        let lT = jtLpHzTarget
        let hT = jtHpHzTarget
        let dT = dampAmtTarget
        os_unfair_lock_unlock(&tiltLock)
        if lT == 0.0, !jtLpEngaged, dT == 0.0, dampAmtCur == 0.0,
           hT == 0.0, jtHpHzCur == 0.0 { return }
        let a = 1.0 - exp(-Double(n48) / (0.04 * sr))
        // jt tone LP (smoothed in Hz; target 0 eases back to the build
        // corner then restores the exact build coefficient)
        let lpGoal = lT > 0 ? lT : tiltPureLpHiHz
        jtLpHzCur += a * (lpGoal - jtLpHzCur)
        if lT == 0.0, abs(jtLpHzCur - tiltPureLpHiHz) < 1.0 {
            jtLpHzCur = tiltPureLpHiHz
            if jtLpEngaged {
                jtLpEngaged = false
                if let pk = pkernel { bow_poly_jt_set_lp(pk, jtLpBaseA) }
            }
        } else if abs(jtLpHzCur - jtLpHzPushed) > 1.0 || (lT > 0 && !jtLpEngaged) {
            jtLpHzPushed = jtLpHzCur
            jtLpEngaged = true
            let lpA = 1.0 - exp(-2.0 * Double.pi * jtLpHzCur / jtTickRate)
            if let pk = pkernel { bow_poly_jt_set_lp(pk, lpA) }
        }
        // jt tone HP (the formant voicing; 0 eases the corner down to
        // bypass — one-pole state kept warm in the kernel)
        jtHpHzCur += a * (hT - jtHpHzCur)
        if hT == 0.0, jtHpHzCur < 1.0 { jtHpHzCur = 0.0 }
        if abs(jtHpHzCur - jtHpHzPushed) > 0.5 {
            jtHpHzPushed = jtHpHzCur
            let hpA = jtHpHzCur > 0
                ? 1.0 - exp(-2.0 * Double.pi * jtHpHzCur / jtTickRate) : 0.0
            if let pk = pkernel { bow_poly_jt_set_hp(pk, hpA) }
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

    /// TARABDAAR FX (2026-08-01): stage one insert point's settings from
    /// the control thread; the render thread adopts them at the next
    /// chunk boundary (the tone-tilt pattern). All-off is byte-null.
    public func setFX(_ point: FXPoint, _ settings: FXSettings) {
        os_unfair_lock_lock(&tiltLock)
        fxPending[point.rawValue] = settings
        fxDirty = true
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Per-chunk FX update (render thread): adopt staged settings and
    /// advance every unit's smoothers. `nk` = the chunk at kernel rate
    /// (drive/voice/taraf), `n48` = at engine rate (global).
    private func updateFX(nk: Int, n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let dirty = fxDirty
        let staged = dirty ? fxPending : []
        fxDirty = false
        os_unfair_lock_unlock(&tiltLock)
        if dirty {
            for i in fxUnits.indices { fxUnits[i].retarget(staged[i]) }
        }
        fxUnits[FXPoint.drive.rawValue].tick(frames: nk)
        fxUnits[FXPoint.voice.rawValue].tick(frames: nk)
        fxUnits[FXPoint.taraf.rawValue].tick(frames: nk)
        fxUnits[FXPoint.global.rawValue].tick(frames: n48)
    }

    /// Called by the kernel's drive hook with the recorded jt-drive block
    /// (render thread, kernel rate) — the voice→taraf insert.
    fileprivate func fxProcessDrive(_ buf: UnsafeMutablePointer<Double>,
                                    _ n: Int) {
        fxUnits[FXPoint.drive.rawValue].processMono(buf, n)
    }

    deinit {
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
            renderPolyChunk(n, outL: outL + done, outR: outR + done)
            done += n
        }
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
        // Melody follower: target = the HIGHEST gated note (the mapper's
        // musical pitch, bend included — scale-exact, which is what a
        // sympathetic resonance wants). No gated note = keep the last
        // target, so the string rings out where the melody left it.
        if trackArmed {
            var hi = 0.0
            for s in 0..<maxPoly {
                let slot = polySnap.slots[s]
                if slot.gate > 0.0, slot.f0Target > hi { hi = slot.f0Target }
            }
            if hi > 0.0, hi != trackHzPushed {
                trackHzPushed = hi
                bow_poly_jt_track_target(pk, hi)
            }
        }
        // RECRUITMENT (bow_jt_sel): re-score the taraf's bridge-drive
        // weights against the gated pitch set (no-op while the axis is
        // off — the kernel stays byte-null)
        updateRecruitment(pk)
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
                                    // Per-slot expression scale (the strum
                                    // chord, 2026-08-28): ×1.0 is an IEEE
                                    // identity, so every non-strum path is
                                    // bit-exact.
                                    let snap = BowControlMapper.Snapshot(
                                        f0Target: slot.f0Target, gate: slot.gate,
                                        expr: polySnap.expr * slot.exprScale,
                                        press: polySnap.press,
                                        pos: polySnap.pos, tiltDb: polySnap.tiltDb,
                                        vib: polySnap.vib,
                                        onVel: slot.onVel)
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
        // FX rack: adopt staged settings + advance smoothers (chunk rate).
        // The voice/taraf inserts split the kernel's buses (bit-exact when
        // idle — each jt term lands exactly once, so bus + bus reproduces
        // the fused rounding); the drive insert fires inside the kernel
        // via the installed hook.
        updateFX(nk: nk, n48: n)
        let vIdx = FXPoint.voice.rawValue, tIdx = FXPoint.taraf.rawValue
        let busFX = fxUnits[vIdx].isEngaged || fxUnits[tIdx].isEngaged
        // Bus volume meter / balance / taraf comp: any of them armed,
        // the split path runs even with the bus FX idle (host-side bus
        // + bus is bit-exact — see setBusMeter; balance and comp are
        // byte-null at their neutral defaults). The voice-relative cap
        // lives inside the kernel per row since 2026-09-01 and needs
        // no split.
        os_unfair_lock_lock(&tiltLock)
        let metering = meterArmed
        let balT = balTarget
        let compTh = compThresh
        let compIR = compInvRatioM1
        let compAtk = compAtkCoef
        let compRel = compRelCoef
        os_unfair_lock_unlock(&tiltLock)
        let balOn = balT != 0.0 || balCur != 0.0
        let compOn = compTh > 0.0 && compIR < 0.0
        if !compOn, compGain != 1.0 || compEnv != 0.0 {
            // disarmed: forget the held reduction so a re-arm starts clean
            compEnv = 0.0
            compGain = 1.0
        }
        let splitBus = busFX || metering || balOn || compOn
        if stereoOn {
            y96.withUnsafeMutableBufferPointer { yb in
                y96S.withUnsafeMutableBufferPointer { sb in
                    if splitBus {
                        y96Jt.withUnsafeMutableBufferPointer { jb in
                            y96JtS.withUnsafeMutableBufferPointer { jsb in
                                bow_poly_process3(
                                    pk, Int32(nk), Int32(slotStride),
                                    cF0, cVb, cFb, cBeta, cGate, cXv,
                                    yb.baseAddress!, sb.baseAddress!,
                                    jb.baseAddress!, jsb.baseAddress!)
                                fxUnits[vIdx].processMidSide(
                                    yb.baseAddress!, sb.baseAddress!, nk)
                                fxUnits[tIdx].processMidSide(
                                    jb.baseAddress!, jsb.baseAddress!, nk)
                                if compOn {
                                    applyJtComp(taraf: jb.baseAddress!,
                                                tarafS: jsb.baseAddress!,
                                                nk: nk, thresh: compTh,
                                                invRatioM1: compIR,
                                                atkCoef: compAtk,
                                                relCoef: compRel)
                                }
                                if balOn {
                                    applyBusBalance(
                                        voice: yb.baseAddress!,
                                        voiceS: sb.baseAddress!,
                                        taraf: jb.baseAddress!,
                                        tarafS: jsb.baseAddress!,
                                        nk: nk, target: balT)
                                }
                                if metering {
                                    meterBuses(voice: yb.baseAddress!,
                                               taraf: jb.baseAddress!,
                                               nk: nk)
                                }
                                for i in 0..<nk {
                                    yb[i] += jb[i]
                                    sb[i] += jsb[i]
                                }
                            }
                        }
                    } else {
                        bow_poly_process2(pk, Int32(nk), Int32(slotStride),
                                          cF0, cVb, cFb, cBeta, cGate, cXv,
                                          yb.baseAddress!, sb.baseAddress!)
                    }
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
                if splitBus {
                    y96Jt.withUnsafeMutableBufferPointer { jb in
                        bow_poly_process3(pk, Int32(nk), Int32(slotStride),
                                          cF0, cVb, cFb, cBeta, cGate, cXv,
                                          yb.baseAddress!, nil,
                                          jb.baseAddress!, nil)
                        fxUnits[vIdx].processMono(yb.baseAddress!, nk)
                        fxUnits[tIdx].processMono(jb.baseAddress!, nk)
                        if compOn {
                            applyJtComp(taraf: jb.baseAddress!, tarafS: nil,
                                        nk: nk, thresh: compTh,
                                        invRatioM1: compIR,
                                        atkCoef: compAtk, relCoef: compRel)
                        }
                        if balOn {
                            applyBusBalance(voice: yb.baseAddress!,
                                            voiceS: nil,
                                            taraf: jb.baseAddress!,
                                            tarafS: nil,
                                            nk: nk, target: balT)
                        }
                        if metering {
                            meterBuses(voice: yb.baseAddress!,
                                       taraf: jb.baseAddress!, nk: nk)
                        }
                        for i in 0..<nk { yb[i] += jb[i] }
                    }
                } else {
                    bow_poly_process(pk, Int32(nk), Int32(slotStride),
                                     cF0, cVb, cFb, cBeta, cGate, cXv,
                                     yb.baseAddress!)
                }
                y48.withUnsafeMutableBufferPointer { ob in
                    dec.process(yb.baseAddress!, count: nk, into: ob.baseAddress!)
                }
            }
            postChain(n48: n, outL: outL, outR: outR)
        }
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
        // cancels the friction pull, so the string sounds at lf0)
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
        // FX rack, global point: after the whole fitted chain. A stereo
        // reverb here decorrelates the equal L/R split — deliberate.
        fxUnits[FXPoint.global.rawValue].processLR(outL, outR, n48)
        applyLimiter(n48: n48, outL: outL, outR: outR)
    }

    /// The output safety limiter (see the state declaration). Linked
    /// stereo: one gain from max(|L|, |R|), so limiting never leans the
    /// image. Below the ceiling — and once the gain has released back to
    /// exactly 1 — samples pass untouched (bit-exact).
    private func applyLimiter(n48: Int, outL: UnsafeMutablePointer<Double>,
                              outR: UnsafeMutablePointer<Double>) {
        let clamp = min(1.0, limThresh * 1.25)
        for i in 0..<n48 {
            let a = max(abs(outL[i]), abs(outR[i]))
            if a > limEnv { limEnv = a }                    // instant attack
            else { limEnv += limRelCoef * (a - limEnv) }    // smooth release
            if limEnv > limThresh || limGain < 1.0 {
                let gT = limEnv > limThresh ? limThresh / limEnv : 1.0
                limGain += limAttCoef * (gT - limGain)
                if gT == 1.0, limGain > 0.99999 { limGain = 1.0 }
                if limGain < 1.0 {
                    var l = outL[i] * limGain
                    var r = outR[i] * limGain
                    // the ~0.2 ms gain smoothing lets a few attack
                    // samples through hot — hard-stop them
                    if l > clamp { l = clamp } else if l < -clamp { l = -clamp }
                    if r > clamp { r = clamp } else if r < -clamp { r = -clamp }
                    outL[i] = l
                    outR[i] = r
                }
            }
        }
    }

    /// Stereo post-chain (Tarabdaar 2026-07-23): the mid (y48) and side
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
        // FX rack, global point (see postChain)
        fxUnits[FXPoint.global.rawValue].processLR(outL, outR, n48)
        applyLimiter(n48: n48, outL: outL, outR: outR)
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
        guard let pk = pkernel else { return }
        y96.withUnsafeMutableBufferPointer { yb in
            bow_poly_process(pk, Int32(nk), Int32(slotStride),
                             cF0, cVb, cFb, cBeta, cGate, cXv,
                             yb.baseAddress!)
            y48.withUnsafeMutableBufferPointer { ob in
                dec.process(yb.baseAddress!, count: nk, into: ob.baseAddress!)
            }
        }
        postChain(n48: nk / osFactor, outL: outL, outR: outR)
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
        for i in fxUnits.indices { fxUnits[i].reset() }
    }
}

/// C trampoline for the kernel's jt-drive FX hook (no captures — a plain
/// @convention(c) pointer). ctx is the unretained BowEngine.
private func bowEngineDriveFXHook(_ ctx: UnsafeMutableRawPointer?,
                                  _ buf: UnsafeMutablePointer<Double>?,
                                  _ n: Int32) {
    guard let ctx, let buf, n > 0 else { return }
    Unmanaged<BowEngine>.fromOpaque(ctx).takeUnretainedValue()
        .fxProcessDrive(buf, Int(n))
}
