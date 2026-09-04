import Foundation
import SarangiKit

/// A VOICE THE FRET NOTES PLAY THROUGH — the String bow or a plucked mount.
/// Every touch entry point of `AudioEngine` speaks this and nothing else,
/// so the per-instrument paths cannot diverge. Calls arrive with the
/// engine's lock released; a voice keeps its own per-touch state.
protocol PlayedVoice: AnyObject {
    func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double, exprScale: Double)
    /// Per-touch expression scale (the strum chord); live while held or
    /// consumed at onset, as the voice can.
    func touchExpr(_ id: UInt16, exprScale: Double)
    func touchGlide(_ id: UInt16, pitchSemis: Double)
    func touchOff(_ id: UInt16)
    func touchAllOff()
    /// The Scope tab's sounding strings of this voice.
    func scopeVoices() -> [AudioEngine.ScopeSnapshot.Voice]
    /// The node's own output level for the volume readout; nil when the
    /// voice is metered on the String kernel's bus instead.
    func outputLevel() -> Double?
}

/// The bow: the mapper allocates a gut string per touch and follows the
/// finger at wire rate.
extension StringVoiceSource: PlayedVoice {
    func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double, exprScale: Double) {
        mapper.touchOn(id, pitchSemis: pitchSemis, velocity: velocity, exprScale: exprScale)
    }

    func touchExpr(_ id: UInt16, exprScale: Double) {
        mapper.setExprScale(exprScale, forTouch: id)
    }

    func touchGlide(_ id: UInt16, pitchSemis: Double) {
        mapper.touchGlide(id, pitchSemis: pitchSemis)
    }

    func touchOff(_ id: UInt16) { mapper.touchOff(id) }

    func touchAllOff() { mapper.touchAllOff() }

    func scopeVoices() -> [AudioEngine.ScopeSnapshot.Voice] {
        var out: [AudioEngine.ScopeSnapshot.Voice] = []
        for (i, s) in scopeSlots().enumerated() where s.level > 0 || s.gated {
            out.append(.init(id: i << 32 | Int(s.serial), pitchHz: s.f0Hz,
                             held: s.gated,
                             level: AudioEngine.bowScopeLevel01(s.level),
                             capture: s.capture, grip: s.grip))
        }
        return out
    }

    func outputLevel() -> Double? { nil }     // metered on the kernel's bus
}

/// A plucked mount: the onset plucks the nearest slot bent to the exact
/// pitch, a glide retunes the ringing slot, the release lets it ring down
/// at `<prefix>_rel_t60`. Expression is consumed at onset (a sounded
/// pluck cannot swell).
extension PluckedVoice: PlayedVoice {
    func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double, exprScale: Double) {
        let hz = Pitch.hz(fractionalMidi: pitchSemis)
        guard let engine = source?.currentEngine(),
              let slot = engine.nearestSlot(toHz: hz, toleranceCents: 60)
        else { return }
        engine.pluck(slot: slot, velocity01: velocity,
                     scale: pluckLevel * exprScale,
                     bendRatio: hz / engine.slotFrequencies[slot],
                     touch: pluckTouch, drive: pluckDrive)
        touchLock.lock()
        touchSlot[id] = slot
        touchLock.unlock()
    }

    func touchExpr(_ id: UInt16, exprScale: Double) {}

    func touchGlide(_ id: UInt16, pitchSemis: Double) {
        touchLock.lock()
        let slot = touchSlot[id]
        touchLock.unlock()
        guard let slot, let engine = source?.currentEngine(),
              slot < engine.slotFrequencies.count else { return }
        let hz = Pitch.hz(fractionalMidi: pitchSemis)
        engine.bend(slot: slot, ratio: hz / engine.slotFrequencies[slot])
    }

    func touchOff(_ id: UInt16) {
        touchLock.lock()
        let slot = touchSlot.removeValue(forKey: id)
        touchLock.unlock()
        guard let slot, let engine = source?.currentEngine() else { return }
        engine.release(slot: slot, rate: releaseRate)
    }

    func touchAllOff() {
        touchLock.lock()
        let slots = Array(touchSlot.values)
        touchSlot.removeAll(keepingCapacity: true)
        touchLock.unlock()
        guard let engine = source?.currentEngine() else { return }
        for s in slots { engine.release(slot: s, rate: releaseRate) }
    }

    func scopeVoices() -> [AudioEngine.ScopeSnapshot.Voice] {
        guard let engine = source?.currentEngine() else { return [] }
        touchLock.lock()
        let held = Set(touchSlot.values)
        touchLock.unlock()
        var out: [AudioEngine.ScopeSnapshot.Voice] = []
        for (i, s) in engine.scopeSlots().enumerated() where s.level > 0 {
            out.append(.init(id: i, pitchHz: s.hz, held: held.contains(i),
                             level: AudioEngine.pluckScopeLevel01(s.level),
                             capture: 0, grip: 0))
        }
        return out
    }

    func outputLevel() -> Double? { source?.outputLevel() }

    /// `<prefix>_rel_t60` as a release rate (fast, even after a switch back
    /// to the String voice).
    private var releaseRate: Double { log(1000.0) / max(0.05, releaseT60) }
}
