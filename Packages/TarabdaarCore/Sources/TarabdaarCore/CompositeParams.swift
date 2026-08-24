import Foundation

/// COMPOSITE PARAMETERS (2026-07-24) — the user-facing parameter language.
///
/// Tarabdaar has ONE parameter list (`ParamRegistry`, edited in the
/// Parameters tab) and one way to build a macro out of it:
///  * **Parameters** — every knob of the String instrument, each with a
///    native range and an apply strategy (live / rebuild / hybrid). A tilt
///    can bind to any one of them directly.
///  * **Composite parameters** — named 0…1 controls BUILT FROM several
///    parameters: each member sweeps its own `lo → hi` range (native
///    units) as the composite goes 0 → 1. Composites are edited exactly
///    like tilt bindings (add/remove members, drag ranges) in the Mac's
///    Controls tab. "Taraf Purity" is a composite over the jawari buzz
///    depth and the jawari tone LP.
///
/// MIDI CC numbers are a TRANSPORT detail: each composite occupies one of
/// 8 fixed slots whose CC carries its value from the iPad; no user-facing
/// surface shows CCs.
/// RAW TILT REPORT (2026-07-24): the iPad knows NOTHING about parameters,
/// slots, or mappings — it streams its three raw tilt values (fixed-scale
/// attitude since 2026-08-13, ~60 Hz, channel 0) on these fixed axis
/// messages, and the Mac evaluates its own tilt bindings (composites,
/// expression, vibrato, …). **14-BIT since 2026-08-14**: each axis is a
/// CC PAIR — MSB on `ccs`, LSB on `lsbCCs` (MSB + 32, the MIDI
/// convention), value = `msb·128 + lsb` of `round(norm·16383)`, sent
/// MSB-then-LSB and combined by the Mac on LSB arrival. One 7-bit step
/// was 1.4° at the ±90° scale — a resting arm flickered across
/// quantization boundaries as a square wave and the arm solve amplified
/// it; 14-bit steps are 0.011°. An MSB with no LSB still decodes at
/// 7-bit (legacy iPad builds). The CC numbers are a transport constant
/// shared by both apps, never user-facing.
public enum TiltAxisWire {
    public static let ccs: [UInt8] = [16, 17, 18]
    public static let lsbCCs: [UInt8] = [48, 49, 50]
    public static let dims: [InputDimension] = [.tilt1, .tilt2, .tilt3]
}

/// The Mac's FIVE bindable control axes (2026-08-13) — what the Controls
/// tab and the tilt-binding menus iterate. Axis index = position here
/// (`AppController.applyTiltAxis`; axis values −1…+1, rest 0 —
/// 2026-08-18). The first three are the ARM axes — the iPad's tilt
/// report through the guided arm calibration (`JoyConInput`, rest → 0,
/// sweep extremes → ±1), or raw pitch/roll/yaw passthrough when
/// uncalibrated; the last two are the Joy-Con stick. The 2026-08-12
/// body rework's WRIST axes are gone: `tilt4` keeps its
/// `InputDimension` case so saved bindings still decode, but it is not
/// a live axis. `TiltAxisWire` above stays the 3-CC iPad TRANSPORT —
/// wire format and Mac axes are different things.
public enum ControlAxes {
    /// 2026-08-23: `.strike` and `.acceleration` joined as the sixth and
    /// seventh axes — BOTH ride the iPad's accelerometer strike envelope
    /// (PERF_STATE `strike` byte, TLP v6), blended per target by time
    /// since the note started (`StrikeBlendWindow`, 2 s: onset = full
    /// Strike, sustain = full Acceleration; an unbound side reads as the
    /// target's default). They are NOT fed through `applyTiltAxis` like
    /// the others — `AppController.evaluateStrikeBlend` evaluates both
    /// axes' bindings jointly, so nothing may drive their axis indices
    /// directly (that would double-apply). UNIPOLAR: the binding curve's
    /// x-domain reads silence at 0 and a hard strike at 1 (the
    /// tilts/stick rest at the centre instead).
    public static let dims: [InputDimension] = [
        .tilt1, .tilt2, .tilt3, .stickX, .stickY, .strike, .acceleration,
    ]
}

