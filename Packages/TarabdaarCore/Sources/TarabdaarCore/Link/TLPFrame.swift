import Foundation

/// TLP — the TarabLink Protocol: the transport-agnostic binary vocabulary
/// for everything that crosses the iPad↔Mac link.
///
/// Frame classes by type byte:
///   0x01–0x3F  events        — reliable, never dropped, never coalesced
///   0x40–0x5F  state frames  — latest-wins, coalescable per type
///
/// All integers little-endian; floats IEEE-754 binary32 LE. Encode/decode
/// is explicit byte-table code. Decoders return nil on any truncation or
/// bounds violation — never trap on wire input.
public enum TLP {
    /// Protocol version — both apps ship in lockstep; the HELLO range check
    /// refuses a mismatched peer cleanly (the symptom otherwise: "drones and
    /// tilt work, touches are silent").
    public static let versionMin: UInt16 = 13
    public static let versionMax: UInt16 = 13
    /// Hard cap on an encoded frame.
    public static let maxFrameBytes = 1024
    /// HELLO magic 'TRBL' (LE u32).
    public static let helloMagic: UInt32 = 0x4C42_5254

    // Type bytes.
    public static let typeHello: UInt8 = 0x01
    public static let typePing: UInt8 = 0x03
    public static let typePong: UInt8 = 0x04
    public static let typePanic: UInt8 = 0x08
    public static let typeScaleState: UInt8 = 0x10
    public static let typeFretArrangement: UInt8 = 0x11
    public static let typeResyncRequest: UInt8 = 0x1F
    public static let typePerfState: UInt8 = 0x40
    public static let typeJoyConState: UInt8 = 0x41
    // 0x42 is retired — do not reuse.

    /// Wrap-aware "candidate is newer than last" for u16 sequence numbers.
    public static func isNewer(_ candidate: UInt16, than last: UInt16) -> Bool {
        let d = candidate &- last
        return d != 0 && d < 0x8000
    }
}

/// The volume-readout byte: 0 = silence (≤ −60 dBFS), 1…255 span −60…0
/// dBFS linearly in dB, so byte/255 is the iPad meter's display height.
public enum TLPVolume {
    public static let floorDb = -60.0

    /// Linear amplitude (0 dBFS = 1.0) → wire byte.
    public static func byte(fromLinear level: Double) -> UInt8 {
        guard level > 0 else { return 0 }
        let db = 20.0 * log10(level)
        let x = 1.0 - db / floorDb          // 0 at the floor, 1 at 0 dBFS
        guard x > 0 else { return 0 }
        return UInt8(min(255.0, max(1.0, (x * 255.0).rounded())))
    }

    /// Wire byte → the 0…1 log-domain display value.
    public static func value01(_ b: UInt8) -> Double { Double(b) / 255.0 }

    /// Linear amplitude (0 dBFS = 1.0) → the same 0…1 log display value,
    /// without the wire's byte quantisation. The ONE level law behind
    /// every scope that draws amplitude: 0 at the floor, 1 at 0 dBFS.
    public static func level01(linear level: Double) -> Double {
        guard level > 0 else { return 0 }
        let db = 20.0 * log10(level)
        return min(1, max(0, 1.0 - db / floorDb))
    }

    /// The 0…1 display value back to dB (0 → the floor, 1 → 0 dBFS).
    public static func db(from01 v: Double) -> Double {
        (1.0 - v) * floorDb
    }
}

/// Which end of the link a HELLO comes from.
public enum TLPRole: UInt8, Equatable, Sendable {
    case pad = 0    // iPad
    case host = 1   // Mac
}

