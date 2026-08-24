import Foundation

/// The link facade: ONE protocol (TLP) over the CoreMIDI SysEx tunnel on
/// both legs — the USB session when wired, the BLE-MIDI session otherwise.
/// Lane selection is inherited from `MIDIEngine`'s wired-first destination
/// routing, so there is no lane state machine here; sequence dedupe covers
/// the brief overlap when both legs deliver during a plug/unplug switch.
///
/// All internal state is confined to the serial link queue
/// (`userInteractive`). Producers call thread-safe entry points; receive
/// callbacks (`onPerfState`/`onJoyConState`/`onEvent`/`onStatus`/
/// `onLinkDrop`) fire ON the link queue — hop to main yourself for UI.
///
/// The paced sender runs at 120 Hz: at most one fresh PERF_STATE (pad) or
/// JOYCON_STATE (host) frame per tick, a 250 ms heartbeat when idle (the
/// far side marks the link stale after 1.5 s of silence), and a 2 s
/// ping/pong for the RTT + clock-offset estimate.
public final class TarabLink {

    public struct Status: Equatable {
        /// HELLO exchanged with a version overlap.
        public var isUp = false
        /// No frames for >1.5 s while up (dead link or sleeping peer).
        public var isStale = false
        public var rttMs: Double?
        public var remoteVersionMax: UInt16?
    }

    private let role: TLPRole
    private let queue = DispatchQueue(label: "tarablink",
                                      qos: .userInteractive)
    private let outbox = LinkOutbox()
    private var clockSync = LinkClockSync()

    // Wiring (set before start()).
    /// Sends one complete SysEx message. `isEvent` = reliable traffic —
    /// the Mac side passes it as `fallbackToAll` so a renamed endpoint
    /// can't silently block a must-arrive sync, while state streams just
    /// drop when the peer is absent.
    public var sendRaw: ((_ sysex: [UInt8], _ isEvent: Bool) -> Void)?
    public var onPerfState: ((TLPPerfState) -> Void)?
    public var onJoyConState: ((TLPJoyConState) -> Void)?
    public var onLingerState: ((TLPLingerState) -> Void)?
    public var onEvent: ((TLPEvent) -> Void)?
    public var onStatus: ((Status) -> Void)?
    /// Fired once when the link goes stale or down while anything might be
    /// held — the Mac wires this to `LinkIngest.linkDidDrop` (the kill
    /// path).
    public var onLinkDrop: (() -> Void)?

    // Link-queue state.
    private var status = Status()
    private var eventSeq: UInt16 = 0
    private var lastEventSeqSeen: UInt16?
    private var lastStateSeqSeen: [UInt8: UInt16] = [:]
    private var lastReceiveUs: UInt32?
    private var lastHelloSentUs: UInt32?
    private var playState: OutboundPlayState?
    private var joyCon: JoyConTiltDisplay?
    private var joyConDirty = false
    private var joyConSeq: UInt16 = 0
    private var linger: [TLPLingerTouch] = []
    private var lingerDirty = false
    private var lingerSeq: UInt16 = 0
    private var lastSentUs: UInt32 = 0        // any outbound frame
    private var lastPingUs: UInt32 = 0
    private var pingId: UInt8 = 0
    private var timer: DispatchSourceTimer?

    private static let tickHz = 120.0
    private static let heartbeatUs: UInt32 = 250_000
    private static let staleUs: UInt32 = 1_500_000
    private static let pingIntervalUs: UInt32 = 2_000_000

    public init(role: TLPRole) {
        self.role = role
    }

    /// Pad role: the outbound snapshot the paced sender serializes. The
    /// 120 Hz tick polls the dirty flag, so a touch burst costs O(1) locked
    /// writes and at most one frame per tick reaches the wire.
    public func attach(playState state: OutboundPlayState) {
        queue.async { self.playState = state }
    }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(),
                       repeating: 1.0 / TarabLink.tickHz,
                       leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            self.sendHelloLocked()
            if self.role == .pad {
                self.enqueueEventLocked(.resyncRequest)
                self.drainLocked()
            }
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// A transport (re)appeared — CoreMIDI setup change. Re-greets and,
    /// on the pad, asks the host for a full resync. Throttled to one per
    /// second: kick is an edge signal, and a caller bug that fires it per
    /// frame must not be able to storm the wire with resync→push cycles.
    public func kick() {
        queue.async {
            let now = LinkClock.nowUs()
            if let last = self.lastKickUs,
               LinkClock.elapsedUs(from: last, to: now) < 1_000_000 { return }
            self.lastKickUs = now
            self.sendHelloLocked()
            if self.role == .pad {
                self.enqueueEventLocked(.resyncRequest)
            }
            self.drainLocked()
        }
    }
    private var lastKickUs: UInt32?

