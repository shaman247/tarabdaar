import CoreMIDI
import Foundation

// MARK: - Synced state

/// Which playing surface the iPad should show. TarabdaarMac drives this; the
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

/// The state TarabdaarMac pushes to the iPad: the scale, the two performance
/// parameters that shape how it sounds and plays — `tonicMidi` (which MIDI
/// note 1/1 maps to) and `marginPixels` (the soft-interpolation half-width) —
/// and the active `layout` (which surface the iPad shows). Codable so it can
/// be persisted on the iPad for offline relaunch.
public struct SyncedScaleState: Codable, Equatable {
    public var points: [PitchPoint]
    public var tonicMidi: Int
    /// Fractional tonic refinement in cents (±50) — the tonic is set in Hz
    /// on the Mac and rarely lands exactly on a MIDI note; without this the
    /// iPad would play up to a quarter-tone off the Mac's tarab.
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

/// Encodes / decodes a `SyncedScaleState` as a MIDI SysEx message so the Mac
/// can push the current Pitch Pad scale + tonic + margin to the iPad over the
/// existing USB-MIDI cable. This is the one deliberate exception to Tarabdaar's
/// "no SysEx, no shared state" rule — TarabdaarMac edits, Tarabdaar performs.
///
/// Wire format: `F0 7D 01 <base64(binary blob) as ASCII> F7`.
///   - `0x7D` is the standard non-commercial / educational SysEx ID.
///   - `0x01` is the Tarabdaar "scale" message subtype.
///   - The payload is base64 (all bytes ASCII ≤ 127, so 7-bit-safe) of a
///     **compact binary** blob — far smaller than JSON so it survives the
///     iOS USB-MIDI SysEx bridge comfortably. Blob layout:
///       `[ver:1][tonic:1][tonicCents14: 2×7-bit][margin:1][layout:1][count:1]`
///       then per point
///       `[num14: 2×7-bit][den14: 2×7-bit][y:1][enabled:1][labelLen:1][label UTF-8…]`.
///     v4 added the fractional tonic (centi-cents above −50 ¢, so ±50 ¢ at
///     0.01 ¢ resolution) — older blobs are rejected; both apps ship the
///     format together, like the fret-arrangement blob.
public enum PitchScaleSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let scaleSubID: UInt8 = 0x01
    private static let version: UInt8 = 4

    /// The raw binary blob — the TLP `SCALE_STATE` event payload (the
    /// SysEx + base64 wrapper below exists only for the persisted store's
    /// byte-compatibility and any legacy sender).
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

    public static func encode(_ state: SyncedScaleState) -> [UInt8] {
        let b64 = Data(encodeBlob(state)).base64EncodedData()   // ASCII ≤ 127
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
        guard let blob = Data(base64Encoded: Data(b[2...])).map(Array.init)
        else { return nil }
        return decodeBlob(blob)
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

/// Persists the last synced state on the iPad so it survives an offline
/// relaunch. Stored as the compact SysEx blob in `UserDefaults` (small, and
/// reuses the wire codec). iPad-only; the Mac never reads/writes this.
public enum SyncedScaleStore {
    private static let key = "tarabdaar.syncedScaleState.v3"

    public static func save(_ state: SyncedScaleState) {
        UserDefaults.standard.set(Data(PitchScaleSysEx.encode(state)), forKey: key)
    }

    public static func load() -> SyncedScaleState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return PitchScaleSysEx.decode([UInt8](data))
    }
}

// MARK: - SysEx String-Pad arrangement codec
/// (The String Pad's `F0 7D 02` arrangement SysEx and its sync store were
/// deleted 2026-07-24 with the rest of that surface's remnants — subtype
/// 0x02 stays unused so the numbering of 0x01/0x03 is untouched.)


/// Encodes / decodes a `FretArrangement` as a **third** Tarabdaar SysEx message
/// (subtype `0x03`), so the Mac can push the Fret Pad's segment layout to the
/// iPad alongside the scale. Like the String Pad's arrangement, the fret
/// layout is its own state (the vertical snap zones aren't derivable from the
/// scale) — sent only while the Fret Pad is the active layout.
///
/// Wire format: `F0 7D 03 <base64(binary blob) as ASCII> F7`. Blob layout:
///   `[ver:1][ghostQuarterOctaves:1][flags:1][count:1]` then per segment
///   `[degreeIndex:1][x14: 2×7-bit][topY:1][bottomY:1][enabled:1]` (x is the
///   free band position, quantized to 14 bits; y to 7 bits; the ghost extent
///   rides as quarter-octaves, so 0.5 → 2; `flags` is RESERVED — its only
///   bit was tap legato, deleted 2026-08-02, so it now writes 0 and decodes
///   ignored; the byte stays for blob-layout compatibility), then the
///   `FretArrangement.droneCount` (3) drone-button ratios as 14-bit
///   cents-above-−1200 (2×7-bit each, so the 0.25–4.0 ratio range fits).
///   Blob v2 replaced v1's integer octaves-per-side with the fractional
///   extent; v3 added the flags byte; v4 added the free per-segment x;
///   v5 added the drone ratios; v6 dropped from 4 to 3 drones (older blobs
///   are rejected — both apps ship the format together).
///   (The fret pitch warp is deliberately NOT in this blob: `ctl_fret_warp`
///   is a live registry param, streamed to the iPad over JOYCON_STATE.)
public enum FretArrangementSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let arrangementSubID: UInt8 = 0x03
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

