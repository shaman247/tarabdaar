import CoreMIDI
import Foundation

// MARK: - Synced state

/// Which playing surface the iPad shows; pushed from the Mac.
public enum PadLayout: Int, Codable, CaseIterable, Identifiable {
    case pitchPad = 0
    case chordPad = 1
    case stringPad = 2
    case fretPad = 3

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .pitchPad:  return "Pitch Pad"
        case .chordPad:  return "Chord Pad"
        case .stringPad: return "String Pad"
        case .fretPad:   return "Fret Pad"
        }
    }
}

/// The state the Mac pushes to the iPad: the scale, the tonic
/// (`tonicMidi` + `tonicCents`), `marginPixels` and the active `layout`.
public struct SyncedScaleState: Codable, Equatable {
    public var points: [PitchPoint]
    public var tonicMidi: Int
    /// Fractional tonic refinement in cents (±50) — the Mac's Hz tonic
    /// rarely lands exactly on a MIDI note.
    public var tonicCents: Double
    public var marginPixels: Double
    public var layout: PadLayout

    public init(points: [PitchPoint], tonicMidi: Int, tonicCents: Double = 0,
                marginPixels: Double, layout: PadLayout = .pitchPad) {
        self.points = points
        self.tonicMidi = tonicMidi
        self.tonicCents = tonicCents
        self.marginPixels = marginPixels
        self.layout = layout
    }

    public var scale: PitchScale { PitchScale(points: points) }
}

// MARK: - SysEx scale codec

/// The scale-state codec. `encodeBlob`/`decodeBlob` produce the blob that
/// rides the TLP `SCALE_STATE` event and is what the iPad's persisted
/// store holds.
///
/// Blob: `[tonic][tonicCents14: 2×7-bit][margin][layout][count]` then per
/// point `[num14][den14][y][enabled][labelLen][label UTF-8…]`;
/// tonicCents14 = centi-cents above −50 ¢. The blob's version is TLP's
/// (`TLP.versionMin`): both apps ship in lockstep and HELLO refuses a
/// mismatched peer, so a layout change bumps the protocol version.
/// 14-bit fields ride as two 7-bit bytes, high first.
private func put14(_ b: inout [UInt8], _ v: Int) {
    b.append(UInt8(v >> 7)); b.append(UInt8(v & 0x7F))
}
private func get14(_ b: [UInt8], _ i: Int) -> Int {
    (Int(b[i]) << 7) | Int(b[i + 1])
}

public enum PitchScaleSysEx {
    /// The raw binary blob — the TLP `SCALE_STATE` event payload.
    public static func encodeBlob(_ state: SyncedScaleState) -> [UInt8] {
        let tonic = UInt8(max(0, min(127, state.tonicMidi)))
        // centi-cents above −50 ¢: 0…10000, fits 14 bits
        let cc = max(0, min(10000, Int(((state.tonicCents + 50.0) * 100.0).rounded())))
        let margin = UInt8(max(0, min(127, Int(state.marginPixels.rounded()))))
        var blob: [UInt8] = [tonic]
        put14(&blob, cc)
        blob += [margin, UInt8(state.layout.rawValue & 0x7F),
                 UInt8(min(127, state.points.count))]
        for p in state.points.prefix(127) {
            let num = min(16383, max(0, p.num))
            let den = min(16383, max(1, p.den))
            put14(&blob, num)
            put14(&blob, den)
            blob.append(UInt8(max(0, min(127, Int((p.y * 127).rounded())))))
            blob.append(p.enabled ? 1 : 0)
            let label = Array(p.label.utf8.prefix(127))
            blob.append(UInt8(label.count))
            blob.append(contentsOf: label)
        }
        return blob
    }

    /// Decode the raw binary blob (the TLP event payload).
    public static func decodeBlob(_ blob: [UInt8]) -> SyncedScaleState? {
        guard blob.count >= 6 else { return nil }

        let tonic = Int(blob[0])
        let cents = Double(get14(blob, 1)) / 100.0 - 50.0
        let margin = Double(blob[3])
        let layout = PadLayout(rawValue: Int(blob[4])) ?? .pitchPad
        let count = Int(blob[5])
        var i = 6
        var points: [PitchPoint] = []
        for _ in 0..<count {
            guard i + 7 <= blob.count else { return nil }
            let num = get14(blob, i)
            let den = get14(blob, i + 2)
            let y = Double(blob[i + 4]) / 127.0
            let enabled = blob[i + 5] != 0
            let labelLen = Int(blob[i + 6])
            i += 7
            guard i + labelLen <= blob.count else { return nil }
            let label = String(decoding: blob[i..<i + labelLen], as: UTF8.self)
            i += labelLen
            points.append(PitchPoint(num: num, den: max(1, den), y: y,
                                     label: label, enabled: enabled))
        }
        return SyncedScaleState(points: points, tonicMidi: tonic,
                                tonicCents: cents,
                                marginPixels: margin, layout: layout)
    }
}

