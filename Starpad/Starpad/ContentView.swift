import StarpadCore
import SwiftUI

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var midi: MIDIEngine
    @StateObject private var noteManager = NoteManager()
    /// The Fret Pad is the iPad's sole playing surface. It emits MPE
    /// through the shared `midi` engine (real USB-MIDI) and borrows
    /// `noteManager` as its tilt sampler (raw tilt report).
    @StateObject private var pad: PitchPadEngine
    /// Receives the scale + fret arrangement pushed from StarpadMac over SysEx.
    /// StarpadMac edits scales; this iPad performs them.
    @StateObject private var scaleSync = ScaleSyncReceiver()
    @State private var showCalibration = false

    init() {
        // One MIDIEngine, shared by the pad (MPE out) and NoteManager
        // (kept alive only as the tilt/mapping host). StateObject's
        // autoclosures capture the same instance and run once.
        let sharedMidi = MIDIEngine()
        _midi = StateObject(wrappedValue: sharedMidi)
        _pad = StateObject(wrappedValue: PitchPadEngine(midi: sharedMidi))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showCalibration {
                CalibrationView(motion: motion) { calibration in
                    motion.calibration = calibration
                    withAnimation { showCalibration = false }
                }
            } else {
                playingSurface
            }
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
            pad.expression = noteManager
            midi.start()

            // Scale sync: open on the last state pushed from the Mac (scale
            // + tonic + margin, if any), then listen for live pushes over
            // USB-MIDI SysEx.
            if let synced = SyncedScaleStore.load() {
                pad.applySyncedState(synced)
            }
            scaleSync.onState = { [weak pad] state in pad?.applySyncedState(state) }
            scaleSync.start()

            if !motion.isCalibrated {
                showCalibration = true
            }
        }
    }

    /// The Fret Pad is the iPad's only playing surface. The Mac always pushes
    /// the `.fretPad` layout; a never-synced iPad falls back to the default
    /// fret layout built from the synced scale so the surface is playable.
    @ViewBuilder
    private var playingSurface: some View {
        let onRecalibrate = { showCalibration = true }
        FretPadViewIOS(engine: pad, noteManager: noteManager, scaleSync: scaleSync,
                       arrangement: scaleSync.fretArrangement
                           ?? FretArrangement.defaultArrangement(
                               degrees: scaleDegrees(from: pad.scale)),
                       onRecalibrate: onRecalibrate)
    }
}

#Preview {
    ContentView()
}
