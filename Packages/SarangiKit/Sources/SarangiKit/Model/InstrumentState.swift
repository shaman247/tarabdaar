import Foundation

/// The persisted instrument document: the tonic, the scale it is resolved
/// against, and the editable sympathetic strings. Saved inside a
/// `.tarabdaar` preset.
///
/// `scaleRatios`/`tonicHz` mirror the one Pitch Pad scale (pushed by
/// `AppController` on every change); strings reference it by degree+octave,
/// so a scale or tonic move always retunes the bank. The raga row LAYOUT
/// regenerates when the degree count changes or on "Regenerate".
///
/// `strings` holds the physical raga bank and the legacy chromatic bank,
/// tagged by `StringSpec.set`, with one string per pitch per bridge.
/// Schema 6 extends the former five-string factory raga layout without
/// replacing existing identities, levels or performance mappings.
public struct InstrumentState: Codable, Sendable {
    public var tonicHz: Double
    /// The centralized scale's degree ratios (0 = Sa = 1.0), the target of
    /// every string's `degree` index.
    public var scaleRatios: [Double]
    public var strings: [StringSpec]
    /// Which sympathetic string each of the 3 Fret Pad drone buttons plucks
    /// (by `StringSpec.id`; nil = unmapped, button inert). Regenerating the
    /// bank re-runs the auto-mapping (fresh ids); manual mappings stick.
    public var droneStringIds: [UUID?]
    /// The Joy-Con L strum set (by `StringSpec.id`) — scale degrees, so the
    /// chord re-voices with the scale. Defaults to low Sa · low Pa.
    public var strumStringIds: [UUID]
    /// The melody-follower string: pitch = the highest note being played
    /// (kernel-side). Default disabled (byte-null when off).
    public var follower: FollowerSpec
    public var schemaVersion: Int

    // Retired keys older documents may carry (`fir`, `fx`, `params`,
    // `eqBands`, `ragaId`, `ragaName`, `intervals`, `manualEdits`,
    // `autoSyncToScale`) decode away ignored.

    /// The document schema this build writes; a lower version on decode
    /// migrates the bridge layout.
    public static let currentSchemaVersion = 6

    /// The strings of one bridge, in pool order.
    public func strings(in set: TarabSet) -> [StringSpec] {
        strings.filter { $0.set == set }
    }

    /// Mirrors TarabdaarCore's `FretArrangement.droneCount` (not visible
    /// from here); `DroneStringTests` pins the two equal.
    public static let droneSlotCount = 3

    /// Auto-map the drone buttons: the highest-gain enabled string on either bridge within
    /// ±100 ¢ of each target (low Sa · low Pa · Sa), nearest as tie-break.
    /// Gain-first: a quiet row can sit below `bow_jt_gmin` and never sound.
    public static func autoDroneMapping(strings: [StringSpec],
                                        scaleRatios: [Double]) -> [UUID?] {
        [0.5, 0.75, 1.0].map { target in
            strings.filter { $0.enabled }
                .filter { abs(1200.0 * log2($0.ratio(in: scaleRatios) / target)) <= 100.0 }
                .min { a, b in
                    if a.gain != b.gain { return a.gain > b.gain }
                    return abs(log2(a.ratio(in: scaleRatios) / target))
                         < abs(log2(b.ratio(in: scaleRatios) / target))
                }?.id
        }
    }

    /// Default strum set: the low Sa and low Pa anchors under the
    /// `autoDroneMapping` selection law; a missing anchor drops out.
    public static func autoStrumMapping(strings: [StringSpec],
                                        scaleRatios: [Double]) -> [UUID] {
        [0.5, 0.75].compactMap { target in
            strings.filter { $0.enabled }
                .filter { abs(1200.0 * log2($0.ratio(in: scaleRatios) / target)) <= 100.0 }
                .min { a, b in
                    if a.gain != b.gain { return a.gain > b.gain }
                    return abs(log2(a.ratio(in: scaleRatios) / target))
                         < abs(log2(b.ratio(in: scaleRatios) / target))
                }?.id
        }
    }

    /// The pool invariant: raga set then chromatic set, each pitch-sorted with
    /// one string per pitch. Duplicates fold into the strongest twin (higher
    /// gain, then longer t60; `preferring` wins); drone/strum ids follow via
    /// the returned map. Every entry path runs it.
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

