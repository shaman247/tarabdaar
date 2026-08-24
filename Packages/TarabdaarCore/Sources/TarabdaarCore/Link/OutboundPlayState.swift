import Foundation

/// The iPad-side outbound performance snapshot: the single mutable truth
/// the paced sender serializes into PERF_STATE frames.
///
/// Producers (touch handlers, the 60 Hz motion tick, drone buttons) do
/// O(1) locked writes from any thread; the sender snapshots under the same
/// lock. Wire touch ids are assigned here from a wrapping u16 counter —
/// callers key by their own touch token (UITouch identity, script voice
/// index, …) and never see wire ids. `onsetSeq` is stamped from a global
/// articulation counter so even a wrapped, reused id reads as a fresh
/// onset on the far side.
public final class OutboundPlayState {
    private let lock = NSLock()
    private struct Touch {
        let wireId: UInt16
        let onsetSeq: UInt8
        let velocity: UInt8
        var pressure: UInt8
        var pitch: Float
        /// Fret-band y (0–255 ↔ 0…1), nil when the producer has none
        /// (keyboard, scripts) — the wire flag stays clear then and the
        /// Mac keeps the legacy behavior for this touch.
        var posY: UInt8?
        /// Within-fret y (0–255 ↔ 0…1 down the HOME fret's extent), nil
        /// for unsnapped/fretless touches — no home fret, no auto-vibrato.
        var fretY: UInt8?
    }
    private var touches: [(token: AnyHashable, touch: Touch)] = []
    /// Wire ids carry a per-instance namespace in the top 4 bits so two
    /// states feeding one sink (the Mac's pitchPad + fretPad preview pads)
    /// can never collide; the low 12 bits wrap per instance.
    private let idNamespace: UInt16
    private var nextWireId: UInt16 = 0
    private var nextOnsetSeq: UInt8 = 0
    private static let namespaceCounter = NSLock()
    private static var nextNamespace: UInt16 = 0
    /// Tilt axes, −1…+1 each (rest = 0, the app-wide tilt convention
    /// since 2026-08-18).
    private var tilt: [Double] = [0, 0, 0]
    /// Raw user acceleration in g (gravity removed), for the Mac's
    /// received-motion diagnostics. Written by the same motion tick as
    /// the tilt; the sensor floor never repeats exactly, so this keeps
    /// the sender dirty at the tick rate — which the tilt's own
    /// sub-quantum jitter already did.
    private var accelG: [Double] = [0, 0, 0]
    /// Strike-scale envelope, already quantized to the wire byte.
    private var strikeByte: UInt8 = 0
    private var droneMask: UInt8 = 0
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

    /// `posY` is the touch's fret-band y (0…1 top→bottom) when the
    /// producer knows one — it feeds the Mac-evaluated fret-linger /
    /// auto-vibrato. `fretY` is the OUTWARD position within the touch's
    /// home fret's vertical extent (snapped onsets only; 0 = the end
    /// toward the pad's centre-line, 1 = the outer end) — the auto-vibrato
    /// ceiling axis. nil = the touch carries no such value.
    public func touchOn(_ token: AnyHashable, pitchSemis: Double,
                        velocity: Double, pressure: Double = 0,
                        posY: Double? = nil, fretY: Double? = nil) {
        lock.lock()
        touches.removeAll { $0.token == token }
        let t = Touch(wireId: idNamespace | (nextWireId & 0x0FFF),
                      onsetSeq: nextOnsetSeq,
                      velocity: clamp255(velocity),
                      pressure: clamp255(pressure),
                      pitch: Float(pitchSemis),
                      posY: posY.map(clamp255),
                      fretY: fretY.map(clamp255))
        nextWireId &+= 1
        nextOnsetSeq &+= 1
        touches.append((token, t))
        markDirtyLockedThenNotify()
    }

    /// `posY`/`fretY` nil = leave the stored value as it stands (a
    /// pitch-only update must not erase the position a fret surface
    /// already reported).
    public func touchGlide(_ token: AnyHashable, pitchSemis: Double,
                           posY: Double? = nil, fretY: Double? = nil) {
        lock.lock()
        guard let i = touches.firstIndex(where: { $0.token == token }) else {
            lock.unlock()
            return
        }
        let newY = posY.map(clamp255) ?? touches[i].touch.posY
        let newFretY = fretY.map(clamp255) ?? touches[i].touch.fretY
        guard touches[i].touch.pitch != Float(pitchSemis)
                || touches[i].touch.posY != newY
                || touches[i].touch.fretY != newFretY else {
            lock.unlock()
            return
        }
        touches[i].touch.pitch = Float(pitchSemis)
        touches[i].touch.posY = newY
        touches[i].touch.fretY = newFretY
        markDirtyLockedThenNotify()
    }

    /// The wire id this state assigned to a live touch token, nil when the
    /// token isn't held. Display plumbing: the host's LINGER_STATE frames
    /// key by wire id, and the pad's touch overlay needs to match them
    /// back to its own touches.
    public func wireId(for token: AnyHashable) -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return touches.first { $0.token == token }?.touch.wireId
    }

    public func touchOff(_ token: AnyHashable) {
        lock.lock()
        let before = touches.count
        touches.removeAll { $0.token == token }
        guard touches.count != before else { lock.unlock(); return }
        markDirtyLockedThenNotify()
    }

    /// value ∈ −1…+1 (rest = 0).
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

    /// Strike-scale accelerometer envelope 0…1 (`.strike` dimension).
    /// Gated on the WIRE BYTE, not the Double: the envelope decays
    /// continuously at the report rate, and float-level gating would mark
    /// the frame dirty on every tick even at rest.
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

    public func setBackgrounded(_ b: Bool) {
        lock.lock()
        guard backgrounded != b else { lock.unlock(); return }
        backgrounded = b
        markDirtyLockedThenNotify()
    }

    /// Panic / teardown: clears everything held. (The panic EVENT is the
    /// caller's job — this is just the state side.)
    public func clearAll() {
        lock.lock()
        touches.removeAll()
        droneMask = 0
        markDirtyLockedThenNotify()
    }

    // MARK: sender (link queue)

    /// Snapshot the current state as a wire frame, bumping stateSeq and
    /// clearing the dirty flag. `force` = heartbeat (emit even when clean).
    /// Returns nil when clean and not forced.
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
            touches: touches.map { pair in
                var flags: UInt8 = 0
                if pair.touch.posY != nil { flags |= TLPTouch.flagPosYValid }
                if pair.touch.fretY != nil { flags |= TLPTouch.flagFretYValid }
                return TLPTouch(id: pair.touch.wireId,
                                onsetSeq: pair.touch.onsetSeq,
                                velocity: pair.touch.velocity,
                                pressure: pair.touch.pressure,
                                flags: flags,
                                posY: pair.touch.posY ?? 0,
                                fretY: pair.touch.fretY ?? 0,
                                pitch: pair.touch.pitch)
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
