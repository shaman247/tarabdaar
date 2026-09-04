import Foundation
import SarangiKit
import TarabdaarCore
import SwiftUI

/// Mac-side editor state for the **String instrument's** parameter surface —
/// the `bowed_string.json` physics scalars (body / bow&string / playing
/// ranges / jawari taraf / taraf / articulation / radiation); the tarab
/// bank itself is `SarangiStore`'s document.
///
/// The bundled artifact IS the Sarangi Live default. Tarabdaar cannot (and
/// should not) rewrite the bundle, so edits live as a persisted **override
/// dict** applied over the artifact at every String-engine build
/// (`AudioEngine.stringVoiceOverrides` → `StringVoiceSource.buildEngine`).
/// Every edit applies live via a debounced off-main engine rebuild (the
/// long-lived mapper keeps held notes across the swap). "Default" = clear
/// all overrides = exactly the Sarangi Live default instrument.
final class StringParamStore: ObservableObject {
    /// Effective scalar values (artifact + overrides merged) for the UI.
    @Published private(set) var values: [String: Double] = [:]
    /// Any overrides active (drives the "Default" button visibility).
    @Published private(set) var dirty = false

    private let audio: AudioEngine
    /// The artifact's own scalars (the Sarangi Live default values).
    private var artifact: [String: Double] = [:]
    private var overrides: [String: Double] = [:]
    private let pushDebounce = Debouncer(delay: 0.06)
    /// Keys touched since the last engine push — lets `pushNow` try the
    /// IN-PLACE path (no rebuild) when every one of them can be applied to
    /// the running engine.
    private var dirtyKeys: Set<String> = []

    private static let persistKey = "tarabdaar.stringOverrides.v1"

    init(audio: AudioEngine) {
        self.audio = audio
        if let bp = Presets.bowedStringParams() { artifact = bp.num }
        // Tarabdaar live seeds (stereo image + room width): part of the
        // BASELINE, not overrides — `buildEngine` seeds the same values
        // into the engine, so the editor's default/reset semantics (and
        // override-dropping on a value that lands back on the default)
        // stay in agreement. An artifact that ever ships a key wins.
        artifact.merge(StringVoiceSource.liveParamSeeds) { a, _ in a }
        if let ov = DefaultsStore.load([String: Double].self, key: Self.persistKey) {
            overrides = ov
        }
        values = artifact.merging(overrides) { _, o in o }
        dirty = !overrides.isEmpty
        // Seed the engine's override dict WITHOUT a rebuild — the String
        // voice isn't armed yet at construction; `applyBaseVoice` builds the
        // first engine with these already in place.
        audio.stringVoiceOverrides = overrides
    }

    /// The artifact default for a key (nil when the artifact lacks it — the
    /// UI row's authored default then stands in).
    func artifactValue(_ key: String) -> Double? { artifact[key] }

    func binding(for key: String, default def: Double) -> Binding<Double> {
        Binding(
            get: { self.values[key] ?? def },
            set: { self.set(key, $0) }
        )
    }

    func set(_ key: String, _ value: Double) {
        store(key, value)
        persist()
        schedulePush()
    }

    /// A settled batch (the bindings' rebuild funnel): every key lands,
    /// then ONE push right away — the funnel already waited.
    func setBatch(_ batch: [String: Double]) {
        guard !batch.isEmpty else { return }
        for (key, value) in batch { store(key, value) }
        persist()
        pushNow()
    }

    private func store(_ key: String, _ value: Double) {
        values[key] = value
        dirtyKeys.insert(key)
        // An override that lands back ON the artifact value is dropped, so
        // `dirty` means "differs from the Sarangi Live default".
        if let base = artifact[key], base == value {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = value
        }
        dirty = !overrides.isEmpty
    }

    /// Reset ONE key to the Sarangi Live default (double-click a slider row).
    func reset(_ key: String) {
        dirtyKeys.insert(key)
        overrides.removeValue(forKey: key)
        values = artifact.merging(overrides) { _, o in o }
        dirty = !overrides.isEmpty
        persist()
        schedulePush()
    }

    /// Reset the whole surface to the Sarangi Live default (the artifact).
    func resetToDefault() {
        dirtyKeys.removeAll()          // a full reset always rebuilds
        overrides.removeAll()
        values = artifact
        dirty = false
        persist()
        pushNow()
    }

    /// The override dict as saved into a `.tarabdaar` preset.
    var overridesSnapshot: [String: Double] { overrides }

    /// Replace every override at once (preset load). Rebuilds rather than
    /// pushing in place: a preset can move anything, including the keys
    /// that resize tables.
    func replaceOverrides(_ new: [String: Double]) {
        overrides = new.filter { $0.value != artifact[$0.key] }
        values = artifact.merging(overrides) { _, o in o }
        dirty = !overrides.isEmpty
        dirtyKeys.removeAll()          // force the rebuild path
        persist()
        pushNow()
    }

    // MARK: - Engine push / persistence

    /// Debounced push (coalesces slider drags — each push rebuilds the
    /// String engine off-main; the generation check discards stale builds).
    private func schedulePush() {
        pushDebounce.schedule { [weak self] in self?.pushNow() }
    }

    private func pushNow() {
        pushDebounce.cancel()
        // IN-PLACE FAST PATH : most parameters can be pushed
        // onto the RUNNING engine — no rebuild, no ~0.2 s latency, no
        // crossfade, and a sounding note/ring is untouched. Falls back to
        // the rebuild when any touched key needs fresh tables.
        let changed = dirtyKeys
        dirtyKeys.removeAll()
        if audio.applyStringVoiceOverridesInPlace(overrides, changed: changed) {
            return
        }
        audio.setStringVoiceOverrides(overrides)
    }

    private func persist() {
        DefaultsStore.save(overrides, key: Self.persistKey)
    }
}
