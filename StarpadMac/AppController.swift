import AppKit
import Combine
import CoreAudioKit
import Foundation
import StarpadCore

/// Mac-side wiring. The Mac is a MIDI sound module that receives MPE
/// input over USB-MIDI and owns every Mac-side knob: the sarangi model
/// (String voice) tuning + physics, the sympathetic-string table, and
/// the Fret Pad layout. The played voice is the sarangi **String model**
/// (`StringVoiceSource` / `BowEngine`) — the only voice. The iPad is
/// purely a MIDI controller; the one thing this side pushes to it is the
/// Pitch Pad scale + Fret Pad layout, sent as SysEx over USB (see
/// `startScaleSync`); tilts come back as a raw report the Mac interprets.
///
/// Architecture:
///   `MIDIInput`  →  `AudioEngine` (String voice)  →  speakers
///   `AppController` holds settings and pushes them into `AudioEngine`
///   on change. No `NoteManager` on the Mac — that class is iPad-only.

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
    /// The scale/tonic model, no longer shown as its own surface — the Fret
    /// Pad reads from it. Owns its own MPE-style MIDIEngine.
    let pitchPad: PitchPadEngine
    /// Fret Pad tab — the sole playing surface: vertical fret segments whose
    /// x-position is their pitch, with onset-only snapping. Reuses a
    /// `PitchPadEngine` as the MPE emitter. `pitchPad` (no longer shown) is kept
    /// as the underlying scale/tonic model that the Fret Pad reads from.
    let fretPad: PitchPadEngine
    /// Computer-keyboard note input. App-wide while enabled; plays the
    /// active scale through `pitchPad`. See `KeyboardNotePlayer`.
    let keyboard: KeyboardNotePlayer

    /// The Fret Pad's fret segments (Mac-only). Auto-saved to disk (debounced)
    /// by a sink in `start()`; edited live from the tab.
    @Published var fretArrangement = FretArrangement(segments: [])

    /// Which playing surface the iPad shows. The Mac drives it; it rides the
    /// synced SysEx state to the iPad. Persisted.
    @Published var ipadLayout: PadLayout =
        PadLayout(rawValue: UserDefaults.standard
            .integer(forKey: "starpad.ipadLayout")) ?? .pitchPad {
        didSet {
            UserDefaults.standard.set(ipadLayout.rawValue, forKey: "starpad.ipadLayout")
        }
    }

    /// TILT CONTROL bindings (2026-07-24), Mac-owned and Mac-EVALUATED
    /// (`applyTiltAxis`): per tilt 1/2/3 an arbitrary set of mapped
    /// parameters with configurable endpoints, edited in the Controls
    /// tab. Nothing syncs to the iPad — the controller streams only its
    /// raw tilt report (`TiltAxisWire`), and edits here take effect
    /// immediately. Persisted via the `DimensionMapping` store.
    @Published var tiltMapping: DimensionMapping = DimensionMapping.load() {
        didSet {
            tiltMapping.save()
            rebuildTiltEvalSnapshot()
        }
    }

    /// Raw-tilt evaluation (2026-07-24): the controller streams only its
    /// three calibrated tilt values (`TiltAxisWire`); the Mac evaluates
    /// its own tilt bindings here. Per axis: the bound targets + transfer
    /// curves, in a MIDI-thread-readable snapshot (delivery arrives on the
    /// CoreMIDI thread). A target is a composite parameter OR any single
    /// registry parameter.
    private var tiltEvalByAxis: [[(target: MapTarget,
                                   binding: DimensionBinding)]] = [[], [], []]

    private func rebuildTiltEvalSnapshot() {
        var byAxis: [[(MapTarget, DimensionBinding)]] = [[], [], []]
        for target in tiltMapping.boundTargets {
            for (axis, dim) in TiltAxisWire.dims.enumerated() {
                if let b = tiltMapping.mapping(for: target).binding(for: dim) {
                    byAxis[axis].append((target, b))
                }
            }
        }
        compositeLock.lock()
        tiltEvalByAxis = byAxis
        compositeLock.unlock()
    }

    /// Apply one raw tilt value (axis 0…2, 0…1 normalized): evaluate each
    /// bound target's transfer curve in the target's native units and
    /// drive it — a composite through `applyComposite`, a single parameter
    /// through the unified apply. Called on the MIDI thread (all
    /// downstream paths are thread-safe).
    private func applyTiltAxis(_ axis: Int, _ value01: Double) {
        guard axis >= 0, axis < 3 else { return }
        compositeLock.lock()
        let bindings = tiltEvalByAxis[axis]
        compositeLock.unlock()
        var rebuild: [String: Double] = [:]
        for (target, binding) in bindings {
            let out = binding.evaluate(value01)          // native units
            switch target.kind {
            case .composite(let slot):
                applyComposite(slot: slot, value: out)
            case .param(let key):
                if let pending = applyParamToVoice(key, out) {
                    rebuild[key] = pending
                }
            }
        }
        queueRebuildValues(rebuild)
    }

    /// COMPOSITE PARAMETERS (2026-07-24): named 0…1 controls built from
    /// BASE parameters (the Sarangi-tab physics scalars + the runtime
    /// pseudo-keys) — each member sweeps its own lo→hi range as the
    /// composite goes 0→1. Edited in the Controls tab; tilts bind to them
    /// by name. Ships with Taraf Purity / Taraf Decay / Tone Tilt as
    /// editable defaults. Persisted as JSON.
    @Published var composites: [CompositeParam] = AppController.loadComposites() {
        didSet {
            AppController.saveComposites(composites)
            rebuildCompositeSnapshot()
        }
    }

    private static let compositesKey = "starpad.compositeParams.v1"

    private static func loadComposites() -> [CompositeParam] {
        if let data = UserDefaults.standard.data(forKey: compositesKey),
           let c = try? JSONDecoder().decode([CompositeParam].self, from: data) {
            return c
        }
        return CompositeParam.defaults()
    }

    private static func saveComposites(_ c: [CompositeParam]) {
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: compositesKey)
        }
    }

    /// MIDI-thread-readable snapshot of the composite member sets, keyed
    /// by slot CC (the delivery from `AudioEngine.onCompositeCC` arrives
    /// on the CoreMIDI thread).
    private let compositeLock = NSLock()
    private var compositeMembersByCC: [UInt8: [CompositeMember]] = [:]
    /// Rebuild-path member values pending a (debounced) main-thread apply.
    private var pendingRebuildMembers: [String: Double] = [:]
    private var rebuildFlushScheduled = false

    /// RESTING PARAMETER VALUES (2026-07-24 unification) for every `.live`
    /// and `.hybrid` registry parameter — the ones whose value does NOT
    /// live in the `bowed_string.json` override dict (`.rebuild`
    /// parameters are stored by `StringParamStore`). Edited in the
    /// Parameters tab, applied instantly to the String voice. Composites
    /// and direct tilt bindings modulate ON TOP of these; a parameter
    /// nothing is driving sits at its resting value. Persisted as JSON
    /// (key inherited from the old control-defaults dict).
    @Published var paramValues: [String: Double] = AppController.loadParamValues() {
        didSet {
            AppController.saveParamValues(paramValues)
            applyRestingParams()
        }
    }

    private static let paramValuesKey = "starpad.controlDefaults.v1"

    private static func loadParamValues() -> [String: Double] {
        var d: [String: Double] = [:]
        if let data = UserDefaults.standard.data(forKey: paramValuesKey),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            // Only keys the registry still knows; the pre-unification
            // scaler keys (`bow_jaw_gain`, `bow_vibrato`) drop out here —
            // their behavior now belongs to `bow_taraf_jawari` /
            // `bow_vib_cents`, whose resting values come from
            // `restFraction × headroom`.
            for (k, v) in saved where ParamRegistry.spec(k)?.apply != .rebuild {
                if ParamRegistry.spec(k) != nil { d[k] = v }
            }
        }
        return d
    }

    private static func saveParamValues(_ d: [String: Double]) {
        if let data = try? JSONEncoder().encode(d) {
            UserDefaults.standard.set(data, forKey: paramValuesKey)
        }
    }

    // MARK: - Unified parameter access (Parameters tab / composites / tilts)

    /// The build-time headroom of a `.hybrid` parameter: the value its
    /// tables were built with (override, else artifact, else the authored
    /// default). Cached under `compositeLock` so the MIDI thread can read
    /// it without touching the `@Published` store.
    private var hybridHeadroom: [String: Double] = [:]

    /// Re-read the headroom cache. `values` defaults to the store's current
    /// dict; pass one explicitly from a `@Published` sink (which fires
    /// before the store's own property is updated).
    private func refreshHybridHeadroom(from values: [String: Double]? = nil) {
        let v = values ?? stringParams.values
        var h: [String: Double] = [:]
        for spec in ParamRegistry.all where spec.apply == .hybrid {
            h[spec.key] = v[spec.key]
                ?? stringParams.artifactValue(spec.key) ?? spec.def
        }
        compositeLock.lock()
        hybridHeadroom = h
        compositeLock.unlock()
    }

    private func headroom(_ key: String) -> Double {
        compositeLock.lock()
        let h = hybridHeadroom[key]
        compositeLock.unlock()
        return h ?? ParamRegistry.spec(key)?.def ?? 0
    }

    /// The resting value of any parameter, in native units: `.rebuild`
    /// parameters read the physics store (artifact + overrides), `.live`
    /// and `.hybrid` read `paramValues` — a hybrid with no stored value
    /// rests at `restFraction × headroom` (full fitted buzz, no vibrato).
    func paramValue(_ key: String) -> Double {
        guard let spec = ParamRegistry.spec(key) else { return 0 }
        switch spec.apply {
        case .rebuild:
            return stringParams.values[key] ?? spec.def
        case .live:
            return paramValues[key] ?? spec.def
        case .hybrid:
            if let v = paramValues[key] { return v }
            return (spec.restFraction ?? 0) * headroom(key)
        }
    }

    /// The value `paramValue` falls back to — what a reset restores.
    func paramDefault(_ key: String) -> Double {
        guard let spec = ParamRegistry.spec(key) else { return 0 }
        switch spec.apply {
        case .rebuild: return stringParams.artifactValue(key) ?? spec.def
        case .live:    return spec.def
        case .hybrid:  return (spec.restFraction ?? 0) * headroom(key)
        }
    }

    func paramIsDefault(_ key: String) -> Bool {
        abs(paramValue(key) - paramDefault(key)) <= 1e-9
    }

    /// Set a parameter's resting value (Parameters tab / audition script).
    /// Routes to whichever store owns it and applies to the voice.
    func setParamValue(_ key: String, _ value: Double) {
        guard let spec = ParamRegistry.spec(key) else { return }
        switch spec.apply {
        case .rebuild:
            stringParams.set(key, value)
        case .live:
            paramValues[key] = value           // didSet applies
        case .hybrid:
            // Above the built headroom the build scalar has to move (that
            // rebuilds); at or below it the kernel's scaler covers it.
            if value > headroom(key) + 1e-12 {
                stringParams.set(key, value)   // raises the headroom
                refreshHybridHeadroom()
            }
            paramValues[key] = value
        }
    }

    /// Restore a parameter to its default and re-apply.
    func resetParam(_ key: String) {
        guard let spec = ParamRegistry.spec(key) else { return }
        switch spec.apply {
        case .rebuild:
            stringParams.reset(key)
        case .live:
            paramValues.removeValue(forKey: key)
        case .hybrid:
            // Drop any RAISED headroom first, then the resting value —
            // back to `restFraction × artifact`. Only touch the physics
            // store if the headroom actually moved: resetting a hybrid
            // that never went above its built value (the common case —
            // double-clicking "vibrato depth") must not cost a rebuild.
            if stringParams.values[key] != stringParams.artifactValue(key) {
                stringParams.reset(key)
                refreshHybridHeadroom()
            }
            paramValues.removeValue(forKey: key)
        }
    }

    /// Reset every parameter to the shipped default: clears the physics
    /// overrides (the Sarangi Live artifact) and every resting value.
    func resetAllParams() {
        stringParams.resetToDefault()
        refreshHybridHeadroom()
        paramValues.removeAll()
    }

    /// Push every `.live`/`.hybrid` resting value to the String voice.
    /// Called at startup, after a Parameters-tab edit, and after a rebuild
    /// that could have moved a hybrid's headroom. (Composites and tilts
    /// re-assert their own values on the next event, so this is the
    /// baseline.)
    func applyRestingParams() {
        for spec in ParamRegistry.storedKeys {
            _ = applyParamToVoice(spec.key, paramValue(spec.key))
        }
    }

    /// THE unified apply: push `value` (native units) for `key` into the
    /// voice. Returns nil when it took effect immediately, or the value
    /// the caller must funnel through the debounced rebuild path (a
    /// `.rebuild` parameter, or a `.hybrid` pushed above its headroom).
    /// Thread-safe — callable from the MIDI thread.
    @discardableResult
    func applyParamToVoice(_ key: String, _ value: Double) -> Double? {
        guard let spec = ParamRegistry.spec(key) else { return nil }
        switch spec.apply {
        case .live:
            audio.setStringControlParam(key, value)
            return nil
        case .rebuild:
            return value
        case .hybrid:
            guard let scaler = ParamRegistry.hybridScaler(key) else { return value }
            let h = headroom(key)
            guard h > 1e-12 else { return value > 1e-12 ? value : nil }
            if value > h + 1e-12 {
                audio.setStringHybridScaler(scaler, 1.0)
                return value                    // needs a taller headroom
            }
            audio.setStringHybridScaler(scaler, value / h)
            return nil
        }
    }

    // jt overload watchdog (see start())
    private var jtStatsTimer: Timer?
    private var lastJtDrops = 0.0
    private var lastJtFlat = 0.0
    private var lastRenderOverruns: UInt64 = 0

    // MARK: - Sarangi model
    //
    // The played voice is the ported `SarangiKit` **String model** (`BowEngine`
    // + `CBowKernel`), owned by `sarangi` (`SarangiStore`): raga + tonic and the
    // editable sympathetic-string table live there (independent of the played
    // Pitch Pad scale). The tarab rows tune the String voice's in-kernel taraf.
    // Edited in the Tarab tab; the String physics scalars in the Sarangi tab.

    /// The ported sarangi model's editable state + engine bridge (tarab tuning).
    let sarangi: SarangiStore

    /// Backing store for the `.rebuild` (and `.hybrid` headroom) half of
    /// the parameter list: the `bowed_string.json` scalars + persisted
    /// overrides. Reached through `setParamValue`/`paramValue` from the
    /// Parameters tab; pushes into `AudioEngine.stringVoiceOverrides` with
    /// a debounced engine rebuild.
    let stringParams: StringParamStore

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
        // The scale/tonic model, no longer shown as its own surface — the Fret
        // Pad reads from it. Kept alive so scale edits + the keyboard still work.
        self.pitchPad = PitchPadEngine(audio: audio)
        // The Fret Pad is the sole playing surface, driven off `pitchPad`'s scale.
        self.fretPad = PitchPadEngine(audio: audio)
        self.fretPad.tonicMidi = self.pitchPad.tonicMidi
        // Fret Pad Snap default: 24 px (not the shared 16) — fitted to real
        // iPad onsets (2026-07-16 phrase recording: worst onset 14.9 px, so
        // 16 left zero headroom; 24 ≈ 43¢ stays under the 40 px minimum fret
        // gap). Syncs to the iPad while the Fret Pad layout is active.
        self.fretPad.marginPixels = 24
        // Computer-keyboard player drives the scale engine directly.
        self.keyboard = KeyboardNotePlayer(engine: self.pitchPad)
        // Restore the last-edited arrangement, or build a starter from the
        // current scale's degrees. (Assigning here doesn't fire the autosave
        // sink — that's wired in `start()`.)
        self.fretArrangement = FretArrangementStore.loadCurrent()
            ?? FretArrangement.defaultArrangement(
                degrees: scaleDegrees(from: self.pitchPad.scale))
        // The sarangi model owns its own tuning + strings (independent of the
        // Pitch Pad). Constructing the store loads the persisted/default state
        // and builds the initial tarab tuning.
        self.sarangi = SarangiStore(audio: audio)
        // The String voice's physics overrides (seeds the engine's override
        // dict before the first BowEngine is built below).
        self.stringParams = StringParamStore(audio: audio)

        // Restore the output device rate on a clean quit (⌘Q / menu Quit); the
        // engine forced it to 44.1 kHz to drop the output resampler. SIGKILL
        // from Xcode's Stop button skips this.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.audio.restoreOutputDeviceRate()
        }

        // The String model is the only voice — arm it. It builds off the tarab
        // tuning + tonic that `SarangiStore` just pushed. The Mac pads hold a
        // flat CC11 per note (no tilt source); 32 ≈ the fitted expr median
        // (the surfaces span ~16 dB around it).
        audio.setSarangiModelVoiceEnabled(true)
        pitchPad.macExpressionLevel = 32
        fretPad.macExpressionLevel = 32

        // Now that all stored properties are set, wire the simulator's
        // CC route back to this controller so its in-process MIDI hits
        // the same handling as a real iPad-over-USB note.
        simulator.controller = self

        // The Fret Pad is the only playing surface, so the iPad always performs
        // it. Force the synced layout (a stale persisted value could be another
        // pad that no longer exists on either side).
        ipadLayout = .fretPad
    }

    /// Combine subscriptions that push the Pitch Pad scale to the iPad.
    private var cancellables = Set<AnyCancellable>()

    func start() {
        midi.start()
        midiIn.start()
        simulator.start()
        pitchPad.start()
        fretPad.start()
        audition.start()
        startScaleSync()
        // Composite parameters + raw-tilt evaluation: snapshots for the
        // MIDI-thread deliveries, then accept the controller's raw tilt
        // report (the Mac evaluates its own tilt bindings) and direct
        // slot-CC drives (auditions / external hardware).
        rebuildCompositeSnapshot()
        rebuildTiltEvalSnapshot()
        refreshHybridHeadroom()      // build depths behind the hybrid knobs
        applyRestingParams()         // resting values for every live param
        // A physics edit (Parameters tab, preset load, audition script)
        // can move a hybrid parameter's build headroom — keep the cache in
        // step. `@Published` fires before the store's own property is
        // updated, so read the value the sink carries.
        stringParams.$values
            .sink { [weak self] v in self?.refreshHybridHeadroom(from: v) }
            .store(in: &cancellables)
        audio.onTiltAxis = { [weak self] axis, value in
            self?.applyTiltAxis(axis, value)
        }
        audio.onCompositeCC = { [weak self] cc, value in
            self?.applyComposite(slotCC: cc, value: value)
        }
        // jt overload watchdog: the String voice's async jawari web drops
        // drive blocks / flat-fills when it misses its realtime budget —
        // audible clicking. Log only when the counters GROW.
        jtStatsTimer = Timer.scheduledTimer(withTimeInterval: 5.0,
                                            repeats: true) { [weak self] _ in
            guard let self else { return }
            if let s = self.audio.stringVoiceJtStats(), s.on > 0.5 {
                if s.drops > self.lastJtDrops || s.flat > self.lastJtFlat {
                    NSLog("Starpad: jt OVERLOAD — +%.0f dropped blocks, +%.0f flat-filled samples (totals %.0f/%.0f, fifo %.0f)",
                          s.drops - self.lastJtDrops, s.flat - self.lastJtFlat,
                          s.drops, s.flat, s.fill)
                    self.lastJtDrops = s.drops
                    self.lastJtFlat = s.flat
                } else if s.drops < self.lastJtDrops || s.flat < self.lastJtFlat {
                    // engine rebuilt — counters reset
                    self.lastJtDrops = s.drops
                    self.lastJtFlat = s.flat
                }
            }
            // main-callback deadline: overruns glitch at the DEVICE (the
            // audition WAV can't show them) — log whenever they grow
            if let r = self.audio.stringVoiceRenderStats() {
                if r.overruns > self.lastRenderOverruns {
                    NSLog("Starpad: render OVERRUN — +%llu late callbacks (worst %.2f ms this period, total %llu/%llu)",
                          r.overruns - self.lastRenderOverruns, r.maxMs,
                          r.overruns, r.callbacks)
                }
                self.lastRenderOverruns = r.overruns
            }
        }
        // Keep the Fret Pad's tonic locked to the scale engine's. Independent
        // of `startScaleSync` (which pushes scale state to the iPad).
        pitchPad.$tonicMidi
            .sink { [weak self] in self?.fretPad.tonicMidi = $0 }
            .store(in: &cancellables)

        // Auto-save the Fret Pad arrangement. Debounced so a drag-edit
        // doesn't write to disk every frame.
        $fretArrangement
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { FretArrangementStore.saveCurrent($0) }
            .store(in: &cancellables)

        // Drone-button config: the 4 ratios ride the arrangement; the tonic
        // is the PLAYED (Fret Pad) tonic, so the drones harmonize with the
        // melody regardless of the tarab tuning. A real change rebuilds the
        // String engine (the jt web gets a row at every configured pitch),
        // so this is debounced and deduplicated.
        let droneTonicHz = { (midi: Int) -> Double in
            440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
        }
        audio.setDroneConfig(ratios: fretArrangement.droneRatios,
                             tonicHz: droneTonicHz(pitchPad.tonicMidi))
        Publishers.CombineLatest(
            $fretArrangement.map(\.droneRatios).removeDuplicates(),
            pitchPad.$tonicMidi.removeDuplicates()
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] ratios, tonicMidi in
            self?.audio.setDroneConfig(ratios: ratios,
                                       tonicHz: droneTonicHz(tonicMidi))
        }
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
            fretPad.$marginPixels.map { _ in () }.eraseToAnyPublisher(),
            $fretArrangement.map { _ in () }.eraseToAnyPublisher(),
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
        // The Fret Pad is the only surface now; its Snap slider is the margin.
        let margin = ipadLayout == .fretPad ? fretPad.marginPixels
                                            : pitchPad.marginPixels
        let state = SyncedScaleState(points: pitchPad.scale.points,
                                     tonicMidi: pitchPad.tonicMidi,
                                     marginPixels: margin,
                                     layout: ipadLayout)
        // Match the iPad's "Starpad Scale" virtual destination loosely on
        // "Starpad" — the USB bridge may prefix the endpoint name with the
        // device name. `sendSysEx` falls back to all destinations if even
        // this matches nothing, so a renamed endpoint can't block sync.
        midi.sendSysEx(PitchScaleSysEx.encode(state), toDestinationsMatching: "Starpad")
        // The Fret Pad's segment layout is its own state (not derivable from
        // the scale), so push it as a second SysEx message while it's active.
        if ipadLayout == .fretPad {
            midi.sendSysEx(FretArrangementSysEx.encode(fretArrangement),
                           toDestinationsMatching: "Starpad")
        }
    }

    // MARK: - Composite parameters (2026-07-24)

    private func rebuildCompositeSnapshot() {
        compositeLock.lock()
        compositeMembersByCC = Dictionary(
            uniqueKeysWithValues: composites.map { ($0.slotCC, $0.members) })
        compositeLock.unlock()
    }

    /// Apply a composite's value 0-1: every member sweeps its lo-hi range
    /// through the unified apply. Live (and hybrid-downward) members take
    /// effect immediately — thread-safe engine setters, chunk-rate
    /// smoothed downstream; members that need a rebuild go through the
    /// String-override path on main, debounced (that path persists +
    /// rebuilds the engine — too heavy per-CC). Called on the MIDI thread
    /// for tilt-driven values and on main for UI/audition drives.
    func applyComposite(slotCC: UInt8, value: Double) {
        compositeLock.lock()
        let members = compositeMembersByCC[slotCC] ?? []
        compositeLock.unlock()
        guard !members.isEmpty else { return }
        var rebuild: [String: Double] = [:]
        for m in members {
            if let pending = applyParamToVoice(m.key, m.value(at: value)) {
                rebuild[m.key] = pending
            }
        }
        queueRebuildValues(rebuild)
    }

    /// Funnel rebuild-path values (from a composite or a direct tilt
    /// binding) into one debounced main-thread flush. Thread-safe.
    private func queueRebuildValues(_ values: [String: Double]) {
        guard !values.isEmpty else { return }
        compositeLock.lock()
        pendingRebuildMembers.merge(values) { _, new in new }
        let schedule = !rebuildFlushScheduled
        rebuildFlushScheduled = true
        compositeLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.compositeLock.lock()
            let flush = self.pendingRebuildMembers
            self.pendingRebuildMembers.removeAll()
            self.rebuildFlushScheduled = false
            self.compositeLock.unlock()
            for (key, v) in flush {
                self.stringParams.setAuditionParam(key, v)
            }
            self.refreshHybridHeadroom()
        }
    }

    /// Convenience: apply by slot index.
    func applyComposite(slot: Int, value: Double) {
        guard slot >= 0, slot < CompositeParam.slotCCs.count else { return }
        applyComposite(slotCC: CompositeParam.slotCCs[slot], value: value)
    }

    /// The user-facing name for a tilt target: a composite slot shows its
    /// composite's name (an empty slot shows "Composite N (empty)"), a
    /// parameter shows its registry label. No CC numbers.
    func targetDisplayName(_ t: MapTarget) -> String {
        guard let slot = t.compositeSlot else { return t.label }
        if let c = composites.first(where: { $0.slot == slot }) {
            return c.name
        }
        return "Composite \(slot + 1) (empty)"
    }

    /// Parameter catalog for the composite editor + tilt Add menus: every
    /// registry parameter, grouped, with its native range.
    static let paramCatalog: [(key: String, label: String,
                               lo: Double, hi: Double)] =
        ParamRegistry.all.map {
            (key: $0.key, label: $0.label, lo: $0.lo, hi: $0.hi)
        }

    static func paramInfo(_ key: String)
        -> (key: String, label: String, lo: Double, hi: Double) {
        paramCatalog.first { $0.key == key }
            ?? (key: key, label: key, lo: 0, hi: 1)
    }

    // MARK: - Composite editing (Controls tab)

    /// Create a composite on the next free slot (nil when all 8 in use).
    @discardableResult
    func addComposite() -> CompositeParam? {
        let used = Set(composites.map(\.slot))
        guard let slot = (0..<CompositeParam.maxSlots).first(where: { !used.contains($0) })
        else { return nil }
        let c = CompositeParam(name: "Composite \(slot + 1)", slot: slot,
                               members: [])
        composites.append(c)
        return c
    }

    func removeComposite(_ id: CompositeParam.ID) {
        composites.removeAll { $0.id == id }
    }

    func renameComposite(_ id: CompositeParam.ID, to name: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        composites[i].name = name
    }

    func addCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }),
              !composites[i].members.contains(where: { $0.key == key })
        else { return }
        let info = AppController.paramInfo(key)
        composites[i].members.append(
            CompositeMember(key: key, lo: info.lo, hi: info.hi))
    }

    func removeCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        composites[i].members.removeAll { $0.key == key }
    }

    func setCompositeMemberRange(_ id: CompositeParam.ID, key: String,
                                 lo: Double, hi: Double) {
        guard let i = composites.firstIndex(where: { $0.id == id }),
              let j = composites[i].members.firstIndex(where: { $0.key == key })
        else { return }
        composites[i].members[j].lo = lo
        composites[i].members[j].hi = hi
    }

    // MARK: - Tilt-control binding edits (Controls tab / Parameters tab)

    /// The targets bound to one tilt (composites first, then parameters).
    func tiltBindings(for dim: InputDimension) -> [MapTarget] {
        tiltMapping.targets(for: dim)
    }

    /// Every tilt a given target is bound to — the Parameters tab's
    /// per-row mapping badge reads this.
    func tiltDimensions(for target: MapTarget) -> [InputDimension] {
        TiltAxisWire.dims.filter { tiltMapping.isConnected(target, $0) }
    }

    /// Bind a target to a tilt over its full native range. For a parameter
    /// whose resting value sits at one end (vibrato depth 0, jawari buzz
    /// full) that reads naturally; endpoints are draggable afterwards.
    func addTiltBinding(_ target: MapTarget, dim: InputDimension) {
        var m = tiltMapping
        let r = target.defaultRange
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        pm.bindings.append(DimensionBinding(dimension: dim,
                                            rangeMin: r.0, rangeMax: r.1))
        m.mappings[target.storageKey] = pm
        tiltMapping = m
    }

    func removeTiltBinding(_ target: MapTarget, dim: InputDimension) {
        var m = tiltMapping
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        m.mappings[target.storageKey] = pm
        tiltMapping = m
        // A parameter that is no longer driven must fall back to its
        // resting value — nothing else will push it.
        if let key = target.paramKey, pm.bindings.isEmpty {
            _ = applyParamToVoice(key, paramValue(key))
        }
    }

    func toggleTiltBinding(_ target: MapTarget, dim: InputDimension) {
        if tiltMapping.isConnected(target, dim) {
            removeTiltBinding(target, dim: dim)
        } else {
            addTiltBinding(target, dim: dim)
        }
    }

    /// Set a binding's endpoints. `fromCenter` = the rest-zero shape used
    /// by the taraf axes: flat at `lo` through the resting half of the
    /// throw, sweeping to `hi` past neutral — `(0,lo) (0.5,lo) (1,hi)`.
    /// Off = plain linear `(0,lo) (1,hi)`.
    func setTiltBinding(_ target: MapTarget, dim: InputDimension,
                        lo: Double, hi: Double, fromCenter: Bool) {
        var m = tiltMapping
        var pm = m.mapping(for: target)
        pm.bindings.removeAll { $0.dimension == dim }
        let pts = fromCenter
            ? [ControlPoint(x: 0, y: lo), ControlPoint(x: 0.5, y: lo),
               ControlPoint(x: 1, y: hi)]
            : [ControlPoint(x: 0, y: lo), ControlPoint(x: 1, y: hi)]
        pm.bindings.append(DimensionBinding(dimension: dim, controlPoints: pts))
        m.mappings[target.storageKey] = pm
        tiltMapping = m
    }

    /// Composites a parameter is a member of (the Parameters tab's
    /// mapping menu ticks these).
    func compositesContaining(_ key: String) -> [CompositeParam] {
        composites.filter { $0.members.contains { $0.key == key } }
    }

    func toggleCompositeMember(_ id: CompositeParam.ID, key: String) {
        guard let i = composites.firstIndex(where: { $0.id == id }) else { return }
        if composites[i].members.contains(where: { $0.key == key }) {
            removeCompositeMember(id, key: key)
        } else {
            addCompositeMember(id, key: key)
        }
    }

    // MARK: - Presets

    /// Capture one half of the rig (or both). The **instrument** scope is
    /// the sound — the sarangi document, the physics overrides and every
    /// parameter's resting value; the **controls** scope is the mapping —
    /// composites and tilt bindings. They are saved separately because
    /// swapping a sound should not cost you your tilt setup, and vice
    /// versa.
    func capturePreset(name: String, scope: PresetScope) -> StarpadPreset {
        var p = StarpadPreset()
        p.name = name
        p.kind = scope
        p.savedAt = ISO8601DateFormatter().string(from: Date())
        if scope.covers(.instrument) {
            p.instrument = sarangi.state
            p.stringOverrides = stringParams.overridesSnapshot
            p.paramValues = paramValues
        }
        if scope.covers(.controls) {
            p.composites = composites
            p.tiltMapping = tiltMapping
        }
        return p
    }

    /// Apply the parts of `p` that fall inside `scope`. Sections the file
    /// lacks are skipped, so a controls preset never disturbs the
    /// instrument — and an older combined `.starpad` can be loaded as
    /// either half.
    func applyPreset(_ p: StarpadPreset, scope: PresetScope = .all) {
        if scope.covers(.instrument) {
            if let inst = p.instrument {
                sarangi.replaceState(inst)
            }
            if let ov = p.stringOverrides {
                stringParams.replaceOverrides(ov)
                refreshHybridHeadroom()
            }
            if let pv = p.paramValues {
                // Keep only keys this build still knows; `didSet` re-applies.
                paramValues = pv.filter {
                    guard let spec = ParamRegistry.spec($0.key) else { return false }
                    return spec.apply != .rebuild
                }
            }
        }
        if scope.covers(.controls) {
            if let c = p.composites { composites = c }
            if let t = p.tiltMapping { tiltMapping = t }
        }
    }

    func savePreset(to url: URL, name: String, scope: PresetScope) throws {
        try capturePreset(name: name, scope: scope).encoded().write(to: url)
    }

    /// Load and apply, returning the decoded document so the caller can
    /// report what landed (`sections(in:)`) — or that nothing did.
    @discardableResult
    func loadPreset(from url: URL, scope: PresetScope) throws -> StarpadPreset {
        let p = try StarpadPreset.decode(Data(contentsOf: url))
        applyPreset(p, scope: scope)
        return p
    }

    /// Public entry for the iPad-simulator's in-process CC delivery. CC → Mac
    /// param mappings were removed with the master-FX bus; expression and the
    /// tilt axes reach the String voice through the MIDI path directly, so this
    /// is now a no-op kept for the simulator's call site.
    func handleSimulatorCC(cc: Int, value: Int) {}

    /// Programmatic entry point used by audition scores' `voiceParam`
    /// events. Names match the parameters below; values are passed through
    /// in each parameter's natural units. Unknown names log and noop so a
    /// typo in a score doesn't take down the runner.
    func setVoiceParam(name: String, value: Double) {
        switch name {
        // Drone buttons: "drone1".."drone4", value > 0.5 = press, else
        // release — lets a score audition the jawari-taraf drones.
        case "drone1", "drone2", "drone3", "drone4":
            let i = Int(String(name.dropFirst(5)))! - 1
            audio.setDronePressed(i, value > 0.5)
        // Tilt performance axes (the iPad tilts' CC71/73/72 targets):
        // purity/decay 0..1, tone tilt -1..1. Runtime playing state —
        // NOT `string.<key>` build scalars (no engine rebuild).
        // Composite parameters (drive the same member sweeps the tilts
        // do; the legacy names map onto the default slots — stringToneTilt
        // keeps its historical -1…1 range):
        case "stringPurity":     applyComposite(slot: 0, value: clamp(value, 0, 1))
        case "stringTarafDecay": applyComposite(slot: 1, value: clamp(value, 0, 1))
        case "stringToneTilt":   applyComposite(slot: 2, value: (clamp(value, -1, 1) + 1) / 2)
        // Generic form: "composite1".."composite8" with value 0…1.
        case let n where n.hasPrefix("composite") && Int(n.dropFirst(9)) != nil:
            applyComposite(slot: Int(n.dropFirst(9))! - 1,
                           value: clamp(value, 0, 1))
        default:
            // Sarangi model params: "sarangi.<paramId>" (the tarab / model
            // document that `SarangiStore` owns — the tarab rows tune the
            // String voice's taraf).
            if name.hasPrefix("sarangi.") {
                if sarangi.setAuditionParam(String(name.dropFirst(8)), value) { return }
                NSLog("Starpad: no sarangi param '\(name.dropFirst(8))'")
                return
            }
            // Any registry parameter: "string.<key>" (historical) or
            // "param.<key>". Routed through the unified setter — the same
            // path the Parameters-tab sliders take — so a scripted sweep
            // shows in the UI, persists like a hand edit, and applies
            // live when the parameter can (`.live` / `.hybrid`).
            for prefix in ["string.", "param."] where name.hasPrefix(prefix) {
                let key = String(name.dropFirst(prefix.count))
                if ParamRegistry.spec(key) != nil {
                    setParamValue(key, value)
                } else {
                    // Unknown to the registry but possibly a real artifact
                    // scalar (the fit can carry keys the editor doesn't
                    // list) — keep the raw override path for those.
                    stringParams.setAuditionParam(key, value)
                }
                return
            }
            NSLog("Starpad: setVoiceParam unknown name '\(name)'")
        }
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }
}
