import Foundation

/// The four FX insert points of the Tarabdaar rack , in signal
/// order. Each point carries an optional graphic EQ and an optional
/// reverb; everything is OFF by default (the whole rack byte-null).
///
///   drive  — the main voice AS THE TARAF HEARS IT: the recorded jt-drive
///            buffer (mono, kernel rate) via `bow_poly_set_drive_fx`.
///            Shapes only what excites the sympathetic strings; the
///            radiated voice is untouched.
///   voice  — the main voice bus (bridge radiation + bow noise) after the
///            taraf tap, before the shared radiation post-chain.
///   taraf  — the modal-jawari web's own radiated output (the split
///            `outJt` bus of `bow_poly_process3`), same insertion depth.
///   global — the final stereo output, after the whole fitted post-chain
///            (radiation, tone tilt, calibration room, outGain).
public enum FXPoint: Int, CaseIterable, Sendable {
    case drive = 0, voice, taraf, global

    public var keyPrefix: String {
        switch self {
        case .drive: return "fx_drive_"
        case .voice: return "fx_voice_"
        case .taraf: return "fx_taraf_"
        case .global: return "fx_global_"
        }
    }

    /// Split a registry key like `fx_voice_eq_b3` into (point, field).
    public static func parse(key: String) -> (FXPoint, String)? {
        for p in FXPoint.allCases where key.hasPrefix(p.keyPrefix) {
            return (p, String(key.dropFirst(p.keyPrefix.count)))
        }
        return nil
    }
}

/// The reverbs an insert point can select.
public enum FXReverbKind: Int, CaseIterable, Sendable {
    /// sndkit Bigverb (Costello `reverbsc`): 8 jittered feedback delay
    /// lines — a wide, modulated hall. The default.
    case bigverb = 0
    /// The Freeverb-style room tank already shipped for the calibration
    /// reverb: tighter, energy-matched to the dry level.
    case room = 1
}

/// One insert point's user-facing state — plain values, `Equatable` so the
/// render thread can skip untouched points. Field names mirror the
/// registry key suffixes (`fx_<point>_<field>`).
public struct FXSettings: Equatable, Sendable {
    public var eqOn = false
    /// Per-band gain in dB (`FXChainUnit.eqBands` centres), ±12.
    public var eqGains = [Double](repeating: 0, count: FXChainUnit.eqBandCount)
    public var revOn = false
    public var revKind = FXReverbKind.bigverb.rawValue
    /// Wet level 0…1 (the dry path always passes at unity — a send).
    public var revMix = 0.3
    /// 0…1: Bigverb feedback directly; the room maps it onto RT60.
    public var revSize = 0.93
    /// Feedback-loop / band-limit lowpass corner, Hz.
    public var revCutoff = 10_000.0

    public init() {}

    /// True when this point does anything at all.
    public var isActive: Bool {
        (eqOn && eqGains.contains { $0 != 0 }) || (revOn && revMix > 0)
    }

    /// Apply one registry value by field suffix (`eq_on`, `eq_b1`…`eq_b10`,
    /// `rev_on`, `rev_type`, `rev_mix`, `rev_size`, `rev_cut`).
    /// Returns false for an unknown field.
    @discardableResult
    public mutating func apply(field: String, value: Double) -> Bool {
        switch field {
        case "eq_on": eqOn = value >= 0.5
        case "rev_on": revOn = value >= 0.5
        case "rev_type":
            revKind = FXReverbKind(rawValue: Int(value.rounded()))?.rawValue
                ?? FXReverbKind.bigverb.rawValue
        case "rev_mix": revMix = min(max(value, 0), 1)
        case "rev_size": revSize = min(max(value, 0), 1)
        case "rev_cut": revCutoff = min(max(value, 100), 20_000)
        default:
            guard field.hasPrefix("eq_b"), let b = Int(field.dropFirst(4)),
                  b >= 1, b <= eqGains.count else { return false }
            eqGains[b - 1] = min(max(value, -12), 12)
        }
        return true
    }
}

