import Foundation

/// COMPOSITE PARAMETERS (2026-07-24) — the user-facing parameter language.
///
/// Starpad has ONE parameter list (`ParamRegistry`, edited in the
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
/// slots, or mappings — it streams its three calibrated tilt values
/// (normalized 0…1 → 0…127, ~60 Hz while playing, channel 0) on these
/// fixed axis messages, and the Mac evaluates its own tilt bindings
/// (composites, expression, vibrato, …). The CC numbers are a transport
/// constant shared by both apps, never user-facing.
public enum TiltAxisWire {
    public static let ccs: [UInt8] = [16, 17, 18]
    public static let dims: [InputDimension] = [.tilt1, .tilt2, .tilt3]
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
            // rest (purity 0) is the FITTED taraf and purity 1 strips
            // it to the played note's harmonic kin (unison / faint
            // octaves / fainter fifth). The lo used to be 1.0 (the
            // full bipolar span), which with the default rest-zero
            // tilt curve parked the RESTING instrument at the ×2 lush
            // boosted chorus — a wash that decoupled from the playing
            // and read as a backing ensemble (2026-08-01 coherence
            // rev). Set lo back above 0.5 to make rest lusher than
            // fitted again.
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