    // Tolerant decode: `droneStringIds`, `strumStringIds`, `follower` and
    // `schemaVersion` default when absent; `scaleRatios` is required.
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
        // Schema < 4: an all-raga document — seed the default chromatic set
        // before applying the schema-5 bank migration.
        if schemaVersion < 4 && !strings.contains(where: { $0.set == .chromatic }) {
            strings += RagaTuning.buildChromaticSpecs()
        }
        if schemaVersion < 5 {
            // Keep identities, degree references, levels and mappings. The
            // usual one-pitch-per-bridge fold remaps any merged twins below.
            for i in strings.indices { strings[i].set = .chromatic }
            strings += RagaTuning.buildSpecs(scaleRatios: scaleRatios)
            schemaVersion = Self.currentSchemaVersion
        }
        if schemaVersion == 5 {
            let raga = strings(in: .raga)
            let oldRatios = [1.0, 5.0/4, 4.0/3, 5.0/3].map { target in
                scaleRatios.min { abs(log2($0/target)) < abs(log2($1/target)) } ?? target
            } + [2.0]
            let existing = Set(raga.map { $0.ratio(in: scaleRatios) })
            if !scaleRatios.isEmpty && raga.allSatisfy(\.followsScale)
                && existing == Set(oldRatios) {
                strings += RagaTuning.buildSpecs(scaleRatios: scaleRatios)
                    .filter { !existing.contains($0.ratio(in: scaleRatios)) }
            }
            schemaVersion = Self.currentSchemaVersion
        }
        // Pool invariant: sort + fold duplicate pitches (mappings follow).
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

    /// Per drone slot, the mapped string's nominal Hz (nil = unmapped, gone
    /// or disabled → inert); the engine finds the jt row by exact Hz.
    public var droneStringFreqs: [Double?] {
        droneStringIds.map { id in
            id.flatMap { id in strings.first { $0.id == id } }
                .flatMap { $0.enabled
                    ? $0.resolved(tonic: tonicHz, scaleRatios: scaleRatios).freq
                    : nil }
        }
    }

    /// Bank identity accompanies nominal Hz so equal pitches on different
    /// bridges remain distinct drone targets.
    public var droneStringChromatic: [Bool?] {
        droneStringIds.map { id in
            id.flatMap { id in strings.first { $0.id == id } }
                .flatMap { $0.enabled ? $0.set == .chromatic : nil }
        }
    }

    /// The strum set's ratios above the tonic, pitch-sorted — the strum plays
    /// main-voice notes through the touch path. Disabled members drop out.
    public var strumStringRatios: [Double] {
        strumStringIds.compactMap { id in
            strings.first { $0.id == id }
                .flatMap { $0.enabled
                    ? $0.ratio(in: scaleRatios)   // octave already folded in
                    : nil }
        }.sorted()
    }

    /// The default bank, generated from the Pilu scale — a seed only; on
    /// launch the Pitch Pad scale is pushed over it.
    public static func makeDefault() -> InstrumentState { Presets.state(.sarangiPilu) }

    /// Adopt a new scale without touching the row layout: pitches follow,
    /// hand-tuned rows stand.
    public mutating func updateScale(tonicHz: Double, ratios: [Double]) {
        guard tonicHz > 20, tonicHz < 4000, !ratios.isEmpty else { return }
        self.tonicHz = tonicHz
        self.scaleRatios = ratios
        // Degree order can move with a scale edit, and two degrees edited
        // onto one ratio would otherwise leave duplicate-pitch rows.
        normalizeStrings()
    }

    /// Rebuild the raga set's layout from the scale, discarding hand edits
    /// to that set; the old ids die, so the drone and strum mappings re-run.
    /// The chromatic set is untouched (`regenerateChromatic` resets it).
    public mutating func regenerateFromScale(tonicHz: Double, ratios: [Double]) {
        guard tonicHz > 20, tonicHz < 4000, !ratios.isEmpty else { return }
        self.tonicHz = tonicHz
        self.scaleRatios = ratios
        strings = RagaTuning.buildSpecs(scaleRatios: ratios)
            + strings(in: .chromatic)
        normalizeStrings()
        let ids = Set(strings.map(\.id))
        let defaults = Self.autoDroneMapping(strings: strings, scaleRatios: ratios)
        droneStringIds = droneStringIds.enumerated().map { i, id in
            id.flatMap { ids.contains($0) ? $0 : nil } ?? defaults[i]
        }
        strumStringIds = strumStringIds.filter { ids.contains($0) }
        if strumStringIds.isEmpty {
            strumStringIds = Self.autoStrumMapping(strings: strings, scaleRatios: ratios)
        }
    }

    /// Reset the chromatic set to its combined legacy layout; the raga
    /// set stands. A mapped chromatic row dies with its id and the mapping
    /// is pruned.
    public mutating func regenerateChromatic() {
        strings = strings(in: .raga) + RagaTuning.buildCombinedChromaticSpecs(scaleRatios: scaleRatios)
        normalizeStrings()
        let ids = Set(strings.map(\.id))
        droneStringIds = droneStringIds.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
        strumStringIds = strumStringIds.filter { ids.contains($0) }
    }
}
