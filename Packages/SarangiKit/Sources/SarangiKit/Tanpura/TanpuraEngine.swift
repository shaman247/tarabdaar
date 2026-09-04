import Foundation
import os.lock
import Accelerate
import CBowKernel

/// The playable TANPURA: one permanently-mounted kernel string per slot,
/// settled ONCE at build, mounted at CALLER-SUPPLIED exact Hz (the scale's
/// JI grid) with the `pitchCents` wrap correction interpolated in note
/// space. `pluck` strikes (no note-off for drones — tanpura strings
/// ring); the main-instrument path adds `bend` (fret glide) and
/// `release`. Post chain: body EQ FIR -> trim -> light mono room.
public final class TanpuraEngine: @unchecked Sendable {
    private let ctx: UnsafeMutableRawPointer
    private let p: TanpuraParams
    /// body EQ as a BLOCK vDSP convolution; taps reversed for
    /// vDSP_convD's correlation form
    private let firTapsRev: [Double]
    private var firHist: [Double]
    private var firTmp: [Double]
    private var reverb: Reverb
    private var mono: [Double]
    public var outGain: Double

    /// Mounted slot pitches (sounding Hz, exactly as requested).
    public let slotFrequencies: [Double]
    private let slotLogF: [Double]
    /// Scope telemetry: each slot's last commanded bend ratio (places a
    /// ringing string at its SOUNDING pitch after the touch has gone).
    private let scopeRatio = OSAllocatedUnfairLock(initialState: [Double]())

    /// pending note events (sync path: the audio thread drains; pool
    /// path: producers serialize through the lock into the kernel's
    /// SPSC ring). op = tanpura_event2's.
    private struct Ev { var slot: Int; var op: Int32; var val: Double }
    private let evLock = OSAllocatedUnfairLock(initialState: [Ev]())
    private var pooled = false

    /// Wrap-pull correction for a sounding Hz: linear interpolation of
    /// the per-12-TET-note `pitchCents` in note space, clamped.
    public static func centsCorrection(forHz f0: Double,
                                       params: TanpuraParams) -> Double {
        guard !params.pitchCents.isEmpty, f0 > 0 else { return 0 }
        let note = Pitch.fractionalMidi(hz: f0)
        let x = note - Double(params.noteLo)
        let n = params.pitchCents.count
        if x <= 0 { return params.pitchCents[0] }
        if x >= Double(n - 1) { return params.pitchCents[n - 1] }
        let i = Int(x)
        let t = x - Double(i)
        return params.pitchCents[i] * (1 - t) + params.pitchCents[i + 1] * t
    }

    /// Build + settle one slot per frequency and arm the ASYNC pool
    /// (workers > 1) so the callback never computes. CALL OFF the audio
    /// thread (seconds of CPU). `threadHMul` / `hfT60Mul` = per-slot
    /// register calibration / cascade slowing.
    public init?(params: TanpuraParams, frequencies: [Double],
                 workers: Int = 8,
                 threadHMul: ((Double) -> Double)? = nil,
                 hfT60Mul: ((Double) -> Double)? = nil) {
        let freqs = frequencies.filter { $0 > 0 }
        guard !freqs.isEmpty else { return nil }
        p = params
        slotFrequencies = freqs
        slotLogF = freqs.map { log2($0) }
        scopeRatio.withLock { $0 = [Double](repeating: 1.0, count: freqs.count) }
        guard let c = tanpura_create(Int32(freqs.count)) else { return nil }
        ctx = c
        let taps = params.bodyFIR.isEmpty ? [1.0] : params.bodyFIR
        firTapsRev = taps.reversed()
        firHist = [Double](repeating: 0, count: taps.count - 1 + 4096)
        firTmp = [Double](repeating: 0, count: 4096)
        reverb = Reverb(rt60: params.revRT60,
                        predelayMs: params.revPredelayMs,
                        mix: params.revMix, width: 0.0, sr: params.sr)
        mono = [Double](repeating: 0, count: 4096)
        outGain = params.gain
        let srSim = params.srSim ?? params.sr
        let settleN = Int(params.settleS * srSim)
        for (i, f0) in freqs.enumerated() {
            let cents = Self.centsCorrection(forHz: f0, params: params)
            let t = TanpuraTables.buildNote(
                f0Sounding: f0, cents: cents, p: params,
                threadHMul: threadHMul?(f0) ?? 1.0,
                hfT60Mul: hfT60Mul?(f0) ?? 1.0)
            // the kernel deep-copies every table at mount
            tanpura_mount(ctx, Int32(i), Int32(t.M), Int32(t.J),
                          t.ca, t.cb, t.ca4, t.cb4, t.ca2, t.cb2,
                          t.cas, t.cbs, t.wd, t.caw, t.cbw, t.wdw,
                          t.phi, t.phiF, t.b, t.g, t.g4, t.gd, t.gd4,
                          t.phiO, t.dq,
                          t.gTh, t.thBase, t.thH,
                          t.thF, t.thQ, t.thK,
                          t.kc, params.alpha, params.hcB,
                          t.deep, t.dt, 1.0,
                          params.pol.g,
                          params.pol.thDeg * Double.pi / 180.0,
                          t.polRt,
                          Int32((params.rampCycles ?? 0.0) * srSim
                                / f0))
            tanpura_set_oversample(ctx, Int32(i),
                                   Int32((srSim / params.sr)
                                         .rounded()))
            tanpura_settle(ctx, Int32(i), settleN)
        }
        if workers >= 2 {
            tanpura_set_threads(ctx, Int32(workers))
            pooled = tanpura_pool_size(ctx) >= 2
        }
    }