// MARK: - Persistence (iPad)

/// iPad-only persistence of the last synced state (the raw blob).
public enum SyncedScaleStore {
    private static let key = "tarabdaar.syncedScaleState.v5"

    public static func save(_ state: SyncedScaleState) {
        UserDefaults.standard.set(Data(PitchScaleSysEx.encodeBlob(state)), forKey: key)
    }

    public static func load() -> SyncedScaleState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return PitchScaleSysEx.decodeBlob([UInt8](data))
    }
}

// MARK: - Fret-Pad arrangement codec

/// The Fret-Pad arrangement codec: the blob that rides the TLP
/// `FRET_ARRANGEMENT` event and is what the iPad's persisted store holds.
/// Sent only while the Fret Pad is the active layout.
///
/// Blob: `[ghostTwentiethOctaves][flags=80][columnCount]`, then
/// `[degreeIndex][rowMask u16 LE]` per pitch and 3 drone ratios.
/// Flag bit 6 selects fifteen-row masks; legacy bits 5/3/2 select nine/five/three-row pairs.
/// Flag bit 4 selects twentieth-octave extents; cached blobs without it use quarters.
/// Cached legacy centres and extents migrate to rows. TLP versions the live wire.
/// The live fret warp travels separately in JOYCON_STATE.
public enum FretArrangementSysEx {
    /// The raw binary blob — the TLP `FRET_ARRANGEMENT` event payload.
    public static func encodeBlob(_ a: FretArrangement) -> [UInt8] {
        func b7(_ v: Int) -> UInt8 { UInt8(max(0, min(127, v))) }
        var degrees: [Int] = []
        var masks: [Int: UInt16] = [:]
        for segment in a.segments {
            let degree = Int(b7(segment.degreeIndex))
            if masks[degree] == nil { degrees.append(degree) }
            masks[degree, default: 0] |= UInt16(1) << (segment.row.rawValue - 1)
        }
        var blob: [UInt8] = [b7(Int((a.ghostExtentOctaves * 20).rounded())),
                             80,   // fifteen-row masks, twentieth-octave extent
                             UInt8(degrees.count)]
        for degree in degrees {
            let mask = masks[degree]!
            blob += [UInt8(degree), UInt8(mask & 0xFF), UInt8(mask >> 8)]
        }
        for i in 0..<FretArrangement.droneCount {
            let r = i < a.droneRatios.count ? a.droneRatios[i]
                : FretArrangement.defaultDroneRatios[i]
            // cents above −1200 (ratio 0.25…4 → 0…3600), 14-bit
            let c = max(0, min(16383, Int((1200.0 * log2(r) + 1200.0).rounded())))
            put14(&blob, c)
        }
        return blob
    }