/// One insert point's DSP: a 10-band octave graphic EQ (RBJ peaking
/// sections, click-free retunes) into a selectable additive reverb.
/// Everything is preallocated at init; `retarget`/`tick`/`process*` run on
/// the render thread only (settings arrive via the engine's staging lock).
///
/// Both halves fade rather than switch: disabling the EQ glides every band
/// to 0 dB before bypassing, and disabling the reverb glides the wet level
/// to zero — the toggles are click-free by construction. Bypassed halves
/// cost nothing.
public struct FXChainUnit: Sendable {
    /// ISO octave centres of the graphic EQ.
    public static let eqBands: [Double] =
        [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]
    public static var eqBandCount: Int { eqBands.count }
    /// Octave-wide peaking sections (Q ≈ f0/BW for BW = 1 octave).
    static let eqQ = 1.41

    public let sr: Double
    private var target = FXSettings()

    // --- graphic EQ (a = mono/mid/L, b = side/R — same coefficients,
    //     independent state: EQing mid and side identically equals EQing
    //     L/R by linearity, the tilt-shelf pattern) ---
    private var eqA: [Biquad]
    private var eqB: [Biquad]
    private var curGains: [Double]
    private var appliedGains: [Double]
    private var eqEngaged = false

    // --- reverb ---
    private var bigverb: Bigverb
    private var room: Reverb
    private var activeKind = FXReverbKind.bigverb.rawValue
    private var curMix = 0.0        // chunk-rate smoothed wet level
    private var mixPrev = 0.0       // where the last chunk's ramp ended
    private var appliedSize = -1.0
    private var appliedCutoff = -1.0
    private var revEngaged = false

    public init(sr: Double) {
        self.sr = sr
        let flat = FXChainUnit.eqBands.map {
            Biquad.peaking(f0: min($0, 0.4 * sr), gainDB: 0,
                           q: FXChainUnit.eqQ, sr: sr)
        }
        eqA = flat
        eqB = flat
        curGains = [Double](repeating: 0, count: flat.count)
        appliedGains = curGains
        bigverb = Bigverb(sr: sr)
        // The room's own mix/width stay pinned (1, 1): the chain owns the
        // wet level so both reverb kinds share one mix law.
        room = Reverb(rt60: 2.0, predelayMs: 12, mix: 1.0, width: 1.0, sr: sr)
    }

    /// Adopt new settings (render thread, chunk boundary). Cheap when
    /// nothing changed; a reverb-kind switch resets the incoming tank so
    /// a stale tail from its last selection doesn't replay.
    public mutating func retarget(_ s: FXSettings) {
        guard s != target else { return }
        if s.revKind != activeKind {
            activeKind = s.revKind
            if activeKind == FXReverbKind.bigverb.rawValue { bigverb.reset() }
            else { room.reset() }
            appliedSize = -1; appliedCutoff = -1
        }
        target = s
    }

    /// Anything to process this chunk (including fade-out tails of a
    /// just-disabled half)?
    public var isEngaged: Bool { eqEngaged || revEngaged }

    /// Advance the chunk-rate smoothers and retune whatever moved.
    /// `frames` is this chunk's length at `sr`.
    public mutating func tick(frames: Int) {
        let a = 1.0 - exp(-Double(frames) / (0.05 * sr))
        // EQ: glide every band toward its effective target (0 dB when off)
        var flat = true
        var moved = false
        for i in curGains.indices {
            let tg = target.eqOn ? target.eqGains[i] : 0.0
            if tg != 0 { flat = false }
            curGains[i] += a * (tg - curGains[i])
            if abs(curGains[i]) > 0.02 { flat = false }
            if abs(curGains[i] - appliedGains[i]) > 0.05 { moved = true }
        }
        if flat {
            if eqEngaged {
                eqEngaged = false
                for i in eqA.indices { eqA[i].reset(); eqB[i].reset() }
                for i in curGains.indices { curGains[i] = 0; appliedGains[i] = 0 }
            }
        } else {
            eqEngaged = true
            if moved {
                for i in curGains.indices where
                    abs(curGains[i] - appliedGains[i]) > 0.05 {
                    appliedGains[i] = curGains[i]
                    let sec = Biquad.peaking(
                        f0: min(FXChainUnit.eqBands[i], 0.4 * sr),
                        gainDB: curGains[i], q: FXChainUnit.eqQ, sr: sr)
                    eqA[i].copyCoefficients(from: sec)
                    eqB[i].copyCoefficients(from: sec)
                }
            }
        }
        // Reverb: glide the wet level; retune the active tank when moved
        mixPrev = curMix
        let mixTarget = target.revOn ? target.revMix : 0.0
        curMix += a * (mixTarget - curMix)
        if mixTarget == 0, curMix < 1e-4 { curMix = 0 }
        let engagedNow = curMix > 0 || mixTarget > 0
        if revEngaged, !engagedNow {
            // fully faded out: silence the tank so a later enable is clean
            if activeKind == FXReverbKind.bigverb.rawValue { bigverb.reset() }
            else { room.reset() }
        }
        revEngaged = engagedNow
        if revEngaged, target.revSize != appliedSize
            || target.revCutoff != appliedCutoff {
            appliedSize = target.revSize
            appliedCutoff = target.revCutoff
            bigverb.size = 0.999 * appliedSize
            bigverb.cutoff = min(appliedCutoff, 0.45 * sr)
            // size → RT60: 0 → 0.25 s, 1 → 8 s (log sweep)
            room.setTone(rt60: 0.25 * pow(32.0, appliedSize),
                         cutoffHz: appliedCutoff)
        }
    }

