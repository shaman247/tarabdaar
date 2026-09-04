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
/// registry key suffixes (`fx_<point>_<field>`); the EQ curve's points are
/// the one structured field (the FX tab edits them, presets carry them).
public struct FXSettings: Equatable, Sendable {
    public var eqOn = false
    /// The EQ curve's control points (`EQCurve`), normalised: pitch-sorted,
    /// 20 Hz…20 kHz, ±12 dB, at most `EQCurve.maxPoints`.
    public var eqPoints: [EQPoint] = []
    /// Curve depth 0…1: every dB of the curve scaled (0 = flat).
    public var eqAmount = 1.0
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
        (eqOn && eqAmount > 0 && eqPoints.contains { $0.db != 0 })
            || (revOn && revMix > 0)
    }

    /// Apply one registry value by field suffix (`eq_on`, `eq_amount`,
    /// `rev_on`, `rev_type`, `rev_mix`, `rev_size`, `rev_cut`).
    /// Returns false for an unknown field.
    @discardableResult
    public mutating func apply(field: String, value: Double) -> Bool {
        switch field {
        case "eq_on": eqOn = value >= 0.5
        case "eq_amount": eqAmount = min(max(value, 0), 1)
        case "rev_on": revOn = value >= 0.5
        case "rev_type":
            revKind = FXReverbKind(rawValue: Int(value.rounded()))?.rawValue
                ?? FXReverbKind.bigverb.rawValue
        case "rev_mix": revMix = min(max(value, 0), 1)
        case "rev_size": revSize = min(max(value, 0), 1)
        case "rev_cut": revCutoff = min(max(value, 100), 20_000)
        default: return false
        }
        return true
    }
}

/// One realised EQ cascade with its own state — the unit keeps two and
/// crossfades between them when the design changes.
struct EQCascade: Sendable {
    /// a = mono/mid/L, b = side/R — same coefficients, independent state:
    /// EQing mid and side identically equals EQing L/R by linearity.
    private var a: [Biquad]
    private var b: [Biquad]
    private(set) var count = 0
    private(set) var gain = 1.0
    private(set) var design = EQDesign()

    init() {
        let flat = Biquad(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)
        a = [Biquad](repeating: flat, count: EQCurve.maxSections)
        b = a
    }

    var isIdentity: Bool { count == 0 && gain == 1 }

    /// Adopt a design from rest (state cleared — the caller warms it up
    /// under a zero crossfade weight before it is heard).
    mutating func load(_ d: EQDesign, sr: Double) {
        design = d
        count = min(d.sections.count, a.count)
        gain = pow(10, d.gainDB / 20)
        for i in 0..<count {
            let sec = d.sections[i].biquad(sr: sr)
            a[i] = sec; b[i] = sec
        }
    }

    mutating func reset() {
        for i in 0..<count { a[i].reset(); b[i].reset() }
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        var y = x
        for k in 0..<count { y = a[k].process(y) }
        return y * gain
    }

    @inline(__always)
    mutating func processPair(_ x: Double, _ z: Double) -> (Double, Double) {
        var y = x, w = z
        for k in 0..<count {
            y = a[k].process(y)
            w = b[k].process(w)
        }
        return (y * gain, w * gain)
    }
}

/// One insert point's DSP: the EQ curve (a fitted cascade, see `EQCurve`)
/// into a selectable additive reverb. Everything is preallocated at init;
/// `retarget`/`tick`/`process*` run on the render thread only (settings
/// and the finished design arrive via the engine's staging lock).
///
/// Both halves fade rather than switch. A new EQ design is loaded into the
/// idle cascade, run silently for `eqWarmMs` so its start-up transient
/// settles, then crossfaded in over `eqFadeMs` and the old cascade dropped —
/// so a point drag, a curve edit and the on/off toggle (a fade to the
/// identity) are all click-free; a design arriving mid-fade waits for the
/// fade to finish (latest wins). Disabling the reverb glides the wet level
/// to zero. Bypassed halves cost nothing.
public struct FXChainUnit: Sendable {
    public static let eqWarmMs = 10.0
    public static let eqFadeMs = 30.0

    public let sr: Double
    private var target = FXSettings()

