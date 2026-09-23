import AppKit
import Combine
import CoreAudioKit
import Foundation
import SarangiKit
import TarabdaarCore

/// Mac-side wiring: owns every Mac-side knob (voice physics, tarab table,
/// Fret Pad layout, composites, bindings), evaluates every control axis,
/// and pushes settings into `AudioEngine`. The iPad streams TLP frames in
/// (`MIDIInput` → `TarabLink` → `LinkIngest` → `AudioEngine`); the Mac
/// pushes back the scale + layout (`startScaleSync`) and JOYCON_STATE.

final class AppController: ObservableObject {
    let audio: AudioEngine
    let midi: MIDIEngine
    let midiIn: MIDIInput
    /// The TarabLink host end: `midiIn` reassembles inbound TLP SysEx,
    /// `midi` sends outbound to the peer learned from where the pad's frames
    /// arrive (wired-first until then); frames diff through `ingest`.
    let link = TarabLink(role: .host)
    /// The link's handshake state (up / stale / RTT), for the status pills.
    @Published private(set) var linkStatus = TarabLink.Status()
    let ingest: LinkIngest

    /// Joy-Con / game-controller input, wired in `start()` into the same
    /// funnels the iPad drives (control axes, drone buttons, strum).
    let joyCon = JoyConInput()
    /// The shared scale/tonic model — the Fret Pad reads from it; the
    /// keyboard player and the strum play through it.
    /// THE scale and tonic, shared by `pitchPad` and `fretPad`.
    let tuning: Tuning
    let pitchPad: PitchPadEngine
    /// The Fret Pad engine — the sole playing surface (fret segments whose
    /// x-position is their pitch, onset-only snapping).
    let fretPad: PitchPadEngine
    /// Computer-keyboard note input. App-wide while enabled; plays the
    /// active scale through `pitchPad`. See `KeyboardNotePlayer`.
    let keyboard: KeyboardNotePlayer

    /// The Fret Pad's fret segments (Mac-only). Auto-saved to disk (debounced)
    /// by a sink in `start()`; edited live from the tab.
    @Published var fretArrangement = FretArrangement(segments: [])

    /// The saved layout the working arrangement came from (Layout menu
    /// checkmark); `nil` = unsaved. Hand edits don't clear it. Not persisted.
    @Published var fretLayoutName: String? = nil

    /// Which surface the iPad shows; rides the synced scale state. Persisted
    /// (always forced to `.fretPad` in `init`).
    @Published var ipadLayout: PadLayout =
        PadLayout(rawValue: UserDefaults.standard
            .integer(forKey: "tarabdaar.ipadLayout")) ?? .pitchPad {
        didSet {
            UserDefaults.standard.set(ipadLayout.rawValue, forKey: "tarabdaar.ipadLayout")
        }
    }

    /// The played voice: the String bow (default), or Tanpura / Sitar plucks
    /// at the exact bent onset. NOT persisted — every launch starts on the
    /// String voice; presets can switch it. Live tab picker.
    @Published var mainInstrument: AudioEngine.MainInstrument = .string {
        didSet {
            audio.setMainInstrument(mainInstrument)
        }
    }

    /// Which voice the drone buttons drive: the tanpura (default — press =
    /// pluck, hold = re-pluck cycle, release = ring out) or the sympathetic
    /// jt swell. Persisted; Strings tab.
    @Published var droneVoice: AudioEngine.DroneVoiceMode =
        AudioEngine.DroneVoiceMode(rawValue: UserDefaults.standard
            .string(forKey: "tarabdaar.droneVoice.v1") ?? "") ?? .tanpura {
        didSet {
            UserDefaults.standard.set(droneVoice.rawValue,
                                      forKey: "tarabdaar.droneVoice.v1")
            audio.setDroneVoiceMode(droneVoice)
        }
    }

    @Published var droneSequenceSteps = DroneSequence.normalized(
        UserDefaults.standard.array(forKey: "tarabdaar.droneSequence.v1") as? [Int]
            ?? DroneSequence.defaultSteps) {
        didSet {
            UserDefaults.standard.set(droneSequenceSteps, forKey: "tarabdaar.droneSequence.v1")
            droneSequencer.restart()
        }
    }
    private var droneSequencer = DroneSequence()
    private var droneSequenceTimer: Timer?
    /// Performance register, reset on launch rather than saved with the rig.
    @Published private(set) var tanpuraDroneOctaveRaised = false
    private var droneOctaveButtonDown = false

    private func cancelSequencedDrone() {
        droneSequenceTimer?.invalidate()
        droneSequenceTimer = nil
        if let slot = droneSequencer.cancel() { audio.setDronePressed(slot, false) }
    }

    private func playDroneStep(_ slot: Int, releasing previous: Int?) {
        if let previous { audio.setDronePressed(previous, false) }
        audio.setDronePressed(slot, true, repeating: false)
    }

    private func sequenceDroneButton(_ control: JoyConControl, pressed: Bool,
                                     enabled: Bool = true) {
        if pressed {
            let previous = droneSequencer.heldSlot
            let slot = droneSequencer.press(steps: droneSequenceSteps,
                enabled: enabled, control: control, now: ProcessInfo.processInfo.systemUptime)
            if let slot {
                playDroneStep(slot, releasing: previous)
                scheduleDroneSequenceStep()
            } else if !droneSequencer.isRunning {
                droneSequenceTimer?.invalidate()
                droneSequenceTimer = nil
                if let previous { audio.setDronePressed(previous, false) }
            }
        } else {
            droneSequencer.release(control: control)
        }
    }