/// One active touch inside a PERF_STATE frame — 9 bytes on the wire:
/// `id u16 · onsetSeq u8 · velocity u8 · radius u8 · pitch f32`.
/// `pitch` is a fractional MIDI note number (69.0 = A440). `onsetSeq`
/// bumps on each fresh articulation of this id, so a lift + re-press
/// survives latest-wins coalescing as a retrigger.
public struct TLPTouch: Equatable, Sendable {
    public var id: UInt16
    public var onsetSeq: UInt8
    public var velocity: UInt8      // 0–255 onset velocity
    /// FINGERTIP SIZE — `UITouch.majorRadius` in POINTS × 4, clamped to
    /// 255 (0 = unknown: producers without a touchscreen). Quarter-point
    /// steps are far finer than Apple's own quantisation; the signal is
    /// used as a BINARY flatten detection, not a continuous axis
    /// (`TouchFlattenDetector`).
    public var radius: UInt8
    public var pitch: Float         // fractional MIDI note
    /// IN-PROCESS ONLY (the Mac strum chord's live loudness): not encoded;
    /// decoded frames carry 1.0.
    public var exprScale: Double
    /// IN-PROCESS ONLY (the strum chord's glide-queue exemption): not
    /// encoded; decoded frames carry `false`.
    public var glideExempt: Bool

    public init(id: UInt16, onsetSeq: UInt8, velocity: UInt8,
                radius: UInt8 = 0, pitch: Float, exprScale: Double = 1.0,
                glideExempt: Bool = false) {
        self.id = id
        self.onsetSeq = onsetSeq
        self.velocity = velocity
        self.radius = radius
        self.pitch = pitch
        self.exprScale = exprScale
        self.glideExempt = glideExempt
    }

    /// Fingertip radius in points → the wire byte (quarter-point steps,
    /// clamped to 255 ≈ 63.75 pt). Negative/zero reads as unknown.
    public static func radiusByte(points: Double) -> UInt8 {
        guard points > 0 else { return 0 }
        return UInt8(min(255.0, max(0.0, (points * 4.0).rounded())))
    }

    /// The wire byte back to points (0 = unknown).
    public static func radiusPoints(_ b: UInt8) -> Double { Double(b) / 4.0 }

    /// This touch's fingertip radius in points (0 = unknown).
    public var radiusPoints: Double { TLPTouch.radiusPoints(radius) }
}

/// iPad→Mac: the whole performance in one atomic frame — the COMPLETE set
/// of active touches (absence = note-off; a new onsetSeq = retrigger),
/// tilt, accelerometer, strike, drone buttons and chord selection. The
/// latest frame is the truth, so coalescing can never lose a release.
///
/// Layout: `type u8 · flags u8 · stateSeq u16 · timestampUs u32 ·
/// tilt s16×3 · accel s16×3 · droneMask u8 · strike u8 · chordDegree u8 ·
/// chordOctave i8 · count u8 · touches (9 B each)`.
public struct TLPPerfState: Equatable, Sendable {
    public static let flagBackgrounded: UInt8 = 1 << 0
    /// Accelerometer wire full scale: ±32767 ↔ ±4 g (diagnostic display).
    public static let accelFullScaleG = 4.0

    public var flags: UInt8
    public var stateSeq: UInt16
    public var timestampUs: UInt32        // sender monotonic µs (wraps ~71.6 min)
    public var tiltX: Int16               // −32767…32767 ↔ normalized −1…+1
    public var tiltY: Int16
    public var tiltZ: Int16
    public var accelX: Int16              // −32767…32767 ↔ ±accelFullScaleG g
    public var accelY: Int16
    public var accelZ: Int16
    public var droneMask: UInt8           // bits 0–2 = drone buttons held
    /// The accelerometer strike-scale envelope, 0–255 ↔ 0…1 — the
    /// `.strike` dimension's wire value; 0 without an accelerometer.
    public var strike: UInt8
    /// The chord bar selection: degree index (0xFF = none) and octave as
    /// an i8 bit pattern. Held state; the Mac acts on the change edges.
    public var chordDegree: UInt8
    public var chordOctave: UInt8
    public var touches: [TLPTouch]

    public static let chordNone: UInt8 = 0xFF

    public init(flags: UInt8 = 0, stateSeq: UInt16, timestampUs: UInt32,
                tiltX: Int16, tiltY: Int16, tiltZ: Int16,
                accelX: Int16 = 0, accelY: Int16 = 0, accelZ: Int16 = 0,
                droneMask: UInt8, strike: UInt8 = 0,
                chordDegree: UInt8 = TLPPerfState.chordNone,
                chordOctave: UInt8 = 0, touches: [TLPTouch]) {
        self.flags = flags
        self.stateSeq = stateSeq
        self.timestampUs = timestampUs
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.tiltZ = tiltZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.droneMask = droneMask
        self.strike = strike
        self.chordDegree = chordDegree
        self.chordOctave = chordOctave
        self.touches = touches
    }

