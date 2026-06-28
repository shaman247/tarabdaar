import CoreMIDI
import Foundation

/// Creates a virtual MIDI source and also sends directly to all external destinations.
///
/// `publishToCoreMIDI: false` skips the CoreMIDI client entirely — events still
/// fire `onLocalEvent` for in-process consumers (used by the Mac iPad-simulator
/// tab so its notes don't loopback to the same Mac's MIDIInput).
public class MIDIEngine: ObservableObject {
    private var midiClient = MIDIClientRef()
    private var midiSource = MIDIEndpointRef()
    private var midiOutputPort = MIDIPortRef()
    private let publishToCoreMIDI: Bool

    @Published public var isActive = false
    @Published public var statusMessage: String = "Not started"
    @Published public var destinationCount: Int = 0
    @Published public var sourceCount: Int = 0

    /// Fires on every emitted MIDI message, regardless of `publishToCoreMIDI`.
    /// Bytes are 2 (Channel Pressure) or 3 (everything else Starpad sends).
    public var onLocalEvent: (([UInt8]) -> Void)?

    public init(publishToCoreMIDI: Bool = true) {
        self.publishToCoreMIDI = publishToCoreMIDI
    }

    /// Call this after the app is fully launched (e.g., from onAppear)
    public func start() {
        guard !isActive else { return }
        if publishToCoreMIDI {
            // Retry a few times with delay — MIDI server may not be ready immediately
            attemptSetup(retriesLeft: 3, delay: 0.5)
        } else {
            // In-process only: mark active and fire MPE master-channel init
            // through `sendMessage`, which now reaches `onLocalEvent`.
            isActive = true
            statusMessage = "In-process"
            sendControlChange(controller: 101, value: 0, channel: 0)
            sendControlChange(controller: 100, value: 6, channel: 0)
            sendControlChange(controller: 6, value: 15, channel: 0)
            sendControlChange(controller: 38, value: 0, channel: 0)
        }
    }

    private func attemptSetup(retriesLeft: Int, delay: TimeInterval) {
        DispatchQueue.main.async {
            self.statusMessage = "Connecting..."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isActive else { return }

            let success = self.setup()
            if !success && retriesLeft > 0 {
                self.statusMessage = "Retrying... (\(retriesLeft))"
                self.attemptSetup(retriesLeft: retriesLeft - 1, delay: delay * 1.5)
            }
        }
    }

    private func setup() -> Bool {
        // Clean up any previous failed attempt
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
            midiSource = 0
            midiOutputPort = 0
        }

