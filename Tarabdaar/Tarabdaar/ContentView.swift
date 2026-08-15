import Combine
import TarabdaarCore
import SwiftUI

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var midi: MIDIEngine
    @StateObject private var noteManager = NoteManager()
    /// The Fret Pad is the iPad's sole playing surface. It writes into the
    /// shared `OutboundPlayState`; `TarabLink`'s 120 Hz off-main sender
    /// serializes state frames onto the CoreMIDI tunnel (USB session when
    /// wired, the BLE-MIDI session otherwise). `noteManager` stays as the
    /// 60 Hz tilt sampler, writing tilt into the same state.
    @StateObject private var pad: PitchPadEngine
    /// Receives the Mac's pushes. The CoreMIDI plumbing (input port on all
    /// sources + the "Tarabdaar Scale" virtual destination) reassembles
    /// SysEx; TLP tunnel messages route to `link`, which decodes and calls
    /// back into this receiver's appliers (same publishers + persistence).
    @StateObject private var scaleSync = ScaleSyncReceiver()

    /// The link + the outbound snapshot it paces. Plain lets — all state
    /// they publish reaches SwiftUI through `scaleSync`.
    private let link: TarabLink
    private let playState: OutboundPlayState

    /// Holds the destination-count subscription OUTSIDE the view tree.
    /// A `.onReceive(midi.$destinationCount…)` modifier re-subscribes on
    /// every body evaluation, and @Published REPLAYS its value to each new
    /// subscriber — so every re-render kicked the link, every kick's
    /// resync made the Mac push, every push re-rendered this view…
    /// the 2026-08-14 staccato feedback loop's engine. One durable sink
    /// with `dropFirst()` (skip the subscription replay) instead.
    private final class SubscriptionBox { var c: AnyCancellable? }
    @State private var subscriptions = SubscriptionBox()

    init() {
        // One MIDIEngine, shared by the link tunnel (SysEx out) and
        // NoteManager (kept alive for audition scripts). StateObject's
        // autoclosures capture the same instance and run once.
        let sharedMidi = MIDIEngine()
        let state = OutboundPlayState()
        _midi = StateObject(wrappedValue: sharedMidi)
        _pad = StateObject(wrappedValue: PitchPadEngine(state: state))
        self.playState = state
        let link = TarabLink(role: .pad)
        link.attach(playState: state)
        self.link = link
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            playingSurface
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            // NoteManager runs purely as the tilt sampler; its voice/glide
            // MIDI paths stay idle because the pad never activates its
            // pitchChannels.
            noteManager.motionSource = motion
            // THE tilt wire: NoteManager's 60 Hz tick writes the raw tilt
            // into the outbound state (16-bit, atomic with pitch in the
            // state frame). Without this assignment the writes no-op
            // silently — same trap as the old midiEngine wire.
            noteManager.playState = playState
            noteManager.midiEngine = midi     // audition scripts only
            midi.start()

            // Scale sync: open on the last state pushed from the Mac (scale
            // + tonic + margin, if any), then listen for live pushes.
            if let synced = SyncedScaleStore.load() {
                pad.applySyncedState(synced)
            }
            scaleSync.onState = { [weak pad] state in pad?.applySyncedState(state) }

            // TarabLink wiring: outbound frames ride the CoreMIDI tunnel
            // to the real link only (wired-first, never the local virtual
            // loopback); inbound TLP SysEx comes back through scaleSync's
            // reassembler; decoded events land in scaleSync's appliers.
            link.sendRaw = { [weak midi] bytes, _ in
                midi?.sendSysExToLink(bytes)
            }
            scaleSync.onSysEx = { [weak link] bytes in
                link?.receivedSysEx(bytes)
            }
            link.onEvent = { [weak scaleSync] event in
                switch event {
                case .scaleState(let blob):
                    if let state = PitchScaleSysEx.decodeBlob(blob) {
                        scaleSync?.applyState(state)
                    }
                case .fretArrangement(let blob):
                    if let a = FretArrangementSysEx.decodeBlob(blob) {
                        scaleSync?.applyArrangement(a)
                    }
                default:
                    break
                }
            }
            link.onJoyConState = { [weak scaleSync] s in
                scaleSync?.applyJoyCon(JoyConTiltDisplay(
                    stickX: Double(s.stickX) / 255.0,
                    stickY: Double(s.stickY) / 255.0,
                    wrist1: Double(s.wrist1) / 255.0,
                    wrist2: Double(s.wrist2) / 255.0,
                    stickLive: s.flags & TLPJoyConState.flagStickLive != 0,
                    bodyLive: s.flags & TLPJoyConState.flagBodyLive != 0,
                    connected: s.flags & TLPJoyConState.flagConnected != 0))
            }
            pad.onPanic = { [weak link] in link?.send(event: .panic) }
            // A transport appearing (cable plugged, BLE session up) →
            // re-greet + ask the Mac for a fresh sync.
            scaleSync.start()
            link.start()
            // Cable plugged / BLE session up or down: re-greet + resync.
            // Durable Combine sink, NOT .onReceive — see SubscriptionBox.
            subscriptions.c = midi.$destinationCount
                .dropFirst()
                .removeDuplicates()
                .sink { [weak link] _ in link?.kick() }
        }
    }

    /// The Fret Pad is the iPad's only playing surface. The Mac always pushes
    /// the `.fretPad` layout; a never-synced iPad falls back to the default
    /// fret layout built from the synced scale so the surface is playable.
    @ViewBuilder
    private var playingSurface: some View {
        FretPadViewIOS(engine: pad, noteManager: noteManager, scaleSync: scaleSync,
                       midi: midi,
                       arrangement: scaleSync.fretArrangement
                           ?? FretArrangement.keyboardArrangement(
                               degrees: scaleDegrees(from: pad.scale)),
                       motion: motion)
    }
}

#Preview {
    ContentView()
}
