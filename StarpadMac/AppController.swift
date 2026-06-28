import AppKit
import Combine
import CoreAudioKit
import Foundation
import StarpadCore
import StarpadDSP

/// Mac-side wiring. The Mac is a MIDI sound module that receives MPE
/// input over USB-MIDI and owns every Mac-side knob: sympathetic-string
/// pool config, FX, hosted-AU selection, and preset state. The played
/// voice is supplied by a hosted Audio Unit (SWAM Viola). The iPad is
/// purely a MIDI controller; the one thing this side pushes to it is the
/// Pitch Pad scale, sent as SysEx over USB (see `startScaleSync`).
///
/// Architecture:
///   `MIDIInput`  →  `AudioEngine` (hosted AU + sym pool)  →  speakers
///   `AppController` holds settings and pushes them into `AudioEngine`
///   on change. No `NoteManager` on the Mac — that class is iPad-only.

/// Notifies AppController when its hosted-AU window closes so the
/// reference can be released and a fresh window can be opened next time.
private final class HostedAUWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

final class AppController: ObservableObject {
    let audio: AudioEngine
    let midi: MIDIEngine
    let midiIn: MIDIInput

    /// Mac-side iPad simulator (Simulator tab). Owns its own
    /// `NoteManager` + `MockMotionSource`. Constructed lazily here so
    /// `MacMainWindow` can hand a single live instance to the view.
    /// Public so the tab's view can grab `.simulator.noteManager` etc.
    let simulator: IPadSimulator
    let audition: AuditionRunner
    /// Alternative-to-keyboard interface (Pitch Pad tab). Owns its own
    /// MPE-style MIDIEngine — sends notes in-process directly to the
    /// hosted AU, completely independent of `simulator`.
    let pitchPad: PitchPadEngine
    /// Chord Pad tab — a second hex-grid playing surface. Reuses a
    /// `PitchPadEngine` purely as the MPE emitter (fed `2^(semis/12)` per
    /// cell); reads the scale + tonic from `pitchPad` (Mac-only, no sync).
    let chordPad: PitchPadEngine
    /// String Pad tab — a third box-plot / abacus playing surface. Reuses a
    /// `PitchPadEngine` as the MPE emitter (fed the resolved ratio per shape);
    /// pitches derive from `pitchPad`'s scale + tonic (Mac-only, no sync).
    let stringPad: PitchPadEngine

    /// The String Pad's arrangement of pitch shapes (Mac-only). Auto-saved to
    /// disk (debounced) by a sink in `start()`; edited live from the tab.
    @Published var stringArrangement = StringArrangement(notes: [], stringCount: 0)

    /// Active preset, or nil if none has been applied this session.
    @Published private(set) var currentPreset: SoundPreset?

    /// Transient feedback for the "Capture SWAM State" dev action.
    @Published var swamCaptureStatus: String = ""

    /// Which playing surface the iPad shows (Pitch Pad or Chord Pad). The Mac
    /// drives it; it rides the synced SysEx state to the iPad. Persisted.
    @Published var ipadLayout: PadLayout =
        PadLayout(rawValue: UserDefaults.standard
            .integer(forKey: "starpad.ipadLayout")) ?? .pitchPad {
        didSet {
            UserDefaults.standard.set(ipadLayout.rawValue, forKey: "starpad.ipadLayout")
        }
    }

    // MARK: - Tanpura drone

    /// Versioned by the baked matched-parameter set: when a new match is
    /// baked into `TanpuraParams` defaults, the key changes and any stale
    /// persisted copy is ignored.
    private static let tanpuraParamsKey =
        "starpad.tanpuraParams.v\(TanpuraParams.matchedVersion)"

    /// Full tanpura model parameter set (tuning, per-harmonic bloom laws +
    /// trims, body, modulation). Persisted to UserDefaults as JSON and
    /// pushed straight to the engine on every change. Deliberately NOT
    /// part of `applyPreset` — the drone keeps its own state across
    /// preset switches.
    @Published var tanpuraParams: TanpuraParams = {
        if let data = UserDefaults.standard.data(forKey: AppController.tanpuraParamsKey),
           let p = try? JSONDecoder().decode(TanpuraParams.self, from: data) {
            return p
        }
        return TanpuraParams()
    }() {
        didSet {
            audio.setTanpuraParams(tanpuraParams)
            if let data = try? JSONEncoder().encode(tanpuraParams) {
                UserDefaults.standard.set(data, forKey: Self.tanpuraParamsKey)
            }
        }
    }

