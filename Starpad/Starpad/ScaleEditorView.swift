import StarpadCore
import SwiftUI

/// In-place scale editor that replaces the keyboard's play behavior.
/// Tap keys to toggle notes on/off. Drag to pan the range. Pinch to zoom.
/// Long press (JI mode) to set the root note. iPad-only editor —
/// sympathetic-string scale is now Mac-side and edited from StarpadMac.
struct ScaleEditorView: View {
    @Binding var playingScale: Scale
    @Binding var isActive: Bool

    /// The scale the user is currently editing. Existing code reads/writes
    /// via `scale.x = y`; we proxy onto `playingScale` so call sites stay
    /// unchanged after dropping the dual-target (playing/strings) editor.
    private var scale: Scale {
        get { playingScale }
        nonmutating set { playingScale = newValue }
    }

    // Drag state for panning
    @State private var panStartNote: Int = 0
    @State private var panEndNote: Int = 0

    // Pinch state for zooming
    @State private var pinchStartRange: Int = 0
    @State private var pinchCenter: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ratioBand
                .frame(height: 24)
            editableKeyboard
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("SCALE EDITOR")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.yellow)

            Spacer()

            // Tuning picker
            ForEach(TuningSystem.allCases, id: \.self) { system in
                Button(action: {
                    scale.tuning = system
                    scale.enforceRootEnabled()
                }) {
                    Text(system == .equalTemperament ? "12-TET" : "JI")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(scale.tuning == system ? Color.blue : Color.gray.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }

            if scale.tuning == .justIntonation {
                Text("Root: \(Scale.noteName(for: scale.baseNote))")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }

            Text(scale.specificNoteMode
                 ? "\(scale.enabledSpecificNotes.count) notes"
                 : "\(scale.enabledDegrees.count)/12")
                .font(.system(size: 11))
                .foregroundColor(.gray)

            Text("\(Scale.noteName(for: scale.startNote))-\(Scale.noteName(for: scale.endNote))")
                .font(.system(size: 11))
                .foregroundColor(.cyan)

            Button(action: { scale = .default }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    // MARK: - Ratio Band

    private var ratioBand: some View {
        GeometryReader { geo in
            let whites = scale.whiteNotesInRange()
            let whiteCount = whites.count
            guard whiteCount > 0 else { return AnyView(Color.clear) }
            let whiteW = geo.size.width / CGFloat(whiteCount)

            return AnyView(
                ZStack(alignment: .leading) {
                    Color(white: 0.05)

                    ForEach(0..<scale.noteCount, id: \.self) { i in
                        let midi = scale.startNote + i
                        let isEnabled = scale.isEnabled(midi)

                        if isEnabled {
                            let isBlack = Scale.isBlackKey(midi)
                            let x = keyXCenter(midi: midi, whites: whites, whiteW: whiteW, isBlack: isBlack)
                            let pc = ((midi - scale.baseNote) % 12 + 12) % 12
                            let ratioText = scale.tuning == .justIntonation ? ratioString(for: pc) : "\(pc)"

                            Text(ratioText)
                                .font(.system(size: 8))
                                .foregroundColor(.yellow.opacity(0.8))
                                .position(x: x, y: geo.size.height / 2)
                        }
                    }
                }
            )
        }
    }

    private func keyXCenter(midi: Int, whites: [Int], whiteW: CGFloat, isBlack: Bool) -> CGFloat {
        if isBlack {
            var whiteIndex = 0
            for n in scale.startNote..<midi {
                if !Scale.isBlackKey(n) { whiteIndex += 1 }
            }
            return CGFloat(whiteIndex) * whiteW
        } else {
            if let idx = whites.firstIndex(of: midi) {
                return CGFloat(idx) * whiteW + whiteW / 2
            }
            return 0
        }
    }

    private func ratioString(for pitchClass: Int) -> String {
        let ratios = [
            "1", "16/15", "9/8", "6/5", "5/4", "4/3",
            "45/32", "3/2", "8/5", "5/3", "16/9", "15/8"
        ]
        return ratios[((pitchClass % 12) + 12) % 12]
    }

    // MARK: - Editable Keyboard

    private var editableKeyboard: some View {
        GeometryReader { geo in
            let whites = scale.whiteNotesInRange()
            let whiteCount = whites.count
            guard whiteCount > 0 else { return AnyView(Color.clear) }
            let whiteW = geo.size.width / CGFloat(whiteCount)
            let blackW = whiteW * 0.75
            let blackH = geo.size.height * 0.6

            return AnyView(
                ZStack(alignment: .topLeading) {
                    // White keys
                    ForEach(0..<whiteCount, id: \.self) { i in
                        let midi = whites[i]
                        let isOn = scale.isEnabled(midi)
                        let isRoot = isRootKey(midi: midi)

                        Rectangle()
                            .fill(editKeyColor(isBlack: false, isOn: isOn, isRoot: isRoot))
                            .frame(width: whiteW - 1, height: geo.size.height)
                            .offset(x: CGFloat(i) * whiteW)
                            .onTapGesture { toggleNote(midi) }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                if scale.tuning == .justIntonation {
                                    scale.baseNote = midi
                                    scale.enforceRootEnabled()
                                }
                            }

                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 1, height: geo.size.height)
                            .offset(x: CGFloat(i) * whiteW)

                        Text(Scale.noteName(for: midi))
                            .font(.system(size: 10))
                            .foregroundColor(isOn ? .white.opacity(0.7) : .gray.opacity(0.3))
                            .position(x: CGFloat(i) * whiteW + whiteW / 2, y: geo.size.height - 14)
                    }

                    // Black keys
                    ForEach(0..<scale.noteCount, id: \.self) { i in
                        let midi = scale.startNote + i
                        if Scale.isBlackKey(midi) {
                            let isOn = scale.isEnabled(midi)
                            let isRoot = isRootKey(midi: midi)
                            let cx = blackKeyCenter(midi: midi, whiteW: whiteW)

                            Rectangle()
                                .fill(editKeyColor(isBlack: true, isOn: isOn, isRoot: isRoot))
                                .frame(width: blackW, height: blackH)
                                .offset(x: cx - blackW / 2)
                                .onTapGesture { toggleNote(midi) }
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    if scale.tuning == .justIntonation {
                                        scale.baseNote = midi
                                        scale.enforceRootEnabled()
                                    }
                                }
                        }
                    }
                }
                // Drag to pan
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if panStartNote == 0 {
                                panStartNote = scale.startNote
                                panEndNote = scale.endNote
                            }
                            let semitoneShift = Int(-value.translation.width / max(1, whiteW * 0.7))
                            scale.startNote = max(12, min(108, panStartNote + semitoneShift))
                            scale.endNote = max(scale.startNote + 5, min(120, panEndNote + semitoneShift))
                        }
                        .onEnded { _ in
                            panStartNote = 0
                            panEndNote = 0
                        }
                )
                // Pinch to zoom
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if pinchStartRange == 0 {
                                pinchStartRange = scale.endNote - scale.startNote
                                pinchCenter = (scale.startNote + scale.endNote) / 2
                            }
                            let newRange = max(5, min(48, Int(Double(pinchStartRange) / value)))
                            scale.startNote = max(12, pinchCenter - newRange / 2)
                            scale.endNote = min(120, scale.startNote + newRange)
                        }
                        .onEnded { _ in
                            pinchStartRange = 0
                            pinchCenter = 0
                        }
                )
            )
        }
    }

    private func blackKeyCenter(midi: Int, whiteW: CGFloat) -> CGFloat {
        var whiteIndex = 0
        for n in scale.startNote..<midi {
            if !Scale.isBlackKey(n) { whiteIndex += 1 }
        }
        return CGFloat(whiteIndex) * whiteW
    }

    /// A key qualifies as the JI root for highlighting. In specific-note mode
    /// (sympathetic scale) only the exact root MIDI note is flagged — other
    /// octaves of the root's pitch class are just regular sympathetic-string
    /// slots and need to show their enabled/disabled state. In pitch-class
    /// mode (playing scale) we still highlight all octaves since the user is
    /// editing pitch classes, not specific notes.
    private func isRootKey(midi: Int) -> Bool {
        guard scale.tuning == .justIntonation else { return false }
        if scale.specificNoteMode {
            return midi == scale.baseNote
        } else {
            return midi % 12 == scale.baseNote % 12
        }
    }

    private func toggleNote(_ midiNote: Int) {
        // Specific-note mode (typical for sympathetic-string scale): toggle the
        // exact MIDI note, not its pitch class.
        if scale.specificNoteMode {
            if scale.tuning == .justIntonation && midiNote == scale.baseNote { return }
            var s = scale
            if s.enabledSpecificNotes.contains(midiNote) {
                if s.enabledSpecificNotes.count > 1 {
                    s.enabledSpecificNotes.remove(midiNote)
                }
            } else {
                s.enabledSpecificNotes.insert(midiNote)
            }
            scale = s
            return
        }

        // Pitch-class mode: toggle the entire pitch class (every octave of it).
        let pc = ((midiNote % 12) + 12) % 12
        if scale.tuning == .justIntonation && pc == ((scale.baseNote % 12) + 12) % 12 {
            return
        }
        if scale.enabledDegrees.contains(pc) {
            if scale.enabledDegrees.count > 1 {
                scale.enabledDegrees.remove(pc)
            }
        } else {
            scale.enabledDegrees.insert(pc)
        }
    }

    private func editKeyColor(isBlack: Bool, isOn: Bool, isRoot: Bool) -> Color {
        if isRoot {
            return isBlack ? Color.green.opacity(0.8) : Color.green.opacity(0.5)
        }
        if isOn {
            return isBlack ? Color.yellow.opacity(0.6) : Color.yellow.opacity(0.3)
        }
        return isBlack ? Color(white: 0.08) : Color(white: 0.2)
    }
}