    /// Decode the raw binary blob (the TLP event payload).
    public static func decodeBlob(_ blob: [UInt8]) -> FretArrangement? {
        guard blob.count >= 3 else { return nil }

        guard blob[1] & ~UInt8(127) == 0 else { return nil }
        let extent = Double(blob[0]) / (blob[1] & 16 != 0 ? 20.0 : 4.0)
        let hasRagaMasks = blob[1] & 1 != 0
        let fifteenRows = blob[1] & 64 != 0
        let nineRows = blob[1] & 32 != 0
        let fiveRows = blob[1] & 8 != 0
        let rows = blob[1] & 4 != 0
        let pairs = blob[1] & 2 != 0
        guard [rows, pairs, fiveRows, nineRows, fifteenRows].filter({ $0 }).count <= 1,
              !fifteenRows || !hasRagaMasks else { return nil }
        let segmentSize = (fifteenRows ? 3 : nineRows || fiveRows || rows ? 2 : pairs ? 3 : 6) + (hasRagaMasks ? 1 : 0)
        let count = Int(blob[2])
        if pairs || rows || fiveRows || nineRows || fifteenRows {
            guard blob.count == 3 + count * segmentSize + 2 * FretArrangement.droneCount
            else { return nil }
        }
        var i = 3
        var segments: [FretSegment] = []
        for _ in 0..<count {
            guard i + segmentSize <= blob.count else { return nil }
            if fifteenRows {
                let mask = UInt16(blob[i + 1]) | UInt16(blob[i + 2]) << 8
                guard blob[i] <= 127, mask != 0, mask & 0x8000 == 0 else { return nil }
                for row in FretRow.allCases where mask & (UInt16(1) << (row.rawValue - 1)) != 0 {
                    segments.append(FretSegment(degreeIndex: Int(blob[i]), row: row))
                }
                i += segmentSize
                continue
            }
            let row: FretRow
            if rows || fiveRows || nineRows {
                guard !nineRows || (1...9).contains(blob[i + 1]) else { return nil }
                guard let decoded = nineRows ? FretRow(rawValue: Int(blob[i + 1]))
                    : FretRow.legacy(Int(blob[i + 1]), count: fiveRows ? 5 : 3) else { return nil }
                row = decoded
            } else {
                let y = pairs ? Double(get14(blob, i + 1)) / 16383
                    : (Double(blob[i + 3]) + Double(blob[i + 4])) / 254
                let old = (1...3).min { abs((3.5 - Double($0)) / 3 - y) < abs((3.5 - Double($1)) / 3 - y) }!
                row = FretRow.legacy(old)!
            }
            let fret = FretSegment(degreeIndex: Int(blob[i]), row: row)
            if rows || fiveRows || nineRows || pairs || blob[i + 5] != 0 { segments.append(fret) }
            i += segmentSize
        }
        var drones = FretArrangement.defaultDroneRatios
        if i + 2 * FretArrangement.droneCount <= blob.count {
            for d in 0..<FretArrangement.droneCount {
                let c = get14(blob, i)
                drones[d] = pow(2.0, (Double(c) - 1200.0) / 1200.0)
                i += 2
            }
        }
        return FretArrangement(segments: nineRows || fifteenRows ? segments : FretArrangement.expandingOverlaps(segments), ghostExtentOctaves: extent,
                               droneRatios: drones)
    }
}

/// iPad-only persistence of the last synced arrangement (the raw blob).
public enum FretArrangementSyncStore {
    private static let key = "tarabdaar.syncedFretArrangement.v3"

    public static func save(_ a: FretArrangement) {
        UserDefaults.standard.set(Data(FretArrangementSysEx.encodeBlob(a)), forKey: key)
    }

    public static func load() -> FretArrangement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return FretArrangementSysEx.decodeBlob([UInt8](data))
    }
}

/// The JOYCON_STATE wire form of a display frame — the ONE encode/decode
/// pair (the host's `TarabLink` and the pad's receiver both use it).
/// Axes −1…+1 ↔ u8 (centre 128); the strike window in 50 ms units with 0
/// = unset (the viewer's 2 s default); the warp and the accel level 0…1
/// ↔ u8; the octave an i8 bit pattern.
extension JoyConTiltDisplay {
    public static let strikeWinUnitS = 0.05
    public static let strikeWinDefaultS = 2.0

    public init(frame s: TLPJoyConState) {
        func ax(_ b: UInt8) -> Double { Double(b) / 255.0 * 2.0 - 1.0 }
        self.init(stickX: ax(s.stickX), stickY: ax(s.stickY),
                  wrist1: ax(s.wrist1), wrist2: ax(s.wrist2),
                  stickLive: s.flags & TLPJoyConState.flagStickLive != 0,
                  bodyLive: s.flags & TLPJoyConState.flagBodyLive != 0,
                  connected: s.flags & TLPJoyConState.flagConnected != 0,
                  wrist3: ax(s.wrist3),
                  arm1: ax(s.arm1), arm2: ax(s.arm2), arm3: ax(s.arm3),
                  armLive: s.flags & TLPJoyConState.flagArmLive != 0,
                  strikeWindowS: s.strikeWin == 0 ? Self.strikeWinDefaultS
                      : Double(s.strikeWin) * Self.strikeWinUnitS,
                  fieldWarp: Double(s.fieldWarp) / 255.0,
                  octaveShift: Int(Int8(bitPattern: s.octave)),
                  wristRate1: ax(s.wristRate1), wristRate2: ax(s.wristRate2),
                  wristRate3: ax(s.wristRate3),
                  accel1: ax(s.accel1), accel2: ax(s.accel2),
                  accel3: ax(s.accel3),
                  accelLevel: Double(s.accelLevel) / 255.0,
                  fretAssist: s.fretAssist)
    }

