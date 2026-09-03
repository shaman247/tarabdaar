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
    private let fingerAccel: FingerAccelSampler

    /// Holds the destination-count subscription OUTSIDE the view tree.
    /// A `.onReceive(midi.$destinationCount…)` modifier re-subscribes on
    /// every body evaluation, and @Published REPLAYS its value to each new
    /// subscriber — so every re-render kicked the link, every kick's
    /// resync made the Mac push, every push re-rendered this view…
    /// the staccato feedback loop's engine. One durable sink
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
        // Display-only finger-accel feed for the toolbar scope (the
        // shared `FingerAccelTracker` law; the Mac evaluates its own
        // instance for the `.fingerAccel` bindings).
        self.fingerAccel = FingerAccelSampler(state: state)
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
            link.onJoyConState = { [weak scaleSync, weak pad] s in
                // Frame u8 (centre 128) → the −1…+1 display convention.
                func ax(_ b: UInt8) -> Double { Double(b) / 255.0 * 2.0 - 1.0 }
                // Volume readout (TLP v9): into the polled history, NOT
                // the published display — level motion must not
                // re-render the toolbar (the scope polls at UI rate).
                scaleSync?.volumeHistory.record(
                    voice: TLPVolume.value01(s.volVoice),
                    taraf: TLPVolume.value01(s.volTaraf))
                scaleSync?.applyJoyCon(JoyConTiltDisplay(
                    stickX: ax(s.stickX),
                    stickY: ax(s.stickY),
                    wrist1: ax(s.wrist1),
                    wrist2: ax(s.wrist2),
                    stickLive: s.flags & TLPJoyConState.flagStickLive != 0,
                    bodyLive: s.flags & TLPJoyConState.flagBodyLive != 0,
                    connected: s.flags & TLPJoyConState.flagConnected != 0,
                    wrist3: ax(s.wrist3),
                    arm1: ax(s.arm1),
                    arm2: ax(s.arm2),
                    arm3: ax(s.arm3),
                    armLive: s.flags & TLPJoyConState.flagArmLive != 0,
                    strikeWindowS: s.strikeWin == 0
                        ? 2.0 : Double(s.strikeWin) * 0.05,
                    // TLP v10: the Mac's live ctl_fret_warp — the fret
                    // field resolves touch pitch through it.
                    fieldWarp: Double(s.fieldWarp) / 255.0,
                    // TLP v11: the playing-range octave shift (i8).
                    octaveShift: Int(Int8(bitPattern: s.octave))))
                // The shift acts at the engine's outbound-pitch point
                // (main-thread model, like applyJoyCon's publish).
                let oct = Int(Int8(bitPattern: s.octave))
                DispatchQueue.main.async {
                    guard let pad, pad.octaveShift != oct else { return }
                    pad.octaveShift = oct
                }
            }
            // Link gone (down or stale) → the Mac's display axes are
            // history: dim every square (the arm pane falls back to the
            // iPad's own raw attitude) and un-hide the drone buttons.
            link.onStatus = { [weak scaleSync, weak pad] status in
                if !status.isUp || status.isStale {
                    scaleSync?.applyJoyCon(.idle)
                    // The Mac's levels are history too — drop the scope
                    // to silence instead of freezing at the last value.
                    scaleSync?.volumeHistory.record(voice: 0, taraf: 0)
                    // And the octave shift with them — .idle shows 0, so
                    // the engine must agree (a re-link resends the truth
                    // via the forced state push).
                    DispatchQueue.main.async {
                        guard let pad, pad.octaveShift != 0 else { return }
                        pad.octaveShift = 0
                    }
                }
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
                       motion: motion,
                       fingerAccel: fingerAccel)
    }
}

#Preview {
    ContentView()
}
