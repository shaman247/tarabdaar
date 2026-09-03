import CoreMIDI
import Foundation

/// The shared CoreMIDI *receive* plumbing behind both inbound taps — the
/// Mac's `MIDIInput` and the iPad's `ScaleSyncReceiver`. It owns the client,
/// an input port connected to EVERY source (refreshed on each CoreMIDI setup
/// change), an optional virtual destination, and the packet-list walk; each
/// packet's bytes are handed to `onBytes` on the CoreMIDI thread together
/// with a per-source key.
///
/// The source key is the connection refCon (the source endpoint ref), or
/// `MIDIInputTap.destinationKey` for the virtual destination. Callers use it
/// to keep ONE SysEx reassembly buffer per source: a single shared buffer
/// corrupts the moment two sources carry SysEx concurrently (the iPad's TLP
/// stream plus its own echo through an IAC loop, or USB + BLE both
/// delivering) because runs interleave across callbacks.
///
/// The tap itself parses nothing — message parsing stays with each owner.
public final class MIDIInputTap {
    /// Called on the CoreMIDI thread with one packet's bytes and the key of
    /// the endpoint that delivered them.
    public typealias ByteHandler = (UnsafeBufferPointer<UInt8>, UInt) -> Void

    /// Sentinel source key for bytes arriving at the virtual destination.
    public static let destinationKey = UInt.max

    private let clientName: String
    private let portName: String
    /// Name of the virtual destination to publish, or `nil` for none.
    private let destinationName: String?
    /// Prefix for the `NSLog` diagnostics, so each owner's lines stay
    /// recognisable.
    private let logLabel: String
    private let onBytes: ByteHandler

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var destination = MIDIEndpointRef()

    public init(clientName: String, portName: String,
                destinationName: String? = nil,
                logLabel: String,
                onBytes: @escaping ByteHandler) {
        self.clientName = clientName
        self.portName = portName
        self.destinationName = destinationName
        self.logLabel = logLabel
        self.onBytes = onBytes
    }

    deinit { stop() }

    public func start() {
        guard client == 0 else { return }
        let cs = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        guard cs == noErr else {
            NSLog("Tarabdaar: \(logLabel) client create failed: \(cs)")
            return
        }

        // Path 1: input port + connect to every source.
        let ps = MIDIInputPortCreateWithBlock(client, portName as CFString, &port) {
            [weak self] packetList, srcRefCon in
            self?.deliver(packetList: packetList,
                          sourceKey: UInt(bitPattern: Int(bitPattern: srcRefCon)))
        }
        if ps == noErr {
            connectAllSources()
        } else {
            NSLog("Tarabdaar: \(logLabel) port create failed: \(ps)")
        }

        // Path 2 (optional): a virtual destination other apps can target.
        if let destinationName {
            let ds = MIDIDestinationCreateWithBlock(client, destinationName as CFString,
                                                    &destination) { [weak self] packetList, _ in
                self?.deliver(packetList: packetList,
                              sourceKey: MIDIInputTap.destinationKey)
            }
            if ds != noErr {
                NSLog("Tarabdaar: \(logLabel) destination create failed: \(ds)")
            }
        }
    }

    public func stop() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    private func connectAllSources() {
        guard port != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            // Idempotent: connecting an already-connected source is a no-op.
            // The source ref rides as the refCon so the read block can key
            // one SysEx reassembly buffer per source.
            MIDIPortConnectSource(port, src,
                                  UnsafeMutableRawPointer(bitPattern: UInt(src)))
        }
    }

    private func deliver(packetList: UnsafePointer<MIDIPacketList>, sourceKey: UInt) {
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
                onBytes(buf, sourceKey)
            }
            current = UnsafePointer(MIDIPacketNext(current))
        }
    }
}