    public func frame(stateSeq: UInt16, timestampUs: UInt32,
                      volVoice: UInt8, volChromatic: UInt8, volRaga: UInt8) -> TLPJoyConState {
        func b(_ v: Double) -> UInt8 {
            UInt8((min(max(v, -1), 1) + 1) / 2 * 255.0 + 0.5)
        }
        var flags: UInt8 = 0
        if stickLive { flags |= TLPJoyConState.flagStickLive }
        if bodyLive { flags |= TLPJoyConState.flagBodyLive }
        if connected { flags |= TLPJoyConState.flagConnected }
        if armLive { flags |= TLPJoyConState.flagArmLive }
        return TLPJoyConState(
            flags: flags, stateSeq: stateSeq, timestampUs: timestampUs,
            stickX: b(stickX), stickY: b(stickY),
            wrist1: b(wrist1), wrist2: b(wrist2), wrist3: b(wrist3),
            arm1: b(arm1), arm2: b(arm2), arm3: b(arm3),
            // floor 1 so a tiny window never encodes as "unset" 0
            strikeWin: UInt8(min(max((strikeWindowS / Self.strikeWinUnitS).rounded(),
                                     1), 255)),
            volVoice: volVoice, volChromatic: volChromatic, volRaga: volRaga,
            fieldWarp: UInt8(min(max(fieldWarp, 0), 1) * 255.0 + 0.5),
            octave: UInt8(bitPattern: Int8(clamping: octaveShift)),
            wristRate1: b(wristRate1), wristRate2: b(wristRate2),
            wristRate3: b(wristRate3),
            accel1: b(accel1), accel2: b(accel2), accel3: b(accel3),
            accelLevel: UInt8(min(max(accelLevel, 0), 1) * 255.0 + 0.5),
            fretAssist: fretAssist)
    }
}

/// One Mac→iPad display frame (axes −1…+1): Joy-Con stick, fused wrist
/// attitude, Mac-evaluated ARM axes (`armLive` = a calibration drives
/// them), liveness flags, and the fields the iPad ACTS on: `fieldWarp`,
/// `octaveShift` and resolved fret assist.
public struct JoyConTiltDisplay: Equatable {
    public var stickX: Double
    public var stickY: Double
    public var wrist1: Double
    public var wrist2: Double
    public var wrist3: Double
    public var arm1: Double
    public var arm2: Double
    public var arm3: Double
    /// The wrist tilt RATES — d/dt of `wrist1–3`, over
    /// `JoyConWristMotion.rateFullScale` → −1…+1.
    public var wristRate1: Double
    public var wristRate2: Double
    public var wristRate3: Double
    /// The Joy-Con's gravity-removed acceleration per body axis, over
    /// `JoyConWristMotion.accelFullScaleG` → −1…+1.
    public var accel1: Double
    public var accel2: Double
    public var accel3: Double
    /// The magnitude of `accel1–3`, over the same full scale (0…1).
    public var accelLevel: Double
    public var stickLive: Bool
    public var bodyLive: Bool
    public var armLive: Bool
    public var connected: Bool
    /// `ctl_strike_window` (s), for the iPad scope's onset fade. 2.0 when
    /// never received.
    public var strikeWindowS: Double
    /// `ctl_fret_warp` (0…1); the fret field resolves touch pitch through
    /// it. 0 when never received.
    public var fieldWarp: Double
    /// Resolved drag-assist controls; defaults while the link is unavailable.
    public var fretAssist: FretAssistSettings
    /// The playing-range octave shift (−3…+3), ONSET-captured per touch by
    /// `PitchPadEngine.octaveShift`. 0 when never received.
    public var octaveShift: Int