    /// Reliable events (blobs, panic, resync).
    public func send(event: TLPEvent) {
        queue.async {
            self.enqueueEventLocked(event)
            self.drainLocked()
        }
    }

    /// Host role: latest Joy-Con display state; the paced sender emits it
    /// coalesced. `force` skips pacing (connect edges acting as state).
    public func setJoyConState(_ display: JoyConTiltDisplay, force: Bool = false) {
        queue.async {
            self.joyCon = display
            self.joyConDirty = true
            if force { self.emitJoyConLocked(); self.drainLocked() }
        }
    }

    /// Host role: the latest per-touch linger envelope state (display
    /// feed for the iPad's overlay). Latest-wins, paced like JOYCON_STATE;
    /// callers push on their own cadence (AppController's ~20 Hz poll) and
    /// should push once with `[]` when the last touch ends.
    public func setLingerState(_ touches: [TLPLingerTouch]) {
        queue.async {
            guard self.linger != touches else { return }
            self.linger = touches
            self.lingerDirty = true
        }
    }

    /// Complete inbound SysEx (F0…F7) from either leg's receiver.
    /// Non-TLP messages are ignored. Any thread.
    public func receivedSysEx(_ sysex: [UInt8]) {
        queue.async { self.processIncomingLocked(sysex) }
    }

    // MARK: - Link queue internals

    private func tick() {
        let now = LinkClock.nowUs()
        // Pad: perf state — dirty, else heartbeat.
        if role == .pad, let state = playState {
            let heartbeat = LinkClock.elapsedUs(from: lastSentUs, to: now)
                >= TarabLink.heartbeatUs
            if let frame = state.snapshotFrame(timestampUs: now,
                                               force: heartbeat) {
                outbox.enqueue(.perfState(frame))
            }
        }
        // Host: joycon state — dirty, else heartbeat.
        if role == .host {
            let heartbeat = LinkClock.elapsedUs(from: lastSentUs, to: now)
                >= TarabLink.heartbeatUs
            if joyConDirty || (heartbeat && joyCon != nil) {
                emitJoyConLocked()
            }
            if lingerDirty {
                lingerDirty = false
                lingerSeq &+= 1
                outbox.enqueue(.lingerState(TLPLingerState(
                    stateSeq: lingerSeq, timestampUs: now,
                    touches: linger)))
            }
            if LinkClock.elapsedUs(from: lastPingUs, to: now)
                >= TarabLink.pingIntervalUs {
                lastPingUs = now
                pingId &+= 1
                enqueueEventLocked(.ping(id: pingId, t1: now))
            }
        }
        drainLocked()
        // Staleness.
        if status.isUp, !status.isStale, let last = lastReceiveUs,
           LinkClock.elapsedUs(from: last, to: now) >= TarabLink.staleUs {
            status.isStale = true
            onStatus?(status)
            onLinkDrop?()
        }
    }

    private func emitJoyConLocked() {
        guard let j = joyCon else { return }
        joyConDirty = false
        joyConSeq &+= 1
        // Display axes −1…+1 → the frame's u8 (centre 128).
        func b(_ v: Double) -> UInt8 {
            UInt8((min(max(v, -1), 1) + 1) / 2 * 255.0 + 0.5)
        }
        var flags: UInt8 = 0
        if j.stickLive { flags |= TLPJoyConState.flagStickLive }
        if j.bodyLive { flags |= TLPJoyConState.flagBodyLive }
        if j.connected { flags |= TLPJoyConState.flagConnected }
        if j.armLive { flags |= TLPJoyConState.flagArmLive }
        outbox.enqueue(.joyConState(TLPJoyConState(
            flags: flags, stateSeq: joyConSeq,
            timestampUs: LinkClock.nowUs(),
            stickX: b(j.stickX), stickY: b(j.stickY),
            wrist1: b(j.wrist1), wrist2: b(j.wrist2), wrist3: b(j.wrist3),
            arm1: b(j.arm1), arm2: b(j.arm2), arm3: b(j.arm3),
            // Blend window → 50 ms wire units (v7), floor 1 so a tiny
            // configured window never encodes as the "unset" 0.
            strikeWin: UInt8(min(max((j.strikeWindowS / 0.05).rounded(),
                                     1), 255)))))
    }

    private func enqueueEventLocked(_ event: TLPEvent) {
        eventSeq &+= 1
        outbox.enqueue(.event(seq: eventSeq, event))
    }

