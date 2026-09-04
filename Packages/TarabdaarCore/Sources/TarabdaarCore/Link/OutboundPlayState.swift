import Foundation

/// The outbound performance snapshot: the single mutable truth the paced
/// sender serializes into PERF_STATE frames. Producers do O(1) locked
/// writes from any thread; the sender snapshots under the same lock. Wire
/// touch ids are assigned here — callers key by their own token and never
/// see them; `onsetSeq` comes from a global articulation counter so a
/// reused id still reads as a fresh onset.
public final class OutboundPlayState {
    private let lock = NSLock()
    private struct Touch {
        let wireId: UInt16
        let onsetSeq: UInt8
        let velocity: UInt8
        /// Fingertip size, the wire byte (see `TLPTouch.radius`).
        var radius: UInt8
        var pitch: Float
        /// In-process only — see `TLPTouch.exprScale`.
        var exprScale: Double
        /// In-process only — see `TLPTouch.glideExempt`.
        let glideExempt: Bool
    }
    private var touches: [(token: AnyHashable, touch: Touch)] = []
    /// Wire ids carry a per-instance namespace in the top 4 bits so two
    /// states feeding one sink never collide; the low 12 bits wrap.
    private let idNamespace: UInt16
    private var nextWireId: UInt16 = 0
    private var nextOnsetSeq: UInt8 = 0
    private static let namespaceCounter = NSLock()
    private static var nextNamespace: UInt16 = 0
    /// Tilt axes, −1…+1 each (rest = 0).
    private var tilt: [Double] = [0, 0, 0]
    /// Raw user acceleration in g (gravity removed), for the Mac's
    /// received-motion diagnostics.
    private var accelG: [Double] = [0, 0, 0]
    /// Strike-scale envelope, already quantized to the wire byte.
    private var strikeByte: UInt8 = 0
    private var droneMask: UInt8 = 0
    /// The chord bar's active strum chord (held state; nil = none).
    private var chordSelection: ChordSelection?
    private var backgrounded = false
    private var stateSeq: UInt16 = 0
    private var dirtyFlag = false
    /// Fired (outside the lock) on every mutation — the sender's wake-up.
    public var onDirty: (() -> Void)?

    public init() {
        OutboundPlayState.namespaceCounter.lock()
        idNamespace = (OutboundPlayState.nextNamespace & 0x0F) << 12
        OutboundPlayState.nextNamespace &+= 1
        OutboundPlayState.namespaceCounter.unlock()
    }

    // MARK: producers (any thread)

    /// `radiusPt`: the fingertip's `UITouch.majorRadius` in POINTS
    /// (0 = unknown — producers without a touchscreen).
    public func touchOn(_ token: AnyHashable, pitchSemis: Double,
                        velocity: Double, radiusPt: Double = 0,
                        exprScale: Double = 1.0, glideExempt: Bool = false) {
        lock.lock()
        touches.removeAll { $0.token == token }
        let t = Touch(wireId: idNamespace | (nextWireId & 0x0FFF),
                      onsetSeq: nextOnsetSeq,
                      velocity: clamp255(velocity),
                      radius: TLPTouch.radiusByte(points: radiusPt),
                      pitch: Float(pitchSemis),
                      exprScale: exprScale,
                      glideExempt: glideExempt)
        nextWireId &+= 1
        nextOnsetSeq &+= 1
        touches.append((token, t))
        markDirtyLockedThenNotify()
    }

    /// Live expression update for a held touch (in-process only).
    public func touchExpr(_ token: AnyHashable, _ exprScale: Double) {
        lock.lock()
        guard let i = touches.firstIndex(where: { $0.token == token }),
              touches[i].touch.exprScale != exprScale else {
            lock.unlock()
            return
        }
        touches[i].touch.exprScale = exprScale
        markDirtyLockedThenNotify()
    }

    /// Fingertip size update for a held touch, in POINTS. Gated on the
    /// WIRE BYTE (quarter-point steps) so jitter cannot dirty the frame.
    public func touchRadius(_ token: AnyHashable, radiusPt: Double) {
        lock.lock()
        let b = TLPTouch.radiusByte(points: radiusPt)
        guard let i = touches.firstIndex(where: { $0.token == token }),
              touches[i].touch.radius != b else {
            lock.unlock()
            return
        }
        touches[i].touch.radius = b
        markDirtyLockedThenNotify()
    }

    public func touchGlide(_ token: AnyHashable, pitchSemis: Double) {
        lock.lock()
        guard let i = touches.firstIndex(where: { $0.token == token }) else {
            lock.unlock()
            return
        }
        guard touches[i].touch.pitch != Float(pitchSemis) else {
            lock.unlock()
            return
        }
        touches[i].touch.pitch = Float(pitchSemis)
        markDirtyLockedThenNotify()
    }

