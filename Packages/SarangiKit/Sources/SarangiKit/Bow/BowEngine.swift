import Foundation
import CBowKernel

/// The live bow-physics instrument: the streaming C friction kernel
/// (CBowKernel `bow_poly_*`) at 96 kHz, decimated 2:1 to the 48 kHz engine
/// rate and radiated through the post-chain (radiation FIR → low-pass →
/// room). The kernel emits ONE mono stream with the taraf fused in; with
/// `bow_st_width` armed it adds a SIDE stream and L/R = mid ± side, the
/// L+R fold-down always equalling the mono output exactly.
///
/// POLYPHONY: every mapper slot is its own gut string loading the SAME
/// bridge (one jawari web, one body, one post chain); each string's -Z·V
/// load is folded delay-free into the bridge solve, so stability is
/// structural at any polyphony.
///
/// RT-safe: all buffers are preallocated; `render` allocates nothing and
/// takes only brief `os_unfair_lock`s on control data (mapper snapshot,
/// `tiltLock`). Structural changes build a fresh engine off the render
/// thread; the long-lived BowControlMapper keeps held notes across swaps.
public final class BowEngine {
    public let sr: Double                 // engine rate (48 kHz)
    public let osFactor: Int              // kernel oversampling (bow_os)
    public let srk: Double                // kernel rate
    public let tables: BowKernelTables
    /// Gut strings on the shared bridge, one per mapper slot.
    public let maxPoly: Int

    /// Long-lived control mapper (owned by the host, shared across rebuilds).
    public let mapper: BowControlMapper
    var filter: BowControlFilter

    /// Fitted output level trim (untrimmed, the post-chain parks in the
    /// clipper). 1.0 (neutral) for the fixture/e2e path.
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
    /// STEREO SIDE PATH: with `bow_st_width` armed the kernel renders a
    /// SIDE stream (its diffuse-field difference bank on the whole radiated
    /// output) which rides decimator + radiation-chain twins here; L/R =
    /// mid ± side, fold-down bit-identical to the mono path. Off = mono.
    private var stereoOn = false
    private var decS = HalfBandDecimator()
    private var radFIRS: FIRFilter?
    private var radLpS: Biquad?
    private var radHillS: Biquad?
    private var radHPS: [Biquad] = []
    /// Membrane radiation-efficiency LF rolloff (`bow_rad_hp`, ord/2
    /// butter-2 sections): a small body cannot radiate below its skin mode.
    private var radHP: [Biquad] = []
    var reverb: Reverb

    // ---- FX RACK: four insert points, off by default (byte-null).
    // drive/voice/taraf run at KERNEL rate on the split buses, global at
    // engine rate after the post-chain. Staged under `tiltLock`. ----
    private var fxUnits: [FXChainUnit]
    private var fxPending: [FXSettings]
    private var fxDirty = false

    // ---- Runtime taraf/tone axes: taraf PURITY (jt tone LP) and DECAY
    // (momentum damping) are kernel scalars; TONE TILT is a shelf pair on
    // the voice output here. Targets under `tiltLock`; off = byte-null.
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
    // kernel-axis smoothers: targets written under `tiltLock`; the render
    // thread smooths at chunk rate and pushes the kernel only on change
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
    // MELODY FOLLOWER: armed when the jt tables carry a tracked row; the
    // render thread pushes the highest gated note as its target per chunk
    private var trackArmed = false
    private var trackHzPushed = 0.0
    // RECRUITMENT PROFILE (`bow_jt_sel`): each jawari row's bridge drive
    // across 0 = kin-only / 0.5 = fitted / 1 = equal contribution, the
    // radiated jt gain holding loudness. Rescored per chunk on the render
    // thread; the kernel slews the per-row weights (~30 ms).
    private var selTarget = 0.5               // bow_jt_sel runtime (0.5 = fitted)
    private var selEngaged = false            // render thread: axis in effect
    private var selWidthCents = 30.0          // bow_jt_sel_width
    private var selComp = 4.0                 // bow_jt_sel_comp (loudness-comp cap)
    private var selGMulPushed = 1.0           // last pushed radiated-gain mul
    private var selKinCents: [Double] = []    // kin offsets (cents)
    private var selKinStrength: [Double] = [] // (p·q)^-kinExp per kin
    private var selRowFreqs: [Double] = []     // row f0s (builder)
    private var jtTrackRowIdx = -1            // follower row: always weight 1
    // Per-row bridge membership + apex (the builder's), for the
    // per-bridge evolve map and the Scope tab.
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
    /// Side twins of the tilt shelves (same coefficients, own state):
    /// EQing mid and side alike equals EQing L/R, so the image holds.
    private var tiltLoShelfS: Biquad
    private var tiltHiShelfS: Biquad

    // ---- OUTPUT SAFETY LIMITER: linked-stereo peak limiter at the very
    // end of both post-chains. Instant attack, exponential release
    // (`bow_lim_rel_ms`), gain smoothed ~0.2 ms, hard clamp at
    // min(1, 1.25×ceiling) for the attack samples that slip through.
    // Below the ceiling it multiplies nothing — bit-exact passthrough. ----
    private var limThresh = 0.8       // bow_lim_thresh (1.0 ≈ FS safety)
    private var limRelCoef = 0.000139 // bow_lim_rel_ms (150 ms at 48 k)
    private let limAttCoef = 0.1      // ~0.2 ms gain smoothing
    private var limEnv = 0.0
    private var limGain = 1.0

    // preallocated per-buffer scratch; control arrays are SLOT-MAJOR at a
    // fixed stride (maxFrames·osFactor), `renderFixture` drives slot 0
    private let maxFrames: Int
    private let slotStride: Int
    private var cF0: [Double], cVb: [Double], cFb: [Double]
    private var cBeta: [Double], cGate: [Double], cXv: [Double]
    private var y96: [Double], y48: [Double]
    private var y96S: [Double], y48S: [Double]   // stereo side scratch
    private var y96Jt: [Double], y96JtS: [Double] // FX split taraf bus
    // poly per-slot state
    private var filters: [BowControlFilter] = []
    private var lastSerial: [UInt32] = []
    private var slotSilent: [Bool] = []
    private var polySnap: BowControlMapper.PolySnapshot

