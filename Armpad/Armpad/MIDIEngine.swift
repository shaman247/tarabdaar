import CoreMIDI
import Foundation

/// Creates a virtual MIDI source and also sends directly to all external destinations.
class MIDIEngine: ObservableObject {
    private var midiClient = MIDIClientRef()
    private var midiSource = MIDIEndpointRef()
    private var midiOutputPort = MIDIPortRef()

    @Published var isActive = false
    @Published var statusMessage: String = "Not started"
    @Published var destinationCount: Int = 0

    /// Call this after the app is fully launched (e.g., from onAppear)
    func start() {
        guard !isActive else { return }
        // Retry a few times with delay — MIDI server may not be ready immediately
        attemptSetup(retriesLeft: 3, delay: 0.5)
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

        var status = MIDIClientCreateWithBlock("Armpad" as CFString, &midiClient) { [weak self] _ in
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
            "Armpad Output" as CFString,
            ._1_0,
            &midiSource
        )

        if status != noErr {
            // Non-fatal — output port can still work
            statusMessage = "Source error: \(Self.midiErrorString(status))"
        }

        // Create output port (for sending to external destinations like Mac over USB)
        status = MIDIOutputPortCreate(midiClient, "Armpad Port" as CFString, &midiOutputPort)

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

    func refreshEndpointCounts() {
        destinationCount = MIDIGetNumberOfDestinations()
        let srcCount = MIDIGetNumberOfSources()
        if isActive {
            statusMessage = "Active (\(destinationCount) dest, \(srcCount) src)"
        }
    }

    func destinationNames() -> [String] {
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

    /// Set pitch bend range via RPN (CC 101, 100, 6, 38)
    func sendPitchBendRange(semitones: UInt8, channel: UInt8) {
        sendControlChange(controller: 101, value: 0, channel: channel)   // RPN MSB
        sendControlChange(controller: 100, value: 0, channel: channel)   // RPN LSB
        sendControlChange(controller: 6, value: semitones, channel: channel) // Data Entry MSB
        sendControlChange(controller: 38, value: 0, channel: channel)    // Data Entry LSB
    }

    /// Channel pressure (aftertouch) — MPE standard for per-note expression
    func sendChannelPressure(value: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        sendMessage(bytes: [status, value])
    }

    func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0x90 | (channel & 0x0F)
        sendBytes(status, note, velocity)
    }

    func sendNoteOff(note: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0x80 | (channel & 0x0F)
        sendBytes(status, note, 0)
    }

    func sendControlChange(controller: UInt8, value: UInt8, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        sendBytes(status, controller, value)
    }

    func sendPitchBend(value: UInt16, channel: UInt8) {
        guard isActive else { return }
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8((value >> 7) & 0x7F)
        sendBytes(status, lsb, msb)
    }

    private func sendBytes(_ byte0: UInt8, _ byte1: UInt8, _ byte2: UInt8) {
        sendMessage(bytes: [byte0, byte1, byte2])
    }

    private func sendMessage(bytes: [UInt8]) {
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
