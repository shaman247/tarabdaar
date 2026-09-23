import CoreMIDI
import Foundation

/// Distinct host-clock deadlines keep USB/IDAM from dropping SysEx bursts.
struct MIDISysExSchedule {
    static let spacingTicks: MIDITimeStamp = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 2_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
    }()

    private var last: MIDITimeStamp?

    mutating func reserve(now: MIDITimeStamp) -> MIDITimeStamp {
        let timestamp = last.map { max(now, $0 + Self.spacingTicks) } ?? now
        last = timestamp
        return timestamp
    }
}

/// How a CoreMIDI endpoint reaches the outside world — the link's bearer,
/// classified by `kMIDIPropertyDriverOwner` at endpoint, entity and device
/// level.
public enum MIDITransport: Equatable {
    /// No driver owner: an endpoint published by an app (other apps' ports,
    /// the iPad's own "Tarabdaar Scale" receiver). Never a link.
    case virtualEndpoint
    /// Any driver but Apple's Bluetooth MIDI driver — the USB/IDAM bridge to
    /// the peer (IAC and network endpoints classify here too; the wired-first
    /// rule counts them, the learned peer never picks them).
    case wired
    /// Apple's Bluetooth MIDI driver: a BLE-MIDI session.
    case bluetooth

    /// The bearer's name as the UI shows it.
    public var label: String {
        switch self {
        case .virtualEndpoint: return "virtual"
        case .wired: return "USB"
        case .bluetooth: return "Bluetooth"
        }
    }