    public init(stickX: Double, stickY: Double, wrist1: Double,
                wrist2: Double, stickLive: Bool, bodyLive: Bool,
                connected: Bool, wrist3: Double = 0, arm1: Double = 0,
                arm2: Double = 0, arm3: Double = 0,
                armLive: Bool = false, strikeWindowS: Double = 2.0,
                fieldWarp: Double = 0, octaveShift: Int = 0,
                wristRate1: Double = 0, wristRate2: Double = 0,
                wristRate3: Double = 0, accel1: Double = 0,
                accel2: Double = 0, accel3: Double = 0,
                accelLevel: Double = 0,
                fretAssist: FretAssistSettings = FretAssistSettings()) {
        self.stickX = stickX
        self.stickY = stickY
        self.wrist1 = wrist1
        self.wrist2 = wrist2
        self.wrist3 = wrist3
        self.arm1 = arm1
        self.arm2 = arm2
        self.arm3 = arm3
        self.wristRate1 = wristRate1
        self.wristRate2 = wristRate2
        self.wristRate3 = wristRate3
        self.accel1 = accel1
        self.accel2 = accel2
        self.accel3 = accel3
        self.accelLevel = min(max(accelLevel, 0), 1)
        self.stickLive = stickLive
        self.bodyLive = bodyLive
        self.armLive = armLive
        self.connected = connected
        self.strikeWindowS = strikeWindowS
        self.fieldWarp = min(max(fieldWarp, 0), 1)
        self.fretAssist = fretAssist
        self.octaveShift = min(max(octaveShift,
                                   PitchPadEngine.octaveShiftRange.lowerBound),
                               PitchPadEngine.octaveShiftRange.upperBound)
    }

    /// The at-rest/no-link display: everything centred and dim.
    public static let idle = JoyConTiltDisplay(
        stickX: 0, stickY: 0, wrist1: 0, wrist2: 0,
        stickLive: false, bodyLive: false, connected: false)
}

// MARK: - iPad SysEx receiver

/// Sync belongs to the current live connection, never to the cached layout.
public struct PadConnectionState: Equatable {
    public private(set) var isConnected = false
    private var receivedScale = false
    private var receivedArrangement = false
    public var isSynced: Bool { isConnected && receivedScale && receivedArrangement }

    public init() {}

    public mutating func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            receivedScale = false
            receivedArrangement = false
        }
    }

    mutating func appliedScale() { if isConnected { receivedScale = true } }
    mutating func appliedArrangement() { if isConnected { receivedArrangement = true } }
}

/// The iPad's CoreMIDI SysEx receiver routes complete TLP envelopes to `TarabLink`.
/// Its input port and virtual destination share per-source reassembly; connections
/// refresh on every CoreMIDI setup change.
public final class ScaleSyncReceiver: ObservableObject {
    @Published public private(set) var connection = PadConnectionState()
    /// Bumped on every applied scale.
    @Published public private(set) var syncCount: Int = 0
    @Published public private(set) var tarafBank = TarafBank.empty

    /// The last synced arrangement (seeded from the store on `start()`).
    @Published public private(set) var fretArrangement: FretArrangement?

    /// The Mac's Joy-Con display stream (not persisted); the surface acts
    /// on `connected`, `fieldWarp`, `octaveShift` and resolved fret assist.
    @Published public private(set) var joyConTilt = JoyConTiltDisplay.idle

    /// Fired on main with each applied state (also persisted here).
    public var onState: ((SyncedScaleState) -> Void)?

    /// A complete TLP-envelope SysEx (`F0 7D 10`), handed RAW on the
    /// CoreMIDI thread to `TarabLink.receivedSysEx`.
    public var onSysEx: (([UInt8]) -> Void)?

    /// The shared CoreMIDI receive plumbing (client, all-sources input port,
    /// the "Tarabdaar Scale" virtual destination, packet walk). Lazily built
    /// so `self` is capturable.
    private lazy var tap = MIDIInputTap(
        clientName: "Tarabdaar Scale In",
        portName: "Tarabdaar Scale In Port",
        destinationName: "Tarabdaar Scale",
        logLabel: "ScaleSyncReceiver"
    ) { [weak self] bytes, sourceKey in
        self?.consume(bytes, sourceKey: sourceKey)
    }

    /// SysEx reassembly PER SOURCE (a shared buffer corrupts under
    /// concurrent sources), keyed by the tap's source key. Locked across
    /// CoreMIDI threads.
    private struct SysExRun {
        var buffer: [UInt8] = []
        var receiving = false
    }
    private var sysexRuns: [UInt: SysExRun] = [:]
    private let lock = NSLock()

    public init() {}