    /// `rfir` = the 48 kHz radiation FIR taps (empty ⇒ flat), `eLp` = the
    /// radiation low-pass corner (Hz; ≥ 0.44·sr ⇒ bypass).
    public init(tables: BowKernelTables, mapper: BowControlMapper,
                bp: BowParams, sr: Double = 48000.0,
                rfir: [Double], eLp: Double,
                reverbRT60: Double, reverbPredelayMs: Double,
                reverbMix: Double, reverbWidth: Double,
                maxFrames: Int = 4096,
                maxPoly: Int = 1) {
        self.sr = sr
        osFactor = max(1, Int(bp.v("bow_os", 2.0).rounded()))
        // the decimator is 2:1 — no other oversampling factor is supported
        precondition(osFactor == 2,
                     "bow_os \(osFactor) unsupported: the live decimator is 2:1")
        srk = sr * Double(osFactor)
        self.tables = tables
        self.mapper = mapper
        self.maxPoly = min(max(maxPoly, 1), BowControlMapper.maxSlots)
        // scalars[38] = f0Open = the tuning tonic (register-force reference)
        filter = BowControlFilter(bp: bp, srk: srk,
                                  tonic: tables.scalars.count > 38
                                      ? tables.scalars[38] : 261.63)
        dec = HalfBandDecimator()
        if !rfir.isEmpty { radFIR = FIRFilter(taps: rfir) }
        // bow_rad_lp_ord < 2 selects a one-pole rolloff; absent → 2nd order
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
        // BRIDGE HILL: presence peak in the radiation path; absent / 0 = off
        let hillDb = bp.v("bow_hill_db", 0.0)
        if abs(hillDb) > 0.01 {
            radHill = Biquad.peaking(f0: bp.v("bow_hill_f", 2400.0),
                                     gainDB: hillDb,
                                     q: bp.v("bow_hill_q", 1.1), sr: sr)
        }
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
        cXv = [Double](repeating: 0, count: nk)   // external force: always 0
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
        precondition(s.count == 52, "bow tables: expected 52 scalars, got \(s.count)")
        // Starting point for the live-parameter ramp (see applyPendingLive).
        liveScalarsCur = s
        liveScalarsTarget = s
        pkernel = bow_poly_init(
            Int32(nPoly), t.sr,
            Int32(t.ba1.count), t.ba1, t.ba2, t.bn0, t.bA, t.bC,
            s[0], s[1], s[2],
            s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
            s[12], s[13], s[14],
            s[15], s[16], s[17], s[18], s[19], s[20], s[21],
            s[22], s[23], s[24], s[25],
            s[26], s[27],
            s[28], s[29], s[30], s[31], s[32],
            s[33], s[34],
            s[35], s[36], s[37], s[38], s[39],
            s[40], s[41], s[42],
            s[43], s[44],
            s[45], s[46],
            s[47], s[48], s[49], s[50], s[51])
        // drone-row excitation scalars (bp defaults, overridable via string.*)
        droneLevel = bp.v("bow_drone_level", 0.026)
        droneOnset = bp.v("bow_drone_onset", 0.052)
        droneAttackSec = bp.v("bow_drone_attack_ms", 150.0) / 1000.0
        droneReleaseSec = bp.v("bow_drone_release_ms", 350.0) / 1000.0
        droneOnsetDecaySec = bp.v("bow_drone_onset_decay_ms", 500.0) / 1000.0
        droneLpHz = bp.v("bow_drone_lp_hz", 1600.0)
        droneHpHz = bp.v("bow_drone_hp_hz", 25.0)
        droneToneMix = bp.v("bow_drone_tone_mix", 0.5)
        droneSpread = bp.v("bow_drone_spread", 1.0)
        // Tilt-axis ranges (bp defaults, overridable via `string.<key>`).
        tiltPureLiftMax = bp.v("bow_tilt_pure_lift", 8.0)
        tiltDampMinT60 = bp.v("bow_tilt_damp_min_t60", 0.25)
        tiltDampMaxT60 = bp.v("bow_tilt_damp_max_t60", 20.0)
        tiltEqDbMax = bp.v("bow_tilt_eq_db", 9.0)
        tiltEqLoHz = bp.v("bow_tilt_eq_lo", 300.0)
        tiltEqHiHz = bp.v("bow_tilt_eq_hi", 2400.0)
        // safety limiter resting values (live edits via applyPendingLive)
        limThresh = min(max(bp.v("bow_lim_thresh", 0.8), 0.1), 1.0)
        limRelCoef = 1.0 - exp(-1.0 /
            (max(bp.v("bow_lim_rel_ms", 150.0), 5.0) * 0.001 * sr))
        tiltLoShelf = Biquad.lowShelf(f0: bp.v("bow_tilt_eq_lo", 300.0),
                                      gainDB: 0.0, sr: sr)
        tiltHiShelf = Biquad.highShelf(f0: bp.v("bow_tilt_eq_hi", 2400.0),
                                       gainDB: 0.0, sr: sr)
        tiltLoShelfS = tiltLoShelf
        tiltHiShelfS = tiltHiShelf
        // MODAL-JAWARI block: loaded AFTER init; never loading it = byte-null
        if let jt = t.jt, !jt.M.isEmpty {
            // recruitment tables + per-row scratch; separate allocations so
            // no COW copy happens on the render thread's first write
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
                                 jt.rowForceScale, jt.rowPinScale,
                                 jt.rowCplScale,
                                 jt.phiD, jt.phiDT, jt.phiU, jt.phiF,
                                 jt.b, jt.G, jt.G4, jt.gd, jt.gd4,
                                 jt.phys, jt.q0)
                // pool spawn happens at build, never on the audio thread
                if jt.threads >= 2 {
                    bow_poly_jt_set_threads(pk, jt.threads)
                }
                // async live mode: the callback never waits (dispatcher + FIFO)
                if jt.async >= 1 {
                    bow_poly_jt_set_async(pk, 1)
                }
                // jt tone LP (bow_jt_lp): unarmed = bit-exact
                if jt.lpA > 0 {
                    bow_poly_jt_set_lp(pk, jt.lpA)
                }
                // drone-row envelope times + drive band-pass corners
                bow_poly_jt_drone_env(pk, droneAttackSec, droneReleaseSec,
                                      droneOnsetDecaySec)
                bow_poly_jt_drone_tone(pk, droneLpHz, droneHpHz,
                                       droneToneMix)
                // HARMONIC EVOLUTION: graze-margin reference for the 0…1 →
                // meters map; a non-neutral rest value is pushed at build
                jtApexRef = jt.apexRef
                let ev = min(max(bp.v("bow_jt_evolve", 0.5), 0.0), 1.0)
                if ev != 0.5 {
                    bow_poly_jt_set_evolve(
                        pk, jtApexRef * (1.0 - pow(4.0, 1.0 - 2.0 * ev)))
                }
                jtEvolveApplied = ev   // dead-band reference (setJtEvolve)
                // chromatic bridge contact law + evolve (inert without rows)
                pushJtRowContact(jt)
                jtEvolveChromaticApplied = min(max(
                    bp.v("bow_jtc_evolve",
                         BowTables.chromaticBridgeDefaults["bow_jtc_evolve"] ?? 0.5),
                    0.0), 1.0)
                // EVOLUTION REGISTER TILT: a bp rest value arms the per-row
                // bone offsets at build; the live push arrives on top. 0 = null
                jtEvolveRegApplied =
                    min(max(bp.v("bow_jt_ev_reg", 0.0), -1.0), 1.0)
                pushJtEvolveOffsets()
                // QUIESCENCE GATE: rows resting below this dB floor under the
                // graze apex freeze in place and skip their tick (idle CPU).
                // Always on; a bp scalar (tests may override), 0 = bit-exact
                // escape hatch. 40 sleeps a pressed bone's limit cycle; >~75
                // never closes.
                let gate = bp.v("bow_jt_gate", 40.0)
                if gate > 0 {
                    bow_poly_jt_set_gate(
                        pk, jtApexRef * pow(10.0, -gate / 20.0))
                }
                // MELODY FOLLOWER: arm the tracked row at the tonic;
                // renderPolyChunk retargets it to the highest gated note
                if jt.trackRow >= 0 {
                    let row = Int(jt.trackRow)
                    bow_poly_jt_track_config(pk, jt.trackRow,
                                             jt.rowFreqs[row], jt.trackT60,
                                             jt.trackFhf, jt.trackBst)
                    let tonic = tables.scalars.count > 38
                        ? tables.scalars[38] : 261.63
                    bow_poly_jt_track_target(pk, tonic)
                    trackHzPushed = tonic
                    trackArmed = true
                }
            }
            // purity LP-sweep references (build corner or open → downward)
            let div = jt.phys.count > 6 ? max(1.0, jt.phys[6].rounded()) : 1.0
            jtTickRate = srk / div
            jtLpBaseA = jt.lpA
            // jt tone HP: a bp rest value arms it at build; 0 = byte-null
            let hpHz = bp.v("bow_jt_hp", 0.0)
            if hpHz > 0, let pk = pkernel {
                let hz = min(max(hpHz, 20.0), 8000.0)
                bow_poly_jt_set_hp(
                    pk, 1.0 - exp(-2.0 * Double.pi * hz / jtTickRate))
            }
            // jt body radiation: same arming rule. 0 = byte-null.
            let bodyMix = bp.v("bow_jt_body", 0.0)
            if bodyMix > 0, let pk = pkernel {
                bow_poly_jt_set_body(pk, min(bodyMix, 1.0))
            }
            // termination drive morph: same arming rule. 0 = byte-null.
            let drvTerm = bp.v("bow_jt_drive_term", 0.0)
            if drvTerm > 0, let pk = pkernel {
                bow_poly_jt_set_drive_term(pk, min(drvTerm, 1.0))
            }
            // two-way bridge coupling: same arming rule. 0 = byte-null.
            let couple = bp.v("bow_jt_couple", 0.0)
            if couple > 0, let pk = pkernel {
                bow_poly_jt_set_couple(pk, couple)
            }
            tiltPureLpHiHz = jt.lpA > 0
                ? -log(1.0 - min(jt.lpA, 0.999999)) * jtTickRate
                    / (2.0 * Double.pi)
                : min(16000.0, 0.45 * jtTickRate)
            jtLpHzCur = tiltPureLpHiHz
            jtLpHzPushed = tiltPureLpHiHz
        }
        // INSTRUMENT WIDTH (`bow_st_width`): the kernel's diffuse-field
        // difference bank on the whole radiated output; fold-down invariant.
        // The per-source pans are gone — every source stays centred and the
        // width bank is the whole stereo law. 0 ⇒ mono path.
        let stWidth = bp.v("bow_st_width", 0.0)
        if let pk = pkernel, stWidth > 1e-6 {
            // arm the kernel's stereo path with every pan at zero
            bow_poly_set_stereo(pk, nil, 0, nil, 0)
            bow_poly_set_stereo_width(pk, stWidth)
            // side twins of the radiation chain (same coefficients, own state)
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
        // voice→taraf drive FX hook, installed unconditionally (off the audio
        // thread); `isEngaged` keeps it byte-null. deinit frees the kernel
        // before self dies, so `passUnretained` is safe.
        if let pk = pkernel {
            bow_poly_set_drive_fx(pk, bowEngineDriveFXHook,
                                  Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// async-jt telemetry: (drops, flat-filled samples, FIFO fill, async flag)
    public func jtAsyncStats() -> (drops: Double, flat: Double,
                                   fill: Double, on: Double) {
        var s = [Double](repeating: 0, count: 4)
        if let pk = pkernel { bow_poly_jt_async_stats(pk, &s) }
        return (s[0], s[1], s[2], s[3])
    }

    // MARK: - Drone rows

    /// The jt row fundamentals (Hz) in kernel order — empty without a jt block.
    public var jtRowFreqs: [Double] { tables.jt?.rowFreqs ?? [] }

    /// The tuning tonic (scalars[38] = f0Open — the open-string reference).
    public var tonicHz: Double {
        tables.scalars.count > 38 ? tables.scalars[38] : 261.63
    }

    /// Drone excitation scalars (set at build, applied per press). The drive
    /// is slewed filtered noise: swells toward `droneLevel + droneOnset` over
    /// `droneAttackSec`, the onset boost decays over `droneOnsetDecaySec`,
    /// release falls over `droneReleaseSec`; the press also spreads to the
    /// held row's KIN rows (the `bow_jt_sel` lattice).
    public var droneLevel = 0.026
    /// Onset-boost drive amplitude (`bow_drone_onset`).
    public var droneOnset = 0.052
    /// Envelope times (`bow_drone_*_ms`), pushed to the kernel at build.
    public var droneAttackSec = 0.15
    public var droneReleaseSec = 0.35
    public var droneOnsetDecaySec = 0.50
    /// Drive band-pass corners (`bow_drone_lp_hz`/`_hp_hz`), pushed at build.
    public var droneLpHz = 1600.0
    public var droneHpHz = 25.0
    /// Pitched fraction of the drive 0..1 (`bow_drone_tone_mix`): a sine at
    /// the row's mode 1 mixed with the noise (pure noise over-rings high modes)
    public var droneToneMix = 0.5
    /// Kin-row drive scale 0..1 (`bow_drone_spread`): how strongly a press
    /// recruits the held row's kin rows. 0 = the held row only.
    public var droneSpread = 1.0
    /// Held drone rows; guarded by `droneLock` (presses arrive on the MIDI
    /// thread, remaps on main).
    private var droneHeldRows: Set<Int> = []
    private var droneLock = os_unfair_lock()
    /// Render-readable shadow of `droneHeldRows` (stores under `droneLock`,
    /// lock-free reads): recruitment counts a held row as fully ringing.
    private var droneHeldMask: [Bool] = []

    /// Per-row drone drive weights: a held row is 1, every other row its
    /// best kin affinity to the held set (soft-OR) × `droneSpread`. The
    /// follower row never takes SPREAD drive; an explicit press is honoured.
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
    /// jawari selection did not pick the string up (then inert). Rows are
    /// ordered raga bridge first, so a shared pitch resolves to its raga row.
    public func droneRow(forExactHz hz: Double) -> Int? {
        jtRowFreqs.firstIndex(of: hz)
    }

    /// Press a drone: swell the row's and its kin rows' sustain drive plus
    /// the decaying onset boost. Control thread; kernel setters are plain
    /// per-row scalar stores.
    public func dronePress(row: Int) {
        guard let pk = pkernel, row >= 0, row < selRowFreqs.count
        else { return }
        os_unfair_lock_lock(&droneLock)
        droneHeldRows.insert(row)
        if row < droneHeldMask.count { droneHeldMask[row] = true }
        let w = droneDriveWeights(rows: droneHeldRows)
        let wNew = droneDriveWeights(rows: [row])
        for i in 0..<w.count {
            // pluck only where THIS press lands (0 would cancel another onset)
            if wNew[i] > 1e-3 {
                bow_poly_jt_pluck(pk, Int32(i), droneOnset * wNew[i])
            }
            bow_poly_jt_drone(pk, Int32(i), droneLevel * w[i])
        }
        os_unfair_lock_unlock(&droneLock)
    }

    /// Release a drone: recompute the drive profile from the remaining held
    /// set; every row that loses its drive rings out on its own t60.
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

    // MARK: - Runtime base parameters

    /// RADIATED-JT TONE LP corner in Hz (`bow_jt_lp`): brightness of the
    /// jawari buzz. <= 0 or ≥ 20 kHz = the exact build-time state. State-
    /// preserving coefficient moves, smoothed at chunk rate.
    public func setJtToneLp(hz: Double) {
        os_unfair_lock_lock(&tiltLock)
        // ≥ 20 kHz = bypass (the builder's law / registry default 20000)
        jtLpHzTarget = (hz > 0 && hz < 19999.0)
            ? min(max(hz, 40.0), tiltPureLpHiHz) : 0.0
        os_unfair_lock_unlock(&tiltLock)
    }

    /// RADIATED-JT TONE HP corner in Hz (`bow_jt_hp`): the jawari-formant
    /// voicing. <= 0 = bypass (bit-exact). Smoothed at chunk rate.
    public func setJtToneHp(hz: Double) {
        os_unfair_lock_lock(&tiltLock)
        jtHpHzTarget = hz > 0 ? min(max(hz, 20.0), 8000.0) : 0.0
        os_unfair_lock_unlock(&tiltLock)
    }

    /// TARAF INJECT gain: scales another voice's output (sitar/tanpura) into
    /// this kernel's jt drive. Control thread only (the first non-zero call
    /// allocates the ring); 0 with nothing written is byte-null.
    public func setJtInjectGain(_ g: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_inject_gain(pk, g)
    }

    /// TARAF INJECT write: append the other voice's mono block to the
    /// kernel's SPSC ring from ITS render callback (the one BowEngine entry
    /// point for a foreign render thread); a full ring drops the block.
    public func jtInjectWrite(_ x: UnsafePointer<Double>, _ n: Int) {
        guard let pk = pkernel else { return }
        bow_poly_jt_inject_write(pk, x, Int32(n))
    }

    /// JT BODY RADIATION mix 0…1 (`bow_jt_body`): the radiated jawari sum
    /// through the played strings' body radiation bank (own filter state).
    /// 0 = bypass (bit-exact). Kernel scalar write, slewed ~30 ms in-kernel.
    public func setJtBody(_ mix01: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_body(pk, min(max(mix01, 0.0), 1.0))
    }

    /// TERMINATION DRIVE morph 0…1 (`bow_jt_drive_term`): where the played
    /// string's bridge force enters each sympathetic row. 0 = the fitted
    /// 0.90 L tap, whose |sin(kπ·0.9)| comb never charges modes 10/20;
    /// 1 = the pin's own mode slope (∝ (−1)^k·k, energy-matched per row to
    /// the tap, same sign convention as the pin-force radiation). 0 =
    /// bit-exact. Kernel scalar write, slewed ~40 ms per row.
    public func setJtDriveTerm(_ w01: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_drive_term(pk, min(max(w01, 0.0), 1.0))
    }

    /// TWO-WAY BRIDGE COUPLING gain (`bow_jt_couple`): how much of the
    /// sympathetic rows' OWN summed bridge force (contact + termination, in
    /// newtons) returns into the played strings' bridge force — the bridge
    /// load the one-way drive leaves out. It reaches the body, every played
    /// string's return, and the next tick's drive of every row, so the web
    /// also exchanges energy with itself through the bridge. 0 = bypass
    /// (bit-exact). Kernel scalar write, slewed ~40 ms in the render loop.
    public func setJtCouple(_ g: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_couple(pk, min(max(g, 0.0), 4.0))
    }

    /// HARMONIC EVOLUTION 0…1 (`bow_jt_evolve`): a SIGNED bone offset,
    /// lift = apex·(1 − 4^(1−2e)) (0.5 → 0 = byte-null), slewed INSIDE the
    /// kernel (~40 ms) so a tilt is a slow jawari adjustment, not a strum.
    /// The ONE sanctioned runtime bone move.
    public func setJtEvolve(_ e01: Double) {
        guard let pk = pkernel else { return }
        let e = min(max(e01, 0.0), 1.0)
        // Cumulative DEAD-BAND against the last APPLIED value: a bound
        // axis streams sensor jitter, and every applied change moves the
        // bone, which would pump the resting taraf above the quiescence
        // floor. Jitter never crosses the band; a real sweep does.
        if abs(e - jtEvolveApplied) < 0.005 { return }
        jtEvolveApplied = e
        bow_poly_jt_set_evolve(pk, jtApexRef * (1.0 - pow(4.0, 1.0 - 2.0 * e)))
        // register tilt / chromatic offsets are differences ON the margin
        // map, so they move with e
        pushJtEvolveOffsets()
    }
    /// Last evolve 0…1 actually forwarded to the kernel (dead-band ref).
    private var jtEvolveApplied = 0.5

    /// THE CHROMATIC BRIDGE'S EVOLUTION 0…1 (`bow_jtc_evolve`): the same
    /// margin map on that bridge's own apex, delivered as per-row offsets
    /// against the raga bridge's lift. Same dead-band; no-op without rows.
    public func setJtEvolveChromatic(_ e01: Double) {
        let e = min(max(e01, 0.0), 1.0)
        if abs(e - jtEvolveChromaticApplied) < 0.005 { return }
        jtEvolveChromaticApplied = e
        pushJtEvolveOffsets()
    }
    private var jtEvolveChromaticApplied = 0.5

    /// Push every row's contact law (alpha / hcB / deep threshold) — only
    /// when a chromatic row exists (an all-raga rig stays byte-null).
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
    /// Graze-margin reference (`bow_jt_apex` at build) for the evolution map.
    private var jtApexRef = 1.0e-5
    /// EVOLUTION REGISTER TILT (`bow_jt_ev_reg`): evolve units per OCTAVE
    /// from the tonic, a per-row SIGNED bone offset added to the global lift
    /// (kernel-slewed). + opens below-tonic rows and closes above; 0 = the
    /// uniform bone, byte-null. Same cumulative dead-band as setJtEvolve.
    public func setJtEvolveRegister(_ reg: Double) {
        let r = min(max(reg, -1.0), 1.0)
        if abs(r - jtEvolveRegApplied) < 0.005 { return }
        jtEvolveRegApplied = r
        pushJtEvolveOffsets()
    }
    /// Last register tilt actually forwarded (dead-band ref).
    private var jtEvolveRegApplied = 0.0

    /// Recompute + push the per-row offsets for (evolve, register): each
    /// row evaluates the SHARED margin map at e_row = clamp(e + reg·log2
    /// (tonic/f_row), 0, 1) on ITS bridge's apex and evolve; offset =
    /// lift(e_row) − lift(e), so rows stay on the calibrated span (×4…×¼).
    /// Nothing is pushed until some offset is non-zero (byte-null); once
    /// armed every recompute is pushed, zeros included.
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
            if !chrom && reg == 0.0 { continue }     // reg 0: no offset
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

    /// Rows currently asleep under the quiescence gate — telemetry/tests.
    public func jtGateAsleep() -> Int {
        guard let pk = pkernel else { return 0 }
        return Int(bow_poly_jt_gate_asleep(pk))
    }
    /// Gate probe telemetry since the last read — (asleep rows, max
    /// ring/floor ratio, max drive/wake ratio, drone-hot); a ratio > 1 names
    /// the condition blocking sleep.
    public func jtGateProbe() -> (asleep: Int, total: Int, ringR: Double,
                                  driveR: Double, droneHot: Bool) {
        guard let pk = pkernel else { return (0, 0, 0, 0, false) }
        var o = [Double](repeating: 0, count: 5)
        bow_poly_jt_gate_probe(pk, &o)
        return (Int(o[0]), Int(o[1]), o[2], o[3], o[4] > 0.5)
    }

    // MARK: - Scope telemetry

    /// One modal-jawari taraf row as the Mac Scope tab reads it.
    public struct ScopeRow: Sendable {
        /// The row's CURRENT fundamental (the follower's live retune).
        public var f0Hz: Double
        /// Radiated peak envelope in display units (voice-bus units × output
        /// gain), comparable with the bus meter.
        public var level: Double
        /// Frozen under the quiescence gate (reads silent).
        public var asleep: Bool
        public var isFollower: Bool
        /// On the chromatic bridge.
        public var isChromatic: Bool
        /// Per-mode MODAL velocity envelopes |p_k|, modes 1…`scopeModeCount`
        /// (zero past the row's mode count) — ∝ the row's radiated spectrum.
        public var modes: [Float]
    }

    /// One played-string slot as the Scope tab reads it (mapper slot index).
    public struct ScopeSlot: Sendable {
        public var f0Hz: Double
        /// Bow down (gated) — released strings keep ringing (level > 0).
        public var gated: Bool
        /// Ring envelope (relative string units; 0 = skipped as silent).
        public var level: Double
        public var serial: UInt32
    }

    /// Per-mode envelopes kept per row by the kernel's scope meters.
    public static let scopeModeCount = 16

    /// Arm/disarm the kernel's display-only per-row meters (a fresh arm
    /// starts cleared). Disarmed = the exact plain tick. Control thread.
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

    // MARK: - Bus volume meter

    /// BUS VOLUME METER (voice, taraf) for the iPad volume readout. Armed,
    /// the render takes the split-bus `bow_poly_process3` path, whose
    /// host-side `out + outJt` is BIT-EXACT against the fused path. Levels
    /// are kernel-rate RMS × output gain (trim × `bow_gain`), INTEGRATE-
    /// AND-DUMP with no smoothing: each `busLevels()` returns the exact RMS
    /// since the previous call, so scope decay rates are the buses' own.
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
    /// — (0, 0) unarmed; nothing rendered in between repeats the previous
    /// reading. Safe from any thread; poll at UI rate.
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
    /// into the interval accumulators — after the bus FX and the balance,
    /// before the merge, so the meter shows each bus's actual contribution.
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

    // MARK: - Voice↔taraf balance + the voice-relative taraf cap

    /// VOICE↔TARAF BALANCE (`bow_bal`, .live): −1…+1, 0 = neutral
    /// (byte-null). A pure attenuator pair at the bus merge — positive turns
    /// the VOICE down (1−b), negative the TARAF (1+b); nothing is boosted.
    /// Slewed ~30 ms and interpolated across the chunk. Needs the split bus.
    public func setBusBalance(_ b: Double) {
        os_unfair_lock_lock(&tiltLock)
        balTarget = min(max(b, -1.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// PER-STRING VOICE-RELATIVE TARAF CAP (`bow_jt_cap*`, .live): each
    /// sympathetic row's radiated output held AT OR BELOW the played voice's
    /// level (the runaway-bloom lever). Side-chain: an instant-attack peak
    /// envelope of the VOICE bus, ~1.2 s-τ release — a row may ring on after
    /// the note but never PEAK above what the voice reached. Ceiling =
    /// voice peak × `ratio`; `hard` = the fraction of the dB overshoot
    /// removed (0 = off, byte-null; 1 = hard limiter). Dimensionless, so it
    /// rides `bow_gain` untouched. Applied per row inside the kernel's jt
    /// tick (`bow_poly_jt_set_cap`), pre-FX/pre-trim. Voice silent from
    /// launch ⇒ ceiling ~0: armed hard, drone-/inject-charged rows are held
    /// until the voice first sounds — that IS the contract; off (default)
    /// keeps an autonomous taraf. Clocks: row env release 150 ms, gain slew
    /// 3 ms down / 120 ms up.
    public func setJtCap(hard: Double, ratio: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_cap(pk, min(max(hard, 0.0), 1.0),
                            min(max(ratio, 0.01), 4.0))
    }

    // staged under tiltLock (target); balCur is render-thread only
    private var balTarget = 0.0
    private var balCur = 0.0

    /// Render thread: the balance attenuator pair, linear across the chunk.
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

    /// SETTLE DAMP: direct, unsmoothed taraf t60 override for the build-time
    /// settle pre-roll only (chokes the q0 relax chime in the discarded
    /// blocks). t60 <= 0 restores the natural ring EXACTLY. Never call on a
    /// published engine — the runtime axis is `setTarafDamp`.
    public func setJtSettleDamp(t60: Double) {
        guard let pk = pkernel else { return }
        bow_poly_jt_set_damp_t60(pk, t60)
    }

    /// TARAF DAMPING 0..1 (`bow_jt_damp`): 0 = natural ring (bit-exact);
    /// rising = extra momentum damping, t60 log-interpolated from
    /// `bow_tilt_damp_max_t60` down to `bow_tilt_damp_min_t60`. Smoothed.
    public func setTarafDamp(_ amt01: Double) {
        os_unfair_lock_lock(&tiltLock)
        dampAmtTarget = min(max(amt01, 0.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// TARAF RECRUITMENT PROFILE 0..1 (`bow_jt_sel`), loudness held:
    ///  * 0.5 = the fitted taraf (all weights 1, bit-exact).
    ///  * below 0.5 rows lose bridge drive by harmonic DISTANCE from the
    ///    played pitches until at 0 only kin rows ring (kin score squared;
    ///    lattice `bow_jt_sel_kin`, shared with the drone spread).
    ///  * above 0.5 the profile FLATTENS: resonant rows are cut toward the
    ///    haze level (`w → √(haze/(haze+kin²))`) until at 1 every row
    ///    contributes EQUALLY.
    ///  * the RADIATED jt gain (`bow_poly_jt_set_gain_mul`) holds the
    ///    level — the note's fitted power below 0.5, blending to the fixed
    ///    rows·haze + `recruitKinNominal` above; capped ×`bow_jt_sel_comp`.
    ///    Held drones and the follower count as fully ringing (never pumped).
    /// Chords recruit by soft-OR. Weights gate the DRIVE only; the kernel
    /// slews them ~30 ms; rescored per chunk on the render thread.
    public func setTarafSelectivity(_ s01: Double) {
        os_unfair_lock_lock(&tiltLock)
        selTarget = min(max(s01, 0.0), 1.0)
        os_unfair_lock_unlock(&tiltLock)
    }

    /// The kin lattice: frequency ratios through which a LINEARLY driven
    /// sympathetic string still resonates, each with p·q, the order of the
    /// shared partial. Kinship = (p·q)^-`bow_jt_sel_kin`.
    static let recruitKin: [(ratio: Double, pq: Double)] = [
        (1.0, 1),                       // unison
        (2.0, 2), (0.5, 2),             // octave
        (4.0, 4), (0.25, 4),            // double octave
        (3.0, 3), (1.0 / 3.0, 3),       // twelfth
        (1.5, 6), (2.0 / 3.0, 6),       // fifth
        (0.75, 12), (4.0 / 3.0, 12),    // fourth
    ]

    /// Kinship 0..1 of a row `c` cents from a played pitch: the best kin
    /// interval's strength through a Gaussian falloff. The ONE scoring core.
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

    /// One row's kin score 0..1 (soft-OR across the chord: misses multiply,
    /// bounded by 1).
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

    /// One row's bridge-drive weight at a profile position — the exact math
    /// the render thread pushes (minus follower/drone exemptions): 0.5 = 1;
    /// 0 = kin²; 1 = `√(haze/(haze+kin²))`. Public for tests/offline tuning.
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

    /// Non-resonant response floor of a jawari row relative to a unison row
    /// (power): the haze it rings with under full drive when it shares no kin
    /// interval. Sets the flat end's level and keeps the compensation smooth.
    static let recruitHazeFloor = 0.05

    /// The flat end's common loudness anchor: the modeled kin power of a
    /// tonic-like note (unison + two octave rows ≈ 1 + 2·0.38).
    static let recruitKinNominal = 1.75

    /// The loudness-consistency gain for a bank at a profile position: the
    /// radiated-gain multiplier holding the taraf's power (incoherent model,
    /// row power ∝ weight² × (haze + kin²)), clamped [1, cap]; 1 at 0.5. The
    /// exact math the render thread pushes (minus follower/held-drone rows).
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

    /// Per-chunk RECRUITMENT update (render thread): score each row's
    /// kinship to the gated pitches, push the per-row drive weights and the
    /// compensating radiated gain (`recruitWeight`/`recruitGainMul` math;
    /// follower + held drones count as fully ringing). No gated note holds
    /// the last state; back at 0.5 one all-ones push restores the fitted
    /// taraf and the path goes quiet. No allocation.
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
        // pInv: rows whose ring does not follow the weights (follower, held
        // drones) enter both sides of the ratio — a held drone is never boosted
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

    // MARK: - Live parameters

    /// A parameter edit staged by the control thread, applied at the next
    /// chunk boundary on the render thread: the 52 kernel scalars, `bp` for
    /// the Swift-side constants and output/radiation/room. Under `tiltLock`.
    private var pendingLive: (bp: BowParams, scalars: [Double],
                              tables: BowKernelTables?)?

    /// Seed the gain ramp from the engine's output settings; called once
    /// the host has assigned `outGain` after init.
    public func seedLiveGains() {
        liveGainCur = (trim: outGain, mix: reverb.mix, width: reverb.width)
        liveGainTarget = liveGainCur
        os_unfair_lock_lock(&tiltLock)
        trimBase = outGain            // build-time trim = the fitted base
        os_unfair_lock_unlock(&tiltLock)
    }

    /// MASTER GAIN (`bow_gain`, .live): the performance volume of the WHOLE
    /// radiated instrument — multiplies the fitted trim on the ramped output
    /// gain (~25 ms), with no bp push, rebuild or debounce, so a binding
    /// sweeps it live. `StringVoiceSource` re-applies it across rebuilds.
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

    /// Master-gain state, all under `tiltLock`; `trimBase` is the FITTED
    /// trim (pre-gain) so bp pushes compare in BASE terms.
    private var masterGain = 1.0
    private var masterGainDirty = false
    private var trimBase = 1.0

    /// Apply a parameter edit WITHOUT rebuilding: the kernel scalars are
    /// overwritten in place (ramped) and the Swift-side constants re-read;
    /// all running state stays intact. Control-thread safe; effective next
    /// chunk. Covers only what does not resize a table
    /// (`ParamRegistry.inPlaceKeys`). `tables` also reloads the body modal
    /// bank + jawari coefficients in place; a shape change is refused.
    public func setLiveParams(bp: BowParams, scalars: [Double],
                              tables: BowKernelTables? = nil) {
        guard scalars.count == 52 else { return }
        // Arm the RAMP only when a ramped quantity moved: the ramp caps the
        // render chunk to 256 frames, and chunk size perturbs the chaotic
        // friction loop, so a no-op push must not arm it. Coefficient
        // reloads are click-free unramped. Trim compares in BASE terms.
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
        // Armed HERE so the chunk cap applies to the FIRST chunk after the
        // push (otherwise that chunk resolves most of the glide in one step)
        if ramped { liveRampArmed = true }
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Swap the body-modal and jawari coefficient arrays on the running
    /// kernel; histories are kept, so it is click-free and not ramped.
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
        jt.rowPinScale.withUnsafeBufferPointer { pinScale in
        jt.rowCplScale.withUnsafeBufferPointer { cplScale in
        jt.phiD.withUnsafeBufferPointer { phiD in
        jt.phiDT.withUnsafeBufferPointer { phiDT in
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
                pinScale.baseAddress, cplScale.baseAddress,
                phiD.baseAddress, phiDT.baseAddress,
                phiU.baseAddress, phiF.baseAddress,
                b.baseAddress, G.baseAddress, G4.baseAddress,
                gd.baseAddress, gd4.baseAddress, phys.baseAddress)
            if ok == 1 {
                // the per-row contact law and the per-bridge evolve map
                // follow the reloaded tables (`bow_jt_apex`)
                jtRowChromatic = jt.rowChromatic
                jtRowApex = jt.rowApex
                jtHasChromatic = jt.hasChromatic
                jtApexRef = jt.apexRef
                pushJtRowContact(jt)
                pushJtEvolveOffsets()
            }
        }}}}}}}}}}}}}}}}}}}
        // Melody follower: refresh the retune-law constants; re-arming the
        // SAME row keeps its current pitch
        if jt.trackRow >= 0, Int(jt.trackRow) < jt.rowFreqs.count {
            bow_poly_jt_track_config(st, jt.trackRow,
                                     jt.rowFreqs[Int(jt.trackRow)],
                                     jt.trackT60, jt.trackFhf, jt.trackBst)
        }
    }

    /// Current / target kernel scalar vectors. Pushes are RAMPED (~25 ms)
    /// rather than stepped: several scalars multiply the signal, so a step
    /// would be a click. Everything ramps together for simplicity.
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
            // mapping into the friction loop, which absorbs a step.
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

        // Gains can ramp before any scalar push has happened (master gain on
        // a fresh engine); the kernel push below stays guarded.
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

    /// Per-chunk runtime-axis update (render thread): smooth each target
    /// (~40 ms) and push the kernel scalars only when they moved.
    private func updateTarafAxes(n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let lT = jtLpHzTarget
        let hT = jtHpHzTarget
        let dT = dampAmtTarget
        os_unfair_lock_unlock(&tiltLock)
        if lT == 0.0, !jtLpEngaged, dT == 0.0, dampAmtCur == 0.0,
           hT == 0.0, jtHpHzCur == 0.0 { return }
        let a = 1.0 - exp(-Double(n48) / (0.04 * sr))
        // jt tone LP: Hz-smoothed; target 0 eases back to the build coefficient
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
        // jt tone HP (0 eases the corner down to bypass; state kept warm)
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

    /// TONE TILT axis -1..1: -1 = bass bias, 0 = flat (bypass —
    /// bit-exact), +1 = treble bias. A complementary
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
            // in-place coefficient swaps, state kept; side twins share them
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

    /// Stage one FX insert point's settings (control thread); adopted at
    /// the next chunk boundary. All-off is byte-null.
    public func setFX(_ point: FXPoint, _ settings: FXSettings) {
        os_unfair_lock_lock(&tiltLock)
        fxPending[point.rawValue] = settings
        fxDirty = true
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Per-chunk FX update (render thread): adopt staged settings, advance
    /// smoothers. `nk` = kernel-rate chunk, `n48` = engine-rate (global).
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
    /// radiation FIR → E_lp → reverb → equal (l, r) split.
    public func render(frames: Int, outL: UnsafeMutablePointer<Double>,
                       outR: UnsafeMutablePointer<Double>) {
        var done = 0
        while done < frames {
            // While a live ramp runs, cap the chunk so the ~25 ms glide is
            // RESOLVED (it advances once per chunk; 4096 frames = one step).
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
    /// strings reset; silent slots skipped) → the poly kernel → post-chain.
    /// The fingerprint mask rides the LEAD slot's (newest gated) pitch.
    private func renderPolyChunk(_ n: Int, outL: UnsafeMutablePointer<Double>,
                                 outR: UnsafeMutablePointer<Double>) {
        let nk = n * osFactor
        guard let pk = pkernel else {
            for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            return
        }
        mapper.snapshotPoly(into: &polySnap)
        // Melody follower: target = the HIGHEST gated note (bend included);
        // no gated note keeps the last target, so the string rings out there.
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
        // RECRUITMENT (bow_jt_sel): re-score the bridge-drive weights
        // against the gated pitch set (no-op while the axis is off)
        updateRecruitment(pk)
        cF0.withUnsafeMutableBufferPointer { f0 in
            cVb.withUnsafeMutableBufferPointer { vb in
                cFb.withUnsafeMutableBufferPointer { fb in
                    cBeta.withUnsafeMutableBufferPointer { be in
                        cGate.withUnsafeMutableBufferPointer { ga in
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
                                // chord): ×1.0 is an IEEE identity, so
                                // every non-strum path is bit-exact.
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
                                    gate: ga.baseAddress! + o)
                            }
                        }
                    }
                }
            }
        }
        // FX rack: adopt staged settings + advance smoothers. The voice/taraf
        // inserts split the kernel's buses (bit-exact when idle — bus + bus
        // reproduces the fused rounding); the drive insert fires in-kernel.
        updateFX(nk: nk, n48: n)
        let vIdx = FXPoint.voice.rawValue, tIdx = FXPoint.taraf.rawValue
        let busFX = fxUnits[vIdx].isEngaged || fxUnits[tIdx].isEngaged
        // Meter / balance: either armed, the split path runs even with the
        // bus FX idle (bus + bus is bit-exact; balance is byte-null at
        // neutral). The per-row cap lives in the kernel.
        os_unfair_lock_lock(&tiltLock)
        let metering = meterArmed
        let balT = balTarget
        os_unfair_lock_unlock(&tiltLock)
        let balOn = balT != 0.0 || balCur != 0.0
        let splitBus = busFX || metering || balOn
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
        // outGain is interpolated ACROSS the chunk (a chunk-rate step would
        // step the waveform); `gFrom` = where the previous chunk left off
        let gTo = 0.5 * outGain, gFrom = 0.5 * gainPrev
        let dg = (gTo - gFrom) / Double(max(n48, 1))
        for i in 0..<n48 {
            let half = (gFrom + dg * Double(i)) * y48[i]
            outL[i] = half
            outR[i] = half
        }
        gainPrev = outGain
        // global FX point after the whole chain (stereo room decorrelates L/R)
        fxUnits[FXPoint.global.rawValue].processLR(outL, outR, n48)
        applyLimiter(n48: n48, outL: outL, outR: outR)
    }

    /// The output safety limiter. Linked stereo: one gain from max(|L|, |R|),
    /// so limiting never leans the image. Below the ceiling — once the gain
    /// has released back to exactly 1 — samples pass untouched (bit-exact).
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

    /// Stereo post-chain: mid (y48) and side (y48S) each run their own
    /// radiation-chain state (same coefficients), the room adds a width-
    /// decorrelated wet pair, L = mid + side, R = mid − side. Side and the
    /// reverb's side tank cancel in L+R, so the fold-down equals `postChain`.
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
            // tilt-EQ on mid AND side (= EQing L/R by linearity), pre-room so
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
    /// the live buffer path. `n96` must be `2·frames` and ≤ the preallocated
    /// scratch per call (the caller chunks). With `maxPoly` > 1 the controls
    /// drive string 0; the other strings stay silent.
    public func renderFixture(f0: [Double], vb: [Double], fb: [Double],
                              beta: [Double], gate: [Double],
                              outL: UnsafeMutablePointer<Double>,
                              outR: UnsafeMutablePointer<Double>) {
        let nk = f0.count
        precondition(nk % osFactor == 0 && nk <= maxFrames * osFactor)
        for i in 0..<nk {
            cF0[i] = f0[i]; cVb[i] = vb[i]; cFb[i] = fb[i]
            cBeta[i] = beta[i]; cGate[i] = gate[i]
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
        // kernel state is the INSTRUMENT's physical state, rebuilt from silence
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

/// C trampoline for the kernel's drive FX hook; ctx = the unretained BowEngine.
private func bowEngineDriveFXHook(_ ctx: UnsafeMutableRawPointer?,
                                  _ buf: UnsafeMutablePointer<Double>?,
                                  _ n: Int32) {
    guard let ctx, let buf, n > 0 else { return }
    Unmanaged<BowEngine>.fromOpaque(ctx).takeUnretainedValue()
        .fxProcessDrive(buf, Int(n))
}