    /// The selection as the model type (nil = none).
    public var chordSelection: ChordSelection? {
        guard chordDegree != TLPPerfState.chordNone else { return nil }
        return ChordSelection(degree: Int(chordDegree),
                              octave: Int(Int8(bitPattern: chordOctave)))
    }
}

/// Mac→iPad: the display frame — Joy-Con stick, wrist attitude, the
/// Mac-evaluated ARM axes, the volume readout and the relayed controls.
/// The pad ACTS on `connected` (flag bit 2, hides the drone buttons),
/// `fieldWarp` and `octave`. Latest-wins with a heartbeat floor.
///
/// Layout: `type u8 · flags u8 · stateSeq u16 · timestampUs u32 · stickX
/// stickY wrist1 wrist2 wrist3 arm1 arm2 arm3 strikeWin volVoice volTaraf
/// fieldWarp octave (u8 each)`.
public struct TLPJoyConState: Equatable, Sendable {
    public static let flagStickLive: UInt8 = 1 << 0
    public static let flagBodyLive: UInt8 = 1 << 1
    public static let flagConnected: UInt8 = 1 << 2
    public static let flagArmLive: UInt8 = 1 << 3

    public var flags: UInt8
    public var stateSeq: UInt16
    public var timestampUs: UInt32
    public var stickX: UInt8              // 0–255 ↔ −1…+1 (centre 128)
    public var stickY: UInt8
    public var wrist1: UInt8
    public var wrist2: UInt8
    public var wrist3: UInt8
    /// `ctl_strike_window` in 50 ms units (0 = unset → the viewer's 2 s
    /// default), for the iPad scope's onset fade.
    public var strikeWin: UInt8
    public var arm1: UInt8
    public var arm2: UInt8
    public var arm3: UInt8
    /// The Mac's radiated voice and taraf levels (`TLPVolume` log scale).
    public var volVoice: UInt8
    public var volTaraf: UInt8
    /// `ctl_fret_warp` (0–255 ↔ 0…1) — acted on by the pad's fret field.
    public var fieldWarp: UInt8
    /// The playing-range octave shift, i8 bit pattern (−3…+3) — acted on
    /// by the pad.
    public var octave: UInt8

    public init(flags: UInt8, stateSeq: UInt16, timestampUs: UInt32,
                stickX: UInt8, stickY: UInt8, wrist1: UInt8, wrist2: UInt8,
                wrist3: UInt8 = 128, arm1: UInt8 = 128, arm2: UInt8 = 128,
                arm3: UInt8 = 128, strikeWin: UInt8 = 0,
                volVoice: UInt8 = 0, volTaraf: UInt8 = 0,
                fieldWarp: UInt8 = 0, octave: UInt8 = 0) {
        self.flags = flags
        self.stateSeq = stateSeq
        self.timestampUs = timestampUs
        self.stickX = stickX
        self.stickY = stickY
        self.wrist1 = wrist1
        self.wrist2 = wrist2
        self.wrist3 = wrist3
        self.arm1 = arm1
        self.arm2 = arm2
        self.arm3 = arm3
        self.strikeWin = strikeWin
        self.volVoice = volVoice
        self.volTaraf = volTaraf
        self.fieldWarp = fieldWarp
        self.octave = octave
    }
}

/// The reliable channel: bring-up, latency, panic, and the Mac→iPad sync
/// payloads (the codecs' raw `encodeBlob` bytes).
public enum TLPEvent: Equatable, Sendable {
    case hello(minVer: UInt16, maxVer: UInt16, role: TLPRole)
    case ping(id: UInt8, t1: UInt32)
    case pong(id: UInt8, t1: UInt32, t2: UInt32)
    case panic
    case scaleState(blob: [UInt8])
    case fretArrangement(blob: [UInt8])
    case resyncRequest
}

