import SwiftUI

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var midi = MIDIEngine()
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var noteManager = NoteManager()
    @State private var touches: [TouchInfo] = []
    @State private var showCalibration = false
    @State private var showScaleEditor = false
    @State private var showMappingPanel = false


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showCalibration {
                CalibrationView(motion: motion) { calibration in
                    motion.calibration = calibration
                    withAnimation {
                        showCalibration = false
                    }
                }
            } else {
                ZStack {
                    mainView

                    if showMappingPanel {
                        MappingMatrixPanel(noteManager: noteManager, onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) { showMappingPanel = false
                                noteManager.paused = false
                            }
                        })
                        .transition(.move(edge: .leading))
                        .zIndex(10)
                    }
                }
            }

        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            noteManager.motionManager = motion
            noteManager.midiEngine = midi
            noteManager.audioEngine = audioEngine
            midi.start()
            if !motion.isCalibrated {
                showCalibration = true
            }
        }
    }

    // MARK: - Main View

    private var mainView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top half: info panels + pitch graph + readout
                HStack(alignment: .top, spacing: 0) {
                    orientationPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    Divider()
                        .background(Color.gray.opacity(0.3))

                    pitchGraphPanel
                        .frame(width: 540)
                }
                .frame(height: geo.size.height * 0.5, alignment: .top)
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { drag in
                            if drag.translation.width > 60 && abs(drag.translation.height) < 100 {
                                noteManager.paused = true
                                withAnimation(.easeInOut(duration: 0.2)) { showMappingPanel = true }
                            }
                        }
                )
                .overlay(alignment: .bottom) {
                    channelReadout
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                    .background(Color.gray)

                // Bottom half: keyboard or scale editor
                if showScaleEditor {
                    ScaleEditorView(scale: $noteManager.scale, isActive: $showScaleEditor)
                        .frame(height: geo.size.height * 0.5)
                } else {
                    ZStack {
                        keyboardView

                        TouchOverlayView(
                            touches: $touches,
                            onTouchBegan: { event in
                                noteManager.touchBegan(
                                    touchId: event.touchId,
                                    xFraction: event.xFraction,
                                    yFraction: event.yFraction,
                                    motionTimestamp: event.timestamp
                                )
                            },
                            onTouchMoved: { event in
                                noteManager.touchMoved(
                                    touchId: event.touchId,
                                    xFraction: event.xFraction,
                                    yFraction: event.yFraction
                                )
                            },
                            onTouchEnded: { touchId in
                                noteManager.touchEnded(touchId: touchId)
                            }
                        )

                        ForEach(touches) { touch in
                            touchDot(for: touch)
                        }
                    }
                    .frame(height: geo.size.height * 0.5)
                }
            }
        }
    }

    // MARK: - Pitch Graph

    private var pitchGraphPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PITCH")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.gray)

                Spacer()

                // Current note names
                ForEach(0..<Config.maxPolyVoices, id: \.self) { i in
                    let ch = noteManager.pitchChannels[i]
                    if ch.state != .idle {
                        Text(NoteManager.noteName(for: ch.targetNote))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                }
            }

            pitchWaveform
                .frame(maxHeight: .infinity)
        }
        .padding(8)
        .background(Color.black)
    }

    // MARK: - Sliders

    private func sliderControl(label: String, value: Binding<Double>,
                               touched: Binding<Bool>, defaultValue: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 20)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let fillWidth = value.wrappedValue * w

                ZStack(alignment: .trailing) {
                    // Track background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    // Fill — grows from right (0) toward left (1)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(touched.wrappedValue ? Color.cyan.opacity(0.6) : Color.cyan.opacity(0.3))
                        .frame(width: fillWidth)

                    // Default marker
                    let markerX = w * (1.0 - defaultValue)
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: h)
                        .position(x: markerX, y: h / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            touched.wrappedValue = true
                            // 0 at right edge, 1 at left edge
                            let fraction = 1.0 - drag.location.x / w
                            value.wrappedValue = max(0, min(1, fraction))
                        }
                        .onEnded { _ in
                            touched.wrappedValue = false
                            value.wrappedValue = defaultValue
                        }
                )
            }
            .frame(height: Config.sliderHeight)
        }
    }

    private var pitchWaveform: some View {
        GeometryReader { geo in
            let history = noteManager.pitchHistory
            guard !history.isEmpty else {
                return AnyView(Color.clear)
            }

            let lowNote = Double(noteManager.startNote)
            let highNote = Double(noteManager.startNote + noteManager.noteCount)
            let stepX = geo.size.width / CGFloat(max(1, history.count - 1))

            return AnyView(
                ZStack {
                    // Horizontal grid lines at each C
                    ForEach(noteManager.startNote...noteManager.startNote + noteManager.noteCount, id: \.self) { midi in
                        if midi % 12 == 0 {
                            let y = geo.size.height * (1.0 - CGFloat((Double(midi) - lowNote) / (highNote - lowNote)))
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)

                            Text(NoteManager.noteName(for: midi))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                                .position(x: 16, y: y - 6)
                        }
                    }

                    // Touch target notes (white dots)
                    touchNoteDots(history: history, geo: geo, lowNote: lowNote, highNote: highNote, stepX: stepX)

                    // Voice lines — uniform color scheme: cyan=tap, green=drag, yellow=snap
                    ForEach(0..<Config.maxPolyVoices, id: \.self) { ch in
                        pitchLine(history: history, geo: geo, channelIndex: ch, lowNote: lowNote, highNote: highNote, stepX: stepX, dragOnly: false, snapOnly: false)
                            .stroke(Color.cyan, lineWidth: 2)
                        pitchLine(history: history, geo: geo, channelIndex: ch, lowNote: lowNote, highNote: highNote, stepX: stepX, dragOnly: true, snapOnly: false)
                            .stroke(Color.green, lineWidth: 2)
                        pitchLine(history: history, geo: geo, channelIndex: ch, lowNote: lowNote, highNote: highNote, stepX: stepX, dragOnly: nil, snapOnly: true)
                            .stroke(Color.yellow, lineWidth: 2.5)
                    }
                }
            )
        }
    }

    private func touchNoteDots(history: [PitchSample], geo: GeometryProxy, lowNote: Double, highNote: Double, stepX: CGFloat) -> some View {
        Canvas { context, size in
            for (i, sample) in history.enumerated() {
                let x = CGFloat(i) * stepX
                for note in sample.touchNotes {
                    let semitone = Double(note)
                    let y = size.height * (1.0 - CGFloat((semitone - lowNote) / (highNote - lowNote)))
                    let rect = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.4)))
                }
            }
        }
    }

    private func pitchLine(history: [PitchSample], geo: GeometryProxy, channelIndex: Int, lowNote: Double, highNote: Double, stepX: CGFloat, dragOnly: Bool? = nil, snapOnly: Bool = false) -> Path {
        Path { path in
            var started = false
            for (i, sample) in history.enumerated() {
                let freq = sample.frequencies.indices.contains(channelIndex) ? sample.frequencies[channelIndex] : nil
                let isDragging = sample.draggingFlags.indices.contains(channelIndex) && sample.draggingFlags[channelIndex]
                let isSnapping = sample.snappingFlags.indices.contains(channelIndex) && sample.snappingFlags[channelIndex]
                // Filter by drag state if specified
                if let dragOnly = dragOnly {
                    if isDragging != dragOnly {
                        started = false
                        continue
                    }
                }
                // Filter by snap state if specified
                if snapOnly && !isSnapping {
                    started = false
                    continue
                }
                guard let f = freq else {
                    started = false
                    continue
                }
                let semitone = 12.0 * log2(f / 440.0) + 69.0
                let y = geo.size.height * (1.0 - CGFloat((semitone - lowNote) / (highNote - lowNote)))
                let x = CGFloat(i) * stepX

                if !started {
                    path.move(to: CGPoint(x: x, y: y))
                    started = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    // MARK: - Visual Keyboard

    private func whiteKeyLayout() -> (whiteNotes: [Int], count: Int) {
        var whites: [Int] = []
        for i in 0..<noteManager.noteCount {
            let midi = noteManager.startNote + i
            if !NoteManager.isBlackKey(midi) {
                whites.append(midi)
            }
        }
        return (whites, whites.count)
    }

    private func blackKeyX(midiNote: Int, totalWhite: Int, width: CGFloat) -> CGFloat {
        var whiteIndex = 0
        for n in noteManager.startNote..<midiNote {
            if !NoteManager.isBlackKey(n) {
                whiteIndex += 1
            }
        }
        let whiteW = width / CGFloat(totalWhite)
        return CGFloat(whiteIndex) * whiteW
    }

    /// Returns the outline path for a white key with cutouts for adjacent black keys.
    /// The key spans from x=0 to x=whiteW, y=0 (top) to y=totalH (bottom).
    private func whiteKeyPath(midi: Int, whiteIndex: Int, whiteW: CGFloat, blackW: CGFloat,
                              blackH: CGFloat, totalH: CGFloat, totalWhite: Int) -> Path {
        let halfBlack = blackW / 2

        // Check if adjacent notes are black keys within the keyboard range
        let hasBlackLeft = midi > noteManager.startNote && Scale.isBlackKey(midi - 1)
        let hasBlackRight = midi + 1 < noteManager.startNote + noteManager.noteCount && Scale.isBlackKey(midi + 1)

        // In the top zone, the key is narrowed by black key intrusions
        // Black keys are centered on white key boundaries
        let leftCutout = hasBlackLeft ? halfBlack : 0
        let rightCutout = hasBlackRight ? halfBlack : 0

        var path = Path()
        // Start at top-left (after any left cutout)
        path.move(to: CGPoint(x: leftCutout, y: 0))
        // Top edge
        path.addLine(to: CGPoint(x: whiteW - rightCutout, y: 0))
        // Right side down to black key bottom
        path.addLine(to: CGPoint(x: whiteW - rightCutout, y: blackH))
        // Step out to full width at black key bottom
        if rightCutout > 0 {
            path.addLine(to: CGPoint(x: whiteW, y: blackH))
        }
        // Right side down to bottom
        path.addLine(to: CGPoint(x: whiteW, y: totalH))
        // Bottom edge
        path.addLine(to: CGPoint(x: 0, y: totalH))
        // Left side up to black key bottom
        path.addLine(to: CGPoint(x: 0, y: blackH))
        // Step in at black key bottom
        if leftCutout > 0 {
            path.addLine(to: CGPoint(x: leftCutout, y: blackH))
        }
        // Left side up to top
        path.addLine(to: CGPoint(x: leftCutout, y: 0))
        path.closeSubpath()
        return path
    }

    /// Returns the highlight color for a key, or nil if not active.
    /// Cyan for tap, green for drag, yellow for snap — same for all voices.
    private func keyColor(for midiNote: Int) -> Color? {
        for i in 0..<Config.maxPolyVoices {
            guard noteManager.pitchChannels[i].state != .idle else { continue }
            let ch = noteManager.pitchChannels[i]
            if ch.dragging {
                // When dragging, highlight the key under the finger, not the sounding pitch
                let noteToShow = ch.displayNote ?? ch.targetNote
                if noteToShow == midiNote {
                    return ch.snapping ? .yellow : .green
                }
            } else if ch.targetNote == midiNote {
                return .cyan
            }
        }
        return nil
    }

    private var keyboardView: some View {
        GeometryReader { geo in
            let layout = whiteKeyLayout()
            let whiteW = geo.size.width / CGFloat(layout.count)
            let blackW = whiteW * 0.65
            let blackH = geo.size.height * 0.6

            ZStack(alignment: .topLeading) {
                // Black background
                Color.black

                // White keys
                ForEach(0..<layout.count, id: \.self) { i in
                    let midi = layout.whiteNotes[i]
                    let color = keyColor(for: midi)
                    let enabled = noteManager.scale.isEnabled(midi)
                    let keyPath = whiteKeyPath(midi: midi, whiteIndex: i, whiteW: whiteW,
                                               blackW: blackW, blackH: blackH,
                                               totalH: geo.size.height, totalWhite: layout.count)

                    // Fill — gray by default, gradient when active
                    if let color {
                        let fillGradient = LinearGradient(
                            colors: [Color(white: 0.15), color.opacity(0.4)],
                            startPoint: .top, endPoint: .bottom)
                        keyPath
                            .fill(fillGradient)
                            .blur(radius: 2)
                            .offset(x: CGFloat(i) * whiteW)
                        keyPath
                            .fill(fillGradient)
                            .offset(x: CGFloat(i) * whiteW)
                    } else {
                        keyPath
                            .fill(Color(white: enabled ? 0.12 : 0.06))
                            .offset(x: CGFloat(i) * whiteW)
                    }

                    // Outline — always black
                    keyPath
                        .stroke(Color.black, lineWidth: 1.0)
                        .offset(x: CGFloat(i) * whiteW)

                    Text(NoteManager.noteName(for: midi))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                        .position(
                            x: CGFloat(i) * whiteW + whiteW / 2,
                            y: geo.size.height - 14
                        )
                }

                // Black keys
                ForEach(0..<noteManager.noteCount, id: \.self) { i in
                    let midi = noteManager.startNote + i
                    if NoteManager.isBlackKey(midi) {
                        let color = keyColor(for: midi)
                        let cx = blackKeyX(midiNote: midi, totalWhite: layout.count, width: geo.size.width)

                        // Fill — gradient when active
                        if let color {
                            let fillGradient = LinearGradient(
                                colors: [Color(white: 0.15), color.opacity(0.4)],
                                startPoint: .top, endPoint: .bottom)
                            Rectangle()
                                .fill(fillGradient)
                                .frame(width: blackW, height: blackH)
                                .blur(radius: 2)
                                .offset(x: cx - blackW / 2)
                            Rectangle()
                                .fill(fillGradient)
                                .frame(width: blackW, height: blackH)
                                .offset(x: cx - blackW / 2)
                        }

                        // Outline — always black
                        Rectangle()
                            .stroke(Color.black, lineWidth: 1.0)
                            .frame(width: blackW, height: blackH)
                            .offset(x: cx - blackW / 2)
                    }
                }
            }
        }
    }

    // MARK: - Orientation Panel

    /// Returns short labels of parameters mapped to a given dimension.
    private func mappedParamLabels(for dim: Dimension) -> String {
        noteManager.dimensionMapping.parameters(for: dim).map(\.shortLabel).joined(separator: ", ")
    }

    private var orientationPanel: some View {
        HStack(spacing: 16) {
            // Dimension values with mapped parameter names
            if let tilts = motion.normalizedTilts {
                VStack(alignment: .leading, spacing: 6) {
                    if tilts.count > 0 { dimensionRow(label: "Tilt 1", value: tilts[0], dim: .tilt1) }
                    if tilts.count > 1 { dimensionRow(label: "Tilt 2", value: tilts[1], dim: .tilt2) }
                    if tilts.count > 2 { dimensionRow(label: "Tilt 3", value: tilts[2], dim: .tilt3) }
                    if !mappedParamLabels(for: .accelPressure).isEmpty {
                        dimensionRow(label: "Pressure", value: noteManager.lastActiveAccelPressure * 2 - 1, dim: .accelPressure)
                    }
                    if !mappedParamLabels(for: .keyY).isEmpty {
                        dimensionRow(label: "Key Y", value: noteManager.lastActiveKeyY * 2 - 1, dim: .keyY)
                    }
                    if !mappedParamLabels(for: .slider1).isEmpty {
                        dimensionRow(label: "Slider 1", value: noteManager.slider1Value * 2 - 1, dim: .slider1)
                    }
                    if !mappedParamLabels(for: .slider2).isEmpty {
                        dimensionRow(label: "Slider 2", value: noteManager.slider2Value * 2 - 1, dim: .slider2)
                    }
                }
            }

            Divider()
                .frame(height: 100)
                .background(Color.gray.opacity(0.3))

            // Buttons
            VStack(alignment: .leading, spacing: 6) {
                Button(action: { noteManager.polyphonicMode.toggle() }) {
                    Text(noteManager.polyphonicMode ? "POLY" : "MONO")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(noteManager.polyphonicMode ? Color.green.opacity(0.7) : Color.gray.opacity(0.5))
                        .cornerRadius(6)
                }

                Button(action: {
                    if showScaleEditor {
                        noteManager.scale.save()
                    }
                    withAnimation { showScaleEditor.toggle() }
                }) {
                    Text(showScaleEditor ? "DONE" : "SCALE")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(showScaleEditor ? Color.blue.opacity(0.7) : Color.purple.opacity(0.7))
                        .cornerRadius(6)
                }

                Button(action: { noteManager.panic() }) {
                    Text("PANIC")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(6)
                }

                Button(action: {
                    noteManager.paused = !showMappingPanel
                    withAnimation(.easeInOut(duration: 0.2)) { showMappingPanel.toggle() }
                }) {
                    Text("MAP")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.7))
                        .cornerRadius(6)
                }

                Button(action: { showCalibration = true }) {
                    Label("Recalibrate", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            Spacer()
        }
        .padding()
        .background(Color.black)
    }

    private func dimensionRow(label: String, value: Double, dim: Dimension) -> some View {
        let params = mappedParamLabels(for: dim)
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 55, alignment: .leading)

            Text(String(format: "%+.2f", value))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.cyan)
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 4)

                    let clamped = max(-1, min(1, value))
                    let barWidth = geo.size.width * abs(clamped) / 2
                    let barX = clamped >= 0
                        ? geo.size.width / 2
                        : geo.size.width / 2 - barWidth
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.cyan)
                        .frame(width: barWidth, height: 4)
                        .offset(x: barX - geo.size.width / 2 + barWidth / 2)
                }
            }
            .frame(width: 50, height: 10)

            Text(params.isEmpty ? "—" : params)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(params.isEmpty ? .gray.opacity(0.3) : .green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }

    private func formatValue(_ value: Double, unit: String) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    // MARK: - Accelerometer Panel


    // MARK: - Touch & Channel Display

    private func touchDot(for touch: TouchInfo) -> some View {
        // Find which voice owns this touch and its drag state
        let voiceIdx = (0..<Config.maxPolyVoices).first { noteManager.pitchChannels[$0].touchIds.contains(touch.id) }
        let color: Color = {
            guard let i = voiceIdx else { return .gray }
            if noteManager.pitchChannels[i].snapping { return .yellow }
            if noteManager.pitchChannels[i].dragging { return .green }
            return .cyan
        }()

        return Circle()
            .fill(voiceIdx != nil ? color.opacity(0.4) : Color.white.opacity(0.2))
            .frame(width: 44, height: 44)
            .overlay(
                Circle()
                    .stroke(voiceIdx != nil ? color : Color.gray, lineWidth: 2)
            )
            .position(touch.location)
    }

    private var channelReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<Config.maxPolyVoices, id: \.self) { i in
                let ch = noteManager.pitchChannels[i]
                if ch.state != .idle {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 8, height: 8)
                        Text("CH\(i)")
                            .foregroundColor(.cyan)
                        Text(NoteManager.noteName(for: ch.targetNote))
                            .foregroundColor(.white)
                            .frame(width: 36, alignment: .leading)
                        Text(String(format: "%.0f Hz", ch.currentFrequency))
                            .foregroundColor(.green)
                        Text("v\(ch.velocity)")
                            .foregroundColor(.yellow)
                        if ch.glideProgress < 1.0 {
                            Text(String(format: "glide: %.0f%%", ch.glideProgress * 100))
                                .foregroundColor(.orange)
                        }
                        Text("\(ch.touchIds.count) touch\(ch.touchIds.count == 1 ? "" : "es")")
                            .foregroundColor(.gray)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }

            // Glide debug
            HStack(spacing: 10) {
                Text(String(format: "t: %.2f/%.2f/%.2f", noteManager.currentTilt[0], noteManager.currentTilt[1], noteManager.currentTilt[2]))
                    .foregroundColor(.cyan)
                Text(String(format: "ms/st: %.0f", noteManager.glideTimePerSemitone * 1000))
                    .foregroundColor(.green)
                Text(String(format: "maxWait: %.0fms", noteManager.glideMaxWait * 1000))
                    .foregroundColor(.orange)
                if let dur = noteManager.pitchChannels[0].glideProgress < 1.0 ?
                    noteManager.pitchChannels[0].glideDuration : nil {
                    Text(String(format: "dur: %.0fms", dur * 1000))
                        .foregroundColor(.yellow)
                }
                Text("q:\(noteManager.pitchChannels[0].queue.count)")
                    .foregroundColor(.gray)
            }
            .font(.system(.caption, design: .monospaced))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("MIDI")
                            .font(.caption).fontWeight(.bold)
                            .foregroundColor(noteManager.midiOutputEnabled ? .green.opacity(0.8) : .gray.opacity(0.5))
                        Text(midi.isActive ? "connected" : "—")
                            .font(.caption)
                            .foregroundColor(midi.isActive ? .green.opacity(0.5) : .red.opacity(0.5))
                    }
                    .onTapGesture { noteManager.midiOutputEnabled.toggle() }

                    Text("Synth")
                        .font(.caption).fontWeight(.bold)
                        .foregroundColor(noteManager.synthEnabled ? .green.opacity(0.8) : .gray.opacity(0.5))
                        .onTapGesture { noteManager.synthEnabled.toggle() }
                }

                Spacer()

                VStack(spacing: 4) {
                    sliderControl(label: "S1", value: $noteManager.slider1Value,
                                  touched: $noteManager.slider1Touched,
                                  defaultValue: Config.slider1Default)
                    sliderControl(label: "S2", value: $noteManager.slider2Value,
                                  touched: $noteManager.slider2Touched,
                                  defaultValue: Config.slider2Default)
                }
                .frame(width: Config.sliderWidth + 26)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Mapping Matrix Panel

