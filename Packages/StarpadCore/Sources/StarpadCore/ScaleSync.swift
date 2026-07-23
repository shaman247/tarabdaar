import CoreMIDI
import Foundation

// MARK: - Synced state

/// Which playing surface the iPad should show. StarpadMac drives this; the
/// iPad performs whichever layout is pushed (see `SyncedScaleState.layout`).
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

/// The state StarpadMac pushes to the iPad: the scale, the two performance
/// parameters that shape how it sounds and plays — `tonicMidi` (which MIDI
/// note 1/1 maps to) and `marginPixels` (the soft-interpolation half-width) —
/// and the active `layout` (which surface the iPad shows). Codable so it can
/// be persisted on the iPad for offline relaunch.
public struct SyncedScaleState: Codable, Equatable {
    public var points: [PitchPoint]
    public var tonicMidi: Int
    public var marginPixels: Double
    public var layout: PadLayout

    public init(points: [PitchPoint], tonicMidi: Int, marginPixels: Double,
                layout: PadLayout = .pitchPad) {
        self.points = points
        self.tonicMidi = tonicMidi
        self.marginPixels = marginPixels
        self.layout = layout
    }

    public var scale: PitchScale { PitchScale(points: points) }
}

// MARK: - SysEx scale codec

/// Encodes / decodes a `SyncedScaleState` as a MIDI SysEx message so the Mac
/// can push the current Pitch Pad scale + tonic + margin to the iPad over the
/// existing USB-MIDI cable. This is the one deliberate exception to Starpad's
/// "no SysEx, no shared state" rule — StarpadMac edits, Starpad performs.
///
/// Wire format: `F0 7D 01 <base64(binary blob) as ASCII> F7`.
///   - `0x7D` is the standard non-commercial / educational SysEx ID.
///   - `0x01` is the Starpad "scale" message subtype.
///   - The payload is base64 (all bytes ASCII ≤ 127, so 7-bit-safe) of a
///     **compact binary** blob — far smaller than JSON so it survives the
///     iOS USB-MIDI SysEx bridge comfortably. Blob layout:
///       `[ver:1][tonic:1][margin:1][layout:1][count:1]` then per point
///       `[num14: 2×7-bit][den14: 2×7-bit][y:1][enabled:1][labelLen:1][label UTF-8…]`.
public enum PitchScaleSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let scaleSubID: UInt8 = 0x01
    private static let version: UInt8 = 3

    public static func encode(_ state: SyncedScaleState) -> [UInt8] {
        let tonic = UInt8(max(0, min(127, state.tonicMidi)))
        let margin = UInt8(max(0, min(127, Int(state.marginPixels.rounded()))))
        var blob: [UInt8] = [version, tonic, margin,
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
        let b64 = Data(blob).base64EncodedData()   // ASCII, every byte ≤ 127
        var out: [UInt8] = [0xF0, nonCommercialID, scaleSubID]
        out.append(contentsOf: b64)
        out.append(0xF7)
        return out
    }

    /// Decode a complete SysEx byte run (with or without the framing
    /// `F0`/`F7`). Returns nil if the header doesn't match or the payload
    /// can't be parsed.
    public static func decode(_ bytes: [UInt8]) -> SyncedScaleState? {
        var b = bytes
        if b.first == 0xF0 { b.removeFirst() }
        if b.last == 0xF7 { b.removeLast() }
        guard b.count >= 2, b[0] == nonCommercialID, b[1] == scaleSubID else { return nil }
        guard let blob = Data(base64Encoded: Data(b[2...])).map(Array.init),
              blob.count >= 5, blob[0] == version else { return nil }

        let tonic = Int(blob[1])
        let margin = Double(blob[2])
        let layout = PadLayout(rawValue: Int(blob[3])) ?? .pitchPad
        let count = Int(blob[4])
        var i = 5
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
                                marginPixels: margin, layout: layout)
    }
}

// MARK: - Persistence (iPad)

/// Persists the last synced state on the iPad so it survives an offline
/// relaunch. Stored as the compact SysEx blob in `UserDefaults` (small, and
/// reuses the wire codec). iPad-only; the Mac never reads/writes this.
public enum SyncedScaleStore {
    private static let key = "starpad.syncedScaleState.v3"

    public static func save(_ state: SyncedScaleState) {
        UserDefaults.standard.set(Data(PitchScaleSysEx.encode(state)), forKey: key)
    }

