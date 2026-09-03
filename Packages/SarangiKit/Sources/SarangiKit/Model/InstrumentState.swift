import Foundation

/// The persisted instrument document: the tonic, the scale it is resolved
/// against, and the editable sympathetic strings. Saved/loaded inside a
/// `.tarabdaar` preset.
///
/// SCALE-CENTRALIZED (2026-07-25): `scaleRatios` mirrors the ONE Pitch Pad
/// scale (degrees from the tonic in [1, 2), sorted ascending) and `tonicHz`
/// mirrors its tonic — `AppController` pushes both on every scale/tonic
/// change, unconditionally. Strings reference the scale by degree+octave,
/// so a scale or tonic move ALWAYS retunes the whole bank — there is no
/// opt-out (the "Follow the Pitch Pad scale" toggle was removed the same
/// day). The ROW LAYOUT (which degrees get strings, emphasis, octave
/// repeats) regenerates when the scale's degree COUNT changes — existing
/// rows would go stale-and-clamped — or on the Strings tab's explicit
/// "Regenerate" action; otherwise hand edits (gains, t60s, added/removed
/// rows) stand. The raga fields (`ragaId`/`ragaName`/`intervals`) were
/// dropped with the free-ratio model — the raga table survives in
/// `RagaTuning` purely to seed the default preset.
///
/// TWO SETS, TWO BRIDGES (2026-09-02, schema 4): `strings` holds BOTH the
/// RAGA set (scale-degree strings, the `bow_jt_*` bridge) and the
/// CHROMATIC set (semitone strings on the fixed JI grid, the `bow_jtc_*`
/// bridge) — tagged per row by `StringSpec.set`. The pool invariant is
/// PER SET (one string per pitch on each bridge; Sa may sit on both, as
/// on the instrument), the raga set alone follows scale edits and
/// regenerations (the chromatic set is tuned once; the tonic moves both),
/// and a schema-3 document (all raga strings) is migrated on decode by
/// seeding the default chromatic set beside its hand-tuned raga rows —
/// the persist key is NOT bumped.
public struct InstrumentState: Codable, Sendable {
    public var tonicHz: Double
    /// The centralized scale's degree ratios (0 = Sa = 1.0), the target of
    /// every string's `degree` index.
    public var scaleRatios: [Double]
    public var strings: [StringSpec]
    /// Which sympathetic string each of the 3 Fret Pad drone buttons plucks
    /// (by `StringSpec.id`; nil = unmapped, button inert). The strings are
    /// ordinary tarab rows — a mapped string sounds with its own pitch/gain/
    /// t60, and if the jawari selection doesn't pick it up the button is
    /// inert like the row itself. Regenerating the bank re-runs the
    /// auto-mapping (fresh ids); manual mappings otherwise stick.
    public var droneStringIds: [UUID?]
    /// The controller's STRUM set (2026-08-27): the sympathetic strings the
    /// Joy-Con L button sweeps low→high (by `StringSpec.id`). Members are
    /// ordinary tarab rows — string references are scale degrees under the
    /// pool invariant, so a configured chord is raga-dependent by
    /// construction (it re-voices when the scale/tonic moves). Defaults to
    /// the two low anchors (low Sa · low Pa); regenerating the bank re-runs
    /// the auto-mapping (fresh ids), manual sets otherwise stick.
    public var strumStringIds: [UUID]
    /// The melody-follower string (2026-07-25): pitch = the highest note
    /// being played (live, kernel-side); gain/t60/enabled are ordinary
    /// Strings-tab knobs. Default disabled (byte-null when off).
    public var follower: FollowerSpec
    public var schemaVersion: Int

    // RETIRED FIELDS: `fir`/`fx`/`params`/`eqBands` (the coupled network,
    // 2026-07-24), `ragaId`/`ragaName`/`intervals` (the free-ratio era,
    // 2026-07-25) and `manualEdits`/`autoSyncToScale` (the follow-the-scale
    // toggle, 2026-07-25 — following is unconditional now). Documents that
    // still carry the keys decode fine — they are ignored.

    /// The document schema this build writes. 4 (2026-09-02) = the
    /// two-set taraf; a lower version on decode seeds the chromatic set.
    public static let currentSchemaVersion = 4

