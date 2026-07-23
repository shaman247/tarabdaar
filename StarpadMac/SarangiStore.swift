import Foundation
import SarangiKit
import StarpadCore
import SwiftUI

/// Mac-side bridge for the ported sarangi model (`SarangiKit`). Owns the editable
/// `InstrumentState` — raga + tonic, the sympathetic-string table, and the 22
/// v57 model parameters — and routes each change to the audio engine as either
/// a **live scalar** update (gains, no rebuild) or a **debounced structural
/// rebuild** (raga/tonic/strings/filter coefficients), exactly the split the
/// standalone model uses (`ParamDescriptor.structural`).
///
/// The tarab auto-tunes to the Pitch Pad scale by default (`autoSyncToScale`);
/// a hand edit / raga pick detaches it so the strings can be tuned manually. The
/// whole document is auto-saved to UserDefaults and can be exported/imported as a
/// `.sarangi` JSON file.
final class SarangiStore: ObservableObject {
    @Published var state: InstrumentState { didSet { scheduleSave() } }

    /// The coupled bridge–body network config, parsed once from the bundled
    /// `sarangi_coupled.json`. REQUIRED since the v57-only simplification — the
    /// engine renders ONLY the passive junction (no legacy fallback, no toggle);
    /// nil (missing/mis-typed resource) leaves the engine silent.
    private lazy var activeCoupledConfig: CoupledConfig? = Presets.coupledConfig()

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
    /// default** (the exact fitted Pilu table with tarab auto-sync OFF so it
    /// sticks; 25 network params incl. `N_jaw_*`, `StringSpec.raga` class).
    private static let persistKey = "starpad.sarangiState.v8"

