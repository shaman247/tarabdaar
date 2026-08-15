import Foundation
import QuartzCore
import TarabdaarCore

/// Mac-side iPad simulator. Owns an iPad-style `NoteManager` plus a
/// `MockMotionSource`, and routes the resulting MPE bytes directly to
/// `AudioEngine.sendHostedMIDI(...)` via the `MIDIEngine.onLocalEvent`
/// in-process callback. CC messages are also delivered to
/// `AppController.handleIncomingCC` so Mac-side CC mappings (sym pool,
/// FX) work identically to the real iPad-over-USB path.
///
/// This intentionally bypasses the Mac's CoreMIDI `MIDIInput`: looping
/// through CoreMIDI would either double-trigger (if MIDIInput connects
/// to our own virtual source) or require runtime route-skipping logic.
/// A direct in-process path keeps the simulator surgical and lets it
/// coexist with a real iPad on the same Mac.
final class IPadSimulator: ObservableObject {
    let noteManager: NoteManager
    let motion: MockMotionSource
    private let midi: MIDIEngine
    private weak var audio: AudioEngine?
    /// Set by `AppController` immediately after init (Swift forbids
    /// passing `self` during init). CC routing into `AppController`'s
    /// preset mappings only fires once this is wired.
    weak var controller: AppController?

    /// Mirrored slider values, surfaced for the UI's two-way binding.
    /// `NoteManager.slider{1,2}Value` is the source of truth; this
    /// proxy wakes SwiftUI redraws via `objectWillChange`.
    @Published var slider1: Double = Config.slider1Default {
        didSet {
            noteManager.slider1Value = slider1
            noteManager.slider1Touched = true
        }
    }
    @Published var slider2: Double = Config.slider2Default {
        didSet {
            noteManager.slider2Value = slider2
            noteManager.slider2Touched = true
        }
    }

    init(audio: AudioEngine) {
        self.audio = audio
        self.motion = MockMotionSource()
        self.noteManager = NoteManager()
        self.midi = MIDIEngine(publishToCoreMIDI: false)
        self.noteManager.motionSource = motion
        self.noteManager.midiEngine = midi
        self.midi.onLocalEvent = { [weak self] bytes in
            self?.deliver(bytes: bytes)
        }
    }

    func start() {
        midi.start()
    }

    /// Route an MPE byte stream from the simulator's `MIDIEngine` into
    /// the Mac signal chain. The byte counts mirror `MIDIEngine`'s emit
    /// shapes: Channel Pressure = 2 bytes, everything else = 3.
    private func deliver(bytes: [UInt8]) {
        guard let audio, bytes.count >= 2 else { return }
        let status = bytes[0]
        let high = status & 0xF0
        if high == 0xD0 {
            audio.sendHostedMIDI2(status: status, data1: bytes[1])
            return
        }
        guard bytes.count >= 3 else { return }
        audio.sendHostedMIDI(status: status, data1: bytes[1], data2: bytes[2])
        if high == 0xB0, let controller {
            controller.handleSimulatorCC(cc: Int(bytes[1]), value: Int(bytes[2]))
        }
    }

    // MARK: - Touch routing (mouse / computer keyboard)

    func touchBegan(touchId: Int, xFraction: Double, yFraction: Double) {
        noteManager.touchBegan(
            touchId: touchId,
            xFraction: xFraction,
            yFraction: yFraction,
            motionTimestamp: CACurrentMediaTime()
        )
    }

    func touchMoved(touchId: Int, xFraction: Double, yFraction: Double) {
        noteManager.touchMoved(touchId: touchId, xFraction: xFraction, yFraction: yFraction)
    }

    func touchEnded(touchId: Int) {
        noteManager.touchEnded(touchId: touchId)
    }

    func panic() {
        noteManager.panic()
    }

    func resetSliders() {
        noteManager.slider1Touched = false
        noteManager.slider2Touched = false
        slider1 = Config.slider1Default
        slider2 = Config.slider2Default
        // Re-setting through `didSet` flips Touched back to true; clear
        // it once more for the "untouched" highlight to be honest.
        noteManager.slider1Touched = false
        noteManager.slider2Touched = false
    }

    // MARK: - Direct-note API (audition runner)

    /// Begin a note at the geometric center of its keyboard cell. The
    /// touchId namespace is the caller's; `noteOff(id:)` must reuse the
    /// same id to release the note.
    func noteOn(id: Int, midiNote: Int, keyY: Double = 0.5) {
        let (x, y) = keyboardLocation(for: midiNote, preferredY: keyY)
        touchBegan(touchId: id, xFraction: x, yFraction: y)
    }

    /// Drag an already-held note to a new pitch. Useful for testing
    /// glide / drag behavior from an audition script.
    func glide(id: Int, toNote midiNote: Int, keyY: Double = 0.5) {
        let (x, y) = keyboardLocation(for: midiNote, preferredY: keyY)
        touchMoved(touchId: id, xFraction: x, yFraction: y)
    }

    func noteOff(id: Int) {
        touchEnded(touchId: id)
    }

    /// Set a tilt axis directly (used by the audition runner). Caller
    /// hops to main for `@Published` thread safety.
    func setTilt(axis: Int, value: Double) {
        let v = max(-1.0, min(1.0, value))
        switch axis {
        case 0: motion.tilt1 = v
        case 1: motion.tilt2 = v
        case 2: motion.tilt3 = v
        default: break
        }
    }

    func setSlider(index: Int, value: Double) {
        let v = max(0.0, min(1.0, value))
        switch index {
        case 0: slider1 = v
        case 1: slider2 = v
        default: break
        }
    }

    // MARK: - Note → keyboard geometry

    /// Returns the (xFraction, yFraction) inside the iPad keyboard
    /// layout that hits the requested note. Mirrors the visual layout
    /// from the iPad's `keyboardView`: white keys split the width
    /// evenly; black keys sit at white-key boundaries, centered.
    private func keyboardLocation(for note: Int, preferredY: Double) -> (Double, Double) {
        let scale = noteManager.scale
        let whites = scale.whiteNotesInRange()
        guard !whites.isEmpty else { return (0.5, 0.5) }
        let count = Double(whites.count)
        let isBlack = Scale.isBlackKey(note)
        let y = isBlack ? 0.3 : max(0.6, min(1.0, 1.0 - preferredY))
        if !isBlack {
            if let idx = whites.firstIndex(of: note) {
                return ((Double(idx) + 0.5) / count, y)
            }
            // Note isn't a white in the scale — fall through to nearest
        } else {
            // A black key sits at the boundary between its prev white
            // and next white. NoteManager's hitTest checks neighbors of
            // the white the touch landed under, so placing x exactly on
            // a white boundary reliably lands on the right black key.
            let prevWhite = note - 1
            let nextWhite = note + 1
            if let idx = whites.firstIndex(of: prevWhite) {
                return (Double(idx + 1) / count, y)
            }
            if let idx = whites.firstIndex(of: nextWhite) {
                return (Double(idx) / count, y)
            }
        }
        // Fallback: linear semitone position
        let span = max(1, scale.noteCount)
        let x = Double(note - scale.startNote) / Double(span)
        return (max(0.0, min(1.0, x)), y)
    }
}