/// A decoded wire frame.
public enum TLPFrame: Equatable, Sendable {
    case perfState(TLPPerfState)
    case joyConState(TLPJoyConState)
    case event(seq: UInt16, TLPEvent)

    /// The wire type byte (state types coalesce per type, events never).
    public var typeByte: UInt8 {
        switch self {
        case .perfState: return TLP.typePerfState
        case .joyConState: return TLP.typeJoyConState
        case .event(_, let e):
            switch e {
            case .hello: return TLP.typeHello
            case .ping: return TLP.typePing
            case .pong: return TLP.typePong
            case .panic: return TLP.typePanic
            case .scaleState: return TLP.typeScaleState
            case .fretArrangement: return TLP.typeFretArrangement
            case .resyncRequest: return TLP.typeResyncRequest
            }
        }
    }

    public var isState: Bool {
        let t = typeByte
        return t >= 0x40 && t <= 0x5F
    }
}

// MARK: - Encode

extension TLPFrame {
    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        switch self {
        case .perfState(let s):
            out.append(TLP.typePerfState)
            out.append(s.flags)
            out.appendLE(s.stateSeq)
            out.appendLE(s.timestampUs)
            out.appendLE(UInt16(bitPattern: s.tiltX))
            out.appendLE(UInt16(bitPattern: s.tiltY))
            out.appendLE(UInt16(bitPattern: s.tiltZ))
            out.appendLE(UInt16(bitPattern: s.accelX))
            out.appendLE(UInt16(bitPattern: s.accelY))
            out.appendLE(UInt16(bitPattern: s.accelZ))
            out.append(s.droneMask)
            out.append(s.strike)
            out.append(s.chordDegree)
            out.append(s.chordOctave)
            out.append(UInt8(min(s.touches.count, 255)))
            for t in s.touches.prefix(255) {
                out.appendLE(t.id)
                out.append(t.onsetSeq)
                out.append(t.velocity)
                out.append(t.radius)
                out.appendLE(t.pitch.bitPattern)
            }
        case .joyConState(let s):
            out.append(TLP.typeJoyConState)
            out.append(s.flags)
            out.appendLE(s.stateSeq)
            out.appendLE(s.timestampUs)
            out.append(contentsOf: [s.stickX, s.stickY, s.wrist1, s.wrist2,
                                    s.wrist3, s.arm1, s.arm2, s.arm3,
                                    s.strikeWin, s.volVoice, s.volTaraf,
                                    s.fieldWarp, s.octave])
        case .event(let seq, let e):
            out.append(typeByte)
            out.appendLE(seq)
            switch e {
            case .hello(let minVer, let maxVer, let role):
                out.appendLE(TLP.helloMagic)
                out.appendLE(minVer)
                out.appendLE(maxVer)
                out.append(role.rawValue)
            case .ping(let id, let t1):
                out.append(id)
                out.appendLE(t1)
            case .pong(let id, let t1, let t2):
                out.append(id)
                out.appendLE(t1)
                out.appendLE(t2)
            case .panic, .resyncRequest:
                break
            case .scaleState(let blob), .fretArrangement(let blob):
                out.appendLE(UInt16(min(blob.count, TLP.maxFrameBytes)))
                out.append(contentsOf: blob.prefix(TLP.maxFrameBytes))
            }
        }
        return out
    }
}

// MARK: - Decode

