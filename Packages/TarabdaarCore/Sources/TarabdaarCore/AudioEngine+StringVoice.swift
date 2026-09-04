import AVFoundation
import Foundation
import SarangiKit

// The String voice: mounting the source on the graph, the live control
// parameters, the off-main engine rebuilds and the tarab tuning push.
extension AudioEngine {
    /// Enable/disable the String voice: creates + connects the node on first
    /// enable and builds the engine off-main. False if `bowed_string.json` is missing.
    @discardableResult
    public func setSarangiModelVoiceEnabled(_ on: Bool) -> Bool {
        if on && stringVoiceSource == nil {
            guard Presets.bowedStringParams() != nil else {
                NSLog("Tarabdaar: bowed_string.json missing from the SarangiKit bundle")
                return false
            }
            let src = StringVoiceSource()
            // always armed — the metered render is bit-exact (`BusMeterTests`)
            src.setBusMeter(true)
            stringVoiceSource = src
        }
        if let src = stringVoiceSource, on != stringVoiceConnected {
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            if on {
                if !stringVoiceAttached {
                    engine.attach(src.node)
                    stringVoiceAttached = true
                }
                let fmt = AVAudioFormat(standardFormatWithSampleRate: src.modelSR, channels: 2)!
                engine.connect(src.node, to: symGain, format: fmt)
            } else {
                engine.disconnectNodeOutput(src.node)
            }
            stringVoiceConnected = on
            if wasRunning {
                do { try engine.start() } catch {
                    print("AudioEngine restart after model-voice switch failed: \(error)")
                    isRunning = false
                }
            }
        }
        stringVoiceSource?.reset()
        lockAndMeasure()
        useSarangiModelVoice = on
        let strings = lastSarangiStrings
        let tonic = lastSarangiTonic
        let follower = lastSarangiFollower
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings,
                                   follower: follower) }
        storeMeter((0, 0, false))
        return true
    }

    /// Whether the String physics instrument is currently the base voice.
    public var isSarangiModelVoice: Bool {
        lock.lock(); defer { lock.unlock() }
        return useSarangiModelVoice
    }

    /// Drive one control axis from the UI (0..1): CC11 expr · CC1 press · CC74 pos · CC2/75 tilt.
    public func setSarangiModelVoiceAxis(cc: UInt8, value01: Double) {
        guard let m = stringVoiceSource?.mapper else { return }
        switch cc {
        case 11: m.setAxis(expr: value01)
        case 1: m.setAxis(press: value01)
        case 74: m.setAxis(pos: value01)
        case 2, 75: m.setAxis(tilt: value01)
        default: break
        }
    }

    /// Player vibrato depth 0..1 (the vibrato axis).
    public func setStringVibrato(_ v01: Double) {
        stringVoiceSource?.mapper.setVibrato(v01)
    }

    /// Apply one `.live` registry parameter to the String voice — the ONE
    /// instant-apply path. Returns false when the key has no live setter (the
    /// caller rebuilds). Setters are thread-safe and persist across rebuilds.
    @discardableResult
    public func setStringControlParam(_ key: String, _ value: Double) -> Bool {
        switch key {
        // the bow-control axes: the mapper, not the engine
        case "bow_expr":      setSarangiModelVoiceAxis(cc: 11, value01: value)
        case "bow_press":     setSarangiModelVoiceAxis(cc: 1, value01: value)
        case "bow_pos":       setSarangiModelVoiceAxis(cc: 74, value01: value)
        case "bow_tilt":      setSarangiModelVoiceAxis(cc: 75, value01: value)
        default:
            // the knob plumbing table (clamp + cache + push, and re-applied
            // across a rebuild); it owns the key even with no voice armed yet
            if StringVoiceSource.handlesControl(key) {
                stringVoiceSource?.setControl(key, value)
                return true
            }
            // FX rack: `fx_<point>_<field>` keys route to the source's cached settings
            if key.hasPrefix("fx_") {
                return stringVoiceSource?.setFXParam(key, value) ?? false
            }
            // the tanpura's `tp_*` group
            if key.hasPrefix("tp_") {
                return setTanpuraParam(key, value)
            }
            // the sitar's `st_*` group
            if key.hasPrefix("st_") {
                return setSitarParam(key, value)
            }
            return false
        }
        return true
    }

    /// Drive the kernel's live 0…1 scaler behind a `.hybrid` parameter (a
    /// build-time depth turned DOWN without a rebuild; `ParamRegistry` converts).
    public func setStringHybridScaler(_ scaler: ParamRegistry.HybridScaler,
                                      _ amount01: Double) {
        let a = max(0.0, min(1.0, amount01))
        switch scaler {
        case .vibratoAmount:  setStringVibrato(a)
        }
    }

    /// Re-arm held drones on a freshly built engine (it starts silent).
    private func reapplyHeldDrones(to engine: BowEngine) {
        lock.lock()
        let held = droneHeld.indices
            .filter { droneHeld[$0] }
            .compactMap { droneFreqs[$0] }
        lock.unlock()
        for hz in held {
            if let row = engine.droneRow(forExactHz: hz) {
                engine.dronePress(row: row)
            }
        }
    }

    /// Build a fresh String `BowEngine` off-main and publish it; the mapper
    /// keeps held notes/axes across the swap, a newer build supersedes.
    private func rebuildStringVoice(tonic: Double, strings: [ResolvedString],
                                    follower: (gain: Double, t60: Double)? = nil) {
        guard let src = stringVoiceSource else { return }
        stringBuildGen += 1
        let gen = stringBuildGen
        let overrides = stringVoiceOverrides
        let mapper = src.mapper
        stringBuildQueue.async { [weak self] in
            let engine = StringVoiceSource.buildEngine(tonicHz: tonic,
                                              strings: strings,
                                              mapper: mapper,
                                              overrides: overrides,
                                              follower: follower)
            DispatchQueue.main.async {
                guard let self, gen == self.stringBuildGen else { return }
                if engine == nil {
                    NSLog("Tarabdaar: String engine build failed (bowed_string.json missing?)")
                }
                self.stringVoiceSource?.setEngine(engine)
                if let engine { self.reapplyHeldDrones(to: engine) }
            }
        }
    }

    /// Push overrides onto the RUNNING engine when every changed key is in
    /// `ParamRegistry.inPlaceKeys`. False = the caller must rebuild.
    @discardableResult
    public func applyStringVoiceOverridesInPlace(
        _ overrides: [String: Double], changed: Set<String>) -> Bool {
        guard !changed.isEmpty,
              changed.allSatisfy({ ParamRegistry.appliesInPlace($0) })
        else { return false }
        lock.lock()
        let on = useSarangiModelVoice
        let tonic = lastSarangiTonic
        let strings = lastSarangiStrings
        let follower = lastSarangiFollower
        lock.unlock()
        guard on, let src = stringVoiceSource else { return false }
        stringVoiceOverrides = overrides
        // the jawari tables are the costly half — only when a jt key moved
        let jtTouched = changed.contains { $0.hasPrefix("bow_jt") }
        return src.applyLiveParams(tonicHz: tonic, strings: strings,
                                   overrides: overrides,
                                   follower: follower,
                                   needsJawariTables: jtTouched)
    }

    /// Re-apply the overrides with a rebuild (artifact scalars bake into the tables).
    public func setStringVoiceOverrides(_ overrides: [String: Double]) {
        stringVoiceOverrides = overrides
        lock.lock()
        let on = useSarangiModelVoice
        let tonic = lastSarangiTonic
        let strings = lastSarangiStrings
        let follower = lastSarangiFollower
        lock.unlock()
        if on { rebuildStringVoice(tonic: tonic, strings: strings,
                                   follower: follower) }
    }

    // MARK: - Tarab tuning (Strings tab) → String voice

    /// Push the tarab tuning (tonic + resolved strings) to the String
    /// voice's in-kernel taraf; the build runs off-main. `droneFreqs` = per
    /// drone button, the mapped string's nominal Hz (nil = inert);
    /// `follower` = the melody-follower's (gain, t60) when enabled.
    public func rebuildSarangi(strings: [ResolvedString], tonic: Double,
                               droneFreqs: [Double?] = [],
                               follower: (gain: Double, t60: Double)? = nil) {
        lockAndMeasure()
        lastSarangiStrings = strings
        lastSarangiTonic = tonic
        lastSarangiFollower = follower
        for i in self.droneFreqs.indices {
            self.droneFreqs[i] = droneFreqs.indices.contains(i) ? droneFreqs[i] : nil
        }
        // a slot unmapped while held must not stay latched
        for i in droneHeld.indices where self.droneFreqs[i] == nil {
            droneHeld[i] = false
        }
        let armModel = useSarangiModelVoice
        lock.unlock()
        if armModel { rebuildStringVoice(tonic: tonic, strings: strings,
                                         follower: follower) }
    }
}
