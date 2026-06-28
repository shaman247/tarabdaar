import AppKit
import StarpadCore
import SwiftUI

/// Tab that simulates the iPad on the Mac — keyboard + tilt sliders +
/// strike-force + recording controls. The point is to iterate on Mac-
/// side sound parameters (sym pool, FX, hosted-AU) without needing the
/// iPad in the loop. The notes themselves drive the same MPE pipeline
/// the iPad uses, via an `IPadSimulator` that owns its own NoteManager
/// and delivers MIDI in-process to `AudioEngine`.
///
/// Multi-touch on a mouse: plain click+drag = single finger; Shift-
/// click locks a finger that stays held until shift-clicked again
/// (good for testing chords / sustained drones). Panic releases all.
///
/// Computer keyboard (piano layout, lower row = white, upper = black):
///   A W S E D F T G Y H U J = C C# D D# E F F# G G# A A# B
///   K O L                  = C5 C#5 D5
///   Z / X                  = octave down / up
struct SimulatorView: View {
    @ObservedObject var simulator: IPadSimulator
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var motion: MockMotionSource
    @ObservedObject var audio: AudioEngine
    @ObservedObject var audition: AuditionRunner

    init(controller: AppController) {
        let sim = controller.simulator
        self.simulator = sim
        self.noteManager = sim.noteManager
        self.motion = sim.motion
        self.audio = controller.audio
        self.audition = controller.audition
    }

    var body: some View {
        VStack(spacing: 8) {
            controlsRow
            sensorsRow
            KeyboardSurface(simulator: simulator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(12)
    }

    // MARK: - Top controls

    private var controlsRow: some View {
        HStack(spacing: 12) {
            recordButton
            Toggle("Poly", isOn: Binding(
                get: { noteManager.polyphonicMode },
                set: { noteManager.polyphonicMode = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Button("Panic") { simulator.panic() }
            Button("Reset sliders") { simulator.resetSliders() }
            Spacer()
            activeNotesPill
            auditionPill
        }
    }

    private var recordButton: some View {
        Button {
            if audio.isRecording {
                audio.stopRecording()
            } else {
                let url = Self.makeRecordingURL()
                do { try audio.startRecording(to: url) }
                catch { NSLog("Starpad: record start failed: \(error)") }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(audio.isRecording ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                Text(audio.isRecording ? "Stop" : "Record")
                    .font(.system(.body, design: .default).weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color(white: 0.18)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = audio.lastRecordingURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private var activeNotesPill: some View {
        HStack(spacing: 4) {
            let active = (0..<Config.maxPolyVoices).compactMap { i -> String? in
                let ch = noteManager.pitchChannels[i]
                return ch.state == .idle ? nil : NoteManager.noteName(for: ch.targetNote)
            }
            Text(active.isEmpty ? "—" : active.joined(separator: " "))
                .font(.system(.caption))
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.12)))
    }

    private var auditionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(audition.isRunning ? Color.orange : Color(white: 0.4))
                .frame(width: 8, height: 8)
            Text(audition.isRunning ? "Audition…" : "Audition idle")
                .font(.system(.caption))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.12)))
    }

    // MARK: - Sensors row

    private var sensorsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            tiltStack(label: "Tilt 1", value: $motion.tilt1)
            tiltStack(label: "Tilt 2", value: $motion.tilt2)
            tiltStack(label: "Tilt 3", value: $motion.tilt3)
            sliderStack(label: "Slider 1", value: $simulator.slider1)
            sliderStack(label: "Slider 2", value: $simulator.slider2)
            strikeForceStack
            Spacer()
        }
        .frame(height: 110)
    }

    private func tiltStack(label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: -1...1)
                .frame(width: 100)
            Text(String(format: "%+0.2f", value.wrappedValue))
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Button("Center") { value.wrappedValue = 0 }
                .buttonStyle(.borderless)
                .controlSize(.mini)
        }
    }

