import CoreMIDI
import Foundation

/// Creates a virtual MIDI source and also sends directly to external destinations,
/// with a **wired-first transport preference**: Bluetooth (BLE-MIDI) destinations
/// are used only when no wired destination exists, so USB carries the traffic
/// when the cable is in and Bluetooth takes over when it's pulled — never both
/// at once (both live would deliver every message twice). The CoreMIDI
/// setup-change notification refreshes the snapshot, so plug/unplug switches
/// automatically.
///
/// `publishToCoreMIDI: false` skips the CoreMIDI client entirely — events still
/// fire `onLocalEvent` for in-process consumers (used by the Mac iPad-simulator
/// tab so its notes don't loopback to the same Mac's MIDIInput).
public class MIDIEngine: ObservableObject {
    private var midiClient = MIDIClientRef()
    private var midiSource = MIDIEndpointRef()
    private var midiOutputPort = MIDIPortRef()
    private let publishToCoreMIDI: Bool

    /// Snapshot of the current destinations with their transport, refreshed
    /// on every CoreMIDI setup change (`refreshEndpointCounts`). Cached so
    /// the 60 Hz send path doesn't re-query endpoint properties per message;
    /// locked because sends can come from the MIDI thread while the refresh
    /// runs on main.
    ///
    /// Three transports, not two: **virtual** endpoints (no driver owner —
    /// other apps' input ports, and the app's OWN receivers like the iPad's
    /// "Tarabdaar Scale" scale-sync destination) are always targeted and never
    /// count as a link — the wired/Bluetooth preference and the transport
    /// indicators consider only driver-backed endpoints. Counting virtuals
    /// as wired once made the iPad's own scale receiver suppress the
    /// Bluetooth link entirely (lit USB icon, no sound).
    private struct Destination {
        enum Transport { case virtualEndpoint, wired, bluetooth }
        let ref: MIDIEndpointRef
        let transport: Transport
    }
    private var destinations: [Destination] = []
    private let destinationsLock = NSLock()

    @Published public var isActive = false
    @Published public var statusMessage: String = "Not started"
    @Published public var destinationCount: Int = 0
    @Published public var sourceCount: Int = 0
    /// Per-transport split of `destinationCount`, for the iPad's toolbar
    /// transport indicators. Wired counts driver-backed non-Bluetooth
    /// destinations (the USB/IDAM bridge); Bluetooth counts BLE-MIDI
    /// session endpoints. Virtual endpoints count toward neither — they
    /// are on-device receivers, not a link to the Mac. The active
    /// transport follows from the wired-first rule: wired when
    /// `wiredDestinationCount > 0`, else Bluetooth.
    @Published public var wiredDestinationCount: Int = 0
    @Published public var bluetoothDestinationCount: Int = 0

    /// Fires on every emitted MIDI message, regardless of `publishToCoreMIDI`.
    /// Bytes are 2 (Channel Pressure) or 3 (everything else Tarabdaar sends).
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

        var status = MIDIClientCreateWithBlock("Tarabdaar" as CFString, &midiClient) { [weak self] _ in
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
            "Tarabdaar Output" as CFString,
            ._1_0,
            &midiSource
        )

        if status != noErr {
            // Non-fatal — output port can still work
            statusMessage = "Source error: \(Self.midiErrorString(status))"
        }

        // Create output port (for sending to external destinations like Mac over USB)
        status = MIDIOutputPortCreate(midiClient, "Tarabdaar Port" as CFString, &midiOutputPort)

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
        let snapshot = (0..<MIDIGetNumberOfDestinations()).map { i -> Destination in
            let dest = MIDIGetDestination(i)
            return Destination(ref: dest, transport: Self.transport(of: dest))
        }
        destinationsLock.lock()
        destinations = snapshot
        destinationsLock.unlock()

