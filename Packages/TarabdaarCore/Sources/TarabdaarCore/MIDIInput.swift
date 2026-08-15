import CoreMIDI
import Foundation

/// CoreMIDI input bridge for the Mac. Every incoming MPE channel-voice
/// message is forwarded verbatim to the hosted Audio Unit (SWAM Viola)
/// via `AudioEngine.sendHostedMIDI(...)`. The AU does its own voice
/// allocation, pitch bending, and expression handling per the MPE spec.
///
/// We still run a small local handler for CC101/100/6 (RPN pitch-bend
/// range) and CC123 (all-notes-off) so a per-channel bend-range state
/// stays accurate across preset switches and so a future on-the-fly
/// re-route (different AU, different bend range) inherits a sane
/// starting state. Those CCs are ALSO forwarded to the AU so its own
/// state stays in sync — the local handler is a side observer, not a
/// gatekeeper.
///
/// CCs are also delivered to `onCC` so `AppController` can drive
/// Tarabdaar-owned parameters (sym pool + FX) from incoming controllers.
public final class MIDIInput: ObservableObject {
    public weak var audioEngine: AudioEngine?

    /// Fires on the CoreMIDI thread for every incoming CC. The consumer
    /// (AppController) hops to main before touching `@Published` state.
    public var onCC: ((_ cc: UInt8, _ value: UInt8) -> Void)?

    /// Fires on the CoreMIDI thread with each COMPLETE inbound SysEx run
    /// (F0…F7 inclusive) — the TarabLink tunnel's receive socket
    /// (`AppController` wires it to `TarabLink.receivedSysEx`). CoreMIDI
    /// may split a SysEx across packets and callbacks; the accumulator
    /// below reassembles (the pattern proven by the iPad's
    /// `ScaleSyncReceiver`).
    public var onSysEx: ((_ bytes: [UInt8]) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    /// SysEx reassembly, PER SOURCE (keyed by the source endpoint ref
    /// passed as the connection refCon). A single shared buffer corrupts
    /// the moment two sources carry SysEx concurrently — e.g. the iPad's
    /// TLP stream plus its own echo through an IAC loop, or USB + BLE both
    /// delivering — because runs interleave across callbacks and each
    /// collision aborts the in-flight frame.
    private struct SysExRun {
        var buffer: [UInt8] = []
        var receiving = false
    }
    private var sysexRuns: [UInt: SysExRun] = [:]
    private let sysexLock = NSLock()

    /// Per-channel RPN accumulator for the (CC101, CC100, CC6, CC38)
    /// sequence that sets pitch-bend range. Per-channel because MPE
    /// member channels can each opt into a different range.
    private struct RPNState {
        var msb: UInt8 = 0x7F   // 0x7F/0x7F = "RPN reset" — no in-flight RPN
        var lsb: UInt8 = 0x7F
        var dataMsb: UInt8 = 0
        var bendRangeSemitones: Double = Config.midiPitchBendRange
    }
    private var rpn: [UInt8: RPNState] = [:]
    private let rpnLock = NSLock()

    public init() {}

    public func start() {
        if client != 0 { return }
        let cs = MIDIClientCreateWithBlock("Tarabdaar MIDI In" as CFString, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        guard cs == noErr else {
            NSLog("Tarabdaar: MIDIInput client create failed: \(cs)")
            return
        }
        let ps = MIDIInputPortCreateWithBlock(client, "Tarabdaar In" as CFString, &port) { [weak self] packetList, srcRefCon in
            self?.handle(packetList: packetList,
                         sourceKey: UInt(bitPattern: Int(bitPattern: srcRefCon)))
        }
        guard ps == noErr else {
            NSLog("Tarabdaar: MIDIInput port create failed: \(ps)")
            return
        }
        connectAllSources()
    }

    public func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        rpnLock.lock()
        rpn.removeAll()
        rpnLock.unlock()
        sysexLock.lock()
        sysexRuns.removeAll()
        sysexLock.unlock()
    }

    deinit { stop() }

    private func connectAllSources() {
        guard port != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            // Idempotent: connecting an already-connected source is a no-op.
            // The source ref rides as the refCon so the read block can keep
            // one SysEx reassembly buffer per source.
            MIDIPortConnectSource(port, src,
                                  UnsafeMutableRawPointer(bitPattern: UInt(src)))
        }
    }

