import Foundation
import CBowKernel

// The sympathetic taraf (the in-kernel modal-jawari web): the drone
// rows, the runtime jt axes (tone LP/HP, body, coupling, evolution,
// register/chromatic tilt, damping, the voice-relative cap) and the
// recruitment profile. Split out of BowEngine.swift; the stored state
// these read stays on the type.
extension BowEngine {
    /// async-jt telemetry: (drops, flat-filled samples, FIFO fill, async flag)
    public func jtAsyncStats() -> (drops: Double, flat: Double,
                                   fill: Double, on: Double) {
        var s = [Double](repeating: 0, count: 4)
        if let pk = pkernel { bow_poly_jt_async_stats(pk, &s) }
        return (s[0], s[1], s[2], s[3])
    }

    /// The jt row fundamentals (Hz) in kernel order — empty without a jt block.
    public var jtRowFreqs: [Double] { tables.jt?.rowFreqs ?? [] }

    /// The tuning tonic (`f0Open` — the open-string reference).
    public var tonicHz: Double { tables.scalars.f0Open }

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

    /// The kernel coupling gain the knob's FULL SCALE maps to: half the
    /// measured divergence gain. `bow_jt_couple` is expressed 0…1 of this
    /// safe range, so the knob's top is a bound, not a cliff.
    ///
    /// Measured on the shipped Pilu bank (34 rows), serial jt, the HEAVY
    /// case — a Sa/Pa/Sa′ chord at full expression held 1 s, then a 4 s ring, the
    /// output trim pulled 60 dB so the safety limiter never masks growth.
    /// The ring's decay from +1 s to +4 s: 31 dB uncoupled, 23 dB at 0.6,
    /// and at **0.8** it stops decaying and GROWS +6 dB through the last
    /// second — the web feeding itself. So the divergence gain is 0.8 and
    /// the knob's full scale is 0.4. (A single bowed note is far more
    /// forgiving, which is exactly why the bound is set on the chord.)
    public static let jtCoupleFullScale = 0.4

    /// TWO-WAY BRIDGE COUPLING (`bow_jt_couple`), **0…1 of the safe range**
    /// (`jtCoupleFullScale`): how much of the sympathetic rows' OWN summed
    /// bridge force (contact + termination, DC-blocked, in bank-normalized
    /// newtons) returns into the played strings' bridge force — the bridge
    /// load the one-way drive leaves out. It reaches the body, every played
    /// string's return, and the next tick's drive of every row, so the web
    /// also exchanges energy with itself through the bridge. The bank
    /// normalization (`JtTables.rowCplScale` ÷ Σ gout) is what makes one
    /// knob position mean one loop gain whatever the document holds.
    /// 0 = bypass (bit-exact). Kernel scalar write, slewed ~40 ms in the
    /// render loop.
    public func setJtCouple(_ k01: Double) {
        guard let pk = pkernel else { return }
        let k = min(max(k01, 0.0), 1.0)
        bow_poly_jt_set_couple(pk, k * Self.jtCoupleFullScale)
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

    /// THE CHROMATIC BRIDGE'S EVOLUTION 0…1 (`bow_jtc_evolve`): the same
    /// margin map on that bridge's own apex, delivered as per-row offsets
    /// against the raga bridge's lift. Same dead-band; no-op without rows.
    public func setJtEvolveChromatic(_ e01: Double) {
        let e = min(max(e01, 0.0), 1.0)
        if abs(e - jtEvolveChromaticApplied) < 0.005 { return }
        jtEvolveChromaticApplied = e
        pushJtEvolveOffsets()
    }

    /// Push every row's contact law (alpha / hcB / deep threshold) — only
    /// when a chromatic row exists (an all-raga rig stays byte-null).
    func pushJtRowContact(_ jt: JtTables) {
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

    /// Recompute + push the per-row offsets for (evolve, register): each
    /// row evaluates the SHARED margin map at e_row = clamp(e + reg·log2
    /// (tonic/f_row), 0, 1) on ITS bridge's apex and evolve; offset =
    /// lift(e_row) − lift(e), so rows stay on the calibrated span (×4…×¼).
    /// Nothing is pushed until some offset is non-zero (byte-null); once
    /// armed every recompute is pushed, zeros included.
    func pushJtEvolveOffsets() {
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
    func updateRecruitment(_ pk: UnsafeMutableRawPointer) {
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

    /// Per-chunk runtime-axis update (render thread): smooth each target
    /// (~40 ms) and push the kernel scalars only when they moved.
    func updateTarafAxes(n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let lT = jtLpHzTarget
        let hT = jtHpHzTarget
        let dT = dampAmtTarget
        os_unfair_lock_unlock(&tiltLock)
        if lT == 0.0, !jtLpEngaged, dT == 0.0, dampAmtCur == 0.0,
           hT == 0.0, jtHpHzCur == 0.0 { return }
        let a = OnePole.coefficient(frames: n48, tau: 0.04, sr: sr)
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
            let lpA = OnePole.coefficient(hz: jtLpHzCur, sr: jtTickRate)
            if let pk = pkernel { bow_poly_jt_set_lp(pk, lpA) }
        }
        // jt tone HP (0 eases the corner down to bypass; state kept warm)
        jtHpHzCur += a * (hT - jtHpHzCur)
        if hT == 0.0, jtHpHzCur < 1.0 { jtHpHzCur = 0.0 }
        if abs(jtHpHzCur - jtHpHzPushed) > 0.5 {
            jtHpHzPushed = jtHpHzCur
            let hpA = jtHpHzCur > 0
                ? OnePole.coefficient(hz: jtHpHzCur, sr: jtTickRate) : 0.0
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
}