    // --- EQ: two cascades, `cur` audible, the other warming/fading in ---
    private var eq: [EQCascade]
    private var cur = 0
    private var incoming = -1          // -1 = none
    private var warmLeft = 0           // samples of silent warm-up left
    private var fadePos = 0            // samples into the crossfade
    private let warmLen: Int
    private let fadeLen: Int
    private var pendingDesign: EQDesign?
    private var targetDesign = EQDesign()
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
        eq = [EQCascade(), EQCascade()]
        warmLen = Int(FXChainUnit.eqWarmMs * 0.001 * sr)
        fadeLen = max(1, Int(FXChainUnit.eqFadeMs * 0.001 * sr))
        bigverb = Bigverb(sr: sr)
        // The room's own mix/width stay pinned (1, 1): the chain owns the
        // wet level so both reverb kinds share one mix law.
        room = Reverb(rt60: 2.0, predelayMs: 12, mix: 1.0, width: 1.0, sr: sr)
    }

    /// Adopt new settings and the EQ design realised from them (render
    /// thread, chunk boundary). Cheap when nothing changed; a reverb-kind
    /// switch resets the incoming tank so a stale tail from its last
    /// selection doesn't replay.
    public mutating func retarget(_ s: FXSettings, design: EQDesign) {
        if design != targetDesign {
            targetDesign = design
            if incoming < 0 {
                startCascade(design)
            } else if warmLeft > 0 {
                // not audible yet: reload in place and warm up again
                eq[incoming].load(design, sr: sr)
                warmLeft = warmLen
                pendingDesign = nil
            } else {
                pendingDesign = design
            }
        }
        guard s != target else { return }
        if s.revKind != activeKind {
            activeKind = s.revKind
            if activeKind == FXReverbKind.bigverb.rawValue { bigverb.reset() }
            else { room.reset() }
            appliedSize = -1; appliedCutoff = -1
        }
        target = s
    }

    private mutating func startCascade(_ d: EQDesign) {
        let j = 1 - cur
        eq[j].load(d, sr: sr)
        incoming = j
        warmLeft = warmLen
        fadePos = 0
    }

    /// Anything to process this chunk (including fade-out tails of a
    /// just-disabled half)?
    public var isEngaged: Bool { eqEngaged || revEngaged }
    private var eqEngaged: Bool { incoming >= 0 || !eq[cur].isIdentity }

    /// Advance the chunk-rate smoothers and retune whatever moved.
    /// `frames` is this chunk's length at `sr`.
    public mutating func tick(frames: Int) {
        let a = OnePole.coefficient(frames: frames, tau: 0.05, sr: sr)
        // EQ: a finished crossfade hands over; a waiting design starts
        if incoming >= 0, fadePos >= fadeLen {
            cur = incoming
            incoming = -1
            if let d = pendingDesign {
                pendingDesign = nil
                if d != eq[cur].design { startCascade(d) }
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

    /// The crossfade weight of the incoming cascade for the next sample.
    @inline(__always)
    private mutating func fadeWeight() -> Double {
        if warmLeft > 0 { warmLeft -= 1; return 0 }
        if fadePos < fadeLen { fadePos += 1 }
        return Double(fadePos) / Double(fadeLen)
    }

    /// Mono in place — the drive point, and the mono post-chain.
    public mutating func processMono(_ buf: UnsafeMutablePointer<Double>,
                                     _ n: Int) {
        guard isEngaged, n > 0 else { return }
        let dm = (curMix - mixPrev) / Double(n)
        let eqOn = eqEngaged
        for i in 0..<n {
            var x = buf[i]
            if eqOn {
                if incoming >= 0 {
                    let y1 = eq[incoming].process(x)
                    let y0 = eq[cur].process(x)
                    let w = fadeWeight()
                    x = y0 + w * (y1 - y0)
                } else {
                    x = eq[cur].process(x)
                }
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
        let eqOn = eqEngaged
        for i in 0..<n {
            var mm = m[i], ss = s[i]
            if eqOn {
                if incoming >= 0 {
                    let (m1, s1) = eq[incoming].processPair(mm, ss)
                    let (m0, s0) = eq[cur].processPair(mm, ss)
                    let w = fadeWeight()
                    mm = m0 + w * (m1 - m0)
                    ss = s0 + w * (s1 - s0)
                } else {
                    (mm, ss) = eq[cur].processPair(mm, ss)
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
        let eqOn = eqEngaged
        for i in 0..<n {
            var ll = l[i], rr = r[i]
            if eqOn {
                if incoming >= 0 {
                    let (l1, r1) = eq[incoming].processPair(ll, rr)
                    let (l0, r0) = eq[cur].processPair(ll, rr)
                    let w = fadeWeight()
                    ll = l0 + w * (l1 - l0)
                    rr = r0 + w * (r1 - r0)
                } else {
                    (ll, rr) = eq[cur].processPair(ll, rr)
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
        for i in eq.indices { eq[i].reset() }
        bigverb.reset()
        room.reset()
    }
}