    private func sendHelloLocked() {
        let now = LinkClock.nowUs()
        // Greeting throttle: a hello-reply-to-hello must not ping-pong.
        if let last = lastHelloSentUs,
           LinkClock.elapsedUs(from: last, to: now) < 1_000_000 { return }
        lastHelloSentUs = now
        enqueueEventLocked(.hello(minVer: TLP.versionMin,
                                  maxVer: TLP.versionMax, role: role))
    }

    private func drainLocked() {
        guard let sendRaw else { return }
        var sent = false
        while let item = outbox.dequeue() {
            sendRaw(TLPPack.envelope(item.bytes, role: role),
                    item.stateType == nil)
            sent = true
        }
        if sent { lastSentUs = LinkClock.nowUs() }
    }

    private func processIncomingLocked(_ sysex: [UInt8]) {
        guard let (senderRole, bytes) = TLPPack.unenvelope(sysex),
              // Our own traffic can echo back through a MIDI loop (IAC
              // bus, patchbays, USB+BLE double delivery). Drop it — a
              // looped hello must never mark the link up (that arms the
              // staleness kill path with no peer), and looped events must
              // never pollute the peer's sequence gating.
              senderRole != role,
              let frame = TLPFrame.decode(bytes) else { return }
        lastReceiveUs = LinkClock.nowUs()
        if status.isStale {
            status.isStale = false
            onStatus?(status)
        }
        // Self-healing handshake: the peer is clearly alive (a valid frame
        // just arrived), but we haven't completed HELLO — keep greeting
        // (1 s-throttled) until its hello lands. Covers every launch-order
        // race: whichever side is down keeps asking.
        if !status.isUp {
            sendHelloLocked()
            drainLocked()
        }
        switch frame {
        case .perfState(let s):
            guard acceptState(type: TLP.typePerfState, seq: s.stateSeq) else { return }
            onPerfState?(s)
        case .joyConState(let s):
            guard acceptState(type: TLP.typeJoyConState, seq: s.stateSeq) else { return }
            onJoyConState?(s)
        case .lingerState(let s):
            guard acceptState(type: TLP.typeLingerState, seq: s.stateSeq) else { return }
            onLingerState?(s)
        case .event(let seq, let event):
            if case .hello = event {
                // A hello is a stream epoch: the peer (re)started, its
                // sequence spaces reset. Always accept, re-anchor gating.
                lastEventSeqSeen = seq
                lastStateSeqSeen.removeAll(keepingCapacity: true)
            } else {
                if let last = lastEventSeqSeen,
                   !TLP.isNewer(seq, than: last) { return }
                lastEventSeqSeen = seq
            }
            handleEventLocked(event)
        }
    }

    private func acceptState(type: UInt8, seq: UInt16) -> Bool {
        if let last = lastStateSeqSeen[type], !TLP.isNewer(seq, than: last) {
            return false
        }
        lastStateSeqSeen[type] = seq
        return true
    }

    private func handleEventLocked(_ event: TLPEvent) {
        switch event {
        case .hello(let minVer, let maxVer, _):
            // Proper range intersection — a one-sided check let a newer
            // peer come "up" against an older one whose frames it could
            // no longer decode.
            let compatible = minVer <= TLP.versionMax
                && maxVer >= TLP.versionMin
            let wasUp = status.isUp
            status.isUp = compatible
            status.remoteVersionMax = maxVer
            if !wasUp || !compatible { onStatus?(status) }
            // Always greet back (the 1 s throttle in sendHelloLocked
            // terminates any reply chain after one round trip). Gating
            // this on the up-transition once left a relaunched peer down
            // forever: the other side was already up, never replied, and
            // the newcomer had no way to learn the link existed.
            sendHelloLocked()
            drainLocked()
        case .ping(let id, let t1):
            enqueueEventLocked(.pong(id: id, t1: t1, t2: LinkClock.nowUs()))
            drainLocked()
        case .pong(_, let t1, let t2):
            clockSync.addPong(t1: t1, t2: t2, t3: LinkClock.nowUs())
            if status.rttMs != clockSync.rttMs {
                status.rttMs = clockSync.rttMs
                onStatus?(status)
            }
        default:
            onEvent?(event)
        }
    }

    // MARK: - Test hooks (logic without the timer)

    func _testProcess(_ sysex: [UInt8]) {
        queue.sync { self.processIncomingLocked(sysex) }
    }
    func _testTick() {
        queue.sync { self.tick() }
    }
    var _testStatus: Status {
        queue.sync { status }
    }
}