    /// Output gain (dB) for the drone, applied in the engine after the
    /// model's peak-normalized `masterGain`. Lives outside
    /// `tanpuraParams` so volume tweaks never touch the matched bake.
    @Published var tanpuraGainDB: Double = 12.0 {
        didSet { audio.setTanpuraGainDB(Float(tanpuraGainDB)) }
    }

    /// Velocity used by the string buttons and the auto-drone.
    @Published var tanpuraVelocity: Double = 0.8

    /// Continuous strum cycle. Controller-owned timer, so the drone keeps
    /// going when the user switches tabs.
    @Published var tanpuraAutoDrone = false {
        didSet { updateDroneTimer() }
    }

    /// Seconds between auto-drone steps (the reference plays ≈ 0.9 s).
    @Published var tanpuraStepSeconds: Double = 0.9

    /// Auto-drone pattern: space-separated string numbers 1–4; anything
    /// else (e.g. "-") is a rest step. "1 2 3 4" = Pa sa sa SA.
    @Published var tanpuraPattern: String = "1 2 3 4" {
        didSet { dronePatternIndex = 0 }
    }

    private var droneTimer: Timer?
    private var dronePatternIndex = 0

    /// Pluck a tanpura string from the UI.
    func tanpuraPluck(_ index: Int) {
        audio.tanpuraPluck(index: index, velocity: tanpuraVelocity)
    }

    private func updateDroneTimer() {
        droneTimer?.invalidate()
        droneTimer = nil
        if tanpuraAutoDrone { scheduleNextDroneStep() }
    }