    // MARK: - Packet dispatch

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
                let buf = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: len)
                parseBytes(buf, sourceKey: sourceKey)
            }
            current = UnsafePointer(MIDIPacketNext(current))
        }
    }

    /// Parses a flat byte sequence (one packet's worth) of MIDI 1.0
    /// channel-voice messages plus SysEx. CoreMIDI guarantees each packet
    /// contains whole channel-voice messages, but a SysEx may span packets
    /// and callbacks — the per-source accumulator carries it across calls.
    private func parseBytes(_ bytes: UnsafeBufferPointer<UInt8>,
                            sourceKey: UInt) {
        // One callback = one source; work on a local copy of that source's
        // run and store it back at the end.
        sysexLock.lock()
        var run = sysexRuns[sourceKey] ?? SysExRun()
        sysexLock.unlock()
        defer {
            sysexLock.lock()
            sysexRuns[sourceKey] = run
            sysexLock.unlock()
        }

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]

            // Mid-SysEx: data bytes accumulate, F7 finalizes, realtime
            // (≥ F8) interleaves legally and is skipped, any other status
            // byte aborts the run (per the MIDI spec) and re-parses.
            if run.receiving {
                if byte < 0x80 {
                    run.buffer.append(byte)
                    i += 1
                    continue
                } else if byte == 0xF7 {
                    run.buffer.append(0xF7)
                    run.receiving = false
                    let complete = run.buffer
                    run.buffer.removeAll(keepingCapacity: true)
                    onSysEx?(complete)
                    i += 1
                    continue
                } else if byte >= 0xF8 {
                    i += 1
                    continue
                } else {
                    run.receiving = false
                    run.buffer.removeAll(keepingCapacity: true)
                    // fall through to normal parse of this status byte
                }
            }

            if byte == 0xF0 {
                run.buffer = [0xF0]
                run.receiving = true
                i += 1
                continue
            }

            let status = byte & 0xF0
            let channel = byte & 0x0F

            switch status {
            case 0x80: // Note Off
                if i + 2 < bytes.count {
                    audioEngine?.sendHostedMIDI(status: byte, data1: bytes[i + 1], data2: bytes[i + 2])
                }
                i += 3
            case 0x90: // Note On (vel=0 → Note Off; AU handles internally)
                if i + 2 < bytes.count {
                    audioEngine?.sendHostedMIDI(status: byte, data1: bytes[i + 1], data2: bytes[i + 2])
                }
                i += 3
            case 0xB0: // CC
                if i + 2 < bytes.count {
                    audioEngine?.sendHostedMIDI(status: byte, data1: bytes[i + 1], data2: bytes[i + 2])
                    handleCC(channel: channel, cc: bytes[i + 1], value: bytes[i + 2])
                }
                i += 3
            case 0xD0: // Channel Pressure
                if i + 1 < bytes.count {
                    audioEngine?.sendHostedMIDI2(status: byte, data1: bytes[i + 1])
                }
                i += 2
            case 0xE0: // Pitch Bend
                if i + 2 < bytes.count {
                    audioEngine?.sendHostedMIDI(status: byte, data1: bytes[i + 1], data2: bytes[i + 2])
                }
                i += 3
            case 0xA0, 0xC0:
                // Poly Aftertouch (3 bytes) / Program Change (2 bytes).
                // Not used by Tarabdaar's iPad output; skip safely.
                i += (status == 0xC0 ? 2 : 3)
            case 0xF0:
                // System-common / system-realtime (F0/F7 handled above).
                // Skip the single byte.
                i += 1
            default:
                i += 1
            }
        }
    }

    /// Local CC observer for RPN-bend-range and CC123. The AU has
    /// already received these bytes by the time we get here; this
    /// handler just keeps a Mac-side mirror of per-channel bend range
    /// (used by any future feature that needs to know what range the
    /// controller agreed on) and propagates the CC to `onCC` for
    /// Tarabdaar-owned mappings.
    private func handleCC(channel: UInt8, cc: UInt8, value: UInt8) {
        rpnLock.lock()
        var state = rpn[channel] ?? RPNState()
        switch cc {
        case 101: state.msb = value
        case 100: state.lsb = value
        case 6:
            state.dataMsb = value
            if state.msb == 0 && state.lsb == 0 {
                state.bendRangeSemitones = Double(value)
            }
        case 38:
            // Data LSB — Tarabdaar sends 0 here, ignore.
            break
        default:
            break
        }
        rpn[channel] = state
        rpnLock.unlock()

        // Per-preset CC → parameter routing happens above this layer.
        onCC?(cc, value)
    }
}