    /// The strings of one bridge, in pool order.
    public func strings(in set: TarabSet) -> [StringSpec] {
        strings.filter { $0.set == set }
    }

    /// The number of drone buttons/slots. Mirrors TarabdaarCore's
    /// `FretArrangement.droneCount` (SarangiKit sits below TarabdaarCore, so
    /// it can't read it) — `DroneStringTests` pins the two equal.
    public static let droneSlotCount = 3

    /// Auto-map the drone buttons to sympathetic strings: per slot, the
    /// HIGHEST-GAIN enabled string within ±100 ¢ of its target ratio
    /// (low Sa · low Pa · Sa), nearest-pitch as the tie-break; nil when no
    /// string is close. Gain-first matters: the emphasized Sa/Pa rows are
    /// the drone-worthy ones, and a quiet row can sit below the jawari
    /// selection's `bow_jt_gmin` and never sound. Used for fresh documents
    /// and whenever the bank regenerates (the old ids die with the rows).
    /// RAGA strings only: the anchors live on the raga bridges (a chromatic
    /// Sa sits at the same pitch but is the haze set, not the drone).
    public static func autoDroneMapping(strings: [StringSpec],
                                        scaleRatios: [Double]) -> [UUID?] {
        [0.5, 0.75, 1.0].map { target in
            strings.filter { $0.enabled && $0.set == .raga }
                .filter { abs(1200.0 * log2($0.ratio(in: scaleRatios) / target)) <= 100.0 }
                .min { a, b in
                    if a.gain != b.gain { return a.gain > b.gain }
                    return abs(log2(a.ratio(in: scaleRatios) / target))
                         < abs(log2(b.ratio(in: scaleRatios) / target))
                }?.id
        }
    }

    /// Default strum set: the low Sa and low Pa anchors (targets 1/2 and
    /// 3/4 of the tonic, the autoDroneMapping selection law — gain-first,
    /// nearest-pitch tie-break, ±100 ¢; a missing anchor just drops out).
    public static func autoStrumMapping(strings: [StringSpec],
                                        scaleRatios: [Double]) -> [UUID] {
        [0.5, 0.75].compactMap { target in
            strings.filter { $0.enabled && $0.set == .raga }
                .filter { abs(1200.0 * log2($0.ratio(in: scaleRatios) / target)) <= 100.0 }
                .min { a, b in
                    if a.gain != b.gain { return a.gain > b.gain }
                    return abs(log2(a.ratio(in: scaleRatios) / target))
                         < abs(log2(b.ratio(in: scaleRatios) / target))
                }?.id
        }
    }

    /// THE POOL INVARIANT (2026-07-26): `strings` is always SORTED by pitch
    /// (lowest resolved frequency first) and holds at most ONE string per
    /// pitch — PER SET since 2026-09-02: the raga set comes first, then the
    /// chromatic set, each pitch-sorted, and a pitch may appear once on
    /// EACH bridge (Sa on both is the instrument's own layout). Duplicates
    /// within a set fold into the strongest twin
    /// (higher gain, then longer t60; `preferring` overrides — the edited
    /// row wins), and drone mappings that pointed at a dropped twin are
    /// re-pointed at its survivor via the returned map. Every entry path
    /// runs it: both inits (persisted documents with the historic Sa/Pa
    /// doubling rows migrate in place — the persist key is NOT bumped),
    /// `updateScale`/`regenerateFromScale`, and the store's edit paths.
    @discardableResult
    public mutating func normalizeStrings(preferring preferred: UUID? = nil)
        -> [UUID: UUID] {
        struct Key: Hashable { let set: TarabSet; let ratio: Double }
        var winnerAt: [Key: Int] = [:]        // (set, resolved ratio) → index
        var kept: [StringSpec] = []
        var remap: [UUID: UUID] = [:]
        for s in strings {
            let key = Key(set: s.set, ratio: s.ratio(in: scaleRatios))
            guard let wi = winnerAt[key] else {
                winnerAt[key] = kept.count
                kept.append(s)
                continue
            }
            let w = kept[wi]
            let sWins = s.id == preferred
                || (w.id != preferred
                    && (s.gain, s.t60) > (w.gain, w.t60))
            if sWins { remap[w.id] = s.id; kept[wi] = s }
            else { remap[s.id] = w.id }
        }
        // resolve remap chains (three-way folds point at a dropped id)
        for (k, v) in remap {
            var t = v
            while let n = remap[t] { t = n }
            remap[k] = t
        }
        kept.sort { a, b in
            if a.set != b.set { return a.set == .raga }   // raga bridge first
            let ra = a.ratio(in: scaleRatios), rb = b.ratio(in: scaleRatios)
            if ra != rb { return ra < rb }
            return (a.octave, a.degree) < (b.octave, b.degree)
        }
        strings = kept
        if !remap.isEmpty {
            droneStringIds = droneStringIds.map { $0.map { remap[$0] ?? $0 } }
            // strum members follow surviving twins too; a fold that lands
            // two members on one string keeps the first (no double-pluck)
            var seen = Set<UUID>()
            strumStringIds = strumStringIds.map { remap[$0] ?? $0 }
                .filter { seen.insert($0).inserted }
        }
        return remap
    }

