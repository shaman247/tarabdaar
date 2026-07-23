import Foundation
import SarangiKit
import StarpadCore
import SwiftUI

/// Mac-side editor state for the **String instrument's** parameter surface —
/// the `bowed_string.json` physics scalars (body / bow&string / playing
/// ranges / jawari taraf / taraf / articulation / radiation), disjoint from
/// the coupled-network `SarangiParams` document that `SarangiStore` edits.
///
/// The bundled artifact IS the Sarangi Live default. Starpad cannot (and
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
    private var pushWork: DispatchWorkItem?

    private static let persistKey = "starpad.stringOverrides.v1"

    init(audio: AudioEngine) {
        self.audio = audio
        if let bp = Presets.bowedStringParams() { artifact = bp.num }
        if let data = UserDefaults.standard.data(forKey: Self.persistKey),
           let ov = try? JSONDecoder().decode([String: Double].self, from: data) {
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
        values[key] = value
        // An override that lands back ON the artifact value is dropped, so
        // `dirty` means "differs from the Sarangi Live default".
        if let base = artifact[key], base == value {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = value
        }
        dirty = !overrides.isEmpty
        persist()
        schedulePush()
    }

    /// Reset ONE key to the Sarangi Live default (double-click a slider row).
    func reset(_ key: String) {
        overrides.removeValue(forKey: key)
        values = artifact.merging(overrides) { _, o in o }
        dirty = !overrides.isEmpty
        persist()
        schedulePush()
    }

    /// Reset the whole surface to the Sarangi Live default (the artifact).
    func resetToDefault() {
        overrides.removeAll()
        values = artifact
        dirty = false
        persist()
        pushNow()
    }

    /// Audition hook (`string.<key>`): same path as the sliders, so scripted
    /// sweeps show in the UI and persist like hand edits.
    func setAuditionParam(_ key: String, _ value: Double) {
        set(key, value)
    }

    // MARK: - Engine push / persistence

    /// Debounced push (coalesces slider drags — each push rebuilds the
    /// String engine off-main; the generation check discards stale builds).
    private func schedulePush() {
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushNow() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func pushNow() {
        pushWork?.cancel()
        audio.setStringVoiceOverrides(overrides)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }
}