    private func scheduleDroneSequenceStep() {
        droneSequenceTimer?.invalidate()
        let timer = Timer(timeInterval: DroneSequence.interval, repeats: false) { [weak self] _ in
            guard let self, self.droneSequencer.isRunning else { return }
            let previous = self.droneSequencer.heldSlot
            if let slot = self.droneSequencer.advanceIfDue(steps: self.droneSequenceSteps,
                now: ProcessInfo.processInfo.systemUptime) {
                self.playDroneStep(slot, releasing: previous)
            }
            self.scheduleDroneSequenceStep()
        }
        droneSequenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Control-axis bindings, Mac-owned and Mac-evaluated (`applyTiltAxis`):
    /// per target a set of curves, one per axis, whose swings about the
    /// target's resting value ADD (`ControlAxisEvaluator`); edited in the
    /// Controls tab. Nothing syncs to the iPad. Persisted.
    @Published var tiltMapping: DimensionMapping = DimensionMapping.load() {
        didSet {
            tiltMapping.save()
            axes.setMapping(tiltMapping)
            axes.reapply()
        }
    }

    /// THE CONTROL-AXIS EVALUATOR: the per-axis binding snapshot, the
    /// strike→acceleration blend (with its 30 Hz weight timer) and the
    /// `.fingerAccel` touch registry all live in `ControlAxisEvaluator`.
    /// This class only feeds it raw axes and applies what it emits.
    let axes = ControlAxisEvaluator()

    /// The live `ctl_fret_warp` value, written only by the `applyParamToVoice`
    /// interception (main); read by the Mac pad, relayed over JOYCON_STATE.
    @Published private(set) var fretFieldWarp: Double = 0

    /// The Mac → iPad JOYCON_STATE mirror: the axes the pad only draws,
    /// plus the four fields it acts on.
    let joyConDisplay = JoyConDisplayRelay()

    /// Every touch currently DOWN with its latest finger pitch, oldest first
    /// — the finger's truth ABOVE the glide queue (parked fingers included).
    func currentTouches() -> [(id: Int, pitchSemis: Double)] {
        axes.currentTouches()
    }

    /// Relay the axis values to the iPad as the latest-wins JOYCON_STATE
    /// frame; the relay sends an acted-on field's edge immediately and paces
    /// the rest.
    private func sendJoyConDisplay() {
        joyConDisplay.push()
    }

    /// Dpad ←/→: step the playing range one octave (clamped). The shift
    /// lives in the shared pad engine — the ONE outbound-pitch point — and
    /// reaches the iPad as the forced JOYCON_STATE `octave` byte. Main thread.
    private func shiftOctave(_ delta: Int) {
        let next = min(max(pitchPad.octaveShift + delta,
                           PitchPadEngine.octaveShiftRange.lowerBound),
                       PitchPadEngine.octaveShiftRange.upperBound)
        guard next != pitchPad.octaveShift else { return }
        pitchPad.octaveShift = next
        sendJoyConDisplay()
    }

    /// The iPad raw-tilt funnel: an arm calibration consumes the report and
    /// drives axes 0–2; otherwise the raw axes pass through, duplicate-dropped.
    private func handleRawTilt(_ axis: Int, _ value: Double) {
        if !joyCon.feedArmTilt(axis, value) {
            axes.applyRawArmAxis(axis, value)
        }
    }

    /// Apply one control-axis value (−1…+1, rest 0 ↔ curve x 0…1) — the
    /// entry point every Joy-Con / tilt funnel calls. Off-main; downstream
    /// is thread-safe.
    private func applyTiltAxis(_ axis: Int, _ value: Double) {
        axes.applyAxis(axis, value)
    }

    /// Drive one batch of evaluated applications in native units: a
    /// composite via `applyComposite`, a parameter via the unified apply,
    /// rebuild-path values through the debounced funnel.
    private func applyControlBatch(_ apps: [ControlAxisEvaluator.Application]) {
        var rebuild: [String: Double] = [:]
        for (target, out) in apps {
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

    /// COMPOSITE PARAMETERS: named 0…1 controls whose members each sweep
    /// their own lo→hi range. Controls tab; axes bind by slot. Persisted.
    @Published var composites: [CompositeParam] = AppController.loadComposites() {
        didSet {
            AppController.saveComposites(composites)
            rebuildCompositeSnapshot()
        }
    }

    private static let compositesKey = "tarabdaar.compositeParams.v1"

    private static func loadComposites() -> [CompositeParam] {
        if let c = DefaultsStore.load([CompositeParam].self, key: compositesKey) {
            return c
        }
        return CompositeParam.defaults()
    }

    private static func saveComposites(_ c: [CompositeParam]) {
        DefaultsStore.save(c, key: compositesKey)
    }

    /// Off-main-readable snapshot of the composite member sets, keyed by
    /// slot index.
    private let compositeLock = NSLock()
    private var compositeMembersBySlot: [Int: [CompositeMember]] = [:]
    /// Rebuild-path values (composites, bindings, the strike blend) funneled
    /// into ONE debounced main-thread apply — `DebouncedParamFlush`.
    private var rebuildFlush: DebouncedParamFlush!

    /// THE RESTING VALUES — one store for every parameter, whatever its
    /// apply strategy: a key that is absent rests at its default (the
    /// artifact's value for a physics scalar, the registry's otherwise, the
    /// rest fraction of the built headroom for a hybrid). Composites and
    /// bindings modulate ON TOP of these and never write here. Persisted
    /// as JSON; the store only persists — each mutation applies what it
    /// changed (one key from a slider, every key from a preset or
    /// reset-all) and routes a physics scalar to `stringParams`.
    @Published var paramValues: [String: Double] = AppController.loadParamValues() {
        didSet { AppController.saveParamValues(paramValues) }
    }

    private static let paramValuesKey = "tarabdaar.paramValues.v2"
    /// The two stores this one replaced, read once when v2 is absent.
    private static let legacyControlKey = "tarabdaar.controlDefaults.v1"
    private static let legacyOverridesKey = "tarabdaar.stringOverrides.v1"

    private static func loadParamValues() -> [String: Double] {
        let saved = DefaultsStore.load([String: Double].self, key: paramValuesKey)
            ?? (DefaultsStore.load([String: Double].self, key: legacyOverridesKey) ?? [:])
                .merging(DefaultsStore.load([String: Double].self, key: legacyControlKey) ?? [:]) { _, c in c }
        return Self.known(saved)
    }

    /// Only keys the registry still knows (retired keys drop out), on the
    /// current scale.
    private static func known(_ d: [String: Double]) -> [String: Double] {
        d.filter { ParamRegistry.spec($0.key) != nil }
            .reduce(into: [:]) { $0[$1.key] = migrated($1.key, $1.value) }
    }

    /// The physics scalars in `values` as `StringParamStore` overrides: every
    /// `.rebuild` key, plus a hybrid raised above its artifact headroom.
    private static func physicsOverrides(in values: [String: Double]) -> [String: Double] {
        values.filter { key, v in
            guard let spec = ParamRegistry.spec(key) else { return false }
            switch spec.apply {
            case .rebuild: return true
            case .hybrid: return v > (Presets.bowedStringParams()?.num[key] ?? spec.def) + 1e-12
            case .live: return false
            }
        }
    }

    /// `ctl_strum_thresh` was 1…127 (≥127 = off) before it became 0…1:
    /// a stored value above 1 is the old scale.
    private static func migrated(_ key: String, _ v: Double) -> Double {
        key == "ctl_strum_thresh" && v > 1.0 ? min(1.0, v / 127.0) : v
    }

    private static func saveParamValues(_ d: [String: Double]) {
        DefaultsStore.save(d, key: paramValuesKey)
    }

    private static let bowAxisCurvesKey = "tarabdaar.bowAxisCurves.v1"
    @Published private(set) var bowAxisCurves = AppController.loadBowAxisCurves() {
        didSet { DefaultsStore.save(bowAxisCurves, key: Self.bowAxisCurvesKey) }
    }

    private static func loadBowAxisCurves() -> [String: [BowAxisPoint]] {
        var preset = TarabdaarPreset()
        preset.bowAxisCurves = DefaultsStore.load([String: [BowAxisPoint]].self, key: bowAxisCurvesKey)
        preset.paramValues = DefaultsStore.load([String: Double].self, key: paramValuesKey)
        preset.stringOverrides = DefaultsStore.load([String: Double].self, key: legacyOverridesKey)
        return preset.resolvedBowAxisCurves() ?? TarabdaarPreset.factoryBowAxisCurves()
    }

    func bowAxisCurve(_ axis: BowAxis) -> [BowAxisPoint] {
        bowAxisCurves[axis.rawValue] ?? BowAxisTransform.identity
    }

    func setBowAxisCurve(_ axis: BowAxis, _ points: [BowAxisPoint]) {
        bowAxisCurves[axis.rawValue] = BowAxisTransform.normalize(points)
        applyBowAxisCurves()
    }

    private func applyBowAxisCurves() {
        // Save migration before a later parameter edit discards the retired band keys.
        DefaultsStore.save(bowAxisCurves, key: Self.bowAxisCurvesKey)
        audio.setBowAxisCurves(bowAxisCurves)
    }

    /// THE FX RACK'S EQ CURVES: each insert point's control points, keyed by
    /// the point's key prefix (`fx_voice_`). Not registry parameters — the
    /// curve is inferred from the points (`SarangiKit.EQCurve`), so they
    /// live beside `paramValues` as one structured value per point: the FX
    /// tab edits them, presets carry them (`TarabdaarPreset.fxCurves`),
    /// and the point's `eq_on` / `eq_amount` knobs switch and scale them.
    /// Persisted as JSON; `applyEQCurves` pushes them to the voice.
    @Published var fxEQCurves: [String: [EQPoint]] = AppController.loadEQCurves() {
        didSet { AppController.saveEQCurves(fxEQCurves) }
    }

    private static let eqCurvesKey = "tarabdaar.fxCurves.v1"

    private static func loadEQCurves() -> [String: [EQPoint]] {
        if let saved = DefaultsStore.load([String: [EQPoint]].self, key: eqCurvesKey) {
            return saved.mapValues(EQCurve.normalize).filter { !$0.value.isEmpty }
        }
        // First run after the graphic EQ: the saved profile's band values
        // become a curve through the band centres (`loadParamValues` drops
        // the retired keys themselves).
        if let saved = DefaultsStore.load([String: Double].self, key: legacyControlKey) {
            return TarabdaarPreset.legacyEQCurves(in: saved)
        }
        return [:]
    }

    private static func saveEQCurves(_ d: [String: [EQPoint]]) {
        DefaultsStore.save(d, key: eqCurvesKey)
    }

    /// One insert point's EQ curve (empty = flat).
    func eqCurve(_ keyPrefix: String) -> [EQPoint] {
        fxEQCurves[keyPrefix] ?? []
    }

    /// Replace one insert point's EQ curve (the FX tab's edits); the points
    /// are normalised (sorted, clamped, merged) on the way in and pushed.
    func setEQCurve(_ keyPrefix: String, _ points: [EQPoint]) {
        let pts = EQCurve.normalize(points)
        if pts.isEmpty { fxEQCurves.removeValue(forKey: keyPrefix) }
        else { fxEQCurves[keyPrefix] = pts }
        applyEQCurves()
    }

    /// Push every point's curve to the voice (startup, edits, preset loads).
    func applyEQCurves() {
        for point in FXPoint.allCases {
            audio.setStringEQCurve(point, fxEQCurves[point.keyPrefix] ?? [])
        }
    }

    // MARK: - Unified parameter access (Parameters tab / composites / tilts)

    /// A `.hybrid` parameter's build-time headroom (override, else artifact,
    /// else default), cached under `compositeLock` for off-main reads.
    private var hybridHeadroom: [String: Double] = [:]

    /// Re-read the headroom cache. Pass `values` from a `@Published` sink
    /// (which fires before the store's own property updates).
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

    /// The resting value of any parameter, native units — the store's
    /// value, else the parameter's default.
    func paramValue(_ key: String) -> Double {
        paramValues[key] ?? paramDefault(key)
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

    /// Set a parameter's resting value (the Parameters tab's path): the
    /// store, then the voice — a physics scalar through `stringParams`, a
    /// live knob straight in, a hybrid both ways when it rises above the
    /// built headroom.
    func setParamValue(_ key: String, _ value: Double) {
        guard let spec = ParamRegistry.spec(key) else { return }
        paramValues[key] = value
        switch spec.apply {
        case .rebuild:
            stringParams.set(key, value)
        case .live:
            applyParamToVoice(key, value)
        case .hybrid:
            // Above the built headroom the build scalar must move (rebuild);
            // at or below it the kernel's scaler covers it.
            if value > headroom(key) + 1e-12 {
                stringParams.set(key, value)   // raises the headroom
                refreshHybridHeadroom()
            }
            applyParamToVoice(key, value)
        }
        // A bound parameter's rest moved: its axes' swings now add to the
        // new value (a no-op for an unbound key).
        axes.setParamRest(key, value)
    }

    /// Restore a parameter to its default and re-apply.
    func resetParam(_ key: String) {
        guard let spec = ParamRegistry.spec(key) else { return }
        paramValues.removeValue(forKey: key)
        switch spec.apply {
        case .rebuild:
            stringParams.reset(key)
        case .live:
            applyParamToVoice(key, paramValue(key))
        case .hybrid:
            // Drop a RAISED headroom first — but only touch the physics store
            // if it actually moved, so a plain reset costs no rebuild.
            if stringParams.values[key] != stringParams.artifactValue(key) {
                stringParams.reset(key)
                refreshHybridHeadroom()
            }
            applyParamToVoice(key, paramValue(key))
        }
    }

    /// Reset every parameter: the store, the physics overrides, the curves.
    func resetAllParams() {
        paramValues.removeAll()
        stringParams.resetToDefault()
        refreshHybridHeadroom()
        bowAxisCurves = TarabdaarPreset.factoryBowAxisCurves()
        applyBowAxisCurves()
        fxEQCurves.removeAll()
        applyRestingParams()
        applyEQCurves()
    }

    /// Push every `.live`/`.hybrid` resting value to the voice — the
    /// baseline composites and bindings modulate on top of.
    func applyRestingParams() {
        for spec in ParamRegistry.storedKeys {
            _ = applyParamToVoice(spec.key, paramValue(spec.key))
        }
    }

    /// THE unified apply (thread-safe). Returns nil when the value took
    /// effect, else the value to funnel through the debounced rebuild path.
    @discardableResult
    func applyParamToVoice(_ key: String, _ value: Double) -> Double? {
        guard let spec = ParamRegistry.spec(key) else { return nil }
        switch spec.apply {
        case .live:
            applyLive(spec.target, key, value)
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

    /// The `.live` routing — ONE switch on the registry's target.
    private func applyLive(_ target: ParamTarget, _ key: String, _ value: Double) {
        switch target {
        case .stringVoice:
            audio.setStringControlParam(key, value)
        case .strikeWindow:
            // Updates the window, forces a blend re-evaluation, relays to the iPad.
            axes.setStrikeWindow(value)
            DispatchQueue.main.async { [weak self] in self?.sendJoyConDisplay() }
        case .accelerationSmoothing(let dimension):
            axes.setAccelerationSmoothing(dimension, milliseconds: value)
        case .strumExpression:
            strumming.setExpression(value)
        case .strumThreshold:
            strumming.setAccelThreshold(value)
        case .glideQueue:
            audio.glideQueue.setControl(key, value)
        case .tarafAdaptation:
            DispatchQueue.main.async { [weak self] in self?.pitchProfile.amount = value }
        case .pitchAccent:
            audio.setPitchAccent(value)
        case .fretWarp:
            // Published for the Mac pad, relayed to the iPad, shapes the glide queue.
            let v = min(max(value, 0), 1)
            audio.glideQueue.setWarp(v)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fretFieldWarp != v else { return }
                self.fretFieldWarp = v
                self.sendJoyConDisplay()
            }
        }
    }

    // jt overload watchdog (see start())
    private var jtStatsTimer: Timer?
    lazy var pitchProfile = PerformanceProfileModel(audio: audio, tuning: tuning)

    /// VOLUME READOUT relay: 60 Hz poll of `AudioEngine.volumeLevels`
    /// (integrate-and-dump — the ONE poller) → JOYCON_STATE, change-gated.
    private var volMeter: VolumeMeterRelay?

    private func startVolMeterRelay() {
        let relay = VolumeMeterRelay(
            levels: { [weak self] in
                self?.audio.volumeLevels() ?? (voice: 0, taraf: 0)
            },
            send: { [weak self] voice, taraf in
                self?.link.setVolumeLevels(voice: voice, taraf: taraf)
            },
            noteControls: { [weak self] in
                self?.audio.noteControls() ?? .idle
            },
            sendNoteControls: { [weak self] controls in
                self?.link.setNoteControls(controls)
            })
        relay.start()
        volMeter = relay
    }

    // MARK: - Controller strum (Joy-Con L)

    /// CONTROLLER STRUM: the mechanics live in `StrumController` (the L
    /// button + the accel trigger, the Shepard chord notes, the in-place
    /// retune, the generation-scoped touch ids). This class owns the note
    /// engine it plays through and the published selection the views read.
    /// Main queue, like the engine it drives.
    private(set) var strumming: StrumController!

    /// THE CHORD BAR's ACTIVE selection (iPad taps via the PERF_STATE chord
    /// bytes, Mac taps via `tapChord` → the local pump) — what the strum
    /// plays, else the Strings tab's configured set. A change while ringing
    /// retunes in place. Performance state, never persisted.
    @Published var strumChord: ChordSelection?

    /// L holds the chord.
    func strum(pressed: Bool) {
        strumming.strum(pressed: pressed)
    }

    /// The Mac chord bar's tap: toggles against the ACTIVE chord through
    /// the shared engine's edge path. Octave-agnostic (stored as octave 0).
    func tapChord(_ sel: ChordSelection) {
        pitchPad.setChordSelection(strumChord?.degree == sel.degree
            ? nil : ChordSelection(degree: sel.degree, octave: 0))
    }

    private var lastJtDrops = 0.0
    private var jtGateLogTicks = 0
    private var lastJtFlat = 0.0
    private var lastRenderOverruns: UInt64 = 0

    // MARK: - Sarangi model
    //
    // The String voice's document is owned by `sarangi` (`SarangiStore`): the
    // sympathetic-string table that tunes the in-kernel taraf (Strings tab).

    /// The sarangi document's editable state + engine bridge (tarab tuning).
    let sarangi: SarangiStore

    /// Store for the `.rebuild` (and `.hybrid` headroom) parameters: artifact
    /// scalars + persisted overrides, applied through a debounced rebuild.
    let stringParams: StringParamStore

    // MARK: - Init / lifecycle

    init() {
        let audio = AudioEngine()
        let midi = MIDIEngine()
        let midiIn = MIDIInput()
        self.audio = audio
        self.midi = midi
        self.midiIn = midiIn
        self.ingest = LinkIngest(sink: audio)
        // ONE scale, ONE tonic: both pad engines share the instance.
        let tuning = Tuning()
        self.tuning = tuning
        self.pitchPad = PitchPadEngine(audio: audio, tuning: tuning)
        self.fretPad = PitchPadEngine(audio: audio, tuning: tuning)
        // Fret Pad Snap: 24 px (not the shared 16), fitted to real iPad
        // onsets — ≈43¢, under the 40 px minimum fret gap. Synced to the iPad.
        self.fretPad.marginPixels = 24
        self.keyboard = KeyboardNotePlayer(engine: self.pitchPad)
        // Restore the last-edited arrangement, or build a starter from the
        // scale. (The autosave sink is wired in `start()`.)
        self.fretArrangement = FretArrangementStore.loadCurrent()
            ?? FretArrangement.keyboardArrangement(
                degrees: scaleDegrees(from: self.pitchPad.scale))
        // Loads the persisted/default document and builds the tarab tuning.
        self.sarangi = SarangiStore(audio: audio)
        // Physics overrides — seeds the engine before the first BowEngine.
        self.stringParams = StringParamStore(
            audio: audio,
            overrides: Self.physicsOverrides(in: Self.loadParamValues()))
        // The debounced rebuild funnel behind every off-main parameter path.
        self.rebuildFlush = DebouncedParamFlush { [weak self] values in
            guard let self else { return }
            self.stringParams.setBatch(values)
            self.refreshHybridHeadroom()
        }
        // The controller strum sounds ordinary notes in the MAIN voice
        // through the shared pad engine, against the one scale.
        let pad = self.pitchPad
        let doc = self.sarangi
        self.strumming = StrumController(
            sink: StrumController.NoteSink(
                noteOn: { id, ratio, expr in
                    // A fixed-register anchor: exempt from the octave shift
                    // and from the glide queue (near-simultaneous onsets
                    // must not chain).
                    pad.noteOn(touchId: id, ratio: ratio,
                               octaveShifted: false,
                               exprScale: expr, glideExempt: true)
                },
                noteOff: { pad.noteOff(touchId: $0) },
                glide: { pad.glide(touchId: $0, ratio: $1) },
                setExpr: { pad.setTouchExpr(touchId: $0, exprScale: $1) }),
            degrees: { scaleDegrees(from: pad.scale) },
            fallbackRatios: { doc.state.strumStringRatios })

        // Restore the output device rate on a clean quit (the engine forces
        // 44.1 kHz to drop the output resampler). SIGKILL skips this.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.audio.restoreOutputDeviceRate()
        }

        // Arm the String voice. The Mac pads hold a flat CC11 per note; 32 ≈
        // the fitted expression median (the surfaces span ~16 dB around it).
        audio.setSarangiModelVoiceEnabled(true)

        // The tanpura voice is always armed beside the String voice; its JI
        // slot grid builds off-main in `start()`. Restore the routing choices.
        audio.setTanpuraVoiceEnabled(true)
        audio.setMainInstrument(mainInstrument)
        audio.setDroneVoiceMode(droneVoice)

        // The Fret Pad is the only surface — force the synced layout.
        ipadLayout = .fretPad
    }

    /// Combine subscriptions (scale sync, autosaves, tarab/tanpura pushes).
    private var cancellables = Set<AnyCancellable>()

    func start() {
        wireControlSinks()
        midi.start()
        midiIn.start()
        pitchPad.start()
        fretPad.start()
        startScaleSync()
        // Snapshots for the off-main deliveries, then the baseline values.
        rebuildCompositeSnapshot()
        axes.setMapping(tiltMapping)
        refreshHybridHeadroom()      // build depths behind the hybrid knobs
        applyRestingParams()         // resting values for every live param
        applyBowAxisCurves()
        applyEQCurves()              // the FX rack's EQ curves
        // A physics edit can move a hybrid's headroom — keep the cache in step
        // (`@Published` fires before the property updates: use the sink value).
        stringParams.$values
            .sink { [weak self] v in self?.refreshHybridHeadroom(from: v) }
            .store(in: &cancellables)
        wireIngest()
        wireLink()
        wireJoyCon()
        // Voice/taraf volume readout → iPad (JOYCON_STATE vol bytes).
        startVolMeterRelay()
        startEngineWatchdog()
        pitchProfile.start()
        wireTuningFollowers()
    }

    /// The control-axis evaluator's sinks and the JOYCON_STATE mirror's
    /// field readers — wired before anything can drive them.
    private func wireControlSinks() {
        // The control-axis evaluator's sinks, before anything can drive it
        // (`setMapping` below arms its timers).
        axes.onApply = { [weak self] apps in self?.applyControlBatch(apps) }
        axes.paramRest = { [weak self] key in self?.paramValue(key) ?? 0 }
        // The JOYCON_STATE mirror: the send plus the four acted-on fields.
        joyConDisplay.send = { [weak self] display, immediate in
            self?.link.setJoyConState(display, immediate: immediate)
        }
        joyConDisplay.connected = { [weak self] in
            self?.joyCon.connectedName != nil
        }
        joyConDisplay.strikeWindowS = { [weak self] in
            self?.axes.strikeWindowS ?? 2.0
        }
        joyConDisplay.fieldWarp = { [weak self] in self?.fretFieldWarp ?? 0 }
        joyConDisplay.octaveShift = { [weak self] in
            self?.pitchPad.octaveShift ?? 0
        }
    }

    /// The wire's inbound frames: raw tilt, accelerometer, strike, touch
    /// gates / pitches / radii and chord edges, on both lanes.
    private func wireIngest() {
        // The iPad's raw tilt, off the TarabLink state frame (change-gated
        // in LinkIngest).
        ingest.onTiltAxis = { [weak self] axis, value in
            self?.handleRawTilt(axis, value)
        }
        // Raw accelerometer off the same frames — display only.
        ingest.onAccel = { [weak self] x, y, z in
            self?.joyCon.feedAccel(x, y, z)
        }
        // The strike envelope: the measurement behind the `.strike` /
        // `.acceleration` pair. Change-gated in LinkIngest.
        ingest.onStrike = { [weak self] v in
            guard let self else { return }
            self.axes.setStrikeMeasure(v)
            // The strum accel trigger rides the same envelope.
            self.strumming.accelSense(v)
        }
        // Note-lifecycle edges anchor the per-note blend windows (a
        // retrigger re-anchors; releases fall back to the survivor's age).
        ingest.onTouchGate = { [weak self] id, on in
            self?.axes.touchGate(lane: .wire, id: id, on: on)
        }
        // The `.fingerAccel` pitch feed — wire lane (source 0) + the local
        // local-pad lane (source 1), so the u16 id spaces can't collide.
        ingest.onTouchPitch = { [weak self] id, pitch in
            self?.axes.touchPitch(lane: .wire, id: id, pitch: pitch)
        }
        pitchPad.localIngest?.onTouchGate = { [weak self] id, on in
            self?.axes.touchGate(lane: .local, id: id, on: on)
        }
        pitchPad.localIngest?.onTouchPitch = { [weak self] id, pitch in
            self?.axes.touchPitch(lane: .local, id: id, pitch: pitch)
        }
        // The `.touchSize` feed — the iPad's `UITouch.majorRadius` in
        // points, on both lanes (the Mac pads have no touchscreen and send
        // 0, which maps to the axis's rest).
        ingest.onTouchRadius = { [weak self] id, r in
            self?.axes.touchRadius(lane: .wire, id: id, radiusPt: r)
        }
        pitchPad.localIngest?.onTouchRadius = { [weak self] id, r in
            self?.axes.touchRadius(lane: .local, id: id, radiusPt: r)
        }
        ingest.onTouchFretPosition = { [weak self] id, value in
            self?.axes.touchFretPosition(lane: .wire, id: id, value: value)
        }
        pitchPad.localIngest?.onTouchFretPosition = { [weak self] id, value in
            self?.axes.touchFretPosition(lane: .local, id: id, value: value)
        }
        fretPad.localIngest?.onTouchGate = pitchPad.localIngest?.onTouchGate
        fretPad.localIngest?.onTouchPitch = pitchPad.localIngest?.onTouchPitch
        fretPad.localIngest?.onTouchRadius = pitchPad.localIngest?.onTouchRadius
        fretPad.localIngest?.onTouchFretPosition = pitchPad.localIngest?.onTouchFretPosition
        // Chord-bar selection edges from both lanes (iPad taps, the Mac bar via
        // `tapChord`) land in `strumChord`; a RINGING chord retunes in place.
        let chordEdge: (ChordSelection?) -> Void = { [weak self] sel in
            DispatchQueue.main.async {
                guard let self, self.strumChord != sel else { return }
                self.strumChord = sel
                self.strumming.setSelection(sel)
            }
        }
        ingest.onChordSelect = chordEdge
        pitchPad.localIngest?.onChordSelect = chordEdge
    }

    /// TarabLink: SysEx transport in and out, state frames, events, status.
    private func wireLink() {
        // TarabLink: inbound TLP SysEx from MIDIInput's reassembler. A frame
        // from the pad also tells `midi` which source carries the link, so
        // replies go back on that bearer alone (USB when the cable is in —
        // the pad's wired-first choice decides both directions). Outbound
        // rides that learned peer; before it is known, the wired-first
        // "iPad" name-match send stands in (events fall back to send-to-all,
        // state frames just drop).
        midiIn.onSysEx = { [weak self] bytes, source in
            guard let self else { return }
            self.link.receivedSysEx(bytes)
            if TLPPack.senderRole(of: bytes) == .pad {
                self.midi.noteLinkFrame(from: source)
            }
        }
        link.sendRaw = { [weak self] bytes, isEvent in
            self?.midi.sendSysExToLinkPeer(bytes, isEvent: isEvent)
        }
        link.onPerfState = { [weak self] frame in
            self?.ingest.apply(frame)
        }
        link.onLinkDrop = { [weak self] in
            guard let self else { return }
            NSLog("Tarabdaar: link stale — releasing everything held")
            self.ingest.linkDidDrop()
            // No more frames: the strike measurement rests at 0.
            self.axes.resetAcceleration(.acceleration)
            // An accel-held strum chord must not outlive the link.
            self.strumming.accelSense(0)
        }
        link.onEvent = { [weak self] event in
            switch event {
            case .tarafPluck(let revision, let row):
                DispatchQueue.main.async { self?.audio.pluckTaraf(revision: revision, row: row) }
            case .resyncRequest:
                DispatchQueue.main.async { self?.pushCurrentState() }
            case .panic:
                // Kill the WIRE's touches/drones only — never the Mac's pads.
                NSLog("TarabLink: panic from pad")
                self?.ingest.linkDidDrop()
                self?.axes.resetAcceleration(.acceleration)
            default:
                break
            }
        }
        link.onStatus = { [weak self] status in
            NSLog("TarabLink: up=%d stale=%d rtt=%@",
                  status.isUp ? 1 : 0, status.isStale ? 1 : 0,
                  status.rttMs.map { String(format: "%.1fms", $0) } ?? "–")
            DispatchQueue.main.async { self?.linkStatus = status }
        }
        // A destination appearing/vanishing → re-greet; scale sync re-pushes.
        midi.$destinationCount
            .removeDuplicates()
            .sink { [weak self] _ in self?.link.kick() }
            .store(in: &cancellables)
        link.start()
    }

    /// The Joy-Con's axes, buttons and connection edge.
    private func wireJoyCon() {
        // Both calibrations feed the shared tilts; controller presence selects the source.
        joyCon.onArmAxes = { [weak self] t1, t2, t3 in
            guard let self else { return }
            self.axes.applyTilt(.iPad, SIMD3(t1, t2, t3))
            // Mirror the calibrated arm axes to the iPad's arm square (main
            // thread; the link paces the sends).
            self.joyConDisplay.setArm(t1, t2, t3)
        }
        joyCon.onWristAttitude = { [weak self] wrist in
            guard let self else { return }
            self.joyConDisplay.setWrist(wrist)
        }
        joyCon.onStickAxes = { [weak self] x, y in
            guard let self else { return }
            self.axes.applyStick(x: x, y: y)
            self.joyConDisplay.setStick(x, y)
        }
        joyCon.onWristAxes = { [weak self] w1, w2, w3 in
            guard let self else { return }
            self.axes.applyTilt(.controller, SIMD3(w1, w2, w3))
        }
        joyCon.onJoyConAccelReset = { [weak self] in
            self?.axes.resetAcceleration(.jcAccel)
        }
        joyCon.onJoyConAccel = { [weak self] level in
            self?.applyTiltAxis(ControlAxisEvaluator.jcAccelAxisIndex,
                                level * 2 - 1)
        }
        joyCon.onButton = { [weak self] control, pressed in
            guard let self else { return }
            switch control {
            case .dpadLeft:
                // ←/→ step the playing range an octave.
                guard pressed else { return }
                self.shiftOctave(-1)
            case .dpadDown:
                let calibrating = self.joyCon.capturingCalibrator != nil
                self.sequenceDroneButton(control, pressed: pressed, enabled: !calibrating)
                if pressed && calibrating {
                    self.joyCon.redoPreviousCalibrationStep()
                }
            case .rearZ:
                self.sequenceDroneButton(control, pressed: pressed)
            case .dpadRight:
                guard pressed else { return }
                self.shiftOctave(+1)
            case .l:
                // L holds the strum chord — see `strum(pressed:)`.
                self.strum(pressed: pressed)
            case .zl:
                // ZL re-zeroes the arm AND wrist axes at the current poses.
                guard pressed else { return }
                self.joyCon.recenterBody()
            case .minus:
                if pressed { self.pitchProfile.toggleSeed() }
            case .capture:
                if pressed { self.pitchProfile.reset() }
            case .sl, .sr, .stickClick:
                // Unassigned — visible in the panel chips.
                break
            case .dpadUp:
                let wasDown = self.droneOctaveButtonDown
                self.droneOctaveButtonDown = pressed
                guard pressed && !wasDown else { return }
                if self.joyCon.capturingCalibrator != nil {
                    self.joyCon.advanceCalibration()
                } else {
                    self.tanpuraDroneOctaveRaised.toggle()
                    self.audio.setTanpuraDroneOctaveRaised(self.tanpuraDroneOctaveRaised)
                }
            }
        }
        // Select tilt immediately on the connection edge. The display push
        // waits until @Published has stored the new connected name.
        joyCon.$connectedName
            .map { $0 != nil }
            .removeDuplicates()
            .handleEvents(receiveOutput: { [weak self] connected in
                self?.axes.setControllerConnected(connected)
            })
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                if !connected {
                    self?.cancelSequencedDrone()
                    self?.droneOctaveButtonDown = false
                }
                self?.sendJoyConDisplay()
            }
            .store(in: &cancellables)
        joyCon.start()
    }

    /// The 5 s engine watchdog: jt overload, the quiescence-gate probe and
    /// render overruns, logged when their counters grow.
    private func startEngineWatchdog() {
        // jt overload watchdog: the async jawari web drops blocks / flat-fills
        // past its realtime budget (audible clicking). Log when counters GROW.
        jtStatsTimer = Timer.scheduledTimer(withTimeInterval: 5.0,
                                            repeats: true) { [weak self] _ in
            guard let self else { return }
            if let s = self.audio.stringVoiceJtStats(), s.on > 0.5 {
                if s.drops > self.lastJtDrops || s.flat > self.lastJtFlat {
                    NSLog("Tarabdaar: jt OVERLOAD — +%.0f dropped blocks, +%.0f flat-filled samples (totals %.0f/%.0f, fifo %.0f)",
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
            // Quiescence-gate probe: what keeps the idle web awake (ring = rows
            // above the floor, drive = bridge drive, drone). Ratios > 1 block.
            let g = self.audio.stringVoiceJtGateProbe()
            let awake = g.map { $0.total > 0 && $0.asleep < $0.total } ?? false
            // The first ~30 s log unconditionally; then only while awake.
            if self.jtGateLogTicks < 6 || awake {
                self.jtGateLogTicks += 1
                if let g {
                    NSLog("Tarabdaar: jt gate — asleep=%d/%d ring×%.2f drive×%.2f%@",
                          g.asleep, g.total, g.ringR, g.driveR,
                          g.droneHot ? " drone" : "")
                } else {
                    NSLog("Tarabdaar: jt gate — no String voice")
                }
            }
            // Render overruns glitch at the DEVICE (an offline render can't
            // show them) — log whenever they grow.
            if let r = self.audio.stringVoiceRenderStats() {
                if r.overruns > self.lastRenderOverruns {
                    NSLog("Tarabdaar: render OVERRUN — +%llu late callbacks (worst %.2f ms this period, total %llu/%llu)",
                          r.overruns - self.lastRenderOverruns, r.maxMs,
                          r.overruns, r.callbacks)
                }
                self.lastRenderOverruns = r.overruns
            }
        }
    }

    /// Everything that follows the ONE scale/tonic (`tuning.didChange`,
    /// each with its own debounce): the arrangement autosave, the
    /// drone-button display ratios, the tarab document and the tanpura grid.
    private func wireTuningFollowers() {
        // Auto-save the Fret Pad arrangement (debounced).
        $fretArrangement
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { FretArrangementStore.saveCurrent($0) }
            .store(in: &cancellables)

        // Drone-button DISPLAY ratios: the buttons pluck MAPPED tarab strings,
        // so `droneRatios` are purely visual (labels/colors on both surfaces).
        // An unmapped slot keeps its last ratio and is inert.
        Publishers.CombineLatest(
            sarangi.$state.map(\.droneStringFreqs).removeDuplicates(),
            tuning.didChange
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] freqs, _ in
            guard let self else { return }
            let tonic = self.pitchPad.tonicHz
            var ratios = self.fretArrangement.droneRatios
            for i in ratios.indices where freqs.indices.contains(i) {
                if let f = freqs[i] {
                    ratios[i] = max(0.25, min(4.0, f / tonic))
                }
            }
            if ratios != self.fretArrangement.droneRatios {
                self.fretArrangement.droneRatios = ratios
            }
        }
        .store(in: &cancellables)

        // Push the scale into the tarab document. Pitches ALWAYS follow; the
        // row LAYOUT regenerates only when the degree count changes.
        tuning.didChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncTarabFromScale() }
        .store(in: &cancellables)
        syncTarabFromScale()        // match the scale on launch

        // The pitch accent's fret grid: a handful of doubles, so it follows
        // the arrangement and the tuning undebounced (held notes re-accent
        // at once).
        Publishers.Merge($fretArrangement.map { _ in () }, tuning.didChange)
            .sink { [weak self] in self?.syncAccentGridFromFrets() }
            .store(in: &cancellables)

        // Rebuild the tanpura's JI slot grid on a scale/tonic change. Heavier
        // debounce than the tarab push — a tanpura build is ~seconds of CPU.
        tuning.didChange
            .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncTanpuraFromScale() }
        .store(in: &cancellables)
        syncTanpuraFromScale()      // arm the drone voice on launch
    }

    /// Push the pad's fret pitches into the pitch accent (`ctl_fret_accent`).
    private func syncAccentGridFromFrets() {
        audio.setFretPitchGrid(FretPitchGrid(tonicHz: pitchPad.tonicHz,
                                             arrangement: fretArrangement,
                                             degrees: fretDegrees))
    }

    /// Last tuning pushed into the tanpura, for the unchanged-skip above.
    private var lastTanpuraSync: (tonic: Double, ratios: [Double])?

    /// Push the centralized scale into the tanpura's slot grid (no-op when
    /// the tuning hasn't actually moved — the build is seconds of CPU).
    func syncTanpuraFromScale() {
        let ratios = scaleDegrees(from: pitchPad.scale).map(\.ratio)
        let tonic = pitchPad.tonicHz
        if let last = lastTanpuraSync, last.tonic == tonic,
           last.ratios == ratios { return }
        lastTanpuraSync = (tonic, ratios)
        audio.rebuildTanpura(tonic: tonic, scaleRatios: ratios)
        // The sitar mounts the same JI grid from its own artifact — a no-op
        // until the voice has been armed (first switch to Sitar).
        audio.rebuildSitar(tonic: tonic, scaleRatios: ratios)
    }

    // MARK: - Fret layouts (Fret Pad tab's Layout menu)

    /// The scale degrees the layouts are built against — the one scale.
    private var fretDegrees: [(ratio: Double, label: String)] {
        scaleDegrees(from: pitchPad.scale)
    }

    /// Build a **built-in** layout from the current scale. It becomes an
    /// unsaved working layout (no name), like loading a `ScalePreset`.
    func loadFretLayout(preset: FretLayoutPreset) {
        fretPad.panic()
        fretArrangement = preset.arrangement(degrees: fretDegrees)
        fretLayoutName = nil
    }

    /// Save the working arrangement under `name` and adopt the name.
    /// Silently no-ops on an empty/reserved name or a failed write.
    func saveFretLayout(name: String) {
        guard let saved = try? FretArrangementStore.save(fretArrangement,
                                                         name: name) else { return }
        fretLayoutName = saved
    }

    /// Load a saved layout. Stops sounding touches first — the frets a held
    /// note was resolved against are about to be replaced.
    func loadFretLayout(name: String) {
        guard let loaded = try? FretArrangementStore.load(name: name) else { return }
        fretPad.panic()
        fretArrangement = loaded
        fretLayoutName = name
    }

    /// Delete a saved layout. If it was the loaded one, the working
    /// arrangement stays put and just loses its name.
    func deleteFretLayout(name: String) {
        try? FretArrangementStore.delete(name: name)
        if fretLayoutName == name { fretLayoutName = nil }
    }

    // MARK: - Sarangi tarab ↔ Pitch Pad scale

    /// Push the scale into the tarab document. Pitches always follow; the row
    /// layout regenerates when the degree count changed or under `force`.
    func syncTarabFromScale(force: Bool = false) {
        let ratios = scaleDegrees(from: pitchPad.scale).map(\.ratio)
        sarangi.syncTarabToScale(tonicHz: pitchPad.tonicHz, ratios: ratios, force: force)
    }

    // MARK: - iPad scale sync (Mac → iPad over TLP events)

    /// Push the scale state and the fret arrangement to the iPad whenever
    /// any of it changes (debounced) or a MIDI destination appears. One-way;
    /// the only cross-device state.
    private func startScaleSync() {
        let triggers: [AnyPublisher<Void, Never>] = [
            tuning.didChange,
            audio.$tarafBank.map { _ in () }.eraseToAnyPublisher(),
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

    /// Rate limit for `pushCurrentState` (≥300 ms apart — a peer requesting
    /// resync per frame must not storm the wire). Coalescing, not dropping.
    private var lastStatePush: CFAbsoluteTime = 0
    private var statePushScheduled = false

    private func pushCurrentState() {
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - lastStatePush
        if gap < 0.3 {
            if !statePushScheduled {
                statePushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.3 - gap)) {
                    [weak self] in
                    self?.statePushScheduled = false
                    self?.pushCurrentState()
                }
            }
            return
        }
        lastStatePush = now
        pushCurrentStateNow()
    }

    private func pushCurrentStateNow() {
        // The active surface's margin (the Fret Pad's Snap slider).
        let margin = ipadLayout == .fretPad ? fretPad.marginPixels
                                            : pitchPad.marginPixels
        let state = SyncedScaleState(points: pitchPad.scale.points,
                                     tonicMidi: pitchPad.tonicMidi,
                                     tonicCents: pitchPad.tonicCents,
                                     marginPixels: margin,
                                     layout: ipadLayout)
        link.send(event: .scaleState(blob: PitchScaleSysEx.encodeBlob(state)))
        if ipadLayout == .fretPad {
            link.send(event: .fretArrangement(
                blob: FretArrangementSysEx.encodeBlob(fretArrangement)))
        }
        link.send(event: .tarafBank(audio.tarafBank))
        // A freshly-linked iPad must also learn the JOYCON_STATE fields.
        joyConDisplay.resend()
    }

    // MARK: - Composite parameters

    private func rebuildCompositeSnapshot() {
        compositeLock.lock()
        compositeMembersBySlot = Dictionary(
            uniqueKeysWithValues: composites.map { ($0.slot, $0.members) })
        compositeLock.unlock()
    }

    /// Apply a composite's value 0…1: every member sweeps its lo→hi range via
    /// the unified apply; rebuild members go through the debounced flush.
    func applyComposite(slot: Int, value: Double) {
        compositeLock.lock()
        let members = compositeMembersBySlot[slot] ?? []
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
    /// binding) into the debounced main-thread flush. Thread-safe.
    private func queueRebuildValues(_ values: [String: Double]) {
        rebuildFlush.queue(values)
    }

    /// The user-facing name for a target: the composite's name (or
    /// "Composite N (empty)"), else the parameter's registry label.
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
            (key: $0.key, label: $0.qualifiedLabel, lo: $0.lo, hi: $0.hi)
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
        ControlAxes.bindableDims.filter { tiltMapping.isConnected(target, $0) }
    }

    /// Bind a target to an axis over its full native range; endpoints are
    /// draggable afterwards.
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
        // An undriven parameter falls back to its resting value.
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

    /// Set a composite's resting value — what it reads with every bound
    /// axis at rest; the bindings' swings add to it.
    func setCompositeRest(slot: Int, _ rest: Double) {
        var m = tiltMapping
        m.setRest(for: MapTarget(compositeSlot: slot),
                  min(max(rest, 0.0), 1.0))
        tiltMapping = m
        if m.mapping(for: MapTarget(compositeSlot: slot)).isEmpty {
            applyComposite(slot: slot, value: min(max(rest, 0), 1))
        }
    }

    func setTiltOffsets(_ target: MapTarget, dim: InputDimension,
                        lo: Double, hi: Double) {
        guard let binding = tiltMapping.mapping(for: target).binding(for: dim) else { return }
        var m = tiltMapping
        m.setBinding(for: target, dimension: dim, to: binding.withOffsets(lo: lo, hi: hi))
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

    /// Capture the whole rig: sarangi document, physics overrides, resting
    /// values, composites, bindings, voice routing. One preset = one rig.
    func capturePreset(name: String) -> TarabdaarPreset {
        var p = TarabdaarPreset()
        p.name = name
        p.savedAt = ISO8601DateFormatter().string(from: Date())
        p.instrument = sarangi.state
        p.paramValues = paramValues            // every parameter, one section
        p.fxCurves = fxEQCurves.isEmpty ? nil : fxEQCurves
        p.bowAxisCurves = bowAxisCurves
        p.composites = composites
        p.tiltMapping = tiltMapping
        p.mainInstrument = mainInstrument.rawValue
        p.droneVoice = droneVoice.rawValue
        p.droneSequence = droneSequenceSteps
        return p
    }

    /// Apply whatever sections `p` carries; missing sections are skipped.
    func applyPreset(_ p: TarabdaarPreset) {
        if let curves = p.resolvedBowAxisCurves() {
            bowAxisCurves = curves
            applyBowAxisCurves()
        }
        if let inst = p.instrument {
            sarangi.replaceState(inst)
        }
        if p.paramValues != nil || p.stringOverrides != nil {
            // One section now; a file from the two-store era carries both.
            let merged = (p.stringOverrides ?? [:])
                .merging(p.paramValues ?? [:]) { _, pv in pv }
            paramValues = Self.known(merged)
            stringParams.replaceOverrides(Self.physicsOverrides(in: paramValues))
            refreshHybridHeadroom()
            applyRestingParams()
        }
        if let c = p.fxCurves {
            fxEQCurves = c.mapValues(EQCurve.normalize).filter { !$0.value.isEmpty }
            applyEQCurves()
        } else if let pv = p.paramValues {
            // a file from the graphic-EQ era: its bands become the curve
            let legacy = TarabdaarPreset.legacyEQCurves(in: pv)
            if !legacy.isEmpty { fxEQCurves = legacy; applyEQCurves() }
        }
        if let c = p.composites { composites = c }
        if let t = p.tiltMapping { tiltMapping = t }
        if let steps = p.droneSequence { droneSequenceSteps = DroneSequence.normalized(steps) }
        if let m = p.mainInstrument,
           let inst = AudioEngine.MainInstrument(rawValue: m) {
            mainInstrument = inst
        }
        if let d = p.droneVoice,
           let mode = AudioEngine.DroneVoiceMode(rawValue: d) {
            droneVoice = mode
        }
    }

    /// The shipped default as a full rig: generated bank, artifact physics,
    /// default composites and bindings, String voice, tanpura drones.
    func loadFactoryPreset(_ preset: Preset) {
        sarangi.loadSarangiLiveDefault(preset)
        resetAllParams()
        composites = CompositeParam.defaults()
        tiltMapping = DimensionMapping.makeDefault()
        mainInstrument = .string
        droneVoice = .tanpura
        droneSequenceSteps = DroneSequence.defaultSteps
    }

    // MARK: The preset library — no file panels

    /// Saved presets live in the app-managed library (one `.tarabdaar` file
    /// each) and appear in the Load-preset menu by name. No file panels.
    let presetLibrary = PresetLibrary.standard()

    /// The library's preset names, refreshed on save/delete and whenever
    /// the toolbar appears.
    @Published private(set) var savedPresetNames: [String] = []

    func refreshPresetLibrary() {
        savedPresetNames = presetLibrary.names()
    }

    /// Save the current rig into the library under `name` (overwrites a
    /// same-named preset). Returns the saved (sanitized) name.
    @discardableResult
    func savePresetToLibrary(name: String) throws -> String {
        let clean = try PresetLibrary.sanitized(name)
        try presetLibrary.save(capturePreset(name: clean), name: clean)
        refreshPresetLibrary()
        return clean
    }

    /// Load and apply a library preset, returning the decoded document so
    /// the caller can report what landed (`sections()`).
    @discardableResult
    func loadPresetFromLibrary(name: String) throws -> TarabdaarPreset {
        let p = try presetLibrary.load(name: name)
        applyPreset(p)
        return p
    }

    func deletePresetFromLibrary(name: String) throws {
        try presetLibrary.delete(name: name)
        refreshPresetLibrary()
    }
}