    deinit { tanpura_free(ctx) }

    /// Nearest mounted slot to a sounding pitch (log-space), or nil when
    /// it misses every slot by more than `toleranceCents`.
    public func nearestSlot(toHz hz: Double,
                            toleranceCents: Double = 1e9) -> Int? {
        guard hz > 0, !slotLogF.isEmpty else { return nil }
        let lf = log2(hz)
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for (i, s) in slotLogF.enumerated() {
            let d = abs(s - lf)
            if d < bestD { bestD = d; best = i }
        }
        return bestD * 1200.0 <= toleranceCents ? best : nil
    }

    /// Pluck: the role's displacement scaled by velocity (gentle floor)
    /// and `scale`. `bendRatio` retunes the slot ahead of the pluck (the
    /// fret's exact Hz; also normalizes a slot left bent). `touch` > 0
    /// migrates the ringing string to a history clone (frozen pitch,
    /// scaled by `touch`) so each pluck is a SEPARATE STRING; 0 = rides
    /// the ring. `drive` (1 = fitted) plucks `drive`-times harder with
    /// output gain 1/drive — the mellow↔buzzy axis at constant level.
    public func pluck(slot: Int, velocity01: Double, scale: Double = 1.0,
                      bendRatio: Double = 1.0, touch: Double = 0.0,
                      drive: Double = 1.0) {
        guard slot >= 0, slot < slotFrequencies.count else { return }
        let f0 = slotFrequencies[slot]
        let v = max(0.0, min(1.0, velocity01))
        let basePluck = TanpuraTables.role(for: f0, in: p).pluck
        let hi = min(1.0, pow(p.pluckRefF / f0, p.pluckExp))
        let amp = basePluck * hi * (0.3 + 0.7 * v)
            * max(0.0, scale)
        guard amp > 0 else { return }
        scopeRatio.withLock { if slot < $0.count { $0[slot] = bendRatio } }
        if pooled {
            evLock.withLock { _ in
                tanpura_event2(ctx, Int32(slot), 3, touch)
                tanpura_event2(ctx, Int32(slot), 4, drive)
                // op 6: a PRE-PLUCK bend migrates the ringing string
                // BEFORE the retune, so history keeps its own pitch
                tanpura_event2(ctx, Int32(slot), 6, bendRatio)
                tanpura_event2(ctx, Int32(slot), 0, amp)
            }
        } else {
            evLock.withLock {
                $0.append(Ev(slot: slot, op: 3, val: touch))
                $0.append(Ev(slot: slot, op: 4, val: drive))
                $0.append(Ev(slot: slot, op: 6, val: bendRatio))
                $0.append(Ev(slot: slot, op: 0, val: amp))
            }
        }
    }

    /// Live-retune a ringing slot: `ratio` vs its mounted pitch (kernel
    /// clamps 0.25…4; modes past the output Nyquist are silenced).
    public func bend(slot: Int, ratio: Double) {
        guard slot >= 0, slot < slotFrequencies.count, ratio > 0
        else { return }
        scopeRatio.withLock { if slot < $0.count { $0[slot] = ratio } }
        if pooled {
            evLock.withLock { _ in
                tanpura_event2(ctx, Int32(slot), 1, ratio)
            }
        } else {
            evLock.withLock {
                $0.append(Ev(slot: slot, op: 1, val: ratio))
            }
        }
    }

