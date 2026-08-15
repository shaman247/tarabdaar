import Foundation
import os.lock
import Accelerate
import CBowKernel

/// The playable TANPURA: the r7 modal-jawari tanpura model as a live
/// instrument, ported from Sarangi Live 2026-08-04. Every slot owns a
/// permanently-mounted kernel string, settled onto its static wrap ONCE
/// at build (through the kernel itself — the jt startup-ping law);
/// `pluck` strikes the slot (velocity scales the pluck displacement),
/// re-plucking a ringing slot re-plucks the same string. Drone plucks
/// have no note-off (tanpura strings ring — the instrument's nature);
/// the main-instrument path additionally drives `bend` (live retune,
/// the fret glide) and `release` (note-off = much-faster decay toward
/// the settled wrap; 2026-08-05).
/// Inactive slots cost nothing; the kernel auto-idles quiet slots.
/// Post chain: fitted body/capture EQ FIR -> trim -> light mono room.
///
/// TARABDAAR DIVERGENCE from the Sarangi Live original: slots mount at
/// CALLER-SUPPLIED exact frequencies (the centralized scale's JI degree
/// grid) instead of the fixed 12-TET keyboard range, with the artifact's
/// per-note `pitchCents` wrap correction interpolated in log-pitch
/// (MIDI-note) space — the curve is smooth and spans +5..+9 c, so the
/// interpolation error is sub-cent. The retired FD-continuum path was
/// not ported (upstream retired it by ear, round 23).
public final class TanpuraEngine: @unchecked Sendable {
    private let ctx: UnsafeMutableRawPointer
    private let p: TanpuraParams
    /// body EQ as a BLOCK vDSP convolution (a 513-tap per-sample Swift
    /// FIR measured ~1x RT alone — the naive loop is not audio-thread
    /// material). taps reversed for vDSP_convD's correlation form.
    private let firTapsRev: [Double]
    private var firHist: [Double]
    private var firTmp: [Double]
    private var reverb: Reverb
    private var mono: [Double]
    public var outGain: Double

    /// The mounted slot pitches, in Hz, exactly as requested (sounding
    /// pitch — the wrap-pull correction is applied inside the tables).
    public let slotFrequencies: [Double]
    private let slotLogF: [Double]

    /// pending note events (sync path: audio thread drains; pool
    /// path: producers serialize through this lock into the kernel's
    /// SPSC event ring). op mirrors tanpura_event2: 0 = pluck,
    /// 1 = bend ratio, 2 = release rate.
    private struct Ev { var slot: Int; var op: Int32; var val: Double }
    private let evLock = OSAllocatedUnfairLock(initialState: [Ev]())
    private var pooled = false

    /// The wrap-pull pitch correction for an arbitrary sounding Hz:
    /// linear interpolation of the artifact's per-12-TET-note
    /// `pitchCents` in note space, clamped at the calibrated ends.
    public static func centsCorrection(forHz f0: Double,
                                       params: TanpuraParams) -> Double {
        guard !params.pitchCents.isEmpty, f0 > 0 else { return 0 }
        let note = 69.0 + 12.0 * log2(f0 / 440.0)
        let x = note - Double(params.noteLo)
        let n = params.pitchCents.count
        if x <= 0 { return params.pitchCents[0] }
        if x >= Double(n - 1) { return params.pitchCents[n - 1] }
        let i = Int(x)
        let t = x - Double(i)
        return params.pitchCents[i] * (1 - t) + params.pitchCents[i + 1] * t
    }