    public static func encode(_ a: FretArrangement) -> [UInt8] {
        let b64 = Data(encodeBlob(a)).base64EncodedData()
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
        guard let blob = Data(base64Encoded: Data(b[2...])).map(Array.init)
        else { return nil }
        return decodeBlob(blob)
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

/// Persists the last synced Fret-Pad arrangement on the iPad (UserDefaults,
/// stored as the compact SysEx blob), so it survives an offline relaunch.
/// iPad-only; the Mac never reads/writes this.
public enum FretArrangementSyncStore {
    private static let key = "tarabdaar.syncedFretArrangement.v1"

    public static func save(_ a: FretArrangement) {
        UserDefaults.standard.set(Data(FretArrangementSysEx.encode(a)), forKey: key)
    }

    public static func load() -> FretArrangement? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return FretArrangementSysEx.decode([UInt8](data))
    }
}

// MARK: - SysEx Joy-Con tilt display codec

/// The THIRD live Tarabdaar SysEx message (2026-08-05, subtype `0x05` —
/// `0x02`/`0x04` are retired, do not reuse): the Mac's Joy-Con tilt
/// values, pushed to
/// the iPad as a DISPLAY-ONLY stream so the player can see all tilts at
/// a glance on the pad. Not state — nothing persists, nothing on the
/// iPad acts on it; a missed message just means a stale dot for a
/// frame. Sent change-gated (the Joy-Con path already quantizes), one
/// 7-byte message per update: `F0 7D 05 <x> <y> <active> F7`, x/y
/// 0…127 = tilt 0…1, active 0/1 (0 = stick at rest, the iPad's own
/// motion owns the tilts).
public enum JoyConTiltSysEx {
    public static let nonCommercialID: UInt8 = 0x7D
    public static let subtype: UInt8 = 0x05

    /// v3 (2026-08-12, 9 bytes): `F0 7D 05 <sx> <sy> <w1> <w2> <flags>
    /// F7` — the Joy-Con stick axes and the two calibrated WRIST body
    /// axes, all 0…127 = 0…1. Flags: bit 0 = stick deflected, bit 1 =
    /// the body solve is driving (arm axes show on the iPad's own
    /// square — its motion IS the arm sensor), bit 2 (2026-08-13) = a
    /// Joy-Con is ATTACHED — the one flag the iPad acts on: the drone
    /// buttons hide on both surfaces while the controller plays the
    /// drones, so the Mac re-sends this message on connect/disconnect
    /// and with every scale push, not just while axes move. The 7-byte
    /// v1 still decodes (as a stick-only frame).
    public static func encode(stickX: Double, stickY: Double,
                              wrist1: Double, wrist2: Double,
                              stickLive: Bool, bodyLive: Bool,
                              connected: Bool) -> [UInt8] {
        // Axes −1…+1 (the 2026-08-18 convention) → the legacy 0…127 wire.
        func b(_ v: Double) -> UInt8 {
            UInt8((max(-1.0, min(1.0, v)) + 1) / 2 * 127.0 + 0.5)
        }
        return [0xF0, nonCommercialID, subtype,
                b(stickX), b(stickY), b(wrist1), b(wrist2),
                (stickLive ? 1 : 0) | (bodyLive ? 2 : 0)
                    | (connected ? 4 : 0), 0xF7]
    }