    private func sliderStack(label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .frame(width: 100)
            Text(String(format: "%0.2f", value.wrappedValue))
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Button("Default") { value.wrappedValue = 0.5 }
                .buttonStyle(.borderless)
                .controlSize(.mini)
        }
    }

    private var strikeForceStack: some View {
        VStack(spacing: 4) {
            Text("Strike").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $motion.strikeForce, in: 0.01...0.5)
                .frame(width: 100)
            Text(String(format: "%0.2fg", motion.strikeForce))
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Text("velocity")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Audition inbox:")
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Text(audition.inboxPath)
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
            Button("Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: audition.inboxPath))
            }
            .buttonStyle(.link)
            .controlSize(.mini)
            Spacer()
            if let url = audio.lastRecordingURL {
                Text("Last WAV:")
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                Button(url.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .controlSize(.mini)
            }
        }
    }

    private static func makeRecordingURL() -> URL {
        let fm = FileManager.default
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let dir = music.appendingPathComponent("Starpad-Recordings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        return dir.appendingPathComponent("Starpad-\(stamp.string(from: Date())).wav")
    }
}

// MARK: - Keyboard surface (mouse + computer keyboard)

/// Combined keyboard view: draws white/black keys, captures mouse
/// drags as touch events, and installs a local NSEvent monitor for the
/// piano-row keyboard layout. The monitor is installed in `onAppear`
/// and removed in `onDisappear` so it only fires while this tab is
/// visible.
private struct KeyboardSurface: View {
    @ObservedObject var simulator: IPadSimulator
    @State private var activeTouchId: Int? = nil
    @State private var lockedTouches: [LockedTouch] = []
    @State private var keyboardTouches: [UInt16: KeyHeld] = [:]
    @State private var octaveOffset: Int = 0
    @State private var keyMonitor: Any? = nil
    @State private var touchCounter: Int = 0

    struct LockedTouch: Equatable { let id: Int; let note: Int }
    struct KeyHeld { let id: Int; let note: Int }