    private func scheduleNextDroneStep() {
        guard tanpuraAutoDrone else { return }
        // ±20 ms humanization so the cycle never sounds quantized.
        let interval = max(0.12, tanpuraStepSeconds + Double.random(in: -0.02...0.02))
        droneTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                          repeats: false) { [weak self] _ in
            self?.fireDroneStep()
        }
    }

    private func fireDroneStep() {
        guard tanpuraAutoDrone else { return }
        let tokens = tanpuraPattern.split(separator: " ")
        if !tokens.isEmpty {
            let tok = tokens[dronePatternIndex % tokens.count]
            dronePatternIndex += 1
            if let n = Int(tok), (1...4).contains(n) {
                let vel = max(0.05, min(1.0, tanpuraVelocity + Double.random(in: -0.05...0.05)))
                audio.tanpuraPluck(index: n - 1, velocity: vel)
            }
        }
        scheduleNextDroneStep()
    }

    // MARK: - Sitar (plucked, same model as the tanpura)

    /// Versioned by the baked sitar parameter set: a fresh bake bumps the
    /// key so any stale persisted copy is ignored.
    private static let sitarParamsKey =
        "starpad.sitarParams.v\(TanpuraParams.sitarMatchedVersion)"

    /// Full sitar model parameter set, fitted to `sitar1.wav`. Persisted to
    /// UserDefaults as JSON and pushed straight to the engine on every
    /// change. Like the tanpura, NOT part of `applyPreset`.
    @Published var sitarParams: TanpuraParams = {
        if let data = UserDefaults.standard.data(forKey: AppController.sitarParamsKey),
           let p = try? JSONDecoder().decode(TanpuraParams.self, from: data) {
            return p
        }
        return TanpuraParams.sitar
    }() {
        didSet {
            audio.setSitarParams(sitarParams)
            if let data = try? JSONEncoder().encode(sitarParams) {
                UserDefaults.standard.set(data, forKey: Self.sitarParamsKey)
            }
        }
    }

    /// Output gain (dB) for the sitar, after the model's peak-normalized
    /// `masterGain`. Lives outside `sitarParams` so it never touches the bake.
    @Published var sitarGainDB: Double = 18.0 {
        didSet { audio.setSitarGainDB(Float(sitarGainDB)) }
    }

    /// Velocity used by the sitar pluck pads.
    @Published var sitarVelocity: Double = 0.85

    /// Pluck a sitar string from the UI (optionally retuned to `f0` first so
    /// the pitch-invariant timbre can play a melody).
    func sitarPluck(_ index: Int, f0: Double? = nil) {
        if let f0 {
            var p = sitarParams
            if p.strings.indices.contains(index), abs(p.strings[index].f0 - f0) > 0.01 {
                p.strings[index].f0 = f0
                sitarParams = p
            }
        }
        audio.sitarPluck(index: index, velocity: sitarVelocity)
    }

    /// Reproduce the matched reference phrase: three C#4 plucks at the
    /// measured onsets/velocities (for A/B against `sitar1.wav`).
    func sitarPlayReferencePhrase() {
        let onsets = [0.0, 1.365, 2.976]          // relative to first pluck
        let vels = [0.82, 1.0, 0.94]
        audio.clearSitarState()
        for (t, v) in zip(onsets, vels) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                self.audio.sitarPluck(index: 0, velocity: v * self.sitarVelocity)
            }
        }
    }

    // MARK: - Sarangi model
    //
    // The sarangi voice is the ported `SarangiKit` model, owned by `sarangi`
    // (`SarangiStore`): raga + tonic, the editable sympathetic-string table, and
    // the 27 model parameters all live there (fully independent of the played
    // Pitch Pad scale). Edited in the Sarangi tab (⌘2). See `SarangiEditorView`.

    /// The ported sarangi model's editable state + engine bridge.
    let sarangi: SarangiStore

    // MARK: - Viola body formants (hosted-AU path)

    @Published var violaBodyEnabled: Bool = false {
        didSet { audio.setViolaBodyEnabled(violaBodyEnabled) }
    }
    @Published var violaBody: [ViolaBodyBand] = [
        ViolaBodyBand(freq: 300, gainDB: 4.0, widthOct: 0.6),
        ViolaBodyBand(freq: 650, gainDB: -3.5, widthOct: 0.8),
        ViolaBodyBand(freq: 1050, gainDB: 5.0, widthOct: 0.5),
        ViolaBodyBand(freq: 3200, gainDB: 3.5, widthOct: 0.7),
    ] {
        didSet { pushViolaBody() }
    }

    /// Makeup gain (dB) applied to the hosted AU (SWAM Violin) drive. Range
    /// [-24, +24] dB; default +6. (The model has its own `gin`/`gout` levels;
    /// this trims the SWAM instrument's own output.)
    @Published var hostedMakeupGainDB: Double = 6.0 {
        didSet { audio.setHostedMakeupGainDB(Float(hostedMakeupGainDB)) }
    }

    /// Calibration gain lifting SWAM's raw output (~0.02 peak) up to the level the
    /// SWAM → model drive gain. **Default 1× = unity**, matching the standalone
    /// "Sarangi Live" app (which feeds SWAM straight into the model). The old 10×
    /// suited the previous quiet recipe; the re-vendored shared recipe is ~15 dB
    /// hotter, so 10× over-drove the model (saturated jawari → buzzy distortion).
    /// Key bumped to `.v2` so a stale persisted `10` doesn't shadow the new default.
    /// Persisted; pushed to the engine's drive stage.
    @Published var sarangiDriveGain: Double =
        UserDefaults.standard.object(forKey: "starpad.sarangiDriveGain.v2") as? Double ?? 1.0 {
        didSet {
            audio.setSarangiDriveGain(sarangiDriveGain)
            UserDefaults.standard.set(sarangiDriveGain, forKey: "starpad.sarangiDriveGain.v2")
        }
    }

    // MARK: - FX

    @Published var reverbMix: Double = 25 {
        didSet { audio.setReverbMix(Float(reverbMix)) }
    }
    @Published var filterCutoff: Double = 18000 {
        didSet { audio.setMasterFilter(cutoff: filterCutoff, resonance: filterResonance) }
    }
    @Published var filterResonance: Double = 0 {
        didSet { audio.setMasterFilter(cutoff: filterCutoff, resonance: filterResonance) }
    }

    // MARK: - Post-reverb shaper (final spectral envelope)

    /// Final 3-band parametric EQ AFTER the master reverb. With SWAM run dry
    /// and body/room handled downstream, this tames the reverb tail's low-mid
    /// bloom and restores air so the combined (SWAM + halo) spectrum reads as a
    /// sharp sarangi, not a smeared violin. Reuses `ViolaBodyBand`.
    @Published var postReverbEnabled: Bool = false {
        didSet { audio.setPostReverbEnabled(postReverbEnabled) }
    }
    @Published var postReverb: [ViolaBodyBand] = [
        ViolaBodyBand(freq: 350, gainDB: 0, widthOct: 1.0),   // low-mid bloom
        ViolaBodyBand(freq: 2500, gainDB: 0, widthOct: 1.0),  // presence
        ViolaBodyBand(freq: 7000, gainDB: 0, widthOct: 1.2),  // air
    ] {
        didSet { pushPostReverb() }
    }

    // MARK: - MIDI CC mappings (per-preset)

    /// Active CC → parameter table for the current preset. Bijective by
    /// construction: assigning a CC to a param that already has one
    /// frees the old CC, and assigning a CC that's already in use frees
    /// the param it pointed to. See `setMapping(cc:param:)`.
    @Published var ccMappings: [Int: MappableMacParam] = [:] {
        didSet { persistActiveCCMappings() }
    }

    /// Persistent per-preset table, keyed by `SoundPreset.rawValue`.
    private var ccMappingLibrary: [String: [Int: MappableMacParam]] = [:]
    private let ccMappingDefaultsKey = "starpad.ccMappingLibrary"

    // MARK: - Init / lifecycle

    init() {
        let audio = AudioEngine()
        let midi = MIDIEngine()
        let midiIn = MIDIInput()
        self.audio = audio
        self.midi = midi
        self.midiIn = midiIn
        midiIn.audioEngine = audio
        // Simulator + audition runner. The simulator's back-ref to
        // `self` is wired below after all stored properties are set,
        // since Swift forbids referencing `self` until init completes.
        let sim = IPadSimulator(audio: audio)
        self.simulator = sim
        self.audition = AuditionRunner(simulator: sim, audio: audio)
        self.pitchPad = PitchPadEngine(audio: audio)
        self.chordPad = PitchPadEngine(audio: audio)
        // The Chord Pad plays against the Pitch Pad's tonic. Seed it now so
        // the first frame is correct; a Combine sink in `start()` keeps it in
        // step with later changes.
        self.chordPad.tonicMidi = self.pitchPad.tonicMidi
        // The String Pad is a third MPE emitter, same as the Chord Pad.
        self.stringPad = PitchPadEngine(audio: audio)
        self.stringPad.tonicMidi = self.pitchPad.tonicMidi
        // Restore the last-edited arrangement, or build a starter from the
        // current scale's degree count. (Assigning here doesn't fire the
        // autosave sink — that's wired in `start()`.)
        self.stringArrangement = StringArrangementStore.loadCurrent()
            ?? StringArrangement.defaultArrangement(
                degreeCount: scaleDegrees(from: self.pitchPad.scale).count)
        // The sarangi model owns its own tuning + strings (independent of the
        // Pitch Pad). Constructing the store loads the persisted/default state
        // and builds the initial `SarangiEngine`.
        self.sarangi = SarangiStore(audio: audio)

        self.ccMappingLibrary = Self.loadCCMappingLibrary(
            defaultsKey: ccMappingDefaultsKey)

        midiIn.onCC = { [weak self] cc, value in
            DispatchQueue.main.async {
                self?.handleIncomingCC(cc: Int(cc), value: Int(value))
            }
        }

        // Hosted AUs (SWAM in particular) acquire license/session
        // tokens via the Audio Modeling Core Assistant daemon when they
        // instantiate. The daemon expects an explicit release on
        // teardown; without it the next launch sees a stuck token and
        // refuses to render. Only fires on a clean quit (⌘Q / menu
        // Quit); SIGKILL from Xcode's Stop button skips this.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.audio.unloadHostedInstrument()
            // Put the output device back to the rate it had before we forced it
            // to 44.1 kHz (the engine/model rate) to drop the output resampler.
            self?.audio.restoreOutputDeviceRate()
        }

        // Default preset — only SWAM Violin ships at the moment.
        applyPreset(.swamViola)
        // Stored-property init skips the didSet — push the hosted makeup gain.
        audio.setHostedMakeupGainDB(Float(hostedMakeupGainDB))
        audio.setSarangiDriveGain(sarangiDriveGain)
        // And the persisted tanpura params (stored-property init skips
        // the didSet that normally pushes them).
        audio.setTanpuraParams(tanpuraParams)
        audio.setTanpuraGainDB(Float(tanpuraGainDB))
        audio.setSitarParams(sitarParams)
        audio.setSitarGainDB(Float(sitarGainDB))

        // Now that all stored properties are set, wire the simulator's
        // CC route back to this controller so its in-process MIDI hits
        // the same preset CC mappings as a real iPad-over-USB note.
        simulator.controller = self
    }

    /// Combine subscriptions that push the Pitch Pad scale to the iPad.
    private var cancellables = Set<AnyCancellable>()

    func start() {
        midi.start()
        midiIn.start()
        simulator.start()
        pitchPad.start()
        chordPad.start()
        stringPad.start()
        audition.start()
        startScaleSync()
        // Keep the Chord Pad's and String Pad's tonic locked to the Pitch
        // Pad's. Independent of `startScaleSync` (which only pushes Pitch Pad
        // state to the iPad).
        pitchPad.$tonicMidi
            .sink { [weak self] in
                self?.chordPad.tonicMidi = $0
                self?.stringPad.tonicMidi = $0
            }
            .store(in: &cancellables)

        // Auto-save the String Pad arrangement. Debounced so a drag-edit
        // doesn't write to disk every frame.
        $stringArrangement
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { StringArrangementStore.saveCurrent($0) }
            .store(in: &cancellables)

        // Auto-sync the sarangi's sympathetic strings (tarab) to the Pitch Pad
        // scale: when the scale or tonic changes, retune the bank (if the user
        // hasn't detached it by hand-editing). Debounced to coalesce drag edits.
        Publishers.MergeMany([
            pitchPad.$scale.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicMidi.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in self?.syncTarabFromScale() }
        .store(in: &cancellables)
        syncTarabFromScale()        // match the scale on launch
    }

    // MARK: - Sarangi tarab ↔ Pitch Pad scale

    /// Retune the sympathetic bank to the current Pitch Pad scale (tonic + degree
    /// ratios). Respects `autoSyncToScale` unless `force` (the Tarab tab's
    /// "Re-sync" / enabling the toggle).
    func syncTarabFromScale(force: Bool = false) {
        let tonicHz = 440.0 * pow(2.0, Double(pitchPad.tonicMidi - 69) / 12.0)   // 12-TET tonic
        let ratios = scaleDegrees(from: pitchPad.scale).map(\.ratio)
        sarangi.syncTarabToScale(tonicHz: tonicHz, ratios: ratios, force: force)
    }

    /// Toggle whether the tarab follows the Pitch Pad scale. Turning it on
    /// immediately re-syncs to the current scale.
    func setTarabAutoSync(_ on: Bool) {
        sarangi.setAutoSync(on)
        if on { syncTarabFromScale(force: true) }
    }

    // MARK: - iPad scale sync (Mac → iPad over SysEx)

    /// StarpadMac edits, Starpad performs: push the current Pitch Pad state
    /// (scale + tonic + margin) to the iPad whenever any of it changes
    /// (debounced to coalesce drag edits) and whenever a MIDI destination
    /// appears (the iPad plugging in). One-way; the only cross-device state,
    /// carried as a SysEx blob on the same USB cable. See `PitchScaleSysEx`.
    private func startScaleSync() {
        // Any of: scale edit, tonic change, margin change, or a new
        // destination → push the whole current state.
        let triggers: [AnyPublisher<Void, Never>] = [
            pitchPad.$scale.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$tonicMidi.map { _ in () }.eraseToAnyPublisher(),
            pitchPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            chordPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            stringPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            $stringArrangement.map { _ in () }.eraseToAnyPublisher(),
            $ipadLayout.map { _ in () }.eraseToAnyPublisher(),
            midi.$destinationCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.pushCurrentState() }
            .store(in: &cancellables)
    }

    private func pushCurrentState() {
        // The iPad shows one surface at a time, so push the margin of the
        // surface that's active — each pad owns its own margin slider.
        let margin: Double
        switch ipadLayout {
        case .chordPad:  margin = chordPad.marginPixels
        case .stringPad: margin = stringPad.marginPixels
        case .pitchPad:  margin = pitchPad.marginPixels
        }
        let state = SyncedScaleState(points: pitchPad.scale.points,
                                     tonicMidi: pitchPad.tonicMidi,
                                     marginPixels: margin,
                                     layout: ipadLayout)
        // Match the iPad's "Starpad Scale" virtual destination loosely on
        // "Starpad" — the USB bridge may prefix the endpoint name with the
        // device name. `sendSysEx` falls back to all destinations if even
        // this matches nothing, so a renamed endpoint can't block sync.
        midi.sendSysEx(PitchScaleSysEx.encode(state), toDestinationsMatching: "Starpad")
        // The String Pad's note layout is its own state (not derivable from the
        // scale), so push it as a second SysEx message while it's active.
        if ipadLayout == .stringPad {
            midi.sendSysEx(StringArrangementSysEx.encode(stringArrangement),
                           toDestinationsMatching: "Starpad")
        }
    }

    /// Public entry for the iPad-simulator's in-process CC delivery.
    /// Mirrors `MIDIInput.onCC` → `handleIncomingCC`.
    func handleSimulatorCC(cc: Int, value: Int) {
        handleIncomingCC(cc: cc, value: value)
    }

    /// Programmatic entry point used by audition scores' `voiceParam`
    /// events. Names match the `@Published` properties above; values
    /// are passed through in each parameter's natural units (cents,
    /// Hz, 0..1 fraction, 0..100 mix). Unknown names log and noop so a
    /// typo in a score doesn't take down the runner. Values are
    /// clamped onto the same ranges enforced by the UI sliders, since
    /// the engine setters trust their callers.
    func setVoiceParam(name: String, value: Double) {
        switch name {
        case "violaBodyEnabled":  violaBodyEnabled  = value > 0.5
        case "postReverbEnabled": postReverbEnabled = value > 0.5
        case "reverbMix":         reverbMix         = clamp(value, 0, 100)
        case "filterCutoff":      filterCutoff      = clamp(value, 20, 20000)
        case "filterResonance":   filterResonance   = clamp(value, 0, 1)
        case "tanpuraGainDB":     tanpuraGainDB     = clamp(value, -24, 24)
        case "sitarGainDB":       sitarGainDB       = clamp(value, -24, 24)
        case "driveGain", "sarangiDriveGain": sarangiDriveGain = clamp(value, 0, 64)
        default:
            // Sarangi model params: "sarangi.<paramId>" — the 27 ParamSpec ids
            // (e.g. "sarangi.B_gain", "sarangi.mix_jaw", "sarangi.F_mix").
            if name.hasPrefix("sarangi.") {
                if sarangi.setAuditionParam(String(name.dropFirst(8)), value) { return }
                NSLog("Starpad: no sarangi param '\(name.dropFirst(8))'")
                return
            }
            // Sitar params route by path: "sitar.<path>" (same paths as
            // tanpura — see TanpuraParams.set(path:value:)).
            if name.hasPrefix("sitar.") {
                var p = sitarParams
                if p.set(path: String(name.dropFirst(6)), value: value) {
                    sitarParams = p
                    return
                }
            }
            // Tanpura params route by path: "tanpura.<path>" with paths
            // like "jivaDepth", "body0.freq", "string2.decay",
            // "string1.gainTrimDB13" (see TanpuraParams.set(path:value:)).
            if name.hasPrefix("tanpura.") {
                var p = tanpuraParams
                if p.set(path: String(name.dropFirst(8)), value: value) {
                    tanpuraParams = p
                    return
                }
            }
            // Viola body bands: "violaBody{0-3}.freq|gainDB|widthOct".
            if setViolaBodyBandParam(name: name, value: value) { return }
            // Post-reverb bands: "postEQ{0-2}.freq|gainDB|widthOct".
            if setPostReverbBandParam(name: name, value: value) { return }
            // Hosted-AU (SWAM Violin) params by identifier: "swam.<identifier>"
            // — e.g. "swam.Vibrato" to disable auto-vibrato. Discover the
            // identifiers with the "__auDump__" audition event.
            if name.hasPrefix("swam.") {
                if audio.setHostedParameter(identifier: String(name.dropFirst(5)),
                                            value: Float(value)) { return }
                NSLog("Starpad: no hosted-AU param '\(name.dropFirst(5))'")
                return
            }
            NSLog("Starpad: setVoiceParam unknown name '\(name)'")
        }
    }

    /// Route "violaBody{i}.{field}" audition params onto `violaBody`.
    private func setViolaBodyBandParam(name: String, value: Double) -> Bool {
        guard name.hasPrefix("violaBody") else { return false }
        let rest = name.dropFirst("violaBody".count)
        let parts = rest.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let i = Int(parts[0]),
              i >= 0 && i < violaBody.count else { return false }
        var bands = violaBody
        switch parts[1] {
        case "freq":     bands[i].freq = clamp(value, 20, 20000)
        case "gainDB":   bands[i].gainDB = clamp(value, -24, 24)
        case "widthOct": bands[i].widthOct = clamp(value, 0.05, 5)
        default: return false
        }
        violaBody = bands
        return true
    }

    /// Route "postEQ{i}.{field}" audition params onto `postReverb`.
    private func setPostReverbBandParam(name: String, value: Double) -> Bool {
        guard name.hasPrefix("postEQ") else { return false }
        let rest = name.dropFirst("postEQ".count)
        let parts = rest.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let i = Int(parts[0]),
              i >= 0 && i < postReverb.count else { return false }
        var bands = postReverb
        switch parts[1] {
        case "freq":     bands[i].freq = clamp(value, 20, 20000)
        case "gainDB":   bands[i].gainDB = clamp(value, -24, 24)
        case "widthOct": bands[i].widthOct = clamp(value, 0.05, 5)
        default: return false
        }
        postReverb = bands
        return true
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }

    // MARK: - Preset application

    func applyPreset(_ preset: SoundPreset) {
        let state = preset.state()
        currentPreset = preset
        // Load this preset's saved CC mapping table first so a quick
        // mapping change during the same frame saves under the correct
        // preset key.
        ccMappings = ccMappingLibrary[preset.rawValue] ?? [:]

        // Copy the master-FX preset values into the @Published mirrors; each
        // setter's `didSet` pushes to the engine. (The sarangi voice itself is
        // owned by `sarangi`/SarangiStore, not by the preset.)
        violaBody = state.violaBody
        violaBodyEnabled = state.violaBodyEnabled
        postReverb = state.postReverb
        postReverbEnabled = state.postReverbEnabled
        reverbMix = state.reverbMix
        filterCutoff = state.filterCutoff
        filterResonance = state.filterResonance

        // Hosted AU lifecycle. Install the preset's full document state (SWAM's
        // opaque encoded state, incl. the MIDI CC assignments) and AU parameter
        // defaults (SWAM bow timbre + vibrato off, run DRY) BEFORE loading so
        // each slot picks them up on attach, then load the new one (or unload
        // the old). The model expects dry SWAM input, so these stay.
        audio.setHostedAUFullState(state.hostedAUState)
        audio.setHostedAUParameterDefaults(state.hostedAUParams)
        if let desc = state.hostedAudioUnit {
            audio.loadHostedInstrument(desc)
        } else {
            audio.unloadHostedInstrument()
        }
    }

    // MARK: - Audio-engine pushes

    /// Push every viola body band to the shared sarangi-body EQ.
    private func pushViolaBody() {
        for (i, band) in violaBody.enumerated() {
            audio.setViolaBodyBand(i, freq: band.freq,
                                   gainDB: band.gainDB,
                                   widthOct: band.widthOct)
        }
    }

    /// Push every post-reverb band to the final spectral shaper.
    private func pushPostReverb() {
        for (i, band) in postReverb.enumerated() {
            audio.setPostReverbBand(i, freq: band.freq,
                                    gainDB: band.gainDB,
                                    widthOct: band.widthOct)
        }
    }

    // MARK: - CC routing

    private func handleIncomingCC(cc: Int, value: Int) {
        guard let param = ccMappings[cc] else { return }
        let normalized = Double(value) / 127.0
        applyMappedCC(param: param, normalized: normalized)
    }

    /// Set or clear the CC bound to a parameter. Pass `cc: nil` to
    /// unmap. Enforces one-to-one in both directions.
    func setMapping(for param: MappableMacParam, cc: Int?) {
        var table = ccMappings
        if let oldCC = table.first(where: { $0.value == param })?.key {
            table.removeValue(forKey: oldCC)
        }
        if let cc, (0...127).contains(cc) {
            table.removeValue(forKey: cc) // free whatever this CC pointed to
            table[cc] = param
        }
        ccMappings = table
    }

    func ccForParam(_ param: MappableMacParam) -> Int? {
        ccMappings.first(where: { $0.value == param })?.key
    }

    private func applyMappedCC(param: MappableMacParam, normalized: Double) {
        let r = param.range
        let v = r.lowerBound + (r.upperBound - r.lowerBound) * normalized
        switch param {
        case .reverbMix:            reverbMix = v
        case .filterCutoff:         filterCutoff = v
        case .filterResonance:      filterResonance = v
        }
    }

    // MARK: - CC mapping persistence

    private func persistActiveCCMappings() {
        guard let preset = currentPreset else { return }
        if ccMappings.isEmpty {
            ccMappingLibrary.removeValue(forKey: preset.rawValue)
        } else {
            ccMappingLibrary[preset.rawValue] = ccMappings
        }
        Self.saveCCMappingLibrary(ccMappingLibrary, defaultsKey: ccMappingDefaultsKey)
    }

    private static func loadCCMappingLibrary(
        defaultsKey: String
    ) -> [String: [Int: MappableMacParam]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode(
                [String: [String: String]].self, from: data)
        else { return [:] }
        var out: [String: [Int: MappableMacParam]] = [:]
        for (presetKey, table) in raw {
            var converted: [Int: MappableMacParam] = [:]
            for (ccStr, paramStr) in table {
                if let cc = Int(ccStr),
                   let param = MappableMacParam(rawValue: paramStr) {
                    converted[cc] = param
                }
            }
            if !converted.isEmpty { out[presetKey] = converted }
        }
        return out
    }

    private static func saveCCMappingLibrary(
        _ library: [String: [Int: MappableMacParam]],
        defaultsKey: String
    ) {
        var raw: [String: [String: String]] = [:]
        for (presetKey, table) in library {
            var stringTable: [String: String] = [:]
            for (cc, param) in table {
                stringTable[String(cc)] = param.rawValue
            }
            raw[presetKey] = stringTable
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Unload + reload the currently-hosted AU. Useful when a load
    /// happens to land in a silent state and a fresh instantiation is
    /// the cheapest recovery.
    func reloadHostedInstrument() {
        guard let preset = currentPreset,
              let desc = preset.state().hostedAudioUnit else { return }
        audio.loadHostedInstrument(desc)
    }

    /// Load a SWAM/AuMo hosted AU by 4-char subType (e.g. "Sva3" Viola,
    /// "Svl3" Violin) — used by the audition `loadAU` event to A/B bases.
    /// The current `hostedAUParams` (bow timbre) re-apply to the new slots.
    func loadHostedAU(subType: String) {
        audio.loadHostedInstrument(
            AudioEngine.HostedAUDescriptor(type: "aumu", subType: subType,
                                           manufacturer: "AuMo"))
    }

    // MARK: - Hosted AU UI

    /// Holds the AU view window open after `openHostedInstrumentWindow()`.
    private var hostedAUWindow: NSWindow?
    private var hostedAUWindowDelegate: HostedAUWindowDelegate?

    func openHostedInstrumentWindow() {
        if let win = hostedAUWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let au = audio.hostedAUAudioUnit else { return }
        let titleHint = currentPreset?.label ?? "Hosted AU"
        au.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self else { return }
                let content: NSViewController
                if let vc {
                    content = vc
                } else {
                    let label = NSTextField(labelWithString:
                        "This Audio Unit does not expose a view controller.")
                    label.alignment = .center
                    let placeholder = NSViewController()
                    placeholder.view = label
                    content = placeholder
                }
                let window = NSWindow(contentViewController: content)
                window.title = titleHint
                window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
                window.isReleasedWhenClosed = false
                let delegate = HostedAUWindowDelegate { [weak self] in
                    self?.hostedAUWindow = nil
                    self?.hostedAUWindowDelegate = nil
                }
                window.delegate = delegate
                self.hostedAUWindowDelegate = delegate
                self.hostedAUWindow = window
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Snapshot the running SWAM's configured `fullStateForDocument` (after
    /// assigning the MIDI CCs in its own UI) and bake it into
    /// `SwamDefaultState.swift`, so `.swamViola` restores it on every launch.
    ///
    /// DEV-ONLY: this writes into the source tree, resolved from `#filePath`, so
    /// it only works from a source/debug build (release builds strip the path).
    /// Rebuild after capturing to compile the new blob in.
    func captureSwamState() {
        guard let data = audio.captureHostedAUFullState() else {
            swamCaptureStatus = "Capture failed — no SWAM AU loaded."
            return
        }
        let b64 = data.base64EncodedString()
        let source = """
        import Foundation

        /// Captured SWAM Violin AU `fullStateForDocument` (binary plist, base64).
        ///
        /// This carries SWAM's OPAQUE encoded state — notably the per-control MIDI
        /// CC assignments (Expression / Vibrato Depth / Bow Pressure / Bow/Pizz
        /// Position), which SWAM does NOT expose as AU parameters and so can't be
        /// set via the `hostedAUParams` dictionary. Regenerated by
        /// `AppController.captureSwamState()` (the "Capture SWAM State" button).
        ///
        /// DO NOT hand-edit the base64; regenerate it via the capture button.
        enum SwamDefaultState {
            /// base64 of the binary-plist `fullStateForDocument`. Empty until captured.
            static let violinBase64 = "\(b64)"

            /// Decoded state ready for `AudioEngine.setHostedAUFullState`, or nil.
            static var violin: Data? {
                violinBase64.isEmpty ? nil : Data(base64Encoded: violinBase64)
            }
        }

        """
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("SwamDefaultState.swift")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            swamCaptureStatus =
                "Captured \(data.count) bytes → SwamDefaultState.swift. Rebuild to bake it in."
            NSLog("Starpad: \(swamCaptureStatus)")
        } catch {
            swamCaptureStatus = "Capture write failed: \(error.localizedDescription)"
            NSLog("Starpad: \(swamCaptureStatus)")
        }
    }
}
