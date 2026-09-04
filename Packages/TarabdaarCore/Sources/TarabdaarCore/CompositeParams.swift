import Foundation

/// COMPOSITE PARAMETERS — named 0…1 controls BUILT FROM several registry
/// parameters: each member sweeps its own `lo → hi` range (native units)
/// as the composite goes 0 → 1. Edited like tilt bindings (add/remove
/// members, drag ranges) in the Mac's Controls tab; a tilt can bind to a
/// composite or directly to any single parameter.
///
/// Each composite occupies one of 8 fixed slots; the slot index is its
/// whole identity.
///
/// RAW TILT REPORT: the iPad knows nothing about parameters, slots or
/// mappings — it streams three raw tilt values in the PERF_STATE frame
/// and the Mac evaluates its own bindings.

/// The Mac's bindable control axes — what the Controls tab and the
/// binding menus iterate. Axis index = position here
/// (`AppController.applyTiltAxis`; axis values −1…+1, rest 0). Append
/// new axes so earlier indices stay put.
public enum ControlAxes {
    /// Per-axis semantics: `InputDimension`. Invariant: `.strike` and
    /// `.acceleration` are evaluated JOINTLY by
    /// `AppController.evaluateStrikeBlend` (the per-note blend), never
    /// through `applyTiltAxis` — driving their indices directly would
    /// double-apply. The unipolar axes (strike pair, `.jcAccel`) read
    /// rest at curve x 0; every other axis rests at the centre.
    public static let dims: [InputDimension] = [
        .tilt1, .tilt2, .tilt3, .stickX, .stickY, .strike, .acceleration,
        .fingerAccel, .tilt4, .wrist2, .wrist3, .jcAccel,
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

    /// How many composite slots exist.
    public static let maxSlots = 8

    /// The factory composites — the shipped taraf/tone behaviors plus
    /// Expression (so a resting device still plays with dynamics), all as
    /// editable member sets over registry parameters.
    public static func defaults() -> [CompositeParam] {
        [
            // Purity: TONE — the radiated jawari sum darkens, open
            // (16 kHz, all the contact sparkle) → 1.5 kHz, only the rows'
            // tonal ring left. RECRUITMENT — `bow_jt_sel` falls 0.5 → 0:
            // rest (purity 0) is the FITTED taraf, purity 1 narrows it to
            // the played note's harmonic kin at held loudness. The lo stays
            // at the fitted midpoint deliberately: the axis' upper half is
            // the note-independent FLAT profile, and resting there would
            // decouple the wash from the playing.
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