    var body: some View {
        GeometryReader { geo in
            let nm = simulator.noteManager
            let whites = nm.scale.whiteNotesInRange()
            let whiteCount = max(1, whites.count)
            let whiteW = geo.size.width / CGFloat(whiteCount)
            let blackW = whiteW * 0.65
            let blackH = geo.size.height * 0.6

            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(0..<whiteCount, id: \.self) { i in
                    let midi = whites[i]
                    let active = nm.pitchChannels.contains {
                        $0.state != .idle && $0.targetNote == midi
                    }
                    let locked = lockedTouches.contains { $0.note == midi }
                    Rectangle()
                        .fill(whiteFill(active: active, locked: locked))
                        .frame(width: whiteW - 1, height: geo.size.height - 1)
                        .offset(x: CGFloat(i) * whiteW)
                    Text(NoteManager.noteName(for: midi))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                        .position(
                            x: CGFloat(i) * whiteW + whiteW / 2,
                            y: geo.size.height - 14
                        )
                }
                ForEach(0..<nm.noteCount, id: \.self) { i in
                    let midi = nm.startNote + i
                    if NoteManager.isBlackKey(midi) {
                        let cx = blackKeyX(midi: midi, whites: whites, whiteW: whiteW)
                        let active = nm.pitchChannels.contains {
                            $0.state != .idle && $0.targetNote == midi
                        }
                        let locked = lockedTouches.contains { $0.note == midi }
                        Rectangle()
                            .fill(blackFill(active: active, locked: locked))
                            .frame(width: blackW, height: blackH)
                            .offset(x: cx - blackW / 2)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(
                // Mouse capture lives in an NSResponder-based view so
                // every `mouseDragged` event reaches us — SwiftUI's
                // DragGesture coalesces moves and skipped most drag
                // ticks on macOS, so the iPad's drag-snap timer would
                // fire between events and pull the pitch back before
                // the next move had a chance to advance it.
                KeyboardMouseCapture(
                    onMouseDown: { point, shift in
                        let xF = max(0, min(1, point.x / geo.size.width))
                        let yF = max(0, min(1, point.y / geo.size.height))
                        mouseDown(xFraction: xF, yFraction: yF, shift: shift)
                    },
                    onMouseDragged: { point in
                        guard let id = activeTouchId else { return }
                        let xF = max(0, min(1, point.x / geo.size.width))
                        let yF = max(0, min(1, point.y / geo.size.height))
                        simulator.touchMoved(touchId: id, xFraction: xF, yFraction: yF)
                    },
                    onMouseUp: {
                        if let id = activeTouchId {
                            simulator.touchEnded(touchId: id)
                            activeTouchId = nil
                        }
                    }
                )
            )
        }
        .background(
            // Floating help text overlay so the keyboard surface
            // itself stays clean. Z/X for octave shift, hold Shift on
            // click to lock a note.
            VStack {
                HStack {
                    Text("Octave: \(octaveOffset >= 0 ? "+" : "")\(octaveOffset)  ·  Shift+click locks  ·  Z/X shifts octave")
                        .font(.system(.caption2))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                    Spacer()
                }
                Spacer()
            }
            .padding(6),
            alignment: .topLeading
        )
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Geometry

    /// Center x for a black key, matching the iPad's layout: each black
    /// key sits at the boundary between the white that comes before it
    /// (e.g. C for C#) and the next white (D for C#).
    private func blackKeyX(midi: Int, whites: [Int], whiteW: CGFloat) -> CGFloat {
        let prev = midi - 1
        if let idx = whites.firstIndex(of: prev) {
            return CGFloat(idx + 1) * whiteW
        }
        let next = midi + 1
        if let idx = whites.firstIndex(of: next) {
            return CGFloat(idx) * whiteW
        }
        return 0
    }

    private func whiteFill(active: Bool, locked: Bool) -> Color {
        if active { return Color.cyan.opacity(0.55) }
        if locked { return Color.cyan.opacity(0.25) }
        return Color(white: 0.18)
    }

    private func blackFill(active: Bool, locked: Bool) -> Color {
        if active { return Color.cyan.opacity(0.7) }
        if locked { return Color.cyan.opacity(0.4) }
        return Color(white: 0.05)
    }

    // MARK: - Mouse handlers

    private func mouseDown(xFraction: Double, yFraction: Double, shift: Bool) {
        let hit = simulator.noteManager.hitTest(xFraction: xFraction, yFraction: yFraction)
        if shift {
            // Toggle a locked finger on this note.
            if let idx = lockedTouches.firstIndex(where: { $0.note == hit.note }) {
                simulator.touchEnded(touchId: lockedTouches[idx].id)
                lockedTouches.remove(at: idx)
            } else {
                let id = nextTouchId()
                lockedTouches.append(LockedTouch(id: id, note: hit.note))
                simulator.touchBegan(touchId: id, xFraction: xFraction, yFraction: yFraction)
            }
            // Shift-click is discrete — no draggable touch.
        } else {
            let id = nextTouchId()
            activeTouchId = id
            simulator.touchBegan(touchId: id, xFraction: xFraction, yFraction: yFraction)
        }
    }

    private func nextTouchId() -> Int {
        touchCounter &+= 1
        return touchCounter
    }

    // MARK: - Keyboard handlers

    /// Lower-row + upper-row piano mapping, anchored to C4 (MIDI 60) at
    /// `octaveOffset == 0`.
    private static let keyMap: [UInt16: Int] = [
        0:  0,   // A  → C
        13: 1,   // W  → C#
        1:  2,   // S  → D
        14: 3,   // E  → D#
        2:  4,   // D  → E
        3:  5,   // F  → F
        17: 6,   // T  → F#
        5:  7,   // G  → G
        16: 8,   // Y  → G#
        4:  9,   // H  → A
        32: 10,  // U  → A#
        38: 11,  // J  → B
        40: 12,  // K  → C5
        31: 13,  // O  → C#5
        37: 14,  // L  → D5
    ]
    private static let octaveDownCode: UInt16 = 6   // Z
    private static let octaveUpCode: UInt16   = 7   // X

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            switch event.type {
            case .keyDown:
                if event.isARepeat { return event }
                if handleKeyDown(code: event.keyCode) { return nil }
            case .keyUp:
                if handleKeyUp(code: event.keyCode) { return nil }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        // Release any keys held when the tab closes — leaving them
        // pressed would leave hanging notes.
        for (_, h) in keyboardTouches {
            simulator.touchEnded(touchId: h.id)
        }
        keyboardTouches.removeAll()
    }

    private func handleKeyDown(code: UInt16) -> Bool {
        if code == Self.octaveDownCode {
            octaveOffset = max(-3, octaveOffset - 1)
            return true
        }
        if code == Self.octaveUpCode {
            octaveOffset = min(3, octaveOffset + 1)
            return true
        }
        guard let offset = Self.keyMap[code] else { return false }
        let note = 60 + offset + 12 * octaveOffset
        guard keyboardTouches[code] == nil else { return true }
        let id = nextTouchId()
        keyboardTouches[code] = KeyHeld(id: id, note: note)
        let (x, y) = locationForNote(note)
        simulator.touchBegan(touchId: id, xFraction: x, yFraction: y)
        return true
    }

    private func handleKeyUp(code: UInt16) -> Bool {
        guard let held = keyboardTouches.removeValue(forKey: code) else { return false }
        simulator.touchEnded(touchId: held.id)
        return true
    }

    private func locationForNote(_ note: Int) -> (Double, Double) {
        let nm = simulator.noteManager
        let whites = nm.scale.whiteNotesInRange()
        guard !whites.isEmpty else { return (0.5, 0.5) }
        let count = Double(whites.count)
        if !Scale.isBlackKey(note), let idx = whites.firstIndex(of: note) {
            return ((Double(idx) + 0.5) / count, 0.8)
        }
        let prev = note - 1
        if let idx = whites.firstIndex(of: prev) {
            return (Double(idx + 1) / count, 0.3)
        }
        // Note out of range — clamp to a safe spot.
        let semi = Double(note - nm.startNote) / Double(max(1, nm.noteCount))
        return (max(0, min(1, semi)), 0.5)
    }
}

// MARK: - NSResponder-backed mouse capture

/// NSView subclass that delivers every `mouseDragged` event in the
/// AppKit responder chain. SwiftUI's `DragGesture` on macOS coalesces
/// drag updates and intermittently skipped events on this surface,
/// which let the iPad NoteManager's 60ms drag-snap timer fire between
/// drags and yank the pitch back to the start note. Capturing the
/// events at the NSResponder level guarantees a tick-per-move stream
/// that keeps the drag-snap timer cancelled and lets the glide chase
/// the cursor smoothly.
private struct KeyboardMouseCapture: NSViewRepresentable {
    let onMouseDown: (CGPoint, Bool) -> Void   // shift held?
    let onMouseDragged: (CGPoint) -> Void
    let onMouseUp: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
    }

    final class CaptureView: NSView {
        var onMouseDown: ((CGPoint, Bool) -> Void)?
        var onMouseDragged: ((CGPoint) -> Void)?
        var onMouseUp: (() -> Void)?

        /// Top-left origin so AppKit coordinates match SwiftUI's
        /// (and the iPad's xFraction/yFraction convention).
        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let shift = event.modifierFlags.contains(.shift)
            onMouseDown?(loc, shift)
        }

        override func mouseDragged(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            onMouseDragged?(loc)
        }

        override func mouseUp(with event: NSEvent) {
            onMouseUp?()
        }
    }
}
