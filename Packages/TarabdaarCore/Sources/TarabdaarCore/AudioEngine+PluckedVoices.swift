import AVFoundation
import Foundation
import SarangiKit

// The plucked voices (tanpura + sitar, one shared mount): enable/rebuild,
// the shared `<prefix>_*` trims, the drone-button path and the main
// instrument selection.
extension AudioEngine {
    /// The plucked voice a main instrument routes to (nil = String). Callers hold `lock`.
    private func pluckVoiceLocked(_ inst: MainInstrument) -> PluckedVoice? {
        switch inst {
        case .string: return nil
        case .tanpura: return tanpuraVoice
        case .sitar: return sitarVoice
        }
    }

    /// The plucked source a main instrument routes to (nil = String). Callers hold `lock`.
    func pluckSourceLocked(_ inst: MainInstrument) -> TanpuraVoiceSource? {
        pluckVoiceLocked(inst)?.source
    }

    /// Per-instrument pluck trims. Callers hold `lock`.
    func pluckTrimsLocked(_ inst: MainInstrument)
        -> (level: Double, touch: Double, drive: Double, relT60: Double) {
        (pluckVoiceLocked(inst) ?? tanpuraVoice).pluckTrims
    }

    /// Touch-keyed twin of `pluckMain`; `exprScale` scales the pluck level
    /// (the strum chord, onset-only).
    func pluckMainTouch(_ inst: MainInstrument, hz: Double,
                        velocity: Double, touch id: UInt16,
                        exprScale: Double = 1.0) {
        lock.lock()
        let (level, fingerTouch, drive, _) = pluckTrimsLocked(inst)
        let src = pluckSourceLocked(inst)
        lock.unlock()
        guard let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 60)
        else { return }
        engine.pluck(slot: slot, velocity01: velocity,
                     scale: level * exprScale,
                     bendRatio: hz / engine.slotFrequencies[slot],
                     touch: fingerTouch, drive: drive)
        lock.lock()
        tanpuraTouchSlot[id] = slot
        lock.unlock()
    }

    // MARK: - Plucked voice bridge (tanpura + sitar, one path)

    /// Enable one plucked voice: mount the source on first enable (artifact
    /// check, out-gain override, the voice→taraf tap at its own drive),
    /// attach/connect the node, then (re)build it on the retained scale.
    /// False only when the fitted artifact is missing.
    @discardableResult
    private func setPluckedVoiceEnabled(_ v: PluckedVoice, _ on: Bool) -> Bool {
        if on && v.source == nil {
            guard v.artifactLoads else {
                NSLog("Tarabdaar: \(v.artifactFile) missing from the SarangiKit bundle")
                return false
            }
            let src = TanpuraVoiceSource()
            if let g = v.gainOverride { src.setOutGain(g) }
            // voice→taraf tap; the String voice exists by now (enabled first)
            if let strSrc = stringVoiceSource {
                src.setInjectSink { strSrc.jtInjectWrite($0, $1) }
            }
            lock.lock()
            let drive = v.tarafDrive
            lock.unlock()
            src.setInjectGain(drive)
            v.source = src
            updateJtInjectArm()
        }
        if let src = v.source, on != v.connected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !v.attached {
                    engine.attach(src.node)
                    v.attached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            v.connected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after \(v.name) switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        lock.lock()
        let tonic = lastTanpuraTonic
        let ratios = lastTanpuraRatios
        lock.unlock()
        if on, !ratios.isEmpty {
            rebuildPlucked(v, tonic: tonic, scaleRatios: ratios)
        }
        return true
    }

    /// (Re)build one plucked voice's JI slot grid off-main (seconds of CPU).
    /// A newer build supersedes; `published` runs on main right after the
    /// swap (the per-voice hooks: the slot map and the tanpura's drones).
    private func rebuildPlucked(_ v: PluckedVoice, tonic: Double,
                                scaleRatios: [Double]) {
        lock.lock()
        let armed = v.source != nil
        let artifact = v.artifact
        let registerComp = v.registerComp
        let cascade = v.cascade
        let poly = Int(v.poly.rounded())
        lock.unlock()
        guard armed else { return }
        v.buildGen += 1
        let gen = v.buildGen
        tanpuraBuildQueue.async { [weak self] in
            let engine = TanpuraVoiceSource.buildEngine(tonicHz: tonic,
                                                scaleRatios: scaleRatios,
                                                artifact: artifact,
                                                registerComp: registerComp,
                                                cascade: cascade,
                                                polyphony: poly)
            DispatchQueue.main.async {
                guard let self, gen == v.buildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: \(v.name) engine build failed (\(v.artifactFile) missing?)")
                }
                v.source?.setEngine(engine)
                self.pluckedEnginePublished(v)
            }
        }
    }

    /// The per-voice hook after a fresh engine is published (main thread):
    /// the fresh slots differ, so held notes lose their binding — the sitar
    /// only owns that map while it IS the main instrument, and the tanpura
    /// re-strikes its held drone buttons onto the silent new engine.
    private func pluckedEnginePublished(_ v: PluckedVoice) {
        lock.lock()
        if v !== sitarVoice || mainInstrumentStorage == .sitar {
            tanpuraTouchSlot.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if v === tanpuraVoice { reapplyHeldTanpuraDrones() }
    }

    /// The `<prefix>_*` trims BOTH plucked voices carry. False for a key
    /// outside the shared set (the caller handles its own extras).
    @discardableResult
    private func setPluckedParam(_ v: PluckedVoice, _ key: String,
                                 _ value: Double) -> Bool {
        switch key.hasPrefix(v.prefix) ? String(key.dropFirst(v.prefix.count)) : "" {
        case "gain":
            v.gainOverride = value
            v.source?.setOutGain(value)
        case "pluck_level":
            lock.lock(); v.pluckLevel = value; lock.unlock()
        case "rel_t60":
            lock.lock(); v.releaseT60 = value; lock.unlock()
        case "pluck_touch":
            lock.lock(); v.pluckTouch = value; lock.unlock()
        case "pluck_drive":
            lock.lock(); v.pluckDrive = value; lock.unlock()
        case "poly":
            lock.lock()
            v.poly = value
            let src = v.source
            lock.unlock()
            src?.currentEngine()?.setPolyphony(Int(value.rounded()))
        case "taraf":
            // per-source tap gain; the kernel-side gain is the shared arm
            lock.lock()
            v.tarafDrive = value
            let src = v.source
            lock.unlock()
            src?.setInjectGain(value)
            updateJtInjectArm()
        default:
            return false
        }
        return true
    }

    /// Enable the tanpura source (node + off-main engine build on first
    /// enable). Armed once at startup — the default drone voice.
    @discardableResult
    public func setTanpuraVoiceEnabled(_ on: Bool) -> Bool {
        setPluckedVoiceEnabled(tanpuraVoice, on)
    }

    /// True once a tanpura engine is mounted and renderable.
    public var isTanpuraArmed: Bool { tanpuraVoice.source?.isArmed ?? false }

    /// (Re)build the tanpura's JI slot grid. The tonic + scale are RETAINED
    /// here for both plucked voices (the sitar rebuilds off the same push).
    public func rebuildTanpura(tonic: Double, scaleRatios: [Double]) {
        lock.lock()
        lastTanpuraTonic = tonic
        lastTanpuraRatios = scaleRatios
        lock.unlock()
        rebuildPlucked(tanpuraVoice, tonic: tonic, scaleRatios: scaleRatios)
    }

    /// Enable the sitar voice (the same mount as the tanpura). Its render
    /// tap feeds the jt inject ring (`st_taraf`); the String voice stays
    /// armed and silent so the web can ring. False if `sitar_live.json` is missing.
    @discardableResult
    public func setSitarVoiceEnabled(_ on: Bool) -> Bool {
        setPluckedVoiceEnabled(sitarVoice, on)
    }

    /// True once a sitar engine is mounted and renderable.
    public var isSitarArmed: Bool { sitarVoice.source?.isArmed ?? false }

    /// (Re)build the sitar's JI slot grid — same discipline as `rebuildTanpura`,
    /// no shaping layers.
    public func rebuildSitar(tonic: Double, scaleRatios: [Double]) {
        rebuildPlucked(sitarVoice, tonic: tonic, scaleRatios: scaleRatios)
    }

    /// Apply one `st_*` live registry parameter (same contract as `setTanpuraParam`).
    @discardableResult
    public func setSitarParam(_ key: String, _ value: Double) -> Bool {
        setPluckedParam(sitarVoice, key, value)
    }

    /// (Re)publish the String kernel's inject-ring arm: 1 while any foreign
    /// voice drives the taraf (`st_taraf` / `tp_taraf` > 0), else 0. Levels
    /// live at the taps; both zero keeps the ring unwritten (byte-null).
    private func updateJtInjectArm() {
        lock.lock()
        let armed = sitarVoice.tarafDrive > 0 || tanpuraVoice.tarafDrive > 0
        lock.unlock()
        stringVoiceSource?.setJtInjectGain(armed ? 1.0 : 0.0)
    }

    /// Which voice the drone buttons drive. Switching releases everything
    /// held so the buttons start clean in the new mode.
    public func setDroneVoiceMode(_ mode: DroneVoiceMode) {
        lock.lock()
        guard mode != droneVoiceModeStorage else { lock.unlock(); return }
        let oldMode = droneVoiceModeStorage
        droneVoiceModeStorage = mode
        let heldOld = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        for i in droneHeld.indices { droneHeld[i] = false }
        for i in droneCycleGen.indices { droneCycleGen[i] += 1 }
        let strSrc = stringVoiceSource
        let tpSrc = tanpuraVoice.source
        lock.unlock()
        if oldMode == .sympathetic, let engine = strSrc?.currentEngine() {
            for hz in heldOld {
                if let row = engine.droneRow(forExactHz: hz) {
                    engine.droneRelease(row: row)
                }
            }
        }
        if oldMode == .tanpura { tpSrc?.currentEngine()?.allNotesOff() }
    }

    public var droneVoiceMode: DroneVoiceMode {
        lock.lock(); defer { lock.unlock() }
        return droneVoiceModeStorage
    }

    /// Which voice the played notes drive. Leaving the String voice
    /// releases its notes; leaving a plucked voice drops pending plucks.
    public func setMainInstrument(_ inst: MainInstrument) {
        // an in-flight glissando references the outgoing voice's notes
        glideQueue.reset()
        lock.lock()
        guard inst != mainInstrumentStorage else { lock.unlock(); return }
        let old = mainInstrumentStorage
        mainInstrumentStorage = inst
        tanpuraTouchSlot.removeAll(keepingCapacity: true)
        let strSrc = stringVoiceSource
        lock.unlock()
        if old == .string { strSrc?.reset() }
        // the sitar arms lazily and stays armed (idle strings are ~free)
        if inst == .sitar { setSitarVoiceEnabled(true) }
    }

    public var mainInstrument: MainInstrument {
        lock.lock(); defer { lock.unlock() }
        return mainInstrumentStorage
    }

    /// Apply one `tp_*` live registry parameter (thread-safe, persists across
    /// rebuilds): the shared plucked trims plus the tanpura's own extras —
    /// the drone-button trims and the two table-build shaping knobs.
    @discardableResult
    public func setTanpuraParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "tp_drone_level":
            lock.lock(); tanpuraDroneLevel = value; lock.unlock()
        case "tp_drone_cycle":
            lock.lock(); tanpuraDroneCycleSec = value; lock.unlock()
        case "tp_jiva_comp":
            lock.lock()
            let old = tanpuraVoice.registerComp
            tanpuraVoice.registerComp = value
            lock.unlock()
            // only a real change burns a seconds-long rebuild
            if value != old { scheduleTanpuraTableRebuild() }
        case "tp_cascade":
            lock.lock()
            let oldC = tanpuraVoice.cascade
            tanpuraVoice.cascade = value
            lock.unlock()
            if value != oldC { scheduleTanpuraTableRebuild() }
        default:
            return setPluckedParam(tanpuraVoice, key, value)
        }
        return true
    }

    /// Debounced table-build rebuild: a slider drag settles (750 ms) before
    /// one seconds-long build runs; the generation guard supersedes in-flight ones.
    private func scheduleTanpuraTableRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tanpuraTableRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let tonic = self.lastTanpuraTonic
                let ratios = self.lastTanpuraRatios
                self.lock.unlock()
                guard !ratios.isEmpty else { return }
                self.rebuildTanpura(tonic: tonic, scaleRatios: ratios)
            }
            self.tanpuraTableRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75,
                                          execute: work)
        }
    }

    /// One drone-button pluck at the mapped pitch's slot (50 ¢ tolerance
    /// guards a mid-rebuild mismatch).
    private func tanpuraPluckDrone(_ index: Int) {
        lock.lock()
        let hz = droneFreqs.indices.contains(index) ? droneFreqs[index] : nil
        let level = tanpuraDroneLevel
        let touch = tanpuraVoice.pluckTouch
        let drive = tanpuraVoice.pluckDrive
        let src = tanpuraVoice.source
        lock.unlock()
        guard let hz, let engine = src?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 50)
        else { return }
        engine.pluck(slot: slot, velocity01: 100.0 / 127.0, scale: level,
                     touch: touch, drive: drive)
    }

    /// Hold re-pluck cycle: re-pluck every `tp_drone_cycle` s while held
    /// (period re-read each hop); a bumped generation orphans the chain.
    private func scheduleDroneCycle(_ index: Int, gen: Int) {
        lock.lock()
        let period = tanpuraDroneCycleSec
        lock.unlock()
        guard period >= 0.1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + period) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.droneCycleGen.indices.contains(index)
                && self.droneCycleGen[index] == gen
                && self.droneHeld.indices.contains(index)
                && self.droneHeld[index]
                && self.droneVoiceModeStorage == .tanpura
            self.lock.unlock()
            guard live else { return }
            self.tanpuraPluckDrone(index)
            self.scheduleDroneCycle(index, gen: gen)
        }
    }

    /// Re-strike held drone buttons on a freshly built tanpura (it starts silent).
    private func reapplyHeldTanpuraDrones() {
        lock.lock()
        let held = droneHeld.indices.filter {
            droneHeld[$0] && droneVoiceModeStorage == .tanpura
        }
        lock.unlock()
        for i in held { tanpuraPluckDrone(i) }
    }

    // MARK: - Drone buttons (Fret Pad)

    /// Update which strings the drone buttons pluck (mapping only — no
    /// rebuild). Any held button is released first.
    public func setDroneMappedFreqs(_ freqs: [Double?]) {
        lock.lock()
        let heldOld = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        for i in droneFreqs.indices {
            droneFreqs[i] = freqs.indices.contains(i) ? freqs[i] : nil
            droneHeld[i] = false
        }
        for i in droneCycleGen.indices { droneCycleGen[i] += 1 }
        let mode = droneVoiceModeStorage
        let src = stringVoiceSource
        lock.unlock()
        guard mode == .sympathetic, let engine = src?.currentEngine() else { return }
        for hz in heldOld {
            if let row = engine.droneRow(forExactHz: hz) {
                engine.droneRelease(row: row)
            }
        }
    }

    /// Press/release drone button `index` (0–2). Tanpura mode: press plucks
    /// + starts the re-pluck cycle, release rings out. Sympathetic mode:
    /// hold/release the mapped jt row. Unmapped = inert. MIDI-thread safe.
    public func setDronePressed(_ index: Int, _ pressed: Bool) {
        lock.lock()
        guard droneHeld.indices.contains(index),
              let hz = droneFreqs[index] else { lock.unlock(); return }
        let was = droneHeld[index]
        droneHeld[index] = pressed
        let mode = droneVoiceModeStorage
        if mode == .tanpura, pressed != was {
            droneCycleGen[index] += 1
        }
        let cycleGen = droneCycleGen[index]
        // a release must not silence a row another held button maps to
        let othersHeld = droneHeld.indices
            .filter { $0 != index && droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        let src = stringVoiceSource
        lock.unlock()
        guard pressed != was else { return }
        if mode == .tanpura {
            guard pressed else { return }   // release = ring out
            tanpuraPluckDrone(index)
            scheduleDroneCycle(index, gen: cycleGen)
            return
        }
        guard let engine = src?.currentEngine(),
              let row = engine.droneRow(forExactHz: hz)
        else { return }
        if pressed {
            engine.dronePress(row: row)
        } else if !othersHeld.contains(where: {
            engine.droneRow(forExactHz: $0) == row
        }) {
            engine.droneRelease(row: row)
        }
    }
}
