import Foundation
import SarangiKit
import TarabdaarCore
import SwiftUI

/// Mac-side bridge for the ported sarangi model (`SarangiKit`). Owns the
/// editable `InstrumentState` — raga + tonic and the sympathetic-string
/// table — and pushes every change to the audio engine as a debounced
/// structural rebuild of the String voice's in-kernel taraf.
///
/// It used to also carry the coupled network's model parameters and FX rack
/// with a live-scalar/structural split; that whole surface drove no-op hooks
/// once the network was deleted, and went with it (2026-07-24).
///
/// The tarab ALWAYS follows the Pitch Pad scale (strings are degree-defined
/// — the follow toggle was removed 2026-07-25); the row layout regenerates
/// when the scale's degree count changes or on the Strings tab's explicit
/// "Regenerate". The whole document is auto-saved to UserDefaults and can
/// be exported/imported as a `.sarangi` JSON file.
final class SarangiStore: ObservableObject {
    @Published var state: InstrumentState { didSet { scheduleSave() } }


    private let audio: AudioEngine
    private var rebuildWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?

    /// Bumped if `InstrumentState`'s schema OR the upstream model recipe changes;
    /// a stale persisted copy is then ignored and the default preset loads
    /// instead. v2–v6: pre-v57 eras (recipe re-vendors, StringSpec `group` +
    /// `autoSyncToScale`, the 4-stage FX rack, the web bank + `sarangi_eb`/`_d`
    /// presets, the coupled-topology era) — see git history. v7: the v57-only
    /// simplification (22-param passive coupled network, single `sarangi_pilu`
    /// preset). v8: the String era — the default state is the **Sarangi Live
    /// default**. NOT bumped for the 2026-07-24 field removals (`StringSpec`'s
    /// `bright`/`raga`; `InstrumentState`'s `fir`, `fx`, `params` and
    /// `eqBands`) nor for the 2026-07-25 model rewrites (weight→gain fold,
    /// chromatic/choir removal, the scale-defined degree+octave pitch model):
    /// a bump would discard the user's tarab edits, so each rewrite MIGRATED
    /// the stored blob in place instead, and retired keys decode away
    /// harmlessly.
    private static let persistKey = "tarabdaar.sarangiState.v8"

    init(audio: AudioEngine) {
        self.audio = audio
        if let data = UserDefaults.standard.data(forKey: Self.persistKey),
           let s = try? JSONDecoder().decode(InstrumentState.self, from: data) {
            self.state = s
        } else {
            // Fresh install = the default bank generated from the Pilu
            // scale. Auto-sync starts ON: on launch AppController pushes the
            // Pitch Pad scale over this seed, regenerating the layout to
            // match. (The fitted-table era's auto-sync-OFF default died
            // with the fitted table itself, 2026-07-25.)
            self.state = InstrumentState.makeDefault()   // sarangi_pilu seed
        }
        rebuildNow()                          // build the initial engine
    }

    // MARK: - Sympathetic strings / tuning

    /// Apply an edit to one string. THE POOL INVARIANT (2026-07-26): the
    /// table stays pitch-sorted and duplicate pitches are impossible — an
    /// edit that would land this row on another row's pitch is REJECTED
    /// (the picker snaps back) rather than silently deleting either row.
    func mutateString(id: UUID, _ body: (inout StringSpec) -> Void) {
        guard let i = state.strings.firstIndex(where: { $0.id == id }) else { return }
        var edited = state.strings[i]
        body(&edited)
        let r = edited.ratio(in: state.scaleRatios)
        guard !state.strings.contains(where: {
            $0.id != id && $0.ratio(in: state.scaleRatios) == r
        }) else { return }
        state.strings[i] = edited
        state.normalizeStrings()              // re-sort into pitch order
        scheduleRebuild()
    }

