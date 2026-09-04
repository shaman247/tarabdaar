import Foundation

/// The link facade: TLP over the CoreMIDI SysEx tunnel — USB when wired,
/// BLE-MIDI otherwise (`MIDIEngine`'s wired-first routing; sequence dedupe
/// covers the plug/unplug overlap). All state lives on the serial link
/// queue; entry points are thread-safe and receive callbacks fire ON the
/// link queue — hop to main yourself for UI.
///
/// The paced sender runs at 120 Hz: at most one fresh PERF_STATE (pad) or
/// JOYCON_STATE (host) frame per tick, a 250 ms heartbeat when idle (the
/// far side marks the link stale after 1.5 s), and a 2 s ping/pong RTT.
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
    /// Sends one complete SysEx message. `isEvent` = reliable traffic (sent
    /// `fallbackToAll` so a renamed endpoint can't block a sync).
    public var sendRaw: ((_ sysex: [UInt8], _ isEvent: Bool) -> Void)?
    public var onPerfState: ((TLPPerfState) -> Void)?
    public var onJoyConState: ((TLPJoyConState) -> Void)?
    public var onEvent: ((TLPEvent) -> Void)?
    public var onStatus: ((Status) -> Void)?
    /// Fired once when the link goes stale — the Mac wires this to
    /// `LinkIngest.linkDidDrop` (the kill path).
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
    private var lastSentUs: UInt32 = 0        // any outbound frame
    private var lastPingUs: UInt32 = 0
    private var pingId: UInt8 = 0
    private var timer: DispatchSourceTimer?

    private static let tickHz = Config.linkTickHz
    private static let heartbeatUs: UInt32 = 250_000
    private static let staleUs: UInt32 = 1_500_000
    private static let pingIntervalUs: UInt32 = 2_000_000

    public init(role: TLPRole) {
        self.role = role
    }

    /// Pad role: the outbound snapshot the paced sender serializes (the
    /// tick polls its dirty flag — at most one frame per tick).
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

    /// A transport (re)appeared: re-greet and (pad) request a resync.
    /// Throttled to one per second so it can never storm the wire.
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

    /// Host role: latest Joy-Con display state, emitted coalesced. `force`
    /// skips pacing.
    public func setJoyConState(_ display: JoyConTiltDisplay, immediate: Bool = false) {
        queue.async {
            self.joyCon = display
            self.joyConDirty = true
            if immediate { self.emitJoyConLocked(); self.drainLocked() }
        }
    }

    /// Host role: the voice/taraf volume-readout bytes riding every
    /// JOYCON_STATE frame. Change-gated, so a silent instrument dirties
    /// nothing.
    public func setVolumeLevels(voice: UInt8, taraf: UInt8) {
        queue.async {
            guard voice != self.volVoice || taraf != self.volTaraf
            else { return }
            self.volVoice = voice
            self.volTaraf = taraf
            // The frame needs a display to ride — seed the idle one.
            if self.joyCon == nil { self.joyCon = .idle }
            self.joyConDirty = true
        }
    }
    private var volVoice: UInt8 = 0
    private var volTaraf: UInt8 = 0

    /// Complete inbound SysEx (F0…F7) from either leg; non-TLP ignored.
    public func receivedSysEx(_ sysex: [UInt8]) {
        queue.async { self.processIncomingLocked(sysex) }
    }

    // MARK: - Link queue internals

    private func tick() {
        let now = LinkClock.nowUs()
        if role == .pad, let state = playState {
            let heartbeat = LinkClock.elapsedUs(from: lastSentUs, to: now)
                >= TarabLink.heartbeatUs
            if let frame = state.snapshotFrame(timestampUs: now,
                                               force: heartbeat) {
                outbox.enqueue(.perfState(frame))
            }
        }
        if role == .host {
            let heartbeat = LinkClock.elapsedUs(from: lastSentUs, to: now)
                >= TarabLink.heartbeatUs
            if joyConDirty || (heartbeat && joyCon != nil) {
                emitJoyConLocked()
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
        // Axes −1…+1 → u8 (centre 128).
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
            // 50 ms units, floor 1 so a tiny window never encodes as
            // "unset" 0.
            strikeWin: UInt8(min(max((j.strikeWindowS / 0.05).rounded(),
                                     1), 255)),
            volVoice: volVoice, volTaraf: volTaraf,
            fieldWarp: UInt8(min(max(j.fieldWarp, 0), 1) * 255.0 + 0.5),
            octave: UInt8(bitPattern: Int8(clamping: j.octaveShift)))))
    }

    private func enqueueEventLocked(_ event: TLPEvent) {
        eventSeq &+= 1
        outbox.enqueue(.event(seq: eventSeq, event))
    }

    private func sendHelloLocked() {
        let now = LinkClock.nowUs()
        // A hello-reply-to-hello must not ping-pong.
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
              // Our own traffic can echo back through a MIDI loop. Drop
              // it — a looped hello must never mark the link up (that arms
              // the staleness kill path with no peer), and looped events
              // must never pollute the sequence gating.
              senderRole != role,
              let frame = TLPFrame.decode(bytes) else { return }
        lastReceiveUs = LinkClock.nowUs()
        if status.isStale {
            status.isStale = false
            onStatus?(status)
        }
        // Self-healing handshake: a valid frame arrived but HELLO is not
        // complete — keep greeting (1 s-throttled) until its hello lands.
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
        case .event(let seq, let event):
            if case .hello = event {
                // A hello is a stream epoch: the peer's sequence spaces
                // reset. Always accept, re-anchor gating.
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
            // Range intersection: a one-sided check would let a newer peer
            // come "up" against one whose frames it cannot decode.
            let compatible = minVer <= TLP.versionMax
                && maxVer >= TLP.versionMin
            let wasUp = status.isUp
            status.isUp = compatible
            status.remoteVersionMax = maxVer
            if !wasUp || !compatible { onStatus?(status) }
            // Always greet back (the 1 s throttle ends the chain). Never
            // gate on the up-transition: a relaunched peer would stay down.
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