struct MappingMatrixPanel: View {
    @ObservedObject var noteManager: NoteManager
    var onDismiss: () -> Void

    @State private var selectedParam: MappableParameter? = nil
    @State private var selectedDim: Dimension? = nil
    @State private var dragSource: (MappableParameter, Dimension)? = nil
    @State private var dragTarget: (MappableParameter, Dimension)? = nil
    @State private var isDragging = false
    @State private var matrixWidth: CGFloat = 0
    private var cellSide: CGFloat {
        let totalCols = 1 + dims.count // default + dims
        guard totalCols > 0, matrixWidth > labelWidth else { return 50 }
        return (matrixWidth - labelWidth) / CGFloat(totalCols)
    }

    private let dims = Dimension.real
    private let params = MappableParameter.allCases
    private let cellHeight: CGFloat = 52
    private let labelWidth: CGFloat = 155
    private let headerFont = Font.system(size: 17, weight: .semibold, design: .default)
    private let font = Font.system(size: 15, weight: .regular, design: .default)
    private let smallFont = Font.system(size: 13, weight: .regular, design: .default)
    private let tinyFont = Font.system(size: 11, weight: .regular, design: .default)

    var body: some View {
        GeometryReader { geo in
            let matrixW = geo.size.width * 2.0 / 3.0
            let editorW = geo.size.width / 3.0

            HStack(spacing: 0) {
                // Left 2/3: Matrix
                VStack(spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        Text("← Mapping")
                            .font(headerFont)
                            .foregroundColor(.cyan)
                            .frame(width: labelWidth, alignment: .leading)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { onDismiss() }

                        Text("Default")
                            .font(smallFont).fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)

                        ForEach(dims, id: \.rawValue) { dim in
                            Text(dim.label)
                                .font(smallFont).fontWeight(.medium)
                                .foregroundColor(dimColor(dim))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                    }
                    .background(Color(white: 0.06))

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            ForEach(MappableParameter.displayOrder.indices, id: \.self) { gi in
                                let group = MappableParameter.displayOrder[gi]
                                if gi > 0 { sectionDivider(group.group) }
                                else { sectionDivider(group.group) }
                                ForEach(group.params, id: \.rawValue) { param in
                                    paramRow(param: param)
                                }
                            }
                        }
                        .coordinateSpace(name: "matrixGrid")
                    }
                }
                .frame(width: matrixW)
                .onAppear { matrixWidth = matrixW }