    init(audio: AudioEngine) {
        self.audio = audio
        if let data = UserDefaults.standard.data(forKey: Self.persistKey),
           let s = try? JSONDecoder().decode(InstrumentState.self, from: data) {
            self.state = s
        } else {
            // Fresh install = the Sarangi Live default: the fitted Pilu
            // instrument exactly as upstream ships it. Auto-sync starts OFF so
            // the exact fitted string table + Sa 328.9 Hz stand; the Tarab
            // tab's "Follow the Pitch Pad scale" switch opts back in.
            var s = InstrumentState.makeDefault()   // sarangi_pilu (fitted)
            s.autoSyncToScale = false
            self.state = s
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

    /// Addresses one stage of the rack (`\.violinPre` / `\.global`).
    typealias FXStage = WritableKeyPath<FXRack, VoiceFXParams>

    /// How an FX edit reaches the engine.
    /// - `liveScalar`: enabled + reverb mix/width — pushed to `scalars` (no rebuild).
    /// - `liveFilter`: the graphical EQ bands + the stage low-pass (cutoff/resonance)
    ///   — an in-place biquad coefficient swap on the running engine (click-free).
    /// - `structural`: reverb RT60 (owns delay-line state) — debounced rebuild.
    enum FXUpdate { case liveScalar, liveFilter, structural }

    private func applyFXChange(_ kind: FXUpdate) {
        switch kind {
        case .liveScalar: audio.applySarangiFXScalars(state.fx)
        case .liveFilter: audio.applySarangiFXFilters(state.fx)
        case .structural: scheduleRebuild()
        }
    }
    /// Back-compat shim for the scalar slider bindings below.
    private func applyFXChange(structural: Bool) { applyFXChange(structural ? .structural : .liveScalar) }

    /// Slider binding for an FX-rack value. `structural` = reverb RT60 (rebuild);
    /// otherwise reverb mix/width (live). Filter/EQ are edited via the graphical
    /// EQ (`setEQBand`/`setFilter`, `.liveFilter`), not this binding.
    func fxBinding(_ kp: WritableKeyPath<FXRack, Double>, structural: Bool) -> Binding<Double> {
        Binding(get: { self.state.fx[keyPath: kp] },
                set: { self.state.fx[keyPath: kp] = $0; self.applyFXChange(structural: structural) })
    }

    /// Toggle binding for an FX stage's `enabled` (always live).
    func fxToggleBinding(_ kp: WritableKeyPath<FXRack, Bool>) -> Binding<Bool> {
        Binding(get: { self.state.fx[keyPath: kp] },
                set: { self.state.fx[keyPath: kp] = $0; self.applyFXChange(structural: false) })
    }

    // MARK: - Graphical EQ (variable bands + stage low-pass, all live)

    /// The stage's whole FX param set (read-only convenience for the EQ view).
    func voiceFX(for stage: FXStage) -> VoiceFXParams { state.fx[keyPath: stage] }
    /// The stage's EQ bands.
    func eqBands(for stage: FXStage) -> [EQBand] { state.fx[keyPath: stage].eq }

    /// Mutate one band (addressed by stable id) and push the coefficients live.
    func setEQBand(_ stage: FXStage, id: UUID, _ body: (inout EQBand) -> Void) {
        guard let i = state.fx[keyPath: stage].eq.firstIndex(where: { $0.id == id }) else { return }
        body(&state.fx[keyPath: stage].eq[i])
        applyFXChange(.liveFilter)
    }

    /// Add a band (kept sorted by frequency); returns its id, or nil at the cap.
    @discardableResult
    func addEQBand(_ stage: FXStage, freq: Double, gainDB: Double = 0,
                   q: Double = 1.0, type: EQBandType = .peaking) -> UUID? {
        guard state.fx[keyPath: stage].eq.count < VoiceFXParams.maxEQBands else { return nil }
        let band = EQBand(freq: freq, gainDB: gainDB, q: q, type: type)
        state.fx[keyPath: stage].eq.append(band)
        state.fx[keyPath: stage].eq.sort { $0.freq < $1.freq }
        applyFXChange(.liveFilter)
        return band.id
    }

    /// Remove a band by id (a no-op at `minEQBands`).
    func removeEQBand(_ stage: FXStage, id: UUID) {
        guard state.fx[keyPath: stage].eq.count > VoiceFXParams.minEQBands,
              let i = state.fx[keyPath: stage].eq.firstIndex(where: { $0.id == id }) else { return }
        state.fx[keyPath: stage].eq.remove(at: i)
        applyFXChange(.liveFilter)
    }

    /// Set the stage low-pass (the EQ's right-edge node) live.
    func setFilter(_ stage: FXStage, cutoff: Double, resonance: Double) {
        state.fx[keyPath: stage].filterCutoff = min(max(20, cutoff), 20000)
        state.fx[keyPath: stage].filterResonance = min(max(0, resonance), 1)
        applyFXChange(.liveFilter)
    }

    // MARK: - Presets / persistence

    /// Load the fitted preset in full (raga + tonic + the EXACT fitted string
    /// table + params), so the live model matches the offline render. Preserves
    /// the user's auto-sync setting (the caller re-syncs the tarab if on — note
    /// a re-sync REPLACES the fitted table; turn auto-sync off to keep it exact).
    func loadPreset(_ preset: Preset) {
        let keepSync = state.autoSyncToScale
        state = Presets.state(preset)
        state.autoSyncToScale = keepSync
        rebuildNow()
    }

    /// Load the preset **as the Sarangi Live default**: the exact fitted
    /// string table + Sa tonic with tarab auto-sync turned OFF, so nothing
    /// re-tunes it out from under the fit. (The String voice reads this
    /// tonic + these strings for its in-kernel taraf; the caller also clears
    /// the String physics overrides — the artifact is the default there.)
    func loadSarangiLiveDefault(_ preset: Preset = .sarangiPilu) {
        state = Presets.state(preset)
        state.autoSyncToScale = false
        rebuildNow()
    }

    func resetParams() { state.params = .defaults; rebuildNow() }

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
    /// Also accepts FX-rack paths: `fx.<violinPre|global>.<field>` and
    /// `fx.<stage>.eq<N>.<freq|gainDB|q>` (arbitrary N for an existing band, e.g.
    /// `sarangi.fx.violinPre.eq0.gainDB`, `sarangi.fx.global.reverbMix`).
    @discardableResult
    func setAuditionParam(_ id: String, _ value: Double) -> Bool {
        if let desc = ParamSpec.byName[id] { setParam(desc, value); return true }
        if id.hasPrefix("fx.") { return setFXAudition(String(id.dropFirst(3)), value) }
        return false
    }

    private func setFXAudition(_ path: String, _ value: Double) -> Bool {
        let p = path.split(separator: ".").map(String.init)
        guard p.count >= 2 else { return false }
        let kp: FXStage
        switch p[0] {
        case "violinPre": kp = \.violinPre
        case "global": kp = \.global
        default: return false
        }
        var kind: FXUpdate = .liveFilter
        if p.count == 2 {
            switch p[1] {
            case "enabled": state.fx[keyPath: kp].enabled = value != 0; kind = .liveScalar
            case "reverbMix": state.fx[keyPath: kp].reverbMix = value; kind = .liveScalar
            case "reverbWidth": state.fx[keyPath: kp].reverbWidth = value; kind = .liveScalar
            case "reverbRT60": state.fx[keyPath: kp].reverbRT60 = value; kind = .structural
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
        applyFXChange(kind)
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
                             tonic: state.tonicHz, fx: state.fx,
                             eqBands: state.resolvedEQ,
                             groups: state.resolvedGroups,
                             coupled: activeCoupledConfig)
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