    public static func load() -> SyncedScaleState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return PitchScaleSysEx.decode([UInt8](data))
    }
}

// MARK: - SysEx String-Pad arrangement codec

/// Encodes / decodes a `StringArrangement` as a **second** Starpad SysEx message
/// (subtype `0x02`), so the Mac can push the String Pad's note layout to the
/// iPad alongside the scale. The String Pad's arrangement is its own state (not
/// derivable from the scale, unlike the Chord Pad), so it rides its own small
/// message rather than bloating the scale blob — sent only while the String Pad
/// is the active layout.
///
/// Wire format: `F0 7D 02 <base64(binary blob) as ASCII> F7`. Blob layout:
///   `[ver:1][stringCount:1][ghost:1][rotationDeg:1][noteCount:1]` then per note
///   `[degreeIndex:1][octave+64:1][stringIndex:1][centerY:1][height:1][enabled:1]`.
public enum StringArrangementSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let arrangementSubID: UInt8 = 0x02
    private static let version: UInt8 = 2

    public static func encode(_ a: StringArrangement) -> [UInt8] {
        func b7(_ v: Int) -> UInt8 { UInt8(max(0, min(127, v))) }
        let notes = a.notes.prefix(127)
        var blob: [UInt8] = [version, b7(a.stringCount), b7(a.ghostStringsPerSide),
                             b7(Int(a.rotationDegrees.rounded())),
                             UInt8(notes.count)]
        for n in notes {
            blob.append(b7(n.degreeIndex))
            blob.append(b7(n.octave + 64))                       // bias-64 signed
            blob.append(b7(n.stringIndex))
            blob.append(b7(Int((n.centerY * 127).rounded())))
            blob.append(b7(Int((n.height * 127).rounded())))
            blob.append(n.enabled ? 1 : 0)
        }
        let b64 = Data(blob).base64EncodedData()
        var out: [UInt8] = [0xF0, nonCommercialID, arrangementSubID]
        out.append(contentsOf: b64)
        out.append(0xF7)
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> StringArrangement? {
        var b = bytes
        if b.first == 0xF0 { b.removeFirst() }
        if b.last == 0xF7 { b.removeLast() }
        guard b.count >= 2, b[0] == nonCommercialID, b[1] == arrangementSubID else { return nil }
        guard let blob = Data(base64Encoded: Data(b[2...])).map(Array.init),
              blob.count >= 5, blob[0] == version else { return nil }

        let stringCount = Int(blob[1])
        let ghost = Int(blob[2])
        let rotation = Double(blob[3])
        let count = Int(blob[4])
        var i = 5
        var notes: [StringNote] = []
        for _ in 0..<count {
            guard i + 6 <= blob.count else { return nil }
            notes.append(StringNote(degreeIndex: Int(blob[i]),
                                    octave: Int(blob[i + 1]) - 64,
                                    stringIndex: Int(blob[i + 2]),
                                    centerY: Double(blob[i + 3]) / 127.0,
                                    height: Double(blob[i + 4]) / 127.0,
                                    enabled: blob[i + 5] != 0))
            i += 6
        }
        return StringArrangement(notes: notes, stringCount: stringCount,
                                 ghostStringsPerSide: ghost, rotationDegrees: rotation)
    }
}

/// Persists the last synced String-Pad arrangement on the iPad (UserDefaults,
/// stored as the compact SysEx blob), so it survives an offline relaunch.
/// iPad-only; the Mac never reads/writes this.
public enum StringArrangementSyncStore {
    private static let key = "starpad.syncedStringArrangement.v1"

    public static func save(_ a: StringArrangement) {
        UserDefaults.standard.set(Data(StringArrangementSysEx.encode(a)), forKey: key)
    }

    public static func load() -> StringArrangement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return StringArrangementSysEx.decode([UInt8](data))
    }
}

// MARK: - SysEx Fret-Pad arrangement codec