    public static func decode(_ bytes: [UInt8]) -> JoyConTiltDisplay? {
        guard bytes.count >= 7, bytes.first == 0xF0, bytes.last == 0xF7,
              bytes[1] == nonCommercialID, bytes[2] == subtype
        else { return nil }
        // Legacy 7-bit axes decode to the −1…+1 display convention.
        func ax(_ b: UInt8) -> Double { Double(b) / 127.0 * 2.0 - 1.0 }
        if bytes.count == 9 {
            return JoyConTiltDisplay(stickX: ax(bytes[3]),
                                     stickY: ax(bytes[4]),
                                     wrist1: ax(bytes[5]),
                                     wrist2: ax(bytes[6]),
                                     stickLive: bytes[7] & 1 != 0,
                                     bodyLive: bytes[7] & 2 != 0,
                                     connected: bytes[7] & 4 != 0)
        }
        guard bytes.count == 7 else { return nil }
        return JoyConTiltDisplay(stickX: ax(bytes[3]),
                                 stickY: ax(bytes[4]),
                                 wrist1: 0, wrist2: 0,
                                 stickLive: bytes[5] != 0,
                                 bodyLive: false,
                                 connected: false)
    }
}

/// One Mac→iPad tilt display frame (all values −1…+1, centre 0 — the
/// app-wide tilt convention since 2026-08-18): the Joy-Con stick
/// axes, the three wrist attitude axes (the Joy-Con's fused
/// pitch/roll/yaw, 2026-08-18), and the three Mac-evaluated ARM axes
/// (the iPad tilts after the arm-calibration solve — `armLive` says a
/// calibration is driving them; without one the iPad's own raw square
/// is already the truth). Liveness flags dim the panes — plus
/// `connected` (2026-08-13), the one field the iPad ACTS on: while a
/// Joy-Con is attached to the Mac its arrows play the drones, so both
/// surfaces hide their drone buttons.
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
    /// The Mac's `ctl_strike_window` blend window (s), relayed so the
    /// iPad scope's white→cyan onset fade tracks the window that
    /// actually governs the strike→acceleration blend (TLP v7). 2.0
    /// when never received (link down, legacy sender).
    public var strikeWindowS: Double
    /// The Mac's `ctl_fret_warp` fret pitch-warp amount (0…1, TLP v10) —
    /// with `connected` one of the fields the pad ACTS on: the fret
    /// field resolves touch pitch through it, so a Mac-side binding
    /// (e.g. the Joy-Con stick) performs the warp live. 0 when never
    /// received (link down = the linear field).
    public var fieldWarp: Double
    /// The Mac's playing-range OCTAVE SHIFT in whole octaves (−3…+3,
    /// TLP v11 — Joy-Con dpad ←/→). Acted on by the pad through
    /// `PitchPadEngine.octaveShift` — ONSET-captured per touch, so a
    /// sounding note keeps its birth octave and only new onsets take
    /// the new range — and shown in the toolbar. 0 when never received
    /// (link down = no shift).
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
///   2. A **virtual destination** ("Tarabdaar Scale") as a belt-and-suspenders
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

    /// The last synced Fret-Pad arrangement (its own SysEx message, subtype
    /// `0x03`), for the iPad Fret Pad surface. Seeded from the persisted store
    /// on `start()` and updated on each push.
    @Published public private(set) var fretArrangement: FretArrangement?

    /// The Mac's Joy-Con tilt display stream (subtype `0x05`) — nothing
    /// persists. `active == false` means the stick is at rest and the
    /// iPad's own motion owns the tilts. The axes are display-only;
    /// `connected` is the one field the surface acts on (drone buttons
    /// hide while a controller plays the drones).
    @Published public private(set) var joyConTilt = JoyConTiltDisplay.idle

    /// Fired on the main thread with each decoded state (scale + tonic +
    /// margin). The receiver also persists it via `SyncedScaleStore`.
    public var onState: ((SyncedScaleState) -> Void)?

