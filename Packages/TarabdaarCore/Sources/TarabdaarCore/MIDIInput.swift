import CoreMIDI
import Foundation

/// CoreMIDI input bridge for the Mac — the TLP tunnel's receive socket.
/// It exists for ONE job: reassemble inbound SysEx runs per source and
/// hand each complete run to `onSysEx`. There is no MIDI note vocabulary;
/// channel-voice bytes on the port are skipped.
public final class MIDIInput: ObservableObject {

    /// Fires on the CoreMIDI thread with each COMPLETE inbound SysEx run
    /// (F0…F7 inclusive) — the TarabLink tunnel's receive socket
    /// (`AppController` wires it to `TarabLink.receivedSysEx`). CoreMIDI
    /// may split a SysEx across packets and callbacks; the accumulator
    /// below reassembles (the pattern proven by the iPad's
    /// `ScaleSyncReceiver`).
    public var onSysEx: ((_ bytes: [UInt8]) -> Void)?

    /// The shared CoreMIDI receive plumbing (client, all-sources input
    /// port, packet walk). Lazily built so `self` is capturable.
    private lazy var tap = MIDIInputTap(
        clientName: "Tarabdaar MIDI In",
        portName: "Tarabdaar In",
        logLabel: "MIDIInput"
    ) { [weak self] bytes, sourceKey in
        self?.parseBytes(bytes, sourceKey: sourceKey)
    }

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

    public init() {}

    public func start() {
        tap.start()
    }

    public func stop() {
        tap.stop()
        sysexLock.lock()
        sysexRuns.removeAll()
        sysexLock.unlock()
    }

    deinit { stop() }

    // MARK: - Packet parsing

    /// Walks a flat byte sequence (one packet's worth) for SysEx runs. A
    /// SysEx may span packets and callbacks, so the per-source accumulator
    /// carries it across calls; every other status byte is stepped over at
    /// its message length.
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

            // Channel-voice and system-common bytes carry nothing this app
            // reads; step over each at its message length so a following
            // SysEx is still found.
            switch byte & 0xF0 {
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0: i += 3   // 2 data bytes
            case 0xC0, 0xD0: i += 2                     // 1 data byte
            default: i += 1                             // F0-range / running status
            }
        }
    }
}
