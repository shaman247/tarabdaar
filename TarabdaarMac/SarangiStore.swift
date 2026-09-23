import Foundation
import SarangiKit
import TarabdaarCore
import SwiftUI

/// Mac-side owner of the editable `InstrumentState` (tonic, scale mirror,
/// sympathetic-string table). Every change reaches the audio engine as a
/// debounced structural rebuild of the String voice's in-kernel taraf.
///
/// The tarab always follows the Pitch Pad scale (strings are degree-defined);
/// the raga row layout regenerates when the scale's degree count changes or
/// on the Strings tab's "Regenerate". The document auto-saves to UserDefaults.
final class SarangiStore: ObservableObject {
    @Published var state: InstrumentState { didSet { scheduleSave() } }


    private let audio: AudioEngine
    private let rebuildDebounce = Debouncer(delay: 0.05)
    private let saveDebounce = Debouncer(delay: 0.4)

    /// A bump discards the user's tarab edits (a stale copy is ignored and the
    /// default loads), so schema changes migrate the stored blob in place on
    /// decode instead and retired keys decode away ignored.
    private static let persistKey = "tarabdaar.sarangiState.v8"

    init(audio: AudioEngine) {
        self.audio = audio
        if let s = DefaultsStore.load(InstrumentState.self, key: Self.persistKey) {
            self.state = s
        } else {
            // Fresh install: the Pilu-scale seed. On launch AppController
            // pushes the Pitch Pad scale over it.
            self.state = InstrumentState.makeDefault()   // sarangi_pilu seed
        }
        rebuildNow()                          // build the initial engine
    }

    // MARK: - Sympathetic strings / tuning

    /// Apply an edit to one string. The pool invariant: the table stays
    /// pitch-sorted and an edit that would land this row on another row's
    /// pitch on the same bridge is rejected (the picker snaps back).
    func mutateString(id: UUID, _ body: (inout StringSpec) -> Void) {
        guard let i = state.strings.firstIndex(where: { $0.id == id }) else { return }
        var edited = state.strings[i]
        body(&edited)
        let r = edited.ratio(in: state.scaleRatios)
        guard !state.strings.contains(where: {
            $0.id != id && $0.set == edited.set
                && $0.ratio(in: state.scaleRatios) == r
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

    /// Add a string at the bridge's first free pitch (base octave, then up,
    /// then down); no-op when the ±2-octave range is full.
    func addString(to bridge: TarabSet = .raga) {
        let taken = Set(state.strings(in: bridge).map { $0.ratio(in: state.scaleRatios) })
        let degrees = bridge == .chromatic ? Array(0..<12) : Array(state.scaleRatios.indices)
        for octave in [0, 1, 2, -1, -2] {
            for d in degrees {
                let spec = StringSpec(degree: d, octave: octave, gain: 0.5, t60: 2.0,
                                      set: bridge)
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

    /// Map a drone button to a string (nil = inert). No rebuild — the engine
    /// just retargets the button.
    func setDroneMapping(slot: Int, stringId: UUID?) {
        guard state.droneStringIds.indices.contains(slot) else { return }
        state.droneStringIds[slot] = stringId
        audio.setDroneMappedFreqs(state.droneStringFreqs, chromatic: state.droneStringChromatic)
    }

    /// Edit the strum set (state-only — resolved at press time, no rebuild).
    /// Duplicate members are rejected.
    func setStrumMapping(index: Int, stringId: UUID) {
        guard state.strumStringIds.indices.contains(index),
              !state.strumStringIds.contains(stringId) else { return }
        state.strumStringIds[index] = stringId
    }

    func addStrumString(_ stringId: UUID) {
        guard !state.strumStringIds.contains(stringId) else { return }
        state.strumStringIds.append(stringId)
    }

    func removeStrumString(at index: Int) {
        guard state.strumStringIds.indices.contains(index) else { return }
        state.strumStringIds.remove(at: index)
    }

    /// Enable / disable every string of one bridge at once (one rebuild);
    /// nil = both bridges.
    func setAllEnabled(_ enabled: Bool, in bridge: TarabSet? = nil) {
        for i in state.strings.indices
        where bridge == nil || state.strings[i].set == bridge {
            state.strings[i].enabled = enabled
        }
        scheduleRebuild()
    }

    /// Reset the CHROMATIC set to its combined legacy layout (the
    /// Strings tab's "Reset chromatic set"); the raga set stands.
    func regenerateChromatic() {
        state.regenerateChromatic()
        rebuildNow()
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

    /// Adopt the centralized scale. Pitches always follow; the raga LAYOUT
    /// regenerates only when the degree count changed or under `force`.
    func syncTarabToScale(tonicHz: Double, ratios: [Double], force: Bool = false) {
        if force || ratios.count != state.scaleRatios.count {
            state.regenerateFromScale(tonicHz: tonicHz, ratios: ratios)
        } else {
            state.updateScale(tonicHz: tonicHz, ratios: ratios)
        }
        rebuildNow()
    }

    // MARK: - Presets / persistence

    /// Load the default preset's bank (the generated Pilu-scale seed).
    /// The next scale push re-aligns it to the Pitch Pad scale.
    func loadPreset(_ preset: Preset) {
        state = Presets.state(preset)
        rebuildNow()
    }

    /// Load the preset as the Sarangi Live default (the caller also clears
    /// the String physics overrides).
    func loadSarangiLiveDefault(_ preset: Preset = .sarangiPilu) {
        state = Presets.state(preset)
        rebuildNow()
    }

    /// Adopt a whole instrument document (preset load).
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
        rebuildDebounce.schedule { [weak self] in self?.rebuildNow() }
    }

    /// Immediate structural rebuild (scale/preset switches).
    private func rebuildNow() {
        rebuildDebounce.cancel()
        audio.rebuildSarangi(strings: state.resolvedStrings, tonic: state.tonicHz,
                             droneFreqs: state.droneStringFreqs,
                             droneChromatic: state.droneStringChromatic,
                             follower: state.resolvedFollower)
    }

    private func scheduleSave() {
        saveDebounce.schedule { [weak self] in
            guard let self else { return }
            DefaultsStore.save(self.state, key: Self.persistKey)
        }
    }
}
