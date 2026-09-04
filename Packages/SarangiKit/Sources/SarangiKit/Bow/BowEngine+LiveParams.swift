import Foundation
import CBowKernel

// The live-parameter path: staging an edit from the control thread,
// the chunk-rate scalar/gain ramp that adopts it, in-place coefficient
// reloads, and the tone-tilt axis.
extension BowEngine {
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

    /// Apply a parameter edit WITHOUT rebuilding: the kernel scalars are
    /// overwritten in place (ramped) and the Swift-side constants re-read;
    /// all running state stays intact. Control-thread safe; effective next
    /// chunk. Covers only what does not resize a table
    /// (`ParamRegistry.inPlaceKeys`). `tables` also reloads the body modal
    /// bank + jawari coefficients in place; a shape change is refused.
    public func setLiveParams(bp: BowParams, scalars: bow_scalars_t,
                              tables: BowKernelTables? = nil) {
        // Arm the RAMP only when a ramped quantity moved: the ramp caps the
        // render chunk to 256 frames, and chunk size perturbs the chaotic
        // friction loop, so a no-op push must not arm it. Coefficient
        // reloads are click-free unramped. Trim compares in BASE terms.
        let gains = (mix: bp.v("bow_rev_mix", reverb.mix),
                     width: bp.v("bow_rev_width", reverb.width))
        os_unfair_lock_lock(&tiltLock)
        let baseTrim = bp.v("bow_live_trim", trimBase)
        let ramped = !scalars.equalsFieldwise(liveScalarsTarget)
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
                phiD.baseAddress,
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
        }}}}}}}}}}}}}}}}}}
        // Melody follower: refresh the retune-law constants; re-arming the
        // SAME row keeps its current pitch
        if jt.trackRow >= 0, Int(jt.trackRow) < jt.rowFreqs.count {
            bow_poly_jt_track_config(st, jt.trackRow,
                                     jt.rowFreqs[Int(jt.trackRow)],
                                     jt.trackT60, jt.trackFhf, jt.trackBst)
        }
    }

    /// Render-thread half of `setLiveParams`: adopt a new target, then
    /// glide toward it at chunk rate.
    func applyPendingLive(n48: Int) {
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
        // Field-by-field over the struct's contiguous doubles, in
        // declaration order — the same order (and the same formula) the
        // positional vector was interpolated in.
        liveScalarsCur.withMutableDoubles { cur in
            liveScalarsTarget.withDoubles { tgt in
                for i in 0..<bow_scalars_t.fieldCount {
                    let d = tgt[i] - cur[i]
                    if abs(d) > 1e-12 {
                        cur[i] += a * d
                        if abs(tgt[i] - cur[i]) > 1e-9 * max(abs(tgt[i]), 1.0) {
                            settled = false
                        } else {
                            cur[i] = tgt[i]
                        }
                    }
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
        if let pk = pkernel {
            withUnsafePointer(to: liveScalarsCur) { bow_poly_set_scalars(pk, $0) }
        }
        if settled {
            liveRamping = false
            os_unfair_lock_lock(&tiltLock)
            liveRampArmed = false
            os_unfair_lock_unlock(&tiltLock)
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
    func updateToneTilt(n48: Int) {
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
}