    /// SF Symbol for the bearer.
    public var symbolName: String {
        switch self {
        case .virtualEndpoint: return "app.connected.to.app.below.fill"
        case .wired: return "cable.connector"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Apple's Bluetooth MIDI driver → `.bluetooth` (measured:
    /// `com.apple.AppleMIDIBluetoothDriver`; "ble" covers a possible
    /// AppleMIDIBLEDriver spelling); any other driver (USB/IDAM bridge, IAC,
    /// network) → `.wired`; no driver owner at all → a virtual endpoint.
    public static func classify(_ endpoint: MIDIEndpointRef) -> MIDITransport {
        var sawDriver = false
        for obj in MIDIEngine.objectChain(of: endpoint) {
            if let owner = MIDIEngine.driverOwner(of: obj) {
                sawDriver = true
                if owner.localizedCaseInsensitiveContains("bluetooth")
                    || owner.localizedCaseInsensitiveContains("ble") {
                    return .bluetooth
                }
            }
        }
        return sawDriver ? .wired : .virtualEndpoint
    }
}

/// One visible endpoint, for the status panels.
public struct MIDIEndpointInfo: Identifiable {
    public let ref: MIDIEndpointRef
    public let name: String
    public let transport: MIDITransport
    /// A short reading of the driver (`USB`, `Bluetooth`, `IAC`, `Network`,
    /// the raw owner otherwise, `virtual` for none).
    public let driver: String
    public var id: MIDIEndpointRef { ref }
}

/// The TLP tunnel's byte pump: a CoreMIDI client and output port that send
/// SysEx to external destinations, with a **wired-first transport
/// preference**: Bluetooth (BLE-MIDI) destinations are used only when no
/// wired destination exists, so USB carries the traffic when the cable is
/// in and Bluetooth takes over when it's pulled — never both at once (both
/// live would deliver every frame twice). The CoreMIDI setup-change
/// notification refreshes the snapshot, so plug/unplug switches
/// automatically. SysEx is the ONLY thing this sends — there is no MIDI
/// note vocabulary.
///
/// The host adds one rule on top: it **learns its peer from the receive
/// side** (`noteLinkFrame(from:)`) — the destination on the same CoreMIDI
/// entity as the source the pad's frames arrive on — and replies there
/// alone. The iPad's wired-first choice therefore decides the bearer for
/// BOTH directions, and no endpoint name is needed to identify the iPad.
public class MIDIEngine: ObservableObject {
    private var midiClient = MIDIClientRef()
    private var midiOutputPort = MIDIPortRef()

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
        let ref: MIDIEndpointRef
        let transport: MIDITransport
    }
    private var destinations: [Destination] = []
    /// The learned peer (host role): the destination answering the source
    /// the pad's frames arrive on, and that source. Under `destinationsLock`.
    private var linkPeer: Destination?
    private var linkPeerSource = MIDIEndpointRef()
    private let destinationsLock = NSLock()
    private let sendLock = NSLock()
    private var sendSchedule = MIDISysExSchedule()

    @Published public var isActive = false
    @Published public var statusMessage: String = "Not started"
    @Published public var destinationCount: Int = 0
    @Published public var sourceCount: Int = 0
    /// Per-transport split of `destinationCount`. Wired counts driver-backed
    /// non-Bluetooth destinations (the USB/IDAM bridge); Bluetooth counts
    /// BLE-MIDI session endpoints. Virtual endpoints count toward neither —
    /// they are on-device receivers, not a link to the Mac.
    @Published public var wiredDestinationCount: Int = 0
    @Published public var bluetoothDestinationCount: Int = 0
    /// The bearer the wired-first rule selects for the tunnel: `.wired`
    /// whenever a wired destination exists, else `.bluetooth`, nil with no
    /// real destination at all. The pad's indicators read this; the host's
    /// UI prefers the learned peer below.
    @Published public private(set) var linkTransport: MIDITransport?
    /// The learned peer's bearer and endpoint name (host role), nil until the
    /// pad's first frame arrives or after its endpoint vanished.
    @Published public private(set) var linkPeerTransport: MIDITransport?
    @Published public private(set) var linkPeerName: String?

    public init() {}

    /// Call this after the app is fully launched (e.g., from onAppear)
    public func start() {
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

        // Create output port (for sending to external destinations like Mac over USB)
        status = MIDIOutputPortCreate(midiClient, "Tarabdaar Port" as CFString, &midiOutputPort)

        guard status == noErr else {
            statusMessage = "Port error: \(Self.midiErrorString(status))"
            return false
        }

        isActive = true
        refreshEndpointCounts()
        return true
    }

    public func refreshEndpointCounts() {
        let snapshot = (0..<MIDIGetNumberOfDestinations()).map { i -> Destination in
            let dest = MIDIGetDestination(i)
            return Destination(ref: dest, transport: MIDITransport.classify(dest))
        }
        destinationsLock.lock()
        destinations = snapshot
        // A peer whose endpoint left the setup (cable pulled, session
        // closed) is forgotten; the pad's next frame re-learns it wherever
        // it now arrives.
        var peerDropped = false
        if let peer = linkPeer, !snapshot.contains(where: { $0.ref == peer.ref }) {
            linkPeer = nil
            linkPeerSource = 0
            peerDropped = true
        }
        destinationsLock.unlock()
        if peerDropped {
            linkPeerTransport = nil
            linkPeerName = nil
        }

        destinationCount = snapshot.count
        bluetoothDestinationCount = snapshot.filter { $0.transport == .bluetooth }.count
        wiredDestinationCount = snapshot.filter { $0.transport == .wired }.count
        linkTransport = wiredDestinationCount > 0 ? .wired
            : (bluetoothDestinationCount > 0 ? .bluetooth : nil)
        sourceCount = MIDIGetNumberOfSources()
        if isActive {
            statusMessage = "Active (\(destinationCount) dest, \(sourceCount) src)"
        }
    }

    private func currentDestinations() -> [Destination] {
        destinationsLock.lock()
        defer { destinationsLock.unlock() }
        return destinations
    }

    /// Host role, from the receive side: a TLP frame from the pad arrived on
    /// `source`. The first frame from a new source learns the peer — the
    /// destination on that source's entity (the USB device or the BLE-MIDI
    /// session) — so replies go back on the bearer the pad is using. Safe
    /// to call per frame from the CoreMIDI thread: an unchanged source is
    /// one lock take and a compare.
    public func noteLinkFrame(from source: MIDIEndpointRef) {
        destinationsLock.lock()
        if source == linkPeerSource { destinationsLock.unlock(); return }
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(source, &entity)
        var peer: Destination?
        if entity != 0, MIDIEntityGetNumberOfDestinations(entity) > 0 {
            let dest = MIDIEntityGetDestination(entity, 0)
            peer = Destination(ref: dest, transport: MIDITransport.classify(dest))
        }
        linkPeer = peer
        linkPeerSource = peer == nil ? 0 : source
        destinationsLock.unlock()
        let name = peer.map { Self.displayName(of: $0.ref) }
        let transport = peer?.transport
        DispatchQueue.main.async {
            self.linkPeerTransport = transport
            self.linkPeerName = name
        }
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

    // MARK: - Endpoint properties

    /// Endpoint, its entity and its device — the objects a driver owner can
    /// sit on.
    fileprivate static func objectChain(of endpoint: MIDIEndpointRef) -> [MIDIObjectRef] {
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        var device = MIDIDeviceRef()
        if entity != 0 { MIDIEntityGetDevice(entity, &device) }
        return [endpoint, entity, device].filter { $0 != 0 }
    }

    fileprivate static func driverOwner(of obj: MIDIObjectRef) -> String? {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, kMIDIPropertyDriverOwner, &cf) == noErr,
              let owner = cf?.takeRetainedValue() as String?, !owner.isEmpty
        else { return nil }
        return owner
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf)
        return cf?.takeRetainedValue() as String? ?? ""
    }