        destinationCount = snapshot.count
        bluetoothDestinationCount = snapshot.filter { $0.transport == .bluetooth }.count
        wiredDestinationCount = snapshot.filter { $0.transport == .wired }.count
        sourceCount = MIDIGetNumberOfSources()
        if isActive {
            // Name the chosen transport only when Bluetooth is in the mix —
            // the plain-USB reading stays as it always was.
            let transport = bluetoothDestinationCount > 0
                ? (wiredDestinationCount > 0 ? ", via USB" : ", via Bluetooth") : ""
            statusMessage = "Active (\(destinationCount) dest, \(sourceCount) src\(transport))"
        }
    }

    private func currentDestinations() -> [Destination] {
        destinationsLock.lock()
        defer { destinationsLock.unlock() }
        return destinations
    }

    /// The transport preference: virtual (on-device) destinations are always
    /// targeted — they're local, free, and may be the app's own receivers —
    /// while between the real links to the outside world, wired wins and
    /// Bluetooth is used only when no wired link exists.
    private static func preferredTargets(_ candidates: [Destination]) -> [MIDIEndpointRef] {
        let wired = candidates.filter { $0.transport == .wired }
        let link = wired.isEmpty
            ? candidates.filter { $0.transport == .bluetooth } : wired
        let virtuals = candidates.filter { $0.transport == .virtualEndpoint }
        return (virtuals + link).map(\.ref)
    }

    /// Transport classification via `kMIDIPropertyDriverOwner` at endpoint,
    /// entity and device level: Apple's Bluetooth MIDI driver → `.bluetooth`
    /// (measured: `com.apple.AppleMIDIBluetoothDriver`; "ble" covers a
    /// possible AppleMIDIBLEDriver spelling); any other driver (USB/IDAM
    /// bridge, IAC, network) → `.wired`; no driver owner at all → a virtual
    /// endpoint published by an app.
    private static func transport(of endpoint: MIDIEndpointRef) -> Destination.Transport {
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        var device = MIDIDeviceRef()
        if entity != 0 { MIDIEntityGetDevice(entity, &device) }
        var sawDriver = false
        for obj in [endpoint, entity, device] where obj != 0 {
            var cf: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(obj, kMIDIPropertyDriverOwner, &cf) == noErr,
               let owner = cf?.takeRetainedValue() as String?, !owner.isEmpty {
                sawDriver = true
                if owner.localizedCaseInsensitiveContains("bluetooth")
                    || owner.localizedCaseInsensitiveContains("ble") {
                    return .bluetooth
                }
            }
        }
        return sawDriver ? .wired : .virtualEndpoint
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
    /// every edit. `fallbackToAll` keeps the match-nothing → send-to-all
    /// safety net for the rare, must-arrive syncs; pass `false` for
    /// high-rate display streams, which should just drop when the iPad
    /// is absent.
    public func sendSysEx(_ bytes: [UInt8], toDestinationsMatching match: String? = nil,
                          fallbackToAll: Bool = true) {
        guard isActive, midiOutputPort != 0, !bytes.isEmpty else { return }

        // Pick the targets: apply the name filter across ALL destinations
        // first, then the wired-first rule within the matches — so when the
        // iPad is reachable over both USB and Bluetooth only the cable
        // carries the blob, and a Bluetooth-only iPad still gets it even if
        // unrelated wired destinations (IAC, other gear) exist.
        //
        // Bluetooth destinations BYPASS the name filter: no app or device
        // name crosses a BLE-MIDI link — the Mac sees only a generic
        // session endpoint (measured: display='iOS Bluetooth'), so a name
        // match can never identify the peer. The filter exists to keep
        // blobs off unrelated USB gear; a BLE-MIDI session in this rig is
        // only ever the iPad link, so transport IS the identification.
        //
        // If a name filter is given but matches nothing (e.g. the bridged
        // iPad endpoint shows up under a different display name than
        // expected), fall back to every destination so the sync isn't
        // silently blocked.
        let all = currentDestinations()
        var matched: [Destination] = []
        for dest in all {
            if let match, dest.transport != .bluetooth {
                var cfName: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(dest.ref, kMIDIPropertyDisplayName, &cfName)
                let name = cfName?.takeRetainedValue() as String? ?? ""
                if !name.localizedCaseInsensitiveContains(match) { continue }
            }
            matched.append(dest)
        }
        if matched.isEmpty, match != nil, fallbackToAll {
            matched = all
        }
        let targets = Self.preferredTargets(matched)
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

    /// TarabLink tunnel send (iPad side): the frame goes ONLY to the real
    /// link — wired-first, BLE otherwise — never to virtual endpoints
    /// (the device's own "Tarabdaar Scale" receiver would just loop the
    /// stream back into its own input port).
    public func sendSysExToLink(_ bytes: [UInt8]) {
        guard isActive, midiOutputPort != 0, !bytes.isEmpty else { return }
        let real = currentDestinations().filter { $0.transport != .virtualEndpoint }
        let targets = Self.preferredTargets(real)
        guard !targets.isEmpty else { return }
        let bufSize = bytes.count + 128
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufSize, alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(listPtr)
        packet = MIDIPacketListAdd(listPtr, bufSize, packet, 0, bytes.count, bytes)
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

        // 2. Send directly to external destinations (Mac over USB, or over
        // BLE-MIDI only when no wired destination exists — wired-first).
        if midiOutputPort != 0 {
            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)

            for dest in Self.preferredTargets(currentDestinations()) {
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
