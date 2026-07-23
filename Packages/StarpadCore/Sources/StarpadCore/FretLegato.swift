import Foundation

// MARK: - Fret Pad tap legato
//
// For very fast phrases, dragging one finger doesn't work — the natural
// gesture is **tapping** the notes. Without help, every tap re-articulates a
// fresh note. Tap legato turns consecutive taps into ONE continuous voice:
//
//   • A tap that lands while the previous note is still sounding — held, or
//     within the **release grace window** (`window`, ~120 ms; fast taps have
//     tiny gaps or overlaps) — takes the voice over instead of retriggering:
//     `PitchPadEngine.transferTouch` moves ownership with no MIDI events (the
//     held note keeps sounding; true legato for SWAM / the sarangi model),
//     and the pitch **glides** from the previous note to the new tap's
//     (onset-snapped) pitch over `glideDuration` (~50 ms, smoothstepped).
//   • In legato mode the surface is mono, last-note priority: a new tap
//     steals the voice; the older finger becomes inert (its `noteOff` is a
//     harmless no-op after the transfer).
//   • Releases of the voice owner are DEFERRED by `window` so the bridge to
//     the next tap exists; if no tap comes, the surface's 60 Hz timer sends
//     the real `noteOff` when the window expires (notes ring ≤ `window`
//     longer than the finger — negligible under a bowed release tail).
//
// The glide is an **additive offset** that starts at exactly the previous
// pitch and smoothsteps to zero: `played = assistOut + offset(t)`. It
// composes with the drag assist and the onset snap, and cannot produce a
// discontinuity (output starts at the old pitch by construction).
//
// One instance per surface (like `FretDragAssist`); the surface reports every
// pitch it sends via `noteOutput` so a takeover knows its from-pitch. Time is
// injected (`CACurrentMediaTime()`), same as the assist.
public final class FretLegato {
    /// Release grace window (s): a tap within this after the owner lifts
    /// glides from it; otherwise the note-off fires when it expires.
    public var window: TimeInterval = 0.12
    /// Takeover glide time (s), smoothstepped old → new pitch.
    public var glideDuration: TimeInterval = 0.05

    private var voiceOwner: Int? = nil
    private var pendingDeadline: TimeInterval? = nil
    private var ramp: (offset0: Double, start: TimeInterval)? = nil
    private var lastLog: [Int: Double] = [:]

    public init() {}

    /// True when no voice is held or pending — the surface's timer may stop.
    public var isIdle: Bool { voiceOwner == nil }

    /// Record what a touch last played (call after every send — noteOn,
    /// glide, and timer ticks); the takeover glide starts from this.
    public func noteOutput(_ touch: Int, log: Double) {
        lastLog[touch] = log
    }

    /// New tap: if a voice is sounding (held or pending), returns its touch
    /// id + last pitch for takeover; nil means start a fresh note. Either
    /// way the new touch becomes the voice owner.
    public func tapBegan(_ touch: Int, time: TimeInterval) -> (touch: Int, log: Double)? {
        defer {
            voiceOwner = touch
            pendingDeadline = nil
        }
        guard let prev = voiceOwner, prev != touch,
              let log = lastLog[prev] else { return nil }
        lastLog.removeValue(forKey: prev)
        return (prev, log)
    }

    /// Arm the takeover glide: output starts at `fromLog` (the previous
    /// note's pitch) and smoothsteps onto the assist output over
    /// `glideDuration`.
    public func startRamp(fromLog: Double, onsetLog: Double, time: TimeInterval) {
        ramp = (fromLog - onsetLog, time)
    }

    /// The glide's additive offset for this touch at `time` (0 when idle,
    /// finished, or not the voice owner).
    public func offset(_ touch: Int, time: TimeInterval) -> Double {
        guard touch == voiceOwner, let r = ramp else { return 0 }
        let t = (time - r.start) / max(0.001, glideDuration)
        if t >= 1 {
            ramp = nil
            return 0
        }
        let s = t * t * (3 - 2 * t)
        return r.offset0 * (1 - s)
    }

    /// A touch lifted. Returns true when it owns the voice → the release is
    /// DEFERRED (skip `noteOff`; the timer sends it via `expiredVoice`).
    /// Non-owners return false (their `noteOff` is a no-op post-transfer).
    public func touchEnded(_ touch: Int, time: TimeInterval) -> Bool {
        guard touch == voiceOwner else {
            lastLog.removeValue(forKey: touch)
            return false
        }
        pendingDeadline = time + window
        return true
    }

    /// Timer poll: the voice touch whose deferred release just expired (send
    /// its `noteOff`), or nil.
    public func expiredVoice(time: TimeInterval) -> Int? {
        guard let deadline = pendingDeadline, time >= deadline,
              let owner = voiceOwner else { return nil }
        voiceOwner = nil
        pendingDeadline = nil
        ramp = nil
        lastLog.removeValue(forKey: owner)
        return owner
    }

    public func reset() {
        voiceOwner = nil
        pendingDeadline = nil
        ramp = nil
        lastLog.removeAll()
    }
}