public struct CompositeMember: Codable, Equatable, Identifiable {
    /// Any `ParamRegistry` key.
    public var key: String
    /// The member's value at composite 0 / composite 1 (native units;
    /// lo > hi = inverted sweep).
    public var lo: Double
    public var hi: Double

    public var id: String { key }

    public init(key: String, lo: Double, hi: Double) {
        self.key = key
        self.lo = lo
        self.hi = hi
    }

    /// The member's value at composite value `v` (0…1).
    public func value(at v: Double) -> Double {
        lo + min(max(v, 0.0), 1.0) * (hi - lo)
    }
}

public struct CompositeParam: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Which of the 8 transport slots this composite occupies (0…7).
    public var slot: Int
    public var members: [CompositeMember]

    public init(id: UUID = UUID(), name: String, slot: Int,
                members: [CompositeMember]) {
        self.id = id
        self.name = name
        self.slot = slot
        self.members = members
    }

    /// Transport CCs per slot — an implementation detail (slots 0–2 are the
    /// original taraf-axis CCs, kept so persisted tilt bindings and the
    /// SysEx wire stay valid; 3–7 extend the pool).
    public static let slotCCs: [UInt8] = [71, 73, 72, 20, 21, 22, 23, 24]
    public static var maxSlots: Int { slotCCs.count }

    public var slotCC: UInt8 { CompositeParam.slotCCs[slot] }

    /// The factory composites — the shipped taraf/tone behaviors plus
    /// Expression (so a resting device still plays with dynamics), all as
    /// editable member sets over registry parameters.
    public static func defaults() -> [CompositeParam] {
        [
            // Purity has two members (2026-07-26). TONE: the radiated
            // jawari sum darkens, open (16 kHz — all the contact
            // sparkle) → 1.5 kHz, where only the rows' tonal ring is
            // left. (The original second member swept the LINEAR web's
            // buzz depth, `bow_taraf_jawari`; that web was deleted
            // 2026-07-24.) RECRUITMENT: `bow_jt_sel` falls 0.5 → 0 —
            // rest (purity 0) is the FITTED taraf and purity 1 narrows
            // it to the played note's harmonic kin (unison / faint
            // octaves / fainter fifth) at held loudness. The lo stays
            // at the fitted midpoint deliberately: the axis' upper
            // half is the note-independent FLAT profile (2026-08-01
            // rework), and resting there would decouple the wash from
            // the playing — the same "backing ensemble" failure the
            // coherence rev fixed when the upper half was the lush
            // boost.
            CompositeParam(name: "Taraf Purity", slot: 0, members: [
                CompositeMember(key: "bow_jt_lp", lo: 16000.0, hi: 1500.0),
                CompositeMember(key: "bow_jt_sel", lo: 0.5, hi: 0.0),
            ]),
            CompositeParam(name: "Taraf Decay", slot: 1, members: [
                CompositeMember(key: "bow_jt_damp", lo: 0.0, hi: 1.0),
            ]),
            CompositeParam(name: "Tone Tilt", slot: 2, members: [
                CompositeMember(key: "bow_tone_tilt", lo: -1.0, hi: 1.0),
            ]),
            // Expression on slot 3, bound to tilt 1 by default. Member
            // range [0, 0.5] with the full-throw tilt curve: resting tilt
            // (0.5 normalized) lands on expr ≈ 0.25 (the fitted median),
            // tilting down fades toward silence, up pushes louder.
            CompositeParam(name: "Expression", slot: 3, members: [
                CompositeMember(key: "bow_expr", lo: 0.0, hi: 0.5),
            ]),
        ]
    }
}