                Divider().background(Color.gray.opacity(0.3))

                // Right 1/3: Curve editor
                curveEditorPanel
                    .frame(width: editorW)
            }
        }
        .background(Color.black.opacity(0.97))
    }

    // MARK: - Curve Editor Panel

    @ViewBuilder
    private var curveEditorPanel: some View {
        if let param = selectedParam, let dim = selectedDim {
            if dim == Dimension.none {
                // Default value editor
                defaultValueEditor(param: param)
            } else if noteManager.dimensionMapping.isConnected(param, dim) {
                CurveEditorView(
                    parameter: param,
                    dimension: dim,
                    binding: bindingProxy(param: param, dim: dim)
                )
            } else {
                paramDescription(param: param)
            }
        } else {
            VStack {
                Text("Tap a cell to edit").font(smallFont).foregroundColor(.gray.opacity(0.4))
                Spacer()
            }.padding()
        }
    }

    private func defaultValueEditor(param: MappableParameter) -> some View {
        let mapping = noteManager.dimensionMapping.mapping(for: param)
        let pr = param.defaultRange

        return VStack(spacing: 12) {
            Text(param.label)
                .font(headerFont).foregroundColor(.white)
            if let detail = param.detail {
                Text(detail).font(smallFont).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }

            Divider().background(Color.gray.opacity(0.3))

            Text("Default Value")
                .font(smallFont).foregroundColor(.gray)

            Text("Used when no dimension is active")
                .font(tinyFont).foregroundColor(.gray.opacity(0.5))

            // Large draggable value
            Text(formatVal(mapping.defaultValue))
                .font(.system(size: 32, weight: .medium, design: .default))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            let step = (pr.1 - pr.0) * 0.002
                            let delta = Double(drag.translation.width) * step
                            let newVal = max(pr.0, min(pr.1, mapping.defaultValue + delta))
                            var m = noteManager.dimensionMapping.mapping(for: param)
                            m.defaultValue = newVal
                            noteManager.dimensionMapping.mappings[param.storageKey] = m
                        }
                )

            HStack {
                Text(formatVal(pr.0)).font(smallFont).foregroundColor(.gray.opacity(0.4))
                Spacer()
                Text(formatVal(pr.1)).font(smallFont).foregroundColor(.gray.opacity(0.4))
            }
            .padding(.horizontal, 20)

            if let unit = param.unit.isEmpty ? nil : param.unit {
                Text(unit).font(smallFont).foregroundColor(.gray)
            }

            Spacer()
        }
        .padding()
    }

    private func paramDescription(param: MappableParameter) -> some View {
        VStack(spacing: 8) {
            Text(param.label).font(font).foregroundColor(.white)
            if let detail = param.detail {
                Text(detail).font(smallFont).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            Text("Tap a cell to edit").font(tinyFont).foregroundColor(.gray.opacity(0.4))
            Spacer()
        }.padding()
    }

    private func bindingProxy(param: MappableParameter, dim: Dimension) -> Binding<DimensionBinding> {
        Binding(
            get: {
                noteManager.dimensionMapping.mapping(for: param).binding(for: dim)
                    ?? DimensionBinding(dimension: dim,
                                        rangeMin: param.defaultRange.0,
                                        rangeMax: param.defaultRange.1)
            },
            set: { newBinding in
                noteManager.dimensionMapping.setBinding(for: param, dimension: dim, to: newBinding)
            }
        )
    }

    // MARK: - Matrix Helpers

    private func sectionDivider(_ label: String) -> some View {
        HStack {
            Text(label).font(tinyFont).foregroundColor(.gray).padding(.leading, 12)
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 0.5)
        }
        .padding(.vertical, 3)
    }

    private func paramRow(param: MappableParameter) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(param.label)
                    .font(font)
                    .foregroundColor(selectedParam == param ? .white : Color(white: 0.7))
                if let detail = param.detail {
                    Text(detail).font(tinyFont).foregroundColor(.gray.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .padding(.leading, 12)

            defaultCell(param: param)

            ForEach(dims, id: \.rawValue) { dim in
                matrixCell(param: param, dim: dim)
            }
        }
        .background(selectedParam == param ? Color.white.opacity(0.03) : Color.clear)
    }

    private func defaultCell(param: MappableParameter) -> some View {
        let mapping = noteManager.dimensionMapping.mapping(for: param)
        let isSelected = selectedParam == param && selectedDim == Dimension.none
        // Default is "active" when no dimension is bound AND the parameter always uses its value
        let isActive = mapping.bindings.isEmpty && param.defaultAlwaysActive
        let activeColor = Color.white

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? activeColor.opacity(0.15) : Color(white: 0.04))
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white :
                        (isActive ? activeColor.opacity(0.4) : Color(white: 0.1)),
                        lineWidth: isSelected ? 2 : 0.5)

            Text(formatVal(mapping.defaultValue))
                .font(smallFont)
                .foregroundColor(isActive ? .white : .white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedParam = param
            selectedDim = Dimension.none
        }
    }

    private func matrixCell(param: MappableParameter, dim: Dimension) -> some View {
        let connected = noteManager.dimensionMapping.isConnected(param, dim)
        let isSelected = selectedParam == param && selectedDim == dim
        let isDragTarget = dragTarget?.0 == param && dragTarget?.1 == dim

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(isDragTarget ? Color.white.opacity(0.15) :
                      (connected ? dimColor(dim).opacity(0.25) : Color(white: 0.04)))
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white :
                        (connected ? dimColor(dim).opacity(0.5) : Color(white: 0.1)),
                        lineWidth: isSelected ? 2 : 0.5)

            if connected {
                miniCurve(param: param, dim: dim)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if connected {
                selectedParam = param; selectedDim = dim
            } else {
                noteManager.dimensionMapping.toggleBinding(for: param, dimension: dim)
                selectedParam = param; selectedDim = dim
            }
        }
        .onLongPressGesture {
            if connected {
                noteManager.dimensionMapping.toggleBinding(for: param, dimension: dim)
                if selectedDim == dim && selectedParam == param { selectedDim = nil }
            }
        }
    }

    private func miniCurve(param: MappableParameter, dim: Dimension) -> some View {
        GeometryReader { geo in
            if let b = noteManager.dimensionMapping.mapping(for: param).binding(for: dim) {
                let w = geo.size.width - 4
                let h = geo.size.height - 4
                let yr = param.defaultRange
                let span = max(yr.1 - yr.0, 0.001)
                Path { path in
                    let steps = 20
                    for s in 0...steps {
                        let t = Double(s) / Double(steps)
                        let y = b.evaluate(t)
                        let sx = 2 + CGFloat(t) * w
                        let sy = 2 + CGFloat(1.0 - (y - yr.0) / span) * h
                        if s == 0 { path.move(to: CGPoint(x: sx, y: sy)) }
                        else { path.addLine(to: CGPoint(x: sx, y: sy)) }
                    }
                }
                .stroke(dimColor(dim), lineWidth: 1)
            }
        }
    }

    /// Flat list of parameters in display order (for cellAt coordinate mapping).
    private var displayParams: [MappableParameter] {
        MappableParameter.displayOrder.flatMap(\.params)
    }

    private func cellAt(_ point: CGPoint) -> (MappableParameter, Dimension)? {
        let rowH = cellSide
        let dividerHeight: CGFloat = 12 // sectionDivider height
        let groups = MappableParameter.displayOrder

        // Walk through groups to find which row the Y coordinate falls in
        var y = point.y
        var paramIndex = 0
        for (gi, group) in groups.enumerated() {
            // Each group has a divider above it
            let _ = gi // all groups have dividers now
            y -= dividerHeight
            if y < 0 { return nil }

            let groupHeight = CGFloat(group.params.count) * rowH
            if y < groupHeight {
                let rowInGroup = Int(y / rowH)
                paramIndex = rowInGroup
                let flatParams = displayParams
                let offset = groups[0..<gi].reduce(0) { $0 + $1.params.count }
                let idx = offset + paramIndex
                guard idx >= 0, idx < flatParams.count else { return nil }

                let cellAreaX = point.x - labelWidth
                guard cellAreaX >= 0, cellSide > 0 else { return nil }
                let colIdx = Int(cellAreaX / cellSide)
                // Column 0 is Default — skip for drag operations
                guard colIdx >= 1, colIdx <= dims.count else { return nil }
                return (flatParams[idx], dims[colIdx - 1])
            }
            y -= groupHeight
        }
        return nil
    }

    private func moveBinding(from srcP: MappableParameter, srcDim: Dimension,
                             to tgtP: MappableParameter, tgtDim: Dimension) {
        guard let binding = noteManager.dimensionMapping.mapping(for: srcP).binding(for: srcDim) else { return }
        // Remove from source
        noteManager.dimensionMapping.toggleBinding(for: srcP, dimension: srcDim)
        // Add to target (if not already connected)
        if !noteManager.dimensionMapping.isConnected(tgtP, tgtDim) {
            noteManager.dimensionMapping.toggleBinding(for: tgtP, dimension: tgtDim)
        }
        // Copy the curve data, updating the dimension
        var moved = binding
        moved.dimension = tgtDim
        noteManager.dimensionMapping.setBinding(for: tgtP, dimension: tgtDim, to: moved)
        selectedParam = tgtP
        selectedDim = tgtDim
    }

    private func formatVal(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func dimColor(_ dim: Dimension) -> Color {
        if dim.isTilt { return .cyan }
        if dim.isPerNote { return .green }
        if dim.isSlider { return .orange }
        return .gray
    }
}

#Preview {
    ContentView()
}
