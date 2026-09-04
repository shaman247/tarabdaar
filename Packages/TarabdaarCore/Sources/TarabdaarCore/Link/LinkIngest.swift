import Foundation

/// What the Mac-side ingest drives (`AudioEngine`; tests use a mock).
/// Called on the link receive queue — must be thread-safe.
public protocol LinkPerformanceSink: AnyObject {
    func touchOn(_ id: UInt16, pitchSemis: Double, velocity: Double)
    func touchGlide(_ id: UInt16, pitchSemis: Double)
    func touchOff(_ id: UInt16)
    func touchesAllOff()
    func setDronePressed(_ index: Int, _ pressed: Bool)
    /// Per-touch expression scale (in-process only; the strum chord).
    /// Delivered BEFORE `touchOn` when ≠ 1, and on change while held.
    func touchExpr(_ id: UInt16, exprScale: Double)
    /// Glide-queue exemption (in-process only; the strum chord). Delivered
    /// BEFORE the touch's `touchOn`.
    func touchGlideExempt(_ id: UInt16)
}

public extension LinkPerformanceSink {
    func touchExpr(_ id: UInt16, exprScale: Double) {}
    func touchGlideExempt(_ id: UInt16) {}
}

extension AudioEngine: LinkPerformanceSink {}

/// Mac-side ingestion of TLP performance state: diffs consecutive
/// PERF_STATE frames into touch on/glide/off + drone edges + tilt changes.
///
/// Each frame is the COMPLETE touch set — an id absent from the new frame
/// is a note-off, a new id is a note-on, a changed onsetSeq on a present
/// id is a retrigger (an off+on collapsed into one frame by latest-wins
/// coalescing). Apply order per frame: removals → additions/retriggers →
/// pitch updates. Every note-on mounts a fresh string.
///
/// NOT thread-safe — confine to the link receive queue. Sequence gating
/// (drop-non-newer stateSeq) happens upstream in the link; `apply` assumes
/// frames arrive in order.
public final class LinkIngest {
    public weak var sink: LinkPerformanceSink?
    /// Raw tilt (axis 0…2, −1…+1, rest 0), fired only on change — the
    /// heartbeat's repeats are dropped here. All handlers below fire on the
    /// link receive queue and must be thread-safe.
    public var onTiltAxis: ((Int, Double) -> Void)?
    /// Raw accelerometer (x, y, z) in g, on change — display diagnostics.
    public var onAccel: ((Double, Double, Double) -> Void)?
    /// Strike-scale envelope 0…1 (the `.strike`/`.acceleration` pair), on
    /// change — byte-gated by the producer, so a resting iPad is silent.
    public var onStrike: ((Double) -> Void)?
    /// Note-lifecycle edges for the strike blend window: (id, true) at
    /// every fresh articulation (new touch or retrigger), (id, false) at
    /// release and on the drop path.
    public var onTouchGate: ((UInt16, Bool) -> Void)?
    /// Per-touch pitch (id, fractional MIDI) at every onset and glide — the
    /// `.fingerAccel` feed.
    public var onTouchPitch: ((UInt16, Double) -> Void)?
    /// Per-touch FINGERTIP RADIUS in points, at every onset and on every
    /// change of the wire byte — the `.touchSize` dimension's feed
    /// (`TouchSizeTracker`). 0 from producers without a touchscreen.
    public var onTouchRadius: ((UInt16, Double) -> Void)?
    /// Chord bar selection, on CHANGE only (heartbeat repeats are silent,
    /// so a Mac-local selection is not clobbered by an idle iPad); nil =
    /// deselected.
    public var onChordSelect: ((ChordSelection?) -> Void)?

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
        // A hand of touches at most: linear scans, no per-frame hashing.
        let prevTouches = prev?.touches ?? []
        for t in prevTouches where !frame.touches.contains(where: { $0.id == t.id }) {
            sink.touchOff(t.id)
            onTouchGate?(t.id, false)
        }
        for t in frame.touches {
            if let p = prevTouches.first(where: { $0.id == t.id }) {
                if p.onsetSeq != t.onsetSeq {
                    // expr before the onset so the pluck level sees it
                    if t.exprScale != 1.0 || p.exprScale != 1.0 {
                        sink.touchExpr(t.id, exprScale: t.exprScale)
                    }
                    if t.glideExempt { sink.touchGlideExempt(t.id) }
                    sink.touchOn(t.id, pitchSemis: Double(t.pitch),
                                 velocity: Double(t.velocity) / 255.0)
                    onTouchGate?(t.id, true)
                    onTouchPitch?(t.id, Double(t.pitch))
                    onTouchRadius?(t.id, t.radiusPoints)
                } else {
                    if p.exprScale != t.exprScale {
                        sink.touchExpr(t.id, exprScale: t.exprScale)
                    }
                    if p.pitch != t.pitch {
                        sink.touchGlide(t.id, pitchSemis: Double(t.pitch))
                        onTouchPitch?(t.id, Double(t.pitch))
                    }
                    if p.radius != t.radius {
                        onTouchRadius?(t.id, t.radiusPoints)
                    }
                }
            } else {
                if t.exprScale != 1.0 {
                    sink.touchExpr(t.id, exprScale: t.exprScale)
                }
                if t.glideExempt { sink.touchGlideExempt(t.id) }
                sink.touchOn(t.id, pitchSemis: Double(t.pitch),
                             velocity: Double(t.velocity) / 255.0)
                onTouchGate?(t.id, true)
                onTouchPitch?(t.id, Double(t.pitch))
                onTouchRadius?(t.id, t.radiusPoints)
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

        // Chord bar selection: change-gated (prev is nil on reconnect).
        if frame.chordSelection != (prev?.chordSelection ?? nil) {
            onChordSelect?(frame.chordSelection)
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

        // Accelerometer: s16 ↔ ±accelFullScaleG g, change-gated as a vector.
        let a = (frame.accelX, frame.accelY, frame.accelZ)
        if a != lastAccel {
            lastAccel = a
            let s = TLPPerfState.accelFullScaleG / 32767.0
            onAccel?(Double(a.0) * s, Double(a.1) * s, Double(a.2) * s)
        }

        // Strike-scale envelope: byte ↔ 0…1, change-gated.
        if frame.strike != lastStrike {
            lastStrike = frame.strike
            onStrike?(Double(frame.strike) / 255.0)
        }
    }

    /// The kill path — link dropped/stale, or the peer sent PANIC.
    /// SURGICAL: only the touches and drones THIS ingest's frames
    /// introduced are released — a wire event must never be able to kill
    /// the Mac's local-pad notes.
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