    public init(tonicHz: Double, scaleRatios: [Double], strings: [StringSpec],
                droneStringIds: [UUID?]? = nil,
                strumStringIds: [UUID]? = nil,
                follower: FollowerSpec = FollowerSpec(),
                schemaVersion: Int = InstrumentState.currentSchemaVersion) {
        self.tonicHz = tonicHz; self.scaleRatios = scaleRatios
        self.strings = strings
        self.droneStringIds = droneStringIds ?? []
        self.strumStringIds = strumStringIds ?? []
        self.follower = follower
        self.schemaVersion = schemaVersion
        normalizeStrings()                    // sort + dedup (remaps drones)
        if droneStringIds == nil {
            self.droneStringIds = Self.autoDroneMapping(
                strings: self.strings, scaleRatios: scaleRatios)
        }
        if strumStringIds == nil {
            self.strumStringIds = Self.autoStrumMapping(
                strings: self.strings, scaleRatios: scaleRatios)
        }
    }

    // Tolerant decode: `droneStringIds` and `follower` default for older
    // documents; retired keys decode away ignored. `scaleRatios` is
    // required — pre-degree documents were migrated in place.
    private enum CodingKeys: String, CodingKey {
        case tonicHz, scaleRatios, strings, droneStringIds, strumStringIds,
             follower, schemaVersion
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tonicHz = try c.decode(Double.self, forKey: .tonicHz)
        scaleRatios = try c.decode([Double].self, forKey: .scaleRatios)
        strings = try c.decode([StringSpec].self, forKey: .strings)
        var mapping = (try? c.decode([UUID?].self, forKey: .droneStringIds))
            ?? Self.autoDroneMapping(strings: strings, scaleRatios: scaleRatios)
        if mapping.count != Self.droneSlotCount {
            mapping = Self.autoDroneMapping(strings: strings, scaleRatios: scaleRatios)
        }
        droneStringIds = mapping
        strumStringIds = (try? c.decode([UUID].self, forKey: .strumStringIds))
            ?? Self.autoStrumMapping(strings: strings, scaleRatios: scaleRatios)
        follower = (try? c.decode(FollowerSpec.self, forKey: .follower))
            ?? FollowerSpec()
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 3
        // THE TWO-SET MIGRATION (2026-09-02): a pre-split document is all
        // raga strings — seed the default chromatic set beside them (the
        // hand-tuned raga rows stand untouched). Only ever runs once: the
        // re-saved document carries schema 4, and a user who deletes the
        // whole chromatic set afterwards keeps it deleted.
        if schemaVersion < Self.currentSchemaVersion {
            if !strings.contains(where: { $0.set == .chromatic }) {
                strings += RagaTuning.buildChromaticSpecs()
            }
            schemaVersion = Self.currentSchemaVersion
        }
        // Pool invariant: sort + fold duplicate pitches (documents from the
        // doubling era migrate here; a drone mapped to a dropped twin is
        // re-pointed at its survivor by the remap inside).
        normalizeStrings()
        // A mapped id must reference an existing string (a deleted row's
        // mapping dies with it rather than dangling).
        let ids = Set(strings.map(\.id))
        droneStringIds = droneStringIds.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
        strumStringIds = strumStringIds.filter { ids.contains($0) }
    }

    /// The melody follower as the engine consumes it — nil when disabled
    /// (no jt row is built; byte-null).
    public var resolvedFollower: (gain: Double, t60: Double)? {
        follower.enabled ? (follower.gain, follower.t60) : nil
    }

