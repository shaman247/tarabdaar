import Foundation
import CBowKernel

// Display-only telemetry and the bus stage: the Scope tab's row/slot
// reads, the voice/taraf bus volume meter and the voice↔taraf balance.
extension BowEngine {
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

    // MARK: - Regime telemetry

    /// One played string's bow-contact regime counters, cumulative since
    /// its mount (diff two reads for a window). `slips / periods` is the
    /// slips-per-period figure: 1 = Helmholtz motion, ≥ 2 = multiple slip.
    public struct SlotRegime: Sendable {
        public var slips: Double
        public var periods: Double
        public var slipSamples: Double
        public var bowedSamples: Double
        /// Share of the string's motion at the fundamental (running, ~4
        /// periods): Helmholtz motion holds it high, an overtone regime
        /// collapses it.
        public var fundamental: Double
        public var slipsPerPeriod: Double {
            periods > 1e-9 ? slips / periods : 0
        }
        public var slipFraction: Double {
            bowedSamples > 0 ? slipSamples / bowedSamples : 0
        }
    }

    /// The slot's regime-grip amount 0…1 (racy telemetry; UI rate).
    public func slotGrip(_ s: Int) -> Double {
        guard s >= 0, s < filters.count else { return 0 }
        return filters[s].gripAmount
    }

    /// Racy telemetry read of slot `s` (any thread; UI rate).
    public func slotRegime(_ s: Int) -> SlotRegime? {
        guard let pk = pkernel, s >= 0, s < maxPoly else { return nil }
        var o = [Double](repeating: 0, count: 5)
        guard bow_poly_regime_slot(pk, Int32(s), &o) != 0 else { return nil }
        return SlotRegime(slips: o[0], periods: o[1], slipSamples: o[2],
                          bowedSamples: o[3], fundamental: o[4])
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

    /// Render thread: fold one split-bus chunk (kernel rate, mid streams)
    /// into the interval accumulators — after the bus FX and the balance,
    /// before the merge, so the meter shows each bus's actual contribution.
    func meterBuses(voice: UnsafePointer<Double>,
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

    /// Render thread: the balance attenuator pair, linear across the chunk.
    func applyBusBalance(voice: UnsafeMutablePointer<Double>,
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
}