        var status = MIDIClientCreateWithBlock("Starpad" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshEndpointCounts()
            }
        }

        guard status == noErr else {
            statusMessage = "Client error: \(Self.midiErrorString(status))"
            return false
        }

        // Create virtual source (for on-device apps)
        status = MIDISourceCreateWithProtocol(
            midiClient,
            "Starpad Output" as CFString,
            ._1_0,
            &midiSource
        )

        if status != noErr {
            // Non-fatal — output port can still work
            statusMessage = "Source error: \(Self.midiErrorString(status))"
        }

        // Create output port (for sending to external destinations like Mac over USB)
        status = MIDIOutputPortCreate(midiClient, "Starpad Port" as CFString, &midiOutputPort)

        guard status == noErr else {
            statusMessage = "Port error: \(Self.midiErrorString(status))"
            return false
        }

        isActive = true
        refreshEndpointCounts()

        // Configure MPE lower zone: channel 0 is master, channels 1-15 are members
        // RPN 0x0006 on channel 0 with value 15 = 15 member channels
        sendControlChange(controller: 101, value: 0, channel: 0)
        sendControlChange(controller: 100, value: 6, channel: 0)
        sendControlChange(controller: 6, value: 15, channel: 0)
        sendControlChange(controller: 38, value: 0, channel: 0)

        return true
    }

    public func refreshEndpointCounts() {
        destinationCount = MIDIGetNumberOfDestinations()
        sourceCount = MIDIGetNumberOfSources()
        if isActive {
            statusMessage = "Active (\(destinationCount) dest, \(sourceCount) src)"
        }
    }

    public func destinationNames() -> [String] {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dest, kMIDIPropertyDisplayName, &cfName)
            if let name = cfName?.takeRetainedValue() as String? {
                names.append(name)
            } else {
                names.append("Destination \(i)")
            }
        }
        return names
    }

    public static func sourceNames() -> [String] {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName)
            if let name = cfName?.takeRetainedValue() as String? {
                names.append(name)
            } else {
                names.append("Source \(i)")
            }
        }
        return names
    }

    /// Set pitch bend range via RPN (CC 101, 100, 6, 38)
    public func sendPitchBendRange(semitones: UInt8, channel: UInt8) {
        sendControlChange(controller: 101, value: 0, channel: channel)   // RPN MSB
        sendControlChange(controller: 100, value: 0, channel: channel)   // RPN LSB
        sendControlChange(controller: 6, value: semitones, channel: channel) // Data Entry MSB
        sendControlChange(controller: 38, value: 0, channel: channel)    // Data Entry LSB
    }

    /// Channel pressure (aftertouch) — MPE standard for per-note expression
    public func sendChannelPressure(value: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        sendMessage(bytes: [status, value])
    }

    public func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0x90 | (channel & 0x0F)
        sendBytes(status, note, velocity)
    }

    public func sendNoteOff(note: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0x80 | (channel & 0x0F)
        sendBytes(status, note, 0)
    }

    public func sendControlChange(controller: UInt8, value: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        sendBytes(status, controller, value)
    }

    public func sendPitchBend(value: UInt16, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8((value >> 7) & 0x7F)
        sendBytes(status, lsb, msb)
    }

    private func sendBytes(_ byte0: UInt8, _ byte1: UInt8, _ byte2: UInt8) {
        sendMessage(bytes: [byte0, byte1, byte2])
    }

    /// Send a complete SysEx byte run (including the framing `0xF0…0xF7`)
    /// to external destinations. Used by the Mac to push the Pitch Pad
    /// scale to the iPad — see `PitchScaleSysEx`. Unlike `sendMessage`,
    /// this does NOT broadcast via the virtual source (which is UMP-only
    /// here) and does NOT fire `onLocalEvent`; it's destination-only.
    ///
    /// `toDestinationsMatching` (if set) restricts the send to
    /// destinations whose display name contains that substring, so a
    /// multi-hundred-byte blob isn't blasted at SWAM and other gear on
    /// every edit.
    public func sendSysEx(_ bytes: [UInt8], toDestinationsMatching match: String? = nil) {
        guard isActive, midiOutputPort != 0, !bytes.isEmpty else { return }

        // Enumerate destinations and pick the targets. If a name filter is
        // given but matches nothing (e.g. the bridged iPad endpoint shows
        // up under a different display name than expected), fall back to
        // sending to every destination so the sync isn't silently blocked.
        let n = MIDIGetNumberOfDestinations()
        var targets: [MIDIEndpointRef] = []
        for i in 0..<n {
            let dest = MIDIGetDestination(i)
            if let match {
                var cfName: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(dest, kMIDIPropertyDisplayName, &cfName)
                let name = cfName?.takeRetainedValue() as String? ?? ""
                if !name.localizedCaseInsensitiveContains(match) { continue }
            }
            targets.append(dest)
        }
        if targets.isEmpty, match != nil {
            targets = (0..<n).map { MIDIGetDestination($0) }
        }
        guard !targets.isEmpty else { return }

        // A default `MIDIPacketList` struct is 256 bytes; our payload may be
        // larger, so allocate a buffer big enough to hold the full byte run
        // in one packet.
        let bufSize = bytes.count + 128
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufSize, alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(listPtr)
        packet = MIDIPacketListAdd(listPtr, bufSize, packet, 0, bytes.count, bytes)
        guard packet != nil else { return }
        for dest in targets {
            MIDISend(midiOutputPort, dest, listPtr)
        }
    }

    private func sendMessage(bytes: [UInt8]) {
        // 0. In-process tap (used by the Mac simulator to deliver MIDI
        // directly to AudioEngine without round-tripping CoreMIDI).
        onLocalEvent?(bytes)
        if !publishToCoreMIDI { return }
        // 1. Broadcast via virtual source (for on-device listeners)
        if midiSource != 0 {
            var word: UInt32 = 0x20000000
            for (i, byte) in bytes.prefix(3).enumerated() {
                word |= UInt32(byte) << UInt32((2 - i) * 8)
            }

            var eventList = MIDIEventList()
            var packet = MIDIEventListInit(&eventList, ._1_0)
            packet = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            MIDIReceivedEventList(midiSource, &eventList)
        }

        // 2. Send directly to all external destinations (for Mac over USB)
        if midiOutputPort != 0 {
            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)

            let numDest = MIDIGetNumberOfDestinations()
            for i in 0..<numDest {
                let dest = MIDIGetDestination(i)
                MIDISend(midiOutputPort, dest, &packetList)
            }
        }
    }

    private static func midiErrorString(_ status: OSStatus) -> String {
        switch status {
        case kMIDIInvalidClient: return "invalid client"
        case kMIDIInvalidPort: return "invalid port"
        case kMIDIWrongEndpointType: return "wrong endpoint type"
        case kMIDINoConnection: return "no connection"
        case kMIDIUnknownEndpoint: return "unknown endpoint"
        case kMIDIUnknownProperty: return "unknown property"
        case kMIDIWrongPropertyType: return "wrong property type"
        case kMIDINoCurrentSetup: return "no current setup"
        case kMIDIMessageSendErr: return "message send error"
        case kMIDIServerStartErr: return "server start error"
        case kMIDISetupFormatErr: return "setup format error"
        case kMIDIWrongThread: return "wrong thread"
        case kMIDIObjectNotFound: return "object not found"
        case kMIDIIDNotUnique: return "ID not unique"
        case kMIDINotPermitted: return "not permitted"
        default: return "OSStatus \(status)"
        }
    }

    deinit {
        if midiSource != 0 { MIDIEndpointDispose(midiSource) }
        if midiOutputPort != 0 { MIDIPortDispose(midiOutputPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }
}