    /// Strings as the taraf builder consumes them (it filters `enabled`
    /// itself). Absolute Hz is minted HERE: degree ratio × octave × tonic.
    public var resolvedStrings: [ResolvedString] {
        strings.map { $0.resolved(tonic: tonicHz, scaleRatios: scaleRatios) }
    }

    /// Per drone slot, the mapped string's resolved Hz — nil when unmapped,
    /// the string is gone, or it is disabled (the button is then inert).
    /// The Hz is the row's nominal table frequency, so the engine can find
    /// the jt row by identity (`BowEngine.droneRow(forExactHz:)`).
    public var droneStringFreqs: [Double?] {
        droneStringIds.map { id in
            id.flatMap { id in strings.first { $0.id == id } }
                .flatMap { $0.enabled
                    ? $0.resolved(tonic: tonicHz, scaleRatios: scaleRatios).freq
                    : nil }
        }
    }

    /// The strum set's resolved frequency RATIOS above the tonic,
    /// pitch-sorted low→high (the sweep order) — ratio space because the
    /// strum plays STACCATO NOTES IN THE MAIN VOICE through the pitch-pad
    /// touch path (`PitchPadEngine.noteOn(ratio:)`), not the drone
    /// machinery. A deleted or disabled member drops out (inert).
    public var strumStringRatios: [Double] {
        strumStringIds.compactMap { id in
            strings.first { $0.id == id }
                .flatMap { $0.enabled
                    ? $0.ratio(in: scaleRatios)   // octave already folded in
                    : nil }
        }.sorted()
    }

    /// The ONE instrument: the default bank generated from the Pilu scale.
    /// (Purely a seed — on launch the Pitch Pad scale is pushed over it.)
    public static func makeDefault() -> InstrumentState { Presets.state(.sarangiPilu) }

    /// Adopt a new scale WITHOUT touching the row layout: pitches follow
    /// (degree-defined strings resolve against the new ratios/tonic), the
    /// hand-tuned rows stand. The unconditional half of the scale push.
    public mutating func updateScale(tonicHz: Double, ratios: [Double]) {
        guard tonicHz > 20, tonicHz < 4000, !ratios.isEmpty else { return }
        self.tonicHz = tonicHz
        self.scaleRatios = ratios
        // Re-established under the new ratios: the pitch ORDER of degrees
        // can move with a scale edit, and two degrees edited onto the same
        // ratio would otherwise leave duplicate-pitch rows.
        normalizeStrings()
    }

    /// Rebuild the RAGA set's LAYOUT from the scale as well: fresh
    /// degree-indexed rows (scale degrees + doublings + octave repeats),
    /// discarding any hand edits to that set. The old rows' ids die with
    /// them, so the drone mapping re-runs too. Used when the scale's
    /// degree count changes and by the Strings tab's explicit "Regenerate"
    /// action. The CHROMATIC set is untouched — its layout does not
    /// depend on the scale (`regenerateChromatic` resets it).
    public mutating func regenerateFromScale(tonicHz: Double, ratios: [Double]) {
        guard tonicHz > 20, tonicHz < 4000, !ratios.isEmpty else { return }
        self.tonicHz = tonicHz
        self.scaleRatios = ratios
        strings = RagaTuning.buildSpecs(scaleRatios: ratios)
            + strings(in: .chromatic)
        normalizeStrings()
        droneStringIds = Self.autoDroneMapping(strings: strings, scaleRatios: ratios)
        strumStringIds = Self.autoStrumMapping(strings: strings, scaleRatios: ratios)
    }

    /// Reset the CHROMATIC set to its default layout (the 15-semitone
    /// row), discarding hand edits to that set; the raga set, the drone
    /// mapping and the strum set stand (they never reference chromatic
    /// rows by default). A chromatic row that WAS mapped dies with its id
    /// — the mapping is pruned like any deleted row's.
    public mutating func regenerateChromatic() {
        strings = strings(in: .raga) + RagaTuning.buildChromaticSpecs()
        normalizeStrings()
        let ids = Set(strings.map(\.id))
        droneStringIds = droneStringIds.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
        strumStringIds = strumStringIds.filter { ids.contains($0) }
    }
}