    public func touchOff(_ token: AnyHashable) {
        lock.lock()
        let before = touches.count
        touches.removeAll { $0.token == token }
        guard touches.count != before else { lock.unlock(); return }
        markDirtyLockedThenNotify()
    }

    /// The NEWEST sounding touch's (wire id, fractional-MIDI pitch), or
    /// nil while nothing sounds (`touches` is append-ordered). Display-only
    /// read (the iPad's finger-accel scope); any thread.
    public func newestTouch() -> (id: UInt16, pitchSemis: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = touches.last else { return nil }
        return (last.touch.wireId, Double(last.touch.pitch))
    }

    public func setTilt(_ axis: Int, _ value: Double) {
        lock.lock()
        guard tilt.indices.contains(axis), tilt[axis] != value else {
            lock.unlock()
            return
        }
        tilt[axis] = value
        markDirtyLockedThenNotify()
    }

    public func setAccel(_ x: Double, _ y: Double, _ z: Double) {
        lock.lock()
        guard accelG != [x, y, z] else {
            lock.unlock()
            return
        }
        accelG = [x, y, z]
        markDirtyLockedThenNotify()
    }

    /// Strike-scale envelope 0…1. Gated on the WIRE BYTE, not the Double:
    /// the envelope decays continuously, and float gating would dirty the
    /// frame every tick even at rest.
    public func setStrike(_ value: Double) {
        lock.lock()
        let b = clamp255(value)
        guard b != strikeByte else { lock.unlock(); return }
        strikeByte = b
        markDirtyLockedThenNotify()
    }

    public func setDrone(_ index: Int, _ pressed: Bool) {
        lock.lock()
        guard (0..<FretArrangement.droneCount).contains(index) else {
            lock.unlock()
            return
        }
        let bit: UInt8 = 1 << UInt8(index)
        let new = pressed ? droneMask | bit : droneMask & ~bit
        guard new != droneMask else { lock.unlock(); return }
        droneMask = new
        markDirtyLockedThenNotify()
    }

    /// The chord bar's selection (nil = none), change-gated.
    public func setChordSelection(_ sel: ChordSelection?) {
        lock.lock()
        guard chordSelection != sel else { lock.unlock(); return }
        chordSelection = sel
        markDirtyLockedThenNotify()
    }

    public func setBackgrounded(_ b: Bool) {
        lock.lock()
        guard backgrounded != b else { lock.unlock(); return }
        backgrounded = b
        markDirtyLockedThenNotify()
    }

    /// Panic / teardown: clears everything held (the panic EVENT is the
    /// caller's job).
    public func clearAll() {
        lock.lock()
        touches.removeAll()
        droneMask = 0
        markDirtyLockedThenNotify()
    }

    // MARK: sender (link queue)

    /// Snapshot the state as a wire frame, bumping stateSeq and clearing
    /// the dirty flag; nil when clean unless `force` (heartbeat).
    public func snapshotFrame(timestampUs: UInt32, force: Bool = false) -> TLPPerfState? {
        lock.lock()
        defer { lock.unlock() }
        guard dirtyFlag || force else { return nil }
        dirtyFlag = false
        stateSeq &+= 1
        return TLPPerfState(
            flags: backgrounded ? TLPPerfState.flagBackgrounded : 0,
            stateSeq: stateSeq,
            timestampUs: timestampUs,
            tiltX: s16(tilt[0]), tiltY: s16(tilt[1]), tiltZ: s16(tilt[2]),
            accelX: s16g(accelG[0]), accelY: s16g(accelG[1]),
            accelZ: s16g(accelG[2]),
            droneMask: droneMask,
            strike: strikeByte,
            chordDegree: chordSelection.map {
                UInt8(min(max($0.degree, 0), 254))
            } ?? TLPPerfState.chordNone,
            chordOctave: UInt8(bitPattern: Int8(clamping:
                chordSelection?.octave ?? 0)),
            touches: touches.map { pair in
                TLPTouch(id: pair.touch.wireId,
                         onsetSeq: pair.touch.onsetSeq,
                         velocity: pair.touch.velocity,
                         radius: pair.touch.radius,
                         pitch: pair.touch.pitch,
                         exprScale: pair.touch.exprScale,
                         glideExempt: pair.touch.glideExempt)
            })
    }

    // MARK: helpers

    private func markDirtyLockedThenNotify() {
        dirtyFlag = true
        lock.unlock()
        onDirty?()
    }

    private func clamp255(_ v: Double) -> UInt8 {
        UInt8(min(max((v * 255.0).rounded(), 0), 255))
    }

    private func s16(_ v: Double) -> Int16 {
        Int16(min(max(v, -1), 1) * 32767.0)
    }

    private func s16g(_ g: Double) -> Int16 {
        let fs = TLPPerfState.accelFullScaleG
        return Int16((min(max(g, -fs), fs) / fs * 32767.0).rounded())
    }
}