    /// Note-off release: extra broadband decay at `rate` 1/s
    /// (t60 = ln(1000)/rate) toward the wrap. 0 = natural ring.
    public func release(slot: Int, rate: Double) {
        guard slot >= 0, slot < slotFrequencies.count else { return }
        let r = max(0.0, rate)
        if pooled {
            evLock.withLock { _ in
                tanpura_event2(ctx, Int32(slot), 2, r)
            }
        } else {
            evLock.withLock {
                $0.append(Ev(slot: slot, op: 2, val: r))
            }
        }
    }

    /// History strings kept alive before the oldest is evicted to the
    /// ghost tier (0 = none). Thread-safe, immediate.
    public func setPolyphony(_ n: Int) {
        tanpura_set_poly(ctx, Int32(n))
    }

    public func allNotesOff() {
        if pooled {
            evLock.withLock { _ in tanpura_event(ctx, -1, 0.0) }
        } else {
            evLock.withLock { $0.removeAll() }
            for i in 0..<slotFrequencies.count {
                tanpura_damp(ctx, Int32(i))
            }
        }
    }

    /// telemetry: async underruns + divergence-guard resets
    public var underruns: Int { Int(tanpura_underruns(ctx)) }
    public var resetCount: Int { Int(tanpura_reset_count(ctx)) }

    public var activeStrings: Int { Int(tanpura_active_count(ctx)) }

    /// Scope telemetry: every slot's sounding pitch and output envelope
    /// (0 = idle). Racy display read; poll at UI rate.
    public func scopeSlots() -> [(hz: Double, level: Double)] {
        let ratios = scopeRatio.withLock { $0 }
        return slotFrequencies.indices.map { i in
            let r = i < ratios.count ? ratios[i] : 1.0
            return (slotFrequencies[i] * r, tanpura_slot_env(ctx, Int32(i)))
        }
    }

    /// Render stereo (mono physics through the body EQ + room).
    public func render(frames: Int, outL: UnsafeMutablePointer<Double>,
                       outR: UnsafeMutablePointer<Double>) {
        if !pooled {
            let evs = evLock.withLock { evts -> [Ev] in
                let out = evts
                evts.removeAll(keepingCapacity: true)
                return out
            }
            for e in evs {
                switch e.op {
                case 1: tanpura_bend(ctx, Int32(e.slot), e.val)
                case 2: tanpura_release(ctx, Int32(e.slot), e.val)
                case 3: tanpura_set_touch(ctx, Int32(e.slot), e.val)
                case 4: tanpura_set_drive(ctx, Int32(e.slot), e.val)
                case 6: tanpura_prepluck_bend(ctx, Int32(e.slot), e.val)
                default: tanpura_pluck(ctx, Int32(e.slot), e.val)
                }
            }
        }
        var done = 0
        let nt = firTapsRev.count
        while done < frames {
            let m = min(mono.count, frames - done)
            for i in 0..<m { mono[i] = 0 }
            mono.withUnsafeMutableBufferPointer { mb in
                if pooled {
                    tanpura_render_async(ctx, Int32(m), mb.baseAddress)
                } else {
                    tanpura_render(ctx, Int32(m), mb.baseAddress)
                }
            }
            // body EQ: slide history, vDSP correlate with reversed taps
            firHist.withUnsafeMutableBufferPointer { hb in
                let h = hb.baseAddress!
                // shift the last (nt-1) samples to the front
                if nt > 1 {
                    memmove(h, h + m, (nt - 1) * 8)
                }
                mono.withUnsafeBufferPointer { mbp in
                    _ = memcpy(h + (nt - 1), mbp.baseAddress!, m * 8)
                }
                firTapsRev.withUnsafeBufferPointer { tb in
                    firTmp.withUnsafeMutableBufferPointer { ob in
                        vDSP_convD(h, 1, tb.baseAddress!, 1,
                                   ob.baseAddress!, 1,
                                   vDSP_Length(m), vDSP_Length(nt))
                    }
                }
            }
            for i in 0..<m {
                let x = firTmp[i] * outGain
                let (l, r) = reverb.process(x)
                outL[done + i] = l
                outR[done + i] = r
            }
            done += m
        }
    }
}