    func stringBinding<V>(_ id: UUID, _ keyPath: WritableKeyPath<StringSpec, V>) -> Binding<V> {
        Binding(
            get: { self.state.strings.first { $0.id == id }?[keyPath: keyPath]
                    ?? self.state.strings[0][keyPath: keyPath] },
            set: { newValue in self.mutateString(id: id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Add a string at the FIRST FREE PITCH (base octave first, then up,
    /// then down — duplicates are impossible, so "add" can never mint a
    /// second row at an occupied pitch). No-op when every slot in the
    /// ±2-octave range is taken.
    func addString() {
        let taken = Set(state.strings.map { $0.ratio(in: state.scaleRatios) })
        for octave in [0, 1, 2, -1, -2] {
            for d in state.scaleRatios.indices {
                let spec = StringSpec(degree: d, octave: octave, gain: 0.5, t60: 2.0)
                if !taken.contains(spec.ratio(in: state.scaleRatios)) {
                    state.strings.append(spec)
                    state.normalizeStrings()
                    scheduleRebuild()
                    return
                }
            }
        }
    }

    func removeStrings(_ ids: Set<UUID>) {
        state.strings.removeAll { ids.contains($0.id) }
        scheduleRebuild()
    }

    /// Map a drone button to a sympathetic string (nil = unmapped, button
    /// inert). A mapping-only change — the jawari web is untouched, so no
    /// rebuild; the engine just retargets the button.
    func setDroneMapping(slot: Int, stringId: UUID?) {
        guard state.droneStringIds.indices.contains(slot) else { return }
        state.droneStringIds[slot] = stringId
        audio.setDroneMappedFreqs(state.droneStringFreqs)
    }

    /// Enable / disable every string at once (one rebuild).
    func setAllEnabled(_ enabled: Bool) {
        for i in state.strings.indices {
            state.strings[i].enabled = enabled
        }
        scheduleRebuild()
    }

    /// Edit the melody-follower string (gain / t60 / enabled) — a
    /// structural taraf change like any row edit.
    func followerBinding<V>(_ keyPath: WritableKeyPath<FollowerSpec, V>) -> Binding<V> {
        Binding(
            get: { self.state.follower[keyPath: keyPath] },
            set: { newValue in
                self.state.follower[keyPath: keyPath] = newValue
                self.scheduleRebuild()
            }
        )
    }

    // MARK: - Scale sync (the centralized scale feeds the tarab)

    /// Adopt the centralized scale (tonic Hz + degree ratios). The PITCHES
    /// always follow — strings are degree-defined, so this retunes the whole
    /// bank unconditionally. The row LAYOUT regenerates only when the
    /// scale's degree COUNT changed (existing rows would go stale-and-
    /// clamped) or under `force` (the Strings tab's "Regenerate" button);
    /// otherwise hand edits stand.
    func syncTarabToScale(tonicHz: Double, ratios: [Double], force: Bool = false) {
        if force || ratios.count != state.scaleRatios.count {
            state.regenerateFromScale(tonicHz: tonicHz, ratios: ratios)
        } else {
            state.updateScale(tonicHz: tonicHz, ratios: ratios)
        }
        rebuildNow()
    }

    // (The Manual-tuning actions — setRaga / regenerate / setTonic — went
    // with the Strings tab's Manual tuning section, 2026-07-25. The bank
    // tunes via scale auto-sync, hand edits, or preset loads.)

    // MARK: - Presets / persistence

    /// Load the default preset's bank (the generated Pilu-scale seed).
    /// The next scale push re-aligns it to the Pitch Pad scale.
    func loadPreset(_ preset: Preset) {
        state = Presets.state(preset)
        rebuildNow()
    }

    /// Load the preset **as the Sarangi Live default**: the generated bank,
    /// immediately re-aligned to the centralized scale by the next push.
    /// (The caller also clears the String physics overrides — the artifact
    /// is the default there.)
    func loadSarangiLiveDefault(_ preset: Preset = .sarangiPilu) {
        state = Presets.state(preset)
        rebuildNow()
    }

    /// Adopt a whole instrument document (preset load). Auto-sync stays
    /// as the document specifies — a saved rig should come back exactly.
    func replaceState(_ s: InstrumentState) {
        state = s
        rebuildNow()
    }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url)
    }

    func load(from url: URL) throws {
        state = try JSONDecoder().decode(InstrumentState.self, from: Data(contentsOf: url))
        rebuildNow()
    }

    // MARK: - Rebuild / save scheduling

    /// Debounced structural rebuild (coalesces rapid slider drags / string edits).
    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildNow() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Immediate structural rebuild (raga/tonic/preset switches).
    private func rebuildNow() {
        rebuildWork?.cancel()
        audio.rebuildSarangi(strings: state.resolvedStrings, tonic: state.tonicHz,
                             droneFreqs: state.droneStringFreqs,
                             follower: state.resolvedFollower)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.state) else { return }
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