extension TLPFrame {
    /// Decodes one complete frame; nil on truncation, unknown type, bad
    /// magic or trailing garbage.
    public static func decode(_ bytes: [UInt8]) -> TLPFrame? {
        guard bytes.count <= TLP.maxFrameBytes else { return nil }
        var r = TLPReader(bytes)
        guard let type = r.u8() else { return nil }
        switch type {
        case TLP.typePerfState:
            guard let flags = r.u8(), let seq = r.u16(), let ts = r.u32(),
                  let tx = r.u16(), let ty = r.u16(), let tz = r.u16(),
                  let ax = r.u16(), let ay = r.u16(), let az = r.u16(),
                  let mask = r.u8(), let strike = r.u8(),
                  let chordDeg = r.u8(), let chordOct = r.u8(),
                  let count = r.u8() else { return nil }
            var touches: [TLPTouch] = []
            touches.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let id = r.u16(), let onset = r.u8(), let vel = r.u8(),
                      let rad = r.u8(),
                      let pitchBits = r.u32() else { return nil }
                touches.append(TLPTouch(id: id, onsetSeq: onset, velocity: vel,
                                        radius: rad,
                                        pitch: Float(bitPattern: pitchBits)))
            }
            guard r.isAtEnd else { return nil }
            return .perfState(TLPPerfState(
                flags: flags, stateSeq: seq, timestampUs: ts,
                tiltX: Int16(bitPattern: tx), tiltY: Int16(bitPattern: ty),
                tiltZ: Int16(bitPattern: tz),
                accelX: Int16(bitPattern: ax), accelY: Int16(bitPattern: ay),
                accelZ: Int16(bitPattern: az),
                droneMask: mask, strike: strike,
                chordDegree: chordDeg, chordOctave: chordOct,
                touches: touches))
        case TLP.typeJoyConState:
            guard let flags = r.u8(), let seq = r.u16(), let ts = r.u32(),
                  let sx = r.u8(), let sy = r.u8(), let w1 = r.u8(),
                  let w2 = r.u8(), let w3 = r.u8(), let a1 = r.u8(),
                  let a2 = r.u8(), let a3 = r.u8(), let sw = r.u8(),
                  let vv = r.u8(), let vt = r.u8(), let fw = r.u8(),
                  let oct = r.u8(),
                  r.isAtEnd
            else { return nil }
            return .joyConState(TLPJoyConState(
                flags: flags, stateSeq: seq, timestampUs: ts,
                stickX: sx, stickY: sy, wrist1: w1, wrist2: w2,
                wrist3: w3, arm1: a1, arm2: a2, arm3: a3, strikeWin: sw,
                volVoice: vv, volTaraf: vt, fieldWarp: fw, octave: oct))
        default:
            guard type >= 0x01, type <= 0x3F, let seq = r.u16() else { return nil }
            let event: TLPEvent
            switch type {
            case TLP.typeHello:
                guard let magic = r.u32(), magic == TLP.helloMagic,
                      let minVer = r.u16(), let maxVer = r.u16(),
                      let roleRaw = r.u8(), let role = TLPRole(rawValue: roleRaw)
                else { return nil }
                event = .hello(minVer: minVer, maxVer: maxVer, role: role)
            case TLP.typePing:
                guard let id = r.u8(), let t1 = r.u32() else { return nil }
                event = .ping(id: id, t1: t1)
            case TLP.typePong:
                guard let id = r.u8(), let t1 = r.u32(), let t2 = r.u32()
                else { return nil }
                event = .pong(id: id, t1: t1, t2: t2)
            case TLP.typePanic:
                event = .panic
            case TLP.typeResyncRequest:
                event = .resyncRequest
            case TLP.typeScaleState, TLP.typeFretArrangement:
                guard let len = r.u16(), let blob = r.bytes(Int(len))
                else { return nil }
                event = type == TLP.typeScaleState
                    ? .scaleState(blob: blob) : .fretArrangement(blob: blob)
            default:
                return nil
            }
            guard r.isAtEnd else { return nil }
            return .event(seq: seq, event)
        }
    }
}

// MARK: - Byte helpers

extension Array where Element == UInt8 {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}

/// Bounds-checked little-endian reader over a decoded frame.
struct TLPReader {
    private let bytes: [UInt8]
    private var i = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var isAtEnd: Bool { i == bytes.count }

    mutating func u8() -> UInt8? {
        guard i < bytes.count else { return nil }
        defer { i += 1 }
        return bytes[i]
    }
    mutating func u16() -> UInt16? {
        guard i + 2 <= bytes.count else { return nil }
        defer { i += 2 }
        return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
    }
    mutating func u32() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        defer { i += 4 }
        return UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }
    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, i + n <= bytes.count else { return nil }
        defer { i += n }
        return Array(bytes[i..<i + n])
    }
}
