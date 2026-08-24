import Foundation

/// What the Mac-side ingest drives. `AudioEngine` conforms; tests use a
/// recording mock. All methods must be thread-safe — they are called on
/// the link receive queue (the CoreMIDI thread's old role).
/// `posY` is the touch's fret-band y (0…1 top→bottom) when the frame
/// carried one, nil otherwise — the fret-linger recharge travel signal.
/// `fretY` is the position within the touch's home fret's extent (0.5 ≈
/// the fret's centre) — the auto-vibrato ceiling axis. Touches without
/// them keep the corresponding legacy behavior.
public protocol LinkPerformanceSink: AnyObject {
    func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double,
                 posY: Double?, fretY: Double?)
    func touchGlide(_ id: UInt16, pitchSemis: Double, posY: Double?,
                    fretY: Double?)
    func touchOff(_ id: UInt16)
    func touchesAllOff()
    func setDronePressed(_ index: Int, _ pressed: Bool)
}

extension AudioEngine: LinkPerformanceSink {}

/// Mac-side ingestion of TLP performance state: diffs consecutive
/// PERF_STATE frames into touch on/glide/off + drone edges + tilt changes.
///
/// Frame semantics (the redesign's core): each frame is the COMPLETE touch
/// set — an id absent from the new frame is a note-off, a new id is a
/// note-on, a changed onsetSeq on a present id is a retrigger (an off+on
/// that collapsed into one frame under latest-wins coalescing). Apply
/// order per frame: removals → additions/retriggers → pitch updates —
/// the same sequence a MIDI stream would have produced, so the mapper's
/// legato/steal laws behave identically.
///
/// NOT thread-safe — confine to the link receive queue. Sequence gating
/// (drop-non-newer stateSeq) happens upstream in the link; `apply` assumes
/// frames arrive in order.
public final class LinkIngest {
    public weak var sink: LinkPerformanceSink?
    /// Raw tilt delivery, (axis 0…2, value −1…+1, rest 0) — same contract
    /// as the old `AudioEngine.onTiltAxis`: fired only on change (the
    /// heartbeat's unchanged repeats are dropped HERE, absorbing the
    /// dedupe AppController used to do). Handler must be thread-safe.
    public var onTiltAxis: ((Int, Double) -> Void)?
    /// Raw accelerometer delivery, (x, y, z) in g — display-only
    /// diagnostics (the Setup tab's received-acceleration view). Fired
    /// on change. Handler must be thread-safe.
    public var onAccel: ((Double, Double, Double) -> Void)?
    /// Strike-scale envelope delivery, 0…1 (TLP v6) — the raw value
    /// behind the `.strike`/`.acceleration` dimension pair. Fired on
    /// change (byte-gated by the producer, so a resting iPad is silent
    /// here). Handler must be thread-safe.
    public var onStrike: ((Double) -> Void)?
    /// Note-lifecycle edges for the strike blend window (2026-08-23):
    /// (id, true) at every fresh articulation — a new touch AND a
    /// retrigger (new onsetSeq), which re-anchors that id's window —
    /// (id, false) at release and on the drop path. Fires alongside the
    /// sink calls on the link receive queue.
    public var onTouchGate: ((UInt16, Bool) -> Void)?

    private var last: TLPPerfState?
    private var lastTilt: [Double] = [.nan, .nan, .nan]
    private var lastAccel: (Int16, Int16, Int16) = (.min, .min, .min)
    private var lastStrike: UInt8 = .max

    public init(sink: LinkPerformanceSink? = nil) {
        self.sink = sink
    }

    public func apply(_ frame: TLPPerfState) {
        let prev = last
        last = frame
        guard let sink else { return }

        // Touches: removals → additions/retriggers → glides.
        let prevTouches = prev?.touches ?? []
        var newIds = Set<UInt16>()
        newIds.reserveCapacity(frame.touches.count)
        for t in frame.touches { newIds.insert(t.id) }
        for t in prevTouches where !newIds.contains(t.id) {
            sink.touchOff(t.id)
            onTouchGate?(t.id, false)
        }
        var prevById = [UInt16: TLPTouch](minimumCapacity: prevTouches.count)
        for t in prevTouches { prevById[t.id] = t }
        for t in frame.touches {
            if let p = prevById[t.id] {
                if p.onsetSeq != t.onsetSeq {
                    sink.touchOn(t.id, pitchSemis: Double(t.pitch),
                                 velocity: Double(t.velocity) / 255.0,
                                 posY: t.posY01, fretY: t.fretY01)
                    onTouchGate?(t.id, true)
                } else if p.pitch != t.pitch || p.posY != t.posY
                            || p.fretY != t.fretY || p.flags != t.flags {
                    // A y-only move (vertical travel along a fret) must
                    // reach the sink — it recharges the linger envelopes
                    // even though the pitch is unchanged.
                    sink.touchGlide(t.id, pitchSemis: Double(t.pitch),
                                    posY: t.posY01, fretY: t.fretY01)
                }
            } else {
                sink.touchOn(t.id, pitchSemis: Double(t.pitch),
                             velocity: Double(t.velocity) / 255.0,
                             posY: t.posY01, fretY: t.fretY01)
                onTouchGate?(t.id, true)
            }
        }

        // Drone buttons: mask-bit edges.
        let prevMask = prev?.droneMask ?? 0
        if frame.droneMask != prevMask {
            for i in 0..<FretArrangement.droneCount {
                let bit: UInt8 = 1 << UInt8(i)
                if (frame.droneMask ^ prevMask) & bit != 0 {
                    sink.setDronePressed(i, frame.droneMask & bit != 0)
                }
            }
        }

        // Tilt: s16 −32767…32767 ↔ −1…+1, change-gated per axis.
        let axes = [frame.tiltX, frame.tiltY, frame.tiltZ]
        for (axis, raw) in axes.enumerated() {
            let v = Double(raw) / 32767.0
            if lastTilt[axis] != v {
                lastTilt[axis] = v
                onTiltAxis?(axis, v)
            }
        }

        // Accelerometer: s16 ↔ ±accelFullScaleG g, change-gated as a
        // vector (the three axes always travel together).
        let a = (frame.accelX, frame.accelY, frame.accelZ)
        if a != lastAccel {
            lastAccel = a
            let s = TLPPerfState.accelFullScaleG / 32767.0
            onAccel?(Double(a.0) * s, Double(a.1) * s, Double(a.2) * s)
        }

        // Strike-scale envelope (v6): byte ↔ 0…1, change-gated.
        if frame.strike != lastStrike {
            lastStrike = frame.strike
            onStrike?(Double(frame.strike) / 255.0)
        }
    }

    /// The kill path — link dropped/stale, or the peer sent PANIC. It is
    /// SURGICAL: only the touches and drones THIS ingest's frames
    /// introduced are released (it knows them from its last frame) — a
    /// wire event must never be able to kill the Mac's local-pad notes
    /// (the 2026-08-14 staccato loop's blast radius).
    public func linkDidDrop() {
        let prev = last
        last = nil
        lastTilt = [.nan, .nan, .nan]
        lastAccel = (.min, .min, .min)
        guard let sink else { return }
        for t in prev?.touches ?? [] {
            sink.touchOff(t.id)
            onTouchGate?(t.id, false)
        }
        let mask = prev?.droneMask ?? 0
        for i in 0..<FretArrangement.droneCount
        where mask & (1 << UInt8(i)) != 0 {
            sink.setDronePressed(i, false)
        }
    }
}