/// Encodes / decodes a `FretArrangement` as a **third** Starpad SysEx message
/// (subtype `0x03`), so the Mac can push the Fret Pad's segment layout to the
/// iPad alongside the scale. Like the String Pad's arrangement, the fret
/// layout is its own state (the vertical snap zones aren't derivable from the
/// scale) — sent only while the Fret Pad is the active layout.
///
/// Wire format: `F0 7D 03 <base64(binary blob) as ASCII> F7`. Blob layout:
///   `[ver:1][ghostQuarterOctaves:1][flags:1][count:1]` then per segment
///   `[degreeIndex:1][topY:1][bottomY:1][enabled:1]` (y quantized to 7 bits;
///   the ghost extent rides as quarter-octaves, so 0.5 → 2; flags bit0 =
///   tap legato). Blob v2 replaced v1's integer octaves-per-side with the
///   fractional extent; v3 added the flags byte.
public enum FretArrangementSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let arrangementSubID: UInt8 = 0x03
    private static let version: UInt8 = 3

    public static func encode(_ a: FretArrangement) -> [UInt8] {
        func b7(_ v: Int) -> UInt8 { UInt8(max(0, min(127, v))) }
        let segments = a.segments.prefix(127)
        var blob: [UInt8] = [version,
                             b7(Int((a.ghostExtentOctaves * 4).rounded())),
                             a.legato ? 1 : 0,
                             UInt8(segments.count)]
        for s in segments {
            blob.append(b7(s.degreeIndex))
            blob.append(b7(Int((s.topY * 127).rounded())))
            blob.append(b7(Int((s.bottomY * 127).rounded())))
            blob.append(s.enabled ? 1 : 0)
        }
        let b64 = Data(blob).base64EncodedData()
        var out: [UInt8] = [0xF0, nonCommercialID, arrangementSubID]
        out.append(contentsOf: b64)
        out.append(0xF7)
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> FretArrangement? {
        var b = bytes
        if b.first == 0xF0 { b.removeFirst() }
        if b.last == 0xF7 { b.removeLast() }
        guard b.count >= 2, b[0] == nonCommercialID, b[1] == arrangementSubID else { return nil }
        guard let blob = Data(base64Encoded: Data(b[2...])).map(Array.init),
              blob.count >= 4, blob[0] == version else { return nil }

        let extent = Double(blob[1]) / 4.0
        let legato = blob[2] & 1 != 0
        let count = Int(blob[3])
        var i = 4
        var segments: [FretSegment] = []
        for _ in 0..<count {
            guard i + 4 <= blob.count else { return nil }
            segments.append(FretSegment(degreeIndex: Int(blob[i]),
                                        topY: Double(blob[i + 1]) / 127.0,
                                        bottomY: Double(blob[i + 2]) / 127.0,
                                        enabled: blob[i + 3] != 0))
            i += 4
        }
        return FretArrangement(segments: segments, ghostExtentOctaves: extent,
                               legato: legato)
    }
}

/// Persists the last synced Fret-Pad arrangement on the iPad (UserDefaults,
/// stored as the compact SysEx blob), so it survives an offline relaunch.
/// iPad-only; the Mac never reads/writes this.
public enum FretArrangementSyncStore {
    private static let key = "starpad.syncedFretArrangement.v1"

    public static func save(_ a: FretArrangement) {
        UserDefaults.standard.set(Data(FretArrangementSysEx.encode(a)), forKey: key)
    }

    public static func load() -> FretArrangement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return FretArrangementSysEx.decode([UInt8](data))
    }
}

// MARK: - iPad SysEx receiver

/// Receives the scale pushed from the Mac over USB-MIDI and reassembles the
/// incoming SysEx (which CoreMIDI may split across packets/callbacks) into a
/// `PitchScale`. On a complete, valid scale message it hops to the main
/// thread and fires `onScale`.
///
/// **Two receive paths, both feeding the same accumulator:**
///   1. An **input port connected to every source** — the Mac, sending to
///      the iPad over USB, appears on the iPad as a *source*; this is how
///      USB-incoming MIDI is actually caught (mirrors the Mac's `MIDIInput`,
///      which is the proven iPad→Mac path in reverse).
///   2. A **virtual destination** ("Starpad Scale") as a belt-and-suspenders
///      named target, in case a host routes to it directly.
/// Connections are refreshed on every CoreMIDI setup change, so plugging the
/// Mac in after launch still connects.
///
/// This is the iPad's only MIDI input — it does not touch the iPad's MPE
/// output (`MIDIEngine`). Channel-voice traffic that leaks in (e.g. the
/// iPad's own notes looping back) is ignored; only SysEx is parsed.
public final class ScaleSyncReceiver: ObservableObject {
    /// Bumped on every successfully-applied scale, for an optional UI pill.
    @Published public private(set) var syncCount: Int = 0

