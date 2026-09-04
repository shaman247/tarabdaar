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
/// Blob (v4): `[ver][tonic][tonicCents14: 2×7-bit][margin][layout][count]`
/// then per point `[num14][den14][y][enabled][labelLen][label UTF-8…]`;
/// tonicCents14 = centi-cents above −50 ¢. Other versions are rejected —
/// both apps ship the format together.
public enum PitchScaleSysEx {
    private static let version: UInt8 = 4

    /// The raw binary blob — the TLP `SCALE_STATE` event payload.
    public static func encodeBlob(_ state: SyncedScaleState) -> [UInt8] {
        let tonic = UInt8(max(0, min(127, state.tonicMidi)))
        // centi-cents above −50 ¢: 0…10000, fits 14 bits
        let cc = max(0, min(10000, Int(((state.tonicCents + 50.0) * 100.0).rounded())))
        let margin = UInt8(max(0, min(127, Int(state.marginPixels.rounded()))))
        var blob: [UInt8] = [version, tonic,
                             UInt8(cc >> 7), UInt8(cc & 0x7F),
                             margin,
                             UInt8(state.layout.rawValue & 0x7F),
                             UInt8(min(127, state.points.count))]
        for p in state.points.prefix(127) {
            let num = min(16383, max(0, p.num))
            let den = min(16383, max(1, p.den))
            blob.append(UInt8(num >> 7));  blob.append(UInt8(num & 0x7F))
            blob.append(UInt8(den >> 7));  blob.append(UInt8(den & 0x7F))
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
        guard blob.count >= 7, blob[0] == version else { return nil }

        let tonic = Int(blob[1])
        let cents = Double((Int(blob[2]) << 7) | Int(blob[3])) / 100.0 - 50.0
        let margin = Double(blob[4])
        let layout = PadLayout(rawValue: Int(blob[5])) ?? .pitchPad
        let count = Int(blob[6])
        var i = 7
        var points: [PitchPoint] = []
        for _ in 0..<count {
            guard i + 7 <= blob.count else { return nil }
            let num = (Int(blob[i]) << 7) | Int(blob[i + 1])
            let den = (Int(blob[i + 2]) << 7) | Int(blob[i + 3])
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
    private static let key = "tarabdaar.syncedScaleState.v4"

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
/// Blob (v6): `[ver][ghostQuarterOctaves][flags][count]`, per segment
/// `[degreeIndex][x14: 2×7-bit][topY][bottomY][enabled]`, then the 3
/// drone-button ratios as 14-bit cents above −1200 (0.25–4.0). `flags` is
/// RESERVED (written 0, decoded ignored). Other versions are rejected.
/// The fret pitch warp is deliberately NOT here — `ctl_fret_warp` is a
/// live registry param relayed over JOYCON_STATE.
public enum FretArrangementSysEx {
    private static let version: UInt8 = 6

    /// The raw binary blob — the TLP `FRET_ARRANGEMENT` event payload.
    public static func encodeBlob(_ a: FretArrangement) -> [UInt8] {
        func b7(_ v: Int) -> UInt8 { UInt8(max(0, min(127, v))) }
        let segments = a.segments.prefix(127)
        var blob: [UInt8] = [version,
                             b7(Int((a.ghostExtentOctaves * 4).rounded())),
                             0,   // flags — reserved
                             UInt8(segments.count)]
        for s in segments {
            blob.append(b7(s.degreeIndex))
            let x14 = max(0, min(16383, Int((s.x * 16383).rounded())))
            blob.append(UInt8(x14 >> 7)); blob.append(UInt8(x14 & 0x7F))
            blob.append(b7(Int((s.topY * 127).rounded())))
            blob.append(b7(Int((s.bottomY * 127).rounded())))
            blob.append(s.enabled ? 1 : 0)
        }
        for i in 0..<FretArrangement.droneCount {
            let r = i < a.droneRatios.count ? a.droneRatios[i]
                : FretArrangement.defaultDroneRatios[i]
            // cents above −1200 (ratio 0.25…4 → 0…3600), 14-bit
            let c = max(0, min(16383, Int((1200.0 * log2(r) + 1200.0).rounded())))
            blob.append(UInt8(c >> 7)); blob.append(UInt8(c & 0x7F))
        }
        return blob
    }

    /// Decode the raw binary blob (the TLP event payload).
    public static func decodeBlob(_ blob: [UInt8]) -> FretArrangement? {
        guard blob.count >= 4, blob[0] == version else { return nil }

        let extent = Double(blob[1]) / 4.0
        // blob[2] = the reserved flags byte (ignored).
        let count = Int(blob[3])
        var i = 4
        var segments: [FretSegment] = []
        for _ in 0..<count {
            guard i + 6 <= blob.count else { return nil }
            let x14 = (Int(blob[i + 1]) << 7) | Int(blob[i + 2])
            segments.append(FretSegment(degreeIndex: Int(blob[i]),
                                        x: Double(x14) / 16383.0,
                                        topY: Double(blob[i + 3]) / 127.0,
                                        bottomY: Double(blob[i + 4]) / 127.0,
                                        enabled: blob[i + 5] != 0))
            i += 6
        }
        var drones = FretArrangement.defaultDroneRatios
        if i + 2 * FretArrangement.droneCount <= blob.count {
            for d in 0..<FretArrangement.droneCount {
                let c = (Int(blob[i]) << 7) | Int(blob[i + 1])
                drones[d] = pow(2.0, (Double(c) - 1200.0) / 1200.0)
                i += 2
            }
        }
        return FretArrangement(segments: segments, ghostExtentOctaves: extent,
                               droneRatios: drones)
    }
}

/// iPad-only persistence of the last synced arrangement (the raw blob).
public enum FretArrangementSyncStore {
    private static let key = "tarabdaar.syncedFretArrangement.v2"

    public static func save(_ a: FretArrangement) {
        UserDefaults.standard.set(Data(FretArrangementSysEx.encodeBlob(a)), forKey: key)
    }

    public static func load() -> FretArrangement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return FretArrangementSysEx.decodeBlob([UInt8](data))
    }
}

/// One Mac→iPad display frame (axes −1…+1): Joy-Con stick, fused wrist
/// attitude, Mac-evaluated ARM axes (`armLive` = a calibration drives
/// them), liveness flags, and the fields the iPad ACTS on: `connected`
/// (hides the drone buttons), `fieldWarp`, `octaveShift`.
public struct JoyConTiltDisplay: Equatable {
    public var stickX: Double
    public var stickY: Double
    public var wrist1: Double
    public var wrist2: Double
    public var wrist3: Double
    public var arm1: Double
    public var arm2: Double
    public var arm3: Double
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
    /// The playing-range octave shift (−3…+3), ONSET-captured per touch by
    /// `PitchPadEngine.octaveShift`. 0 when never received.
    public var octaveShift: Int

    public init(stickX: Double, stickY: Double, wrist1: Double,
                wrist2: Double, stickLive: Bool, bodyLive: Bool,
                connected: Bool, wrist3: Double = 0, arm1: Double = 0,
                arm2: Double = 0, arm3: Double = 0,
                armLive: Bool = false, strikeWindowS: Double = 2.0,
                fieldWarp: Double = 0, octaveShift: Int = 0) {
        self.stickX = stickX
        self.stickY = stickY
        self.wrist1 = wrist1
        self.wrist2 = wrist2
        self.wrist3 = wrist3
        self.arm1 = arm1
        self.arm2 = arm2
        self.arm3 = arm3
        self.stickLive = stickLive
        self.bodyLive = bodyLive
        self.armLive = armLive
        self.connected = connected
        self.strikeWindowS = strikeWindowS
        self.fieldWarp = min(max(fieldWarp, 0), 1)
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

/// The iPad's CoreMIDI SysEx receiver: reassembles incoming SysEx (split
/// across packets/callbacks) and routes each complete message — TLP
/// envelopes to `TarabLink` via `onSysEx`, legacy blobs to the appliers.
/// Two receive paths feed the same per-source accumulator: an input port
/// connected to every source (the Mac appears on the iPad as a source) and
/// a virtual destination ("Tarabdaar Scale"). Connections refresh on every
/// CoreMIDI setup change. Only SysEx is parsed.
public final class ScaleSyncReceiver: ObservableObject {
    /// Bumped on every applied scale.
    @Published public private(set) var syncCount: Int = 0

    /// The last synced arrangement (seeded from the store on `start()`).
    @Published public private(set) var fretArrangement: FretArrangement?

    /// The Mac's Joy-Con display stream (not persisted); the surface acts
    /// on `connected`, `fieldWarp` and `octaveShift`.
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
        }
    }

    public func applyArrangement(_ arrangement: FretArrangement) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            FretArrangementSyncStore.save(arrangement)
            self.fretArrangement = arrangement
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
}

/// Thread-safe rolling buffer of received (voice, taraf) levels; samples
/// are sparse and the scope forward-fills.
public final class VolumeHistory {
    public struct Sample: Sendable {
        public let t: TimeInterval        // ProcessInfo systemUptime
        public let voice: Double
        public let taraf: Double
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    /// Retention window, longer than any display window.
    private static let window: TimeInterval = 8.0

    public init() {}

    /// Append one received level pair (any thread).
    public func record(voice: Double, taraf: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        samples.append(Sample(t: now, voice: voice, taraf: taraf))
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
