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

    var pkernel: UnsafeMutableRawPointer?     // bow_kernel_poly.c
    private var dec: HalfBandDecimator
    private var radFIR: FIRFilter?
    var radLp: Biquad?
    var radHill: Biquad?
    /// STEREO SIDE PATH: with `bow_st_width` armed the kernel renders a
    /// SIDE stream (its diffuse-field difference bank on the whole radiated
    /// output) which rides decimator + radiation-chain twins here; L/R =
    /// mid ± side, fold-down bit-identical to the mono path. Off = mono.
    private var stereoOn = false
    private var decS = HalfBandDecimator()
    private var radFIRS: FIRFilter?
    var radLpS: Biquad?
    private var radHillS: Biquad?
    var radHPS: [Biquad] = []
    /// Membrane radiation-efficiency LF rolloff (`bow_rad_hp`, ord/2
    /// butter-2 sections): a small body cannot radiate below its skin mode.
    var radHP: [Biquad] = []
    var reverb: Reverb

    // ---- FX RACK: four insert points, off by default (byte-null).
    // drive/voice/taraf run at KERNEL rate on the split buses, global at
    // engine rate after the post-chain. Staged under `tiltLock`. ----
    var fxUnits: [FXChainUnit]
    var fxPending: [FXStaged]
    var fxDirty = false
    /// Per point: the last fitted point set and its full-depth design
    /// (control thread; under `tiltLock` for the brief read/write).
    var fxDesignCache: [(points: [EQPoint], design: EQDesign)?]

    // ---- Runtime taraf/tone axes: taraf PURITY (jt tone LP) and DECAY
    // (momentum damping) are kernel scalars; TONE TILT is a shelf pair on
    // the voice output here. Targets under `tiltLock`; off = byte-null.
    private let tiltPureLiftMax: Double     // bow_tilt_pure_lift
    var tiltPureLpHiHz = 16000.0    // axis-0 corner (build LP or open)
    var jtLpBaseA = 0.0             // build-time jt LP coeff (≤0 bypass)
    var jtTickRate = 48000.0        // jt tick rate (srk / bow_jt_div)
    let tiltDampMinT60: Double      // bow_tilt_damp_min_t60
    let tiltDampMaxT60: Double      // bow_tilt_damp_max_t60
    let tiltEqDbMax: Double         // bow_tilt_eq_db
    let tiltEqLoHz: Double          // bow_tilt_eq_lo
    let tiltEqHiHz: Double          // bow_tilt_eq_hi
    var tiltLock = os_unfair_lock()
    // kernel-axis smoothers: targets written under `tiltLock`; the render
    // thread smooths at chunk rate and pushes the kernel only on change
    var jtLpHzTarget = 0.0          // bow_jt_lp runtime (0 = build)
    var jtLpHzCur = 16000.0         // synced to tiltPureLpHiHz at load
    var jtLpHzPushed = 16000.0
    var jtLpEngaged = false
    var jtHpHzTarget = 0.0          // bow_jt_hp runtime (0 = off)
    var jtHpHzCur = 0.0
    var jtHpHzPushed = 0.0
    var dampAmtTarget = 0.0         // bow_jt_damp (0 = natural ring)
    var dampAmtCur = 0.0
    var dampAmtPushed = 0.0
    // MELODY FOLLOWER: armed when the jt tables carry a tracked row; the
    // render thread pushes the highest gated note as its target per chunk
    private var trackArmed = false
    private var trackHzPushed = 0.0
    // RECRUITMENT PROFILE (`bow_jt_sel`): each jawari row's bridge drive
    // across 0 = kin-only / 0.5 = fitted / 1 = equal contribution, the
    // radiated jt gain holding loudness. Rescored per chunk on the render
    // thread; the kernel slews the per-row weights (~30 ms).
    var selTarget = 0.5               // bow_jt_sel runtime (0.5 = fitted)
    var selEngaged = false            // render thread: axis in effect
    var selWidthCents = 30.0          // bow_jt_sel_width
    var selComp = 4.0                 // bow_jt_sel_comp (loudness-comp cap)
    var selGMulPushed = 1.0           // last pushed radiated-gain mul
    var selKinCents: [Double] = []    // kin offsets (cents)
    var selKinStrength: [Double] = [] // (p·q)^-kinExp per kin
    var selRowFreqs: [Double] = []     // row f0s (builder)
    var jtTrackRowIdx = -1            // follower row: always weight 1
    // Per-row bridge membership + apex (the builder's), for the
    // per-bridge evolve map and the Scope tab.
    var jtRowChromatic: [Bool] = []
    var jtRowApex: [Double] = []
    var jtHasChromatic = false
    var jtEvOfsArmed = false          // offsets ever pushed
    var jtDwTargets: [Double] = []    // scratch: weights to push
    var jtDwPushed: [Double] = []     // last pushed (skip no-ops)
    var selPitches: [Double] = []     // scratch: gated pitches
    var toneTiltTarget = 0.0        // control-thread write
    var toneTiltCur = 0.0           // render-thread smoother
    var toneTiltApplied = 0.0       // shelves built for this value
    var tiltEqActive = false
    var tiltLoShelf: Biquad
    var tiltHiShelf: Biquad
    /// Side twins of the tilt shelves (same coefficients, own state):
    /// EQing mid and side alike equals EQing L/R, so the image holds.
    var tiltLoShelfS: Biquad
    var tiltHiShelfS: Biquad

    // ---- OUTPUT SAFETY LIMITER: linked-stereo peak limiter at the very
    // end of both post-chains. Instant attack, exponential release
    // (`bow_lim_rel_ms`), gain smoothed ~0.2 ms, hard clamp at
    // min(1, 1.25×ceiling) for the attack samples that slip through.
    // Below the ceiling it multiplies nothing — bit-exact passthrough. ----
    var limThresh = 0.8       // bow_lim_thresh (1.0 ≈ FS safety)
    var limRelCoef = 0.000139 // bow_lim_rel_ms (150 ms at 48 k)
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
    var filters: [BowControlFilter] = []
    private var lastSerial: [UInt32] = []
    private var slotSilent: [Bool] = []
    var polySnap: BowControlMapper.PolySnapshot

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
        // f0Open = the tuning tonic (register-force reference)
        filter = BowControlFilter(bp: bp, srk: srk,
                                  tonic: tables.scalars.f0Open)
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
        fxPending = FXPoint.allCases.map { _ in FXStaged() }
        fxDesignCache = FXPoint.allCases.map { _ in nil }
        polySnap = BowControlMapper.PolySnapshot(count: nPoly)
        filters = [BowControlFilter](repeating: filter, count: nPoly)
        for i in filters.indices { filters[i].seedDrift(UInt64(i)) }
        lastSerial = [UInt32](repeating: 0, count: nPoly)
        slotSilent = [Bool](repeating: false, count: nPoly)
        mapper.setSlotLimit(nPoly)

        let t = tables
        let s = t.scalars
        // Starting point for the live-parameter ramp (see applyPendingLive).
        liveScalarsCur = s
        liveScalarsTarget = s
        pkernel = withUnsafePointer(to: s) { sp in
            bow_poly_init(
                Int32(nPoly), t.sr,
                Int32(t.ba1.count), t.ba1, t.ba2, t.bn0, t.bA, t.bC, sp)
        }
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
                                 jt.phiD, jt.phiU, jt.phiF,
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
                    let tonic = tables.scalars.f0Open
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
            // two-way bridge coupling: same arming rule. 0 = byte-null.
            // The key is 0…1 of the safe range (see setJtCouple).
            let couple = bp.v("bow_jt_couple", 0.0)
            if couple > 0, pkernel != nil {
                setJtCouple(couple)
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

    // MARK: - Drone rows

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
    /// Held drone rows; guarded by `droneLock` (presses arrive on the link
    /// thread, remaps on main).
    var droneHeldRows: Set<Int> = []
    var droneLock = os_unfair_lock()
    /// Render-readable shadow of `droneHeldRows` (stores under `droneLock`,
    /// lock-free reads): recruitment counts a held row as fully ringing.
    var droneHeldMask: [Bool] = []

    /// Last evolve 0…1 actually forwarded to the kernel (dead-band ref).
    var jtEvolveApplied = 0.5

    var jtEvolveChromaticApplied = 0.5

    /// Graze-margin reference (`bow_jt_apex` at build) for the evolution map.
    var jtApexRef = 1.0e-5
    /// Last register tilt actually forwarded (dead-band ref).
    var jtEvolveRegApplied = 0.0

    // All under tiltLock.
    var meterArmed = false
    var meterSumV = 0.0          // Σ (outGain·x)² since last read
    var meterSumT = 0.0
    var meterFrames = 0
    var meterLast = (0.0, 0.0)

    // staged under tiltLock (target); balCur is render-thread only
    var balTarget = 0.0
    var balCur = 0.0

    // MARK: - Live parameters

    /// A parameter edit staged by the control thread, applied at the next
    /// chunk boundary on the render thread: the kernel scalar struct, `bp`
    /// for the Swift-side constants and output/radiation/room. Under
    /// `tiltLock`.
    var pendingLive: (bp: BowParams, scalars: bow_scalars_t,
                      tables: BowKernelTables?)?

    /// Master-gain state, all under `tiltLock`; `trimBase` is the FITTED
    /// trim (pre-gain) so bp pushes compare in BASE terms.
    var masterGain = 1.0
    var masterGainDirty = false
    var trimBase = 1.0

    /// Current / target kernel scalar blocks. Pushes are RAMPED (~25 ms)
    /// rather than stepped: several scalars multiply the signal, so a step
    /// would be a click. Everything ramps together for simplicity — the
    /// struct is interpolated FIELD BY FIELD in declaration order.
    var liveScalarsCur = bow_scalars_t()
    var liveScalarsTarget = bow_scalars_t()
    var liveGainCur = (trim: 1.0, mix: 0.0, width: 0.0)
    var liveGainTarget = (trim: 1.0, mix: 0.0, width: 0.0)
    var liveRamping = false
    /// Set by `setLiveParams` under `tiltLock`, cleared when the glide
    /// settles. Read by `render` to cap its chunk size.
    var liveRampArmed = false

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
                                // regime grip input: the kernel's running
                                // fundamental-capture fraction for the slot
                                if filters[s].gripArmed {
                                    var rg = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                                    withUnsafeMutablePointer(to: &rg) { rp in
                                        rp.withMemoryRebound(to: Double.self,
                                                             capacity: 6) { dp in
                                            if bow_poly_regime_slot(pk, Int32(s), dp) != 0 {
                                                filters[s].capture = dp[5]
                                            }
                                        }
                                    }
                                }
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