    /// The last synced String-Pad arrangement (its own SysEx message), for the
    /// iPad String Pad surface. Seeded from the persisted store on `start()` and
    /// updated on each push.
    @Published public private(set) var stringArrangement: StringArrangement?

    /// The last synced Fret-Pad arrangement (its own SysEx message, subtype
    /// `0x03`), for the iPad Fret Pad surface. Seeded from the persisted store
    /// on `start()` and updated on each push.
    @Published public private(set) var fretArrangement: FretArrangement?

    /// Fired on the main thread with each decoded state (scale + tonic +
    /// margin). The receiver also persists it via `SyncedScaleStore`.
    public var onState: ((SyncedScaleState) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()

    /// SysEx reassembly buffer + state, guarded since the two receive paths
    /// can fire on different CoreMIDI threads.
    private var sysexBuffer: [UInt8] = []
    private var receiving = false
    private let lock = NSLock()

    public init() {}

    public func start() {
        guard client == 0 else { return }
        // Seed the String-Pad / Fret-Pad arrangements from the last persisted
        // push so those surfaces are populated on an offline relaunch.
        stringArrangement = StringArrangementSyncStore.load()
        fretArrangement = FretArrangementSyncStore.load()
        let cs = MIDIClientCreateWithBlock("Starpad Scale In" as CFString, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        guard cs == noErr else {
            NSLog("Starpad: ScaleSyncReceiver client create failed: \(cs)")
            return
        }

        // Path 1: input port + connect to every source.
        let ps = MIDIInputPortCreateWithBlock(
            client, "Starpad Scale In Port" as CFString, &inputPort
        ) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }
        if ps == noErr {
            connectAllSources()
        } else {
            NSLog("Starpad: ScaleSyncReceiver input port create failed: \(ps)")
        }

        // Path 2: virtual destination (named target).
        let ds = MIDIDestinationCreateWithBlock(
            client, "Starpad Scale" as CFString, &destination
        ) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }
        if ds != noErr {
            NSLog("Starpad: ScaleSyncReceiver destination create failed: \(ds)")
        }
    }

    private func connectAllSources() {
        guard inputPort != 0 else { return }
        let n = MIDIGetNumberOfSources()
        for i in 0..<n {
            // Idempotent: connecting an already-connected source is a no-op.
            MIDIPortConnectSource(inputPort, MIDIGetSource(i), nil)
        }
    }

    public func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    deinit { stop() }

    // MARK: - Packet handling

    private func handle(packetList: UnsafePointer<MIDIPacketList>) {
        let count = Int(packetList.pointee.numPackets)
        var current = UnsafeRawPointer(packetList).advanced(by: MemoryLayout<UInt32>.size)
            .assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<count {
            let len = Int(current.pointee.length)
            if len > 0 {
                let raw = UnsafeRawPointer(current)
                    .advanced(by: MemoryLayout<MIDITimeStamp>.size + MemoryLayout<UInt16>.size)
                let buf = UnsafeBufferPointer(
                    start: raw.assumingMemoryBound(to: UInt8.self), count: len
                )
                consume(buf)
            }
            current = UnsafePointer(MIDIPacketNext(current))
        }
    }

    private func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        for byte in bytes {
            if byte == 0xF0 {
                sysexBuffer = [0xF0]
                receiving = true
            } else if byte == 0xF7 {
                guard receiving else { continue }
                sysexBuffer.append(0xF7)
                receiving = false
                finalize(sysexBuffer)
                sysexBuffer.removeAll(keepingCapacity: true)
            } else if byte >= 0xF8 {
                // System realtime — may be interleaved inside SysEx. Ignore.
                continue
            } else if receiving {
                sysexBuffer.append(byte)
            }
        }
    }

    private func finalize(_ bytes: [UInt8]) {
        if let state = PitchScaleSysEx.decode(bytes) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                SyncedScaleStore.save(state)
                self.onState?(state)
                self.syncCount += 1
            }
        } else if let arrangement = StringArrangementSysEx.decode(bytes) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                StringArrangementSyncStore.save(arrangement)
                self.stringArrangement = arrangement
            }
        } else if let arrangement = FretArrangementSysEx.decode(bytes) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                FretArrangementSyncStore.save(arrangement)
                self.fretArrangement = arrangement
            }
        }
    }
}
