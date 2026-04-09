import SwiftUI

/// In-place scale editor that replaces the keyboard's play behavior.
/// Tap keys to toggle notes on/off. Drag to pan the range. Pinch to zoom.
/// Long press (JI mode) to set the root note.
struct ScaleEditorView: View {
    @Binding var scale: Scale
    @Binding var isActive: Bool

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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
            }

            Text("\(scale.enabledDegrees.count)/12")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)

            Text("\(Scale.noteName(for: scale.startNote))-\(Scale.noteName(for: scale.endNote))")
                .font(.system(size: 11, design: .monospaced))
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
                                .font(.system(size: 8, design: .monospaced))
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
                        let isRoot = scale.tuning == .justIntonation && midi % 12 == scale.baseNote % 12

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
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(isOn ? .white.opacity(0.7) : .gray.opacity(0.3))
                            .position(x: CGFloat(i) * whiteW + whiteW / 2, y: geo.size.height - 14)
                    }

                    // Black keys
                    ForEach(0..<scale.noteCount, id: \.self) { i in
                        let midi = scale.startNote + i
                        if Scale.isBlackKey(midi) {
                            let isOn = scale.isEnabled(midi)
                            let isRoot = scale.tuning == .justIntonation && midi % 12 == scale.baseNote % 12
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

    private func toggleNote(_ midiNote: Int) {
        let pc = ((midiNote % 12) + 12) % 12

        // Don't allow disabling the JI root
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