    public func start() {
        fretArrangement = FretArrangementSyncStore.load()
        tap.start()
    }

    public func stop() {
        tap.stop()
        lock.lock()
        sysexRuns.removeAll()
        lock.unlock()
    }

    deinit { stop() }

    // MARK: - Packet handling

    private func consume(_ bytes: UnsafeBufferPointer<UInt8>, sourceKey: UInt) {
        lock.lock()
        var run = sysexRuns[sourceKey] ?? SysExRun()
        lock.unlock()
        var completed: [[UInt8]] = []
        for byte in bytes {
            if byte == 0xF0 {
                run.buffer = [0xF0]
                run.receiving = true
            } else if byte == 0xF7 {
                guard run.receiving else { continue }
                run.buffer.append(0xF7)
                run.receiving = false
                completed.append(run.buffer)
                run.buffer.removeAll(keepingCapacity: true)
            } else if byte >= 0xF8 {
                // System realtime — may be interleaved inside SysEx. Ignore.
                continue
            } else if run.receiving {
                run.buffer.append(byte)
            }
        }
        lock.lock()
        sysexRuns[sourceKey] = run
        lock.unlock()
        for msg in completed { finalize(msg) }
    }

    /// Routes one complete SysEx run. The wire is TLP: every envelope
    /// (`F0 7D 10 …`) goes to the link, and nothing else is understood any
    /// more — the legacy per-message subtypes (0x01/0x03/0x05) are retired.
    private func finalize(_ bytes: [UInt8]) {
        if bytes.count > 3, bytes[1] == 0x7D, bytes[2] == TLPPack.sysExSubtype {
            onSysEx?(bytes)
        }
    }

    // MARK: - State appliers (any thread; publish + persist on main)

    public func applyState(_ state: SyncedScaleState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            SyncedScaleStore.save(state)
            self.onState?(state)
            self.syncCount += 1
            self.connection.appliedScale()
        }
    }

    public func applyTarafBank(_ bank: TarafBank) {
        DispatchQueue.main.async { [weak self] in self?.tarafBank = bank }
    }

    public func applyArrangement(_ arrangement: FretArrangement) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            FretArrangementSyncStore.save(arrangement)
            self.fretArrangement = arrangement
            self.connection.appliedArrangement()
        }
    }

    public func applyLinkStatus(_ status: TarabLink.Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let connected = status.isUp && !status.isStale
            guard self.connection.isConnected != connected else { return }
            self.connection.setConnected(connected)
        }
    }

    public func applyJoyCon(_ tilt: JoyConTiltDisplay) {
        DispatchQueue.main.async { [weak self] in
            // Change-gated: frames stream at up to 30 Hz; an unchanged
            // display must not re-render the toolbar.
            guard let self, self.joyConTilt != tilt else { return }
            self.joyConTilt = tilt
        }
    }

    /// Volume readout history (the JOYCON_STATE vol bytes, `TLPVolume`
    /// scale). Deliberately NOT `@Published`: the toolbar scope polls it in
    /// a `TimelineView`, so level motion never re-renders the toolbar.
    public let volumeHistory = VolumeHistory()
    public let noteControls = NoteControlDisplay()
}

/// Latest display-only note controls, polled without publishing toolbar updates.
public final class NoteControlDisplay {
    private let lock = NSLock()
    private var value: TLPNoteControls = .idle

    public init() {}

    public func update(_ controls: TLPNoteControls) {
        lock.lock()
        value = controls
        lock.unlock()
    }

    public var latest: TLPNoteControls {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe rolling buffer of received (voice, chromatic, raga) levels; samples
/// are sparse and the scope forward-fills.
public final class VolumeHistory {
    public struct Sample: Sendable {
        public let t: TimeInterval        // ProcessInfo systemUptime
        public let voice: Double
        public let chromatic: Double
        public let raga: Double
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    /// Retention window, longer than any display window.
    private static let window: TimeInterval = 8.0

    public init() {}

    /// Append one received level triple (any thread).
    public func record(voice: Double, chromatic: Double, raga: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        samples.append(Sample(t: now, voice: voice, chromatic: chromatic, raga: raga))
        let cutoff = now - Self.window
        if let first = samples.first, first.t < cutoff {
            samples.removeFirst(samples.firstIndex { $0.t >= cutoff } ?? 0)
        }
        lock.unlock()
    }

    /// Snapshot for drawing (any thread).
    public func snapshot() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