    /// Build + settle one slot per requested frequency; arms the ASYNC
    /// worker pool (workers > 1) — the callback then never computes (the
    /// jt live law: a callback that waits on workers chirps under load,
    /// and a budget-degraded solve clicks; one block of latency on a
    /// plucked drone is inaudible). CALL OFF the audio thread — the
    /// settle pass is ~seconds of CPU and the pool spawn is build-time
    /// only.
    /// `shaping` (2026-08-05): the scale-shaped-overtones transform,
    /// applied per slot at table build (nil = the physical tanpura).
    /// The slot's seed is its frequency in mHz — stable across grid
    /// rebuilds, so `spread`'s per-string jitter is reproducible.
    public init?(params: TanpuraParams, frequencies: [Double],
                 workers: Int = 8, shaping: TanpuraShaping? = nil) {
        let freqs = frequencies.filter { $0 > 0 }
        guard !freqs.isEmpty else { return nil }
        p = params
        slotFrequencies = freqs
        slotLogF = freqs.map { log2($0) }
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
                shaping: shaping,
                slotSeed: UInt64((f0 * 1000.0).rounded()))
            // implicit array->pointer bridging (valid for the call;
            // the kernel deep-copies every table at mount)
            tanpura_mount(ctx, Int32(i), Int32(t.M), Int32(t.J),
                          t.ca, t.cb, t.ca4, t.cb4, t.ca2, t.cb2,
                          t.cas, t.cbs, t.wd, t.caw, t.cbw, t.wdw,
                          t.phi, t.phiF, t.b, t.g, t.g4, t.gd, t.gd4,
                          t.phiO, t.dq,
                          t.gTh, t.thBase, t.thH,
                          t.thF, t.thQ, t.thK,
                          params.kc, params.alpha, params.hcB,
                          t.deep, t.dt, 1.0,
                          params.pol.g,
                          params.pol.thDeg * Double.pi / 180.0,
                          params.pol.rt,
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

    /// The pluck amplitude for a slot: the role's total displacement
    /// scaled by velocity (gentle floor — a tanpura is never hammered)
    /// and an optional caller scale (the drone-level trim).
    /// `bendRatio` retunes the slot at the pluck (main-instrument
    /// exact pitch: nearest slot bent to the fret's Hz) — sent as its
    /// own event ahead of the pluck, so it also NORMALIZES a slot a
    /// previous note left bent (the default 1.0 is a no-op kernel-side
    /// when the slot is already unbent).
    public func pluck(slot: Int, velocity: Int, scale: Double = 1.0,
                      bendRatio: Double = 1.0) {
        guard slot >= 0, slot < slotFrequencies.count else { return }
        let f0 = slotFrequencies[slot]
        let v = max(1, min(127, velocity))
        let basePluck = TanpuraTables.role(for: f0, in: p).pluck
        let hi = min(1.0, pow(p.pluckRefF / f0, p.pluckExp))
        let amp = basePluck * hi * (0.3 + 0.7 * Double(v) / 127.0)
            * max(0.0, scale)
        guard amp > 0 else { return }
        if pooled {
            // the lock serializes producers into the kernel's SPSC ring
            evLock.withLock { _ in
                tanpura_event2(ctx, Int32(slot), 1, bendRatio)
                tanpura_event2(ctx, Int32(slot), 0, amp)
            }
        } else {
            evLock.withLock {
                $0.append(Ev(slot: slot, op: 1, val: bendRatio))
                $0.append(Ev(slot: slot, op: 0, val: amp))
            }
        }
    }

    /// Live-retune a slot's ringing string: `ratio` vs its mounted
    /// pitch (the kernel clamps to 0.25…4 and silences modes bent past
    /// the output Nyquist). The main-instrument glide path drives this
    /// from the MPE per-channel pitch bend.
    public func bend(slot: Int, ratio: Double) {
        guard slot >= 0, slot < slotFrequencies.count, ratio > 0
        else { return }
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
    /// (t60 = ln(1000)/rate) toward the settled wrap — much faster
    /// than the natural ring, but still a decay, not a hard damp.
    /// Rate 0 restores the natural ring; a pluck clears it.
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

    /// telemetry: async underruns + divergence-guard resets (a click
    /// hunt reads these — both should stay at their startup values)
    public var underruns: Int { Int(tanpura_underruns(ctx)) }
    public var resetCount: Int { Int(tanpura_reset_count(ctx)) }

    public var activeStrings: Int { Int(tanpura_active_count(ctx)) }

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
