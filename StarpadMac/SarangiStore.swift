import Foundation
import SarangiKit
import StarpadCore
import SwiftUI

/// Mac-side bridge for the ported sarangi model (`SarangiKit`). Owns the editable
/// `InstrumentState` — raga + tonic, the sympathetic-string table, the 27 model
/// parameters, and the per-preset body FIR — and routes each change to the audio
/// engine as either a **live scalar** update (gains/mixes, no rebuild) or a
/// **debounced structural rebuild** (raga/tonic/strings/filter coefficients),
/// exactly the split the standalone model uses (`ParamDescriptor.structural`).
///
/// The model is fully independent of the played Pitch Pad scale: its strings and
/// tuning live here and nowhere else (the user tunes the tarab to the raga). The
/// whole document is auto-saved to UserDefaults and can be exported/imported as a
/// `.sarangi` JSON file.
final class SarangiStore: ObservableObject {
    @Published var state: InstrumentState { didSet { scheduleSave() } }

    private let audio: AudioEngine
    private var rebuildWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?

    /// Bumped if `InstrumentState`'s schema OR the upstream model recipe changes;
    /// a stale persisted copy is then ignored and the default preset loads
    /// instead. v2: re-vendored SarangiKit (B_lp, Butterworth jawari, recipe).
    /// v3: StringSpec gains a `group`; `autoSyncToScale` (tarab follows the Pitch
    /// Pad scale by default). v4: per-voice `FXRack` replaces the single block-F
    /// reverb (the default sound changes — bump to load a clean known-good rack).
    private static let persistKey = "starpad.sarangiState.v4"

    init(audio: AudioEngine) {
        self.audio = audio
        if let data = UserDefaults.standard.data(forKey: Self.persistKey),
           let s = try? JSONDecoder().decode(InstrumentState.self, from: data) {
            self.state = s
        } else {
            self.state = .makeDefault()       // pair1 — E♭ harmonic minor
        }
        rebuildNow()                          // build the initial engine
    }

    // MARK: - Parameters

    func binding(for desc: ParamDescriptor) -> Binding<Double> {
        Binding(get: { self.state.params[desc.id] },
                set: { self.setParam(desc, $0) })
    }

    func setParam(_ desc: ParamDescriptor, _ value: Double) {
        state.params[desc.id] = value
        if desc.structural { scheduleRebuild() } else { audio.applySarangiScalars(state.params, fx: state.fx) }
    }

    /// Master output gain (`gout`) — a live scalar (no rebuild).
    var goutBinding: Binding<Double> {
        Binding(get: { self.state.params.gout },
                set: { self.state.params.gout = $0; self.audio.applySarangiScalars(self.state.params, fx: self.state.fx) })
    }

    // MARK: - Sympathetic strings / tuning

    func mutateString(id: UUID, _ body: (inout StringSpec) -> Void) {
        guard let i = state.strings.firstIndex(where: { $0.id == id }) else { return }
        body(&state.strings[i])
        state.manualEdits = true
        state.autoSyncToScale = false      // a hand edit detaches from the scale
        scheduleRebuild()
    }