    /// TarabLink tunnel routing (2026-08-14): a complete inbound SysEx
    /// whose header is the TLP envelope (`F0 7D 10`) is handed here RAW —
    /// on the CoreMIDI thread — for `TarabLink.receivedSysEx`. The link
    /// decodes and calls back into the appliers below, so the published
    /// state and its persistence are identical to the legacy SysEx path.
    public var onSysEx: (([UInt8]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()

    /// SysEx reassembly, PER SOURCE (2026-08-14): one shared buffer
    /// corrupts when two sources carry SysEx concurrently (runs interleave
    /// across callbacks and each collision aborts the in-flight frame).
    /// Keyed by the input-port connection refCon (= the source endpoint
    /// ref); the virtual-destination path uses a sentinel key. Guarded
    /// since the paths can fire on different CoreMIDI threads.
    private struct SysExRun {
        var buffer: [UInt8] = []
        var receiving = false
    }
    private var sysexRuns: [UInt: SysExRun] = [:]
    private static let destinationKey = UInt.max
    private let lock = NSLock()

    public init() {}

    public func start() {
        guard client == 0 else { return }
        // Seed the Fret-Pad arrangement from the last persisted push so the
        // surface is populated on an offline relaunch.
        fretArrangement = FretArrangementSyncStore.load()
        let cs = MIDIClientCreateWithBlock("Tarabdaar Scale In" as CFString, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        guard cs == noErr else {
            NSLog("Tarabdaar: ScaleSyncReceiver client create failed: \(cs)")
            return
        }

        // Path 1: input port + connect to every source.
        let ps = MIDIInputPortCreateWithBlock(
            client, "Tarabdaar Scale In Port" as CFString, &inputPort
        ) { [weak self] packetList, srcRefCon in
            self?.handle(packetList: packetList,
                         sourceKey: UInt(bitPattern: Int(bitPattern: srcRefCon)))
        }
        if ps == noErr {
            connectAllSources()
        } else {
            NSLog("Tarabdaar: ScaleSyncReceiver input port create failed: \(ps)")
        }

        // Path 2: virtual destination (named target).
        let ds = MIDIDestinationCreateWithBlock(
            client, "Tarabdaar Scale" as CFString, &destination
        ) { [weak self] packetList, _ in
            self?.handle(packetList: packetList,
                         sourceKey: ScaleSyncReceiver.destinationKey)
        }
        if ds != noErr {
            NSLog("Tarabdaar: ScaleSyncReceiver destination create failed: \(ds)")
        }
    }

    private func connectAllSources() {
        guard inputPort != 0 else { return }
        let n = MIDIGetNumberOfSources()
        for i in 0..<n {
            // Idempotent: connecting an already-connected source is a no-op.
            // The source ref rides as the refCon → per-source reassembly.
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, src,
                                  UnsafeMutableRawPointer(bitPattern: UInt(src)))
        }
    }

    public func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        lock.lock()
        sysexRuns.removeAll()
        lock.unlock()
    }

    deinit { stop() }

    // MARK: - Packet handling

    private func handle(packetList: UnsafePointer<MIDIPacketList>,
                        sourceKey: UInt) {
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
                consume(buf, sourceKey: sourceKey)
            }
            current = UnsafePointer(MIDIPacketNext(current))
        }
    }

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

    private func finalize(_ bytes: [UInt8]) {
        // TLP tunnel messages (the shipping wire) route to the link.
        if bytes.count > 3, bytes[1] == 0x7D, bytes[2] == TLPPack.sysExSubtype {
            onSysEx?(bytes)
            return
        }
        // Legacy per-message SysEx (0x01/0x03/0x05) — nothing ships these
        // any more; kept one release as a decode fallback.
        if let state = PitchScaleSysEx.decode(bytes) {
            applyState(state)
        } else if let arrangement = FretArrangementSysEx.decode(bytes) {
            applyArrangement(arrangement)
        } else if let tilt = JoyConTiltSysEx.decode(bytes) {
            applyJoyCon(tilt)
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
            // Change-gated (2026-08-24): JOYCON_STATE frames stream at up
            // to 30 Hz while the volume readout moves; an unchanged tilt
            // display must not re-render every toolbar pane each frame.
            guard let self, self.joyConTilt != tilt else { return }
            self.joyConTilt = tilt
        }
    }

    /// VOLUME READOUT history (2026-08-24): the Mac's radiated voice/
    /// taraf levels — the JOYCON_STATE vol bytes on the `TLPVolume` 0…1
    /// log scale — stamped with receive time. Deliberately NOT
    /// `@Published`: frames arrive at up to 30 Hz while sound plays, and
    /// the toolbar's volume scope polls this at UI rate inside a
    /// `TimelineView` instead (the strike scope's pattern), so level
    /// motion never re-renders the toolbar.
    public let volumeHistory = VolumeHistory()
}

/// Thread-safe rolling buffer of received (voice, taraf) volume levels
/// (0…1 log scale — see `TLPVolume`). Samples are sparse: change-gated
/// 30 Hz while levels move, the link's 250 ms heartbeat at rest — the
/// scope forward-fills between them.
public final class VolumeHistory {
    public struct Sample: Sendable {
        public let t: TimeInterval        // ProcessInfo systemUptime
        public let voice: Double
        public let taraf: Double
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    /// Retention window — comfortably longer than any display window, so
    /// the scope always has the one sample preceding its left edge to
    /// forward-fill from.
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