    // MARK: - processing (render thread; call `tick` once per chunk first)

    /// Mono in place — the drive point, and the mono post-chain.
    public mutating func processMono(_ buf: UnsafeMutablePointer<Double>,
                                     _ n: Int) {
        guard isEngaged, n > 0 else { return }
        let dm = (curMix - mixPrev) / Double(n)
        for i in 0..<n {
            var x = buf[i]
            if eqEngaged {
                for k in eqA.indices { x = eqA[k].process(x) }
            }
            if revEngaged {
                let wet: Double
                if activeKind == FXReverbKind.bigverb.rawValue {
                    let (wl, wr) = bigverb.process(x, x)
                    wet = 0.5 * (wl + wr)
                } else {
                    wet = room.processMono(x)
                }
                x += (mixPrev + dm * Double(i)) * wet
            }
            buf[i] = x
        }
    }

    /// Mid/side pair in place — the voice and taraf buses (kernel rate,
    /// pre-decimation). The reverb hears L/R and its wet folds back to
    /// mid/side, so the host's L = m + s, R = m − s stays consistent.
    public mutating func processMidSide(_ m: UnsafeMutablePointer<Double>,
                                        _ s: UnsafeMutablePointer<Double>,
                                        _ n: Int) {
        guard isEngaged, n > 0 else { return }
        let dm = (curMix - mixPrev) / Double(n)
        for i in 0..<n {
            var mm = m[i], ss = s[i]
            if eqEngaged {
                for k in eqA.indices {
                    mm = eqA[k].process(mm)
                    ss = eqB[k].process(ss)
                }
            }
            if revEngaged {
                let wl: Double, wr: Double
                if activeKind == FXReverbKind.bigverb.rawValue {
                    (wl, wr) = bigverb.process(mm + ss, mm - ss)
                } else {
                    (wl, wr) = room.processMonoStereo(mm)
                }
                let mix = mixPrev + dm * Double(i)
                mm += mix * 0.5 * (wl + wr)
                ss += mix * 0.5 * (wl - wr)
            }
            m[i] = mm
            s[i] = ss
        }
    }

    /// L/R pair in place — the global point (post everything).
    public mutating func processLR(_ l: UnsafeMutablePointer<Double>,
                                   _ r: UnsafeMutablePointer<Double>,
                                   _ n: Int) {
        guard isEngaged, n > 0 else { return }
        let dm = (curMix - mixPrev) / Double(n)
        for i in 0..<n {
            var ll = l[i], rr = r[i]
            if eqEngaged {
                for k in eqA.indices {
                    ll = eqA[k].process(ll)
                    rr = eqB[k].process(rr)
                }
            }
            if revEngaged {
                let wl: Double, wr: Double
                if activeKind == FXReverbKind.bigverb.rawValue {
                    (wl, wr) = bigverb.process(ll, rr)
                } else {
                    (wl, wr) = room.processMonoStereo(0.5 * (ll + rr))
                }
                let mix = mixPrev + dm * Double(i)
                ll += mix * wl
                rr += mix * wr
            }
            l[i] = ll
            r[i] = rr
        }
    }

    public mutating func reset() {
        for i in eqA.indices { eqA[i].reset(); eqB[i].reset() }
        bigverb.reset()
        room.reset()
    }
}