    func stringBinding<V>(_ id: UUID, _ keyPath: WritableKeyPath<StringSpec, V>) -> Binding<V> {
        Binding(
            get: { self.state.strings.first { $0.id == id }?[keyPath: keyPath]
                    ?? self.state.strings[0][keyPath: keyPath] },
            set: { newValue in self.mutateString(id: id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func addString(group: StringGroup = .scale) {
        state.strings.append(StringSpec(freq: state.tonicHz, gain: 0.5, t60: 2.0, bright: false, group: group))
        state.manualEdits = true
        state.autoSyncToScale = false
        scheduleRebuild()
    }

    func removeStrings(_ ids: Set<UUID>) {
        state.strings.removeAll { ids.contains($0.id) }
        state.manualEdits = true
        state.autoSyncToScale = false
        scheduleRebuild()
    }

    /// Enable / disable a whole choir at once (one rebuild). A manual edit, so it
    /// detaches auto-sync (the choice persists instead of being wiped on re-sync).
    func setGroupEnabled(_ group: StringGroup, _ enabled: Bool) {
        for i in state.strings.indices where state.strings[i].group == group {
            state.strings[i].enabled = enabled
        }
        state.manualEdits = true
        state.autoSyncToScale = false
        scheduleRebuild()
    }

    // MARK: - Scale auto-sync (tarab follows the Pitch Pad scale)

    /// Re-tune the sympathetic bank to a scale (tonic Hz + degree ratios). Applies
    /// only when `autoSyncToScale` is on, unless `force` (the Tarab tab's "Re-sync"
    /// / enabling the toggle). `force` also turns auto-sync back on.
    func syncTarabToScale(tonicHz: Double, ratios: [Double], force: Bool = false) {
        guard force || state.autoSyncToScale else { return }
        if force { state.autoSyncToScale = true }
        state.regenerateFromScale(tonicHz: tonicHz, ratios: ratios)
        rebuildNow()
    }

    /// Toggle auto-sync. Turning it on does NOT itself re-sync (the caller pushes
    /// the current scale via `syncTarabToScale(..., force: true)`); turning it off
    /// just freezes the current strings for hand editing.
    func setAutoSync(_ on: Bool) {
        state.autoSyncToScale = on
    }

    // Manual tuning actions detach the tarab from the Pitch Pad scale.
    func setRaga(id: Int) { state.setRaga(id: id); state.autoSyncToScale = false; rebuildNow() }
    func regenerate() { state.regenerate(); state.autoSyncToScale = false; rebuildNow() }

    /// Set the tonic. `transpose` scales every string (keeping manual edits);
    /// otherwise the bank is regenerated from raga + tonic.
    func setTonic(_ hz: Double, transpose: Bool) {
        guard hz > 20, hz < 4000 else { return }
        if transpose { state.transpose(toTonic: hz) } else { state.tonicHz = hz; state.regenerate() }
        state.autoSyncToScale = false
        rebuildNow()
    }

    // MARK: - Per-voice FX rack (FX tab)

    /// Live FX scalar (enabled/reverb mix/width) → no rebuild; structural
    /// (filter/EQ/rt60) → debounced rebuild.
    private func applyFXChange(structural: Bool) {
        if structural { scheduleRebuild() } else { audio.applySarangiFXScalars(state.fx) }
    }

    /// Slider binding for an FX-rack value. `structural` = filter/EQ/rt60 (rebuild);
    /// otherwise reverb mix/width (live).
    func fxBinding(_ kp: WritableKeyPath<FXRack, Double>, structural: Bool) -> Binding<Double> {
        Binding(get: { self.state.fx[keyPath: kp] },
                set: { self.state.fx[keyPath: kp] = $0; self.applyFXChange(structural: structural) })
    }

    /// Toggle binding for an FX stage's `enabled` (always live).
    func fxToggleBinding(_ kp: WritableKeyPath<FXRack, Bool>) -> Binding<Bool> {
        Binding(get: { self.state.fx[keyPath: kp] },
                set: { self.state.fx[keyPath: kp] = $0; self.applyFXChange(structural: false) })
    }

    // MARK: - Presets / persistence

    /// Load a fitted preset in full (raga + tonic + strings + params + body FIR),
    /// so the live model matches that pair's offline render. Preserves the user's
    /// current auto-sync setting (the caller re-syncs the tarab to the scale if on).
    func loadPreset(_ preset: Preset) {
        let keepSync = state.autoSyncToScale
        state = Presets.state(preset)
        state.autoSyncToScale = keepSync
        rebuildNow()
    }

    func resetParams() { state.params = .defaults; state.fir = nil; rebuildNow() }

    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url)
    }

    func load(from url: URL) throws {
        state = try JSONDecoder().decode(InstrumentState.self, from: Data(contentsOf: url))
        rebuildNow()
    }

    /// Route an audition `sarangi.<paramId>` voiceParam onto the model (so the
    /// autonomous loop can sweep model params, same as the on-screen sliders).
    /// Also accepts FX-rack paths: `fx.<violin|sym|global>.<field>` and
    /// `fx.<stage>.eq<0..2>.<freq|gainDB|q>` (e.g. `sarangi.fx.violin.reverbMix`).
    @discardableResult
    func setAuditionParam(_ id: String, _ value: Double) -> Bool {
        if let desc = ParamSpec.byName[id] { setParam(desc, value); return true }
        if id.hasPrefix("fx.") { return setFXAudition(String(id.dropFirst(3)), value) }
        return false
    }

    private func setFXAudition(_ path: String, _ value: Double) -> Bool {
        let p = path.split(separator: ".").map(String.init)
        guard p.count >= 2 else { return false }
        let kp: WritableKeyPath<FXRack, VoiceFXParams>
        switch p[0] {
        case "violin": kp = \.violin
        case "sym": kp = \.sym
        case "global": kp = \.global
        default: return false
        }
        var structural = true
        if p.count == 2 {
            switch p[1] {
            case "enabled": state.fx[keyPath: kp].enabled = value != 0; structural = false
            case "reverbMix": state.fx[keyPath: kp].reverbMix = value; structural = false
            case "reverbWidth": state.fx[keyPath: kp].reverbWidth = value; structural = false
            case "reverbRT60": state.fx[keyPath: kp].reverbRT60 = value
            case "filterCutoff": state.fx[keyPath: kp].filterCutoff = value
            case "filterResonance": state.fx[keyPath: kp].filterResonance = value
            default: return false
            }
        } else if p.count == 3, p[1].hasPrefix("eq"), let n = Int(p[1].dropFirst(2)),
                  n >= 0, n < state.fx[keyPath: kp].eq.count {
            switch p[2] {
            case "freq": state.fx[keyPath: kp].eq[n].freq = value
            case "gainDB": state.fx[keyPath: kp].eq[n].gainDB = value
            case "q": state.fx[keyPath: kp].eq[n].q = value
            default: return false
            }
        } else { return false }
        applyFXChange(structural: structural)
        return true
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
        audio.rebuildSarangi(params: state.params, strings: state.resolvedStrings,
                             tonic: state.tonicHz, fir: state.fir, fx: state.fx)
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