    private static func info(of endpoint: MIDIEndpointRef, fallback: String) -> MIDIEndpointInfo {
        let owner = objectChain(of: endpoint).lazy.compactMap(driverOwner(of:)).first ?? ""
        let driver: String
        if owner.isEmpty { driver = "virtual" }
        else if owner.localizedCaseInsensitiveContains("bluetooth")
                    || owner.localizedCaseInsensitiveContains("ble") { driver = "Bluetooth" }
        else if owner.localizedCaseInsensitiveContains("usb") { driver = "USB" }
        else if owner.localizedCaseInsensitiveContains("iac") { driver = "IAC" }
        else if owner.localizedCaseInsensitiveContains("network") { driver = "Network" }
        else { driver = owner }
        let name = displayName(of: endpoint)
        return MIDIEndpointInfo(ref: endpoint, name: name.isEmpty ? fallback : name,
                                transport: MIDITransport.classify(endpoint), driver: driver)
    }

    /// Every visible source with its bearer, for the status panels.
    public static func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).map { i in
            info(of: MIDIGetSource(i), fallback: "Source \(i)")
        }
    }

    // MARK: - Sending

    /// Send a complete SysEx byte run (including the framing `0xF0…0xF7`)
    /// to external destinations. Destination-only.
    ///
    /// `toDestinationsMatching` (if set) restricts the send to
    /// destinations whose display name contains that substring, so a
    /// multi-hundred-byte blob isn't blasted at other gear on every edit.
    /// `fallbackToAll` keeps the match-nothing → send-to-all safety net for
    /// the rare, must-arrive syncs; pass `false` for high-rate display
    /// streams, which should just drop when the iPad is absent.
    public func sendSysEx(_ bytes: [UInt8],
                          toDestinationsMatching match: String? = nil,
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
            if let match, dest.transport != .bluetooth,
               !Self.displayName(of: dest.ref).localizedCaseInsensitiveContains(match) {
                continue
            }
            matched.append(dest)
        }
        if matched.isEmpty, match != nil, fallbackToAll {
            matched = all
        }
        send(bytes, to: Self.preferredTargets(matched))
    }

    /// TarabLink tunnel send (iPad side): the frame goes ONLY to the real
    /// link — wired-first, BLE otherwise — never to virtual endpoints
    /// (the device's own "Tarabdaar Scale" receiver would just loop the
    /// stream back into its own input port).
    public func sendSysExToLink(_ bytes: [UInt8]) {
        guard isActive, midiOutputPort != 0, !bytes.isEmpty else { return }
        let real = currentDestinations().filter { $0.transport != .virtualEndpoint }
        send(bytes, to: Self.preferredTargets(real))
    }

    /// TarabLink tunnel send (Mac side): to the learned peer alone once the
    /// pad's frames have shown where it is. Before that (or after its
    /// endpoint vanished) the name-filtered wired-first send stands in —
    /// events falling back to every destination so a hello always lands,
    /// state frames simply dropping.
    public func sendSysExToLinkPeer(_ bytes: [UInt8], isEvent: Bool) {
        destinationsLock.lock()
        let peer = linkPeer
        destinationsLock.unlock()
        if let peer {
            guard isActive, midiOutputPort != 0, !bytes.isEmpty else { return }
            send(bytes, to: [peer.ref])
        } else {
            sendSysEx(bytes, toDestinationsMatching: "iPad", fallbackToAll: isEvent)
        }
    }

    /// One packet list, one `MIDISend` per target. A default
    /// `MIDIPacketList` struct is 256 bytes; the payload may be larger, so
    /// the buffer is sized to hold the full byte run in one packet.
    private func send(_ bytes: [UInt8], to targets: [MIDIEndpointRef]) {
        guard !targets.isEmpty else { return }
        // Keep reservation and submission ordered even with concurrent senders.
        // Timestamp 0 lets the USB driver merge a burst and lose later SysEx;
        // reserve 2 ms between envelopes without sleeping on the link queue.
        sendLock.lock()
        defer { sendLock.unlock() }
        let bufSize = bytes.count + 128
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufSize, alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(listPtr)
        let timestamp = sendSchedule.reserve(now: mach_absolute_time())
        packet = MIDIPacketListAdd(listPtr, bufSize, packet, timestamp, bytes.count, bytes)
        guard packet != nil else { return }
        for dest in targets {
            let status = MIDISend(midiOutputPort, dest, listPtr)
            if status != noErr {
                NSLog("Tarabdaar: SysEx send failed (%d)", status)
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
        if midiOutputPort != 0 { MIDIPortDispose(midiOutputPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }
}
