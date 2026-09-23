import TarabdaarCore
import SwiftUI

/// One reading of the link for every status surface (top-bar pill, Live
/// tab, Setup panel): the bearer the pad's frames arrive on — USB or
/// Bluetooth, never both — and the handshake state over it.
struct LinkReadout {
    enum State { case off, waiting, up, stale, down }
    let state: State
    let transport: MIDITransport?
    let peerName: String?
    let rttMs: Double?

    init(midi: MIDIEngine, status: TarabLink.Status) {
        transport = midi.linkPeerTransport
        peerName = midi.linkPeerName
        rttMs = status.rttMs
        if !midi.isActive { state = .off }
        else if status.isStale { state = .stale }
        else if status.isUp { state = .up }
        else if midi.linkPeerTransport == nil { state = .waiting }
        else { state = .down }
    }

    var color: Color {
        switch state {
        case .off, .down: return .red
        case .waiting: return .yellow
        case .stale: return .orange
        case .up: return .green
        }
    }

    var symbol: String { transport?.symbolName ?? "cable.connector.slash" }

    private var bearer: String { transport?.label ?? "Link" }

    /// The pill's text.
    var short: String {
        switch state {
        case .off: return "Link off"
        case .waiting: return "No iPad"
        case .up: return rttMs.map { String(format: "%@ %.1f ms", bearer, $0) } ?? bearer
        case .stale: return "\(bearer) · stale"
        case .down: return "\(bearer) · version mismatch"
        }
    }

    /// The Live tab's headline.
    var headline: String {
        switch state {
        case .off: return "MIDI not started"
        case .waiting: return "Waiting for the iPad"
        case .up: return "iPad over \(bearer)"
        case .stale: return "iPad over \(bearer) — stale"
        case .down: return "iPad over \(bearer) — TLP version mismatch"
        }
    }

    var detail: String {
        switch state {
        case .off: return "Start MIDI on the Setup tab."
        case .waiting: return "Plug the iPad in over USB, or connect its Bluetooth MIDI session."
        case .up: return rttMs.map { String(format: "round trip %.1f ms", $0) } ?? "handshake done"
        case .stale: return "no frames for 1.5 s — the pad is asleep or the bearer dropped"
        case .down: return "frames arrive but the HELLO versions do not overlap — install both apps together"
        }
    }
}

/// Link status panel: the bearer carrying the link (USB or Bluetooth), the
/// handshake over it, the outbound bearers the wired-first rule sees, and
/// every visible MIDI source with the TLP frames it has delivered — so the
/// one-bearer-at-a-time rule can be read off the counters.
struct ConnectionStatusView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    var body: some View {
        let readout = LinkReadout(midi: midi, status: controller.linkStatus)
        VStack(alignment: .leading, spacing: 12) {
            Text("LINK")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            linkPanel(readout)
            bearersPanel
            sourcesPanel
        }
        .padding(20)
    }

    private func linkPanel(_ r: LinkReadout) -> some View {
        Panel(title: "iPad link") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: r.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(r.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.headline).font(.system(.body).weight(.semibold))
                        Text(r.detail).font(.padCaption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Bearer", value: r.transport?.label ?? "—")
                LabeledContent("Endpoint", value: r.peerName ?? "—")
                LabeledContent("Handshake",
                               value: controller.linkStatus.isUp
                                   ? (controller.linkStatus.isStale ? "up, stale" : "up") : "down")
                LabeledContent("Round trip",
                               value: r.rttMs.map { String(format: "%.1f ms", $0) } ?? "—")
                LabeledContent("Peer TLP version",
                               value: controller.linkStatus.remoteVersionMax.map { "\($0)" } ?? "—")
            }
            .font(.system(.body))
        }
    }

    /// The wired-first rule's view of the outbound side: which bearers
    /// exist and which one the pump would pick before the peer is learned.
    private var bearersPanel: some View {
        Panel(title: "Bearers") {
            VStack(alignment: .leading, spacing: 8) {
                bearerRow(.wired, count: midi.wiredDestinationCount)
                bearerRow(.bluetooth, count: midi.bluetoothDestinationCount)
                LabeledContent("Sending on",
                               value: (midi.linkPeerTransport ?? midi.linkTransport)?.label ?? "—")
                Text("USB carries the link whenever the cable is in; Bluetooth only when it is not. Frames never leave on both.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
            }
            .font(.system(.body))
        }
    }

    private func bearerRow(_ t: MIDITransport, count: Int) -> some View {
        let carrying = midi.linkPeerTransport == t
        return HStack(spacing: 8) {
            Image(systemName: t.symbolName)
                .foregroundStyle(carrying ? .green : (count > 0 ? .primary : .secondary))
                .frame(width: 18)
            Text(t.label)
            Spacer()
            Text(count == 0 ? "absent"
                 : carrying ? "carrying the link" : "present, idle")
                .foregroundStyle(carrying ? .green : .secondary)
        }
    }

    /// Every source with its bearer and the TLP frames it has delivered,
    /// polled once a second (the counters live on the MIDI thread).
    private var sourcesPanel: some View {
        Panel(title: "MIDI sources") {
            if midi.sourceCount == 0 {
                Text("No MIDI sources. Plug the iPad in over USB or connect its Bluetooth MIDI session.")
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let activity = Dictionary(
                        controller.midiIn.sourceActivity().map { ($0.source, $0) },
                        uniquingKeysWith: { a, _ in a })
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(MIDIEngine.sources()) { src in
                            sourceRow(src, activity: activity[src.ref], now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func sourceRow(_ src: MIDIEndpointInfo,
                           activity: MIDIInput.SourceActivity?,
                           now: Date) -> some View {
        let frames = activity?.tlpFrames ?? 0
        let live = activity?.lastTLPAt.map { now.timeIntervalSince($0) < 2 } ?? false
        return HStack(spacing: 8) {
            Image(systemName: src.transport.symbolName)
                .foregroundStyle(live ? .green : .secondary)
                .frame(width: 18)
            Text(src.name).font(.system(.body))
            Text(src.driver).font(.padCaption).foregroundStyle(.secondary)
            Spacer()
            Text(frames == 0 ? "no TLP" : "\(frames) TLP frames")
                .font(.padCaption.monospacedDigit())
                .foregroundStyle(live ? .green : .secondary)
        }
    }
}
