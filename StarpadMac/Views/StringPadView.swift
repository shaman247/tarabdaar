import AppKit
import StarpadCore
import SwiftUI
import UniformTypeIdentifiers

/// The **String Pad** tab — a third 2D playing surface, a box-plot / abacus.
/// Discrete vertical **strings** (columns) hold stacked **notes**: each note is
/// a single **hexagon** (rectangular middle with a fixed-length tip top/bottom)
/// with **constant pitch throughout** and a sargam **name** (S r R g G m M P d D
/// n N). A note's pitch is a **scale degree** of the shared Pitch Pad scale (+ an
/// octave), looked up live, so re-tuning the scale retunes the pad.
///
/// **Strings repeat across octaves**: the editable base strings sit in the
/// centre, with `ghostStringsPerSide` read-only octave-repeat strings on each
/// side, continuing the ascending svara sequence into the octave below (left)
/// and above (right). Pitch is **continuous everywhere** between hexagons
/// (inverse-distance, `polyPitchAt`). Reuses `controller.stringPad` (a third
/// `PitchPadEngine`) as the MPE emitter and reads the scale + tonic from
/// `controller.pitchPad`. Mac-only; no iPad view, no sync. See
/// [docs/string-pad.md](../../docs/string-pad.md).
struct StringPadView: View {
    @ObservedObject var controller: AppController
    /// The MPE emitter (the `stringPad` engine). Owns velocity / sharpness /
    /// `sounding`; its own `scale` is unused here.
    @ObservedObject var engine: PitchPadEngine
    /// The shared scale + tonic source (read-only here; edit on the Pitch Pad).
    @ObservedObject var pitchPad: PitchPadEngine

    init(controller: AppController) {
        self.controller = controller
        self.engine = controller.stringPad
        self.pitchPad = controller.pitchPad
    }

    /// The scale's enabled degrees, low→high, the notes draw their pitch from.
    private var degrees: [(ratio: Double, label: String)] {
        scaleDegrees(from: pitchPad.scale)
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                StringPadSurface(engine: engine,
                                 arrangement: $controller.stringArrangement,
                                 degrees: degrees,
                                 tonicMidi: pitchPad.tonicMidi)
                    .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StringPadEditor(arrangement: $controller.stringArrangement,
                                degrees: degrees)
                    .frame(width: 280)
            }
            footer
        }
        .padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            Button("Reset to Scale") {
                controller.stringArrangement =
                    .defaultArrangement(degreeCount: degrees.count)
            }
            .help("Rebuild the default 7-string sargam arrangement (S · R/r · G/g · m/M · P · D/d · N/n).")
            octaveControl
            Toggle("Perform", isOn: $engine.performanceMode)
                .toggleStyle(.button)
                .help("Clean playing surface: editing off, gridlines + labels hidden, octave-repeat strings shown identically to the editable ones.")
            Spacer()
            StringSoundingReadout(sounding: engine.sounding,
                                  tonicMidi: pitchPad.tonicMidi)
            sharpnessControl
            velocityControl
            tonicReadout
        }
    }

    /// How many octave-repeat (ghost) strings to show on each side.
    private var octaveControl: some View {
        HStack(spacing: 4) {
            Text("Octave ±").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Stepper(value: $controller.stringArrangement.ghostStringsPerSide,
                    in: 0...14) {
                Text("\(controller.stringArrangement.ghostStringsPerSide)")
                    .font(.system(.caption).monospacedDigit())
                    .frame(width: 16, alignment: .trailing)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .help("Number of octave-repeat strings shown on each side of the editable strings (read-only copies, octave-shifted).")
    }

    private var velocityControl: some View {
        HStack(spacing: 6) {
            Text("Velocity").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(
                value: Binding(
                    get: { Double(engine.velocity) },
                    set: { engine.velocity = Int($0.rounded()) }
                ),
                in: 1...127
            )
            .frame(width: 90)
            Text("\(engine.velocity)")
                .font(.system(.caption))
                .frame(width: 28, alignment: .trailing)
        }
    }

    /// Inverse-distance blend power (continuous everywhere — see `polyPitchAt`),
    /// backed by `engine.marginPixels` (0–64).
    private var sharpnessControl: some View {
        HStack(spacing: 6) {
            Text("Sharpness").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: $engine.marginPixels, in: 0...64)
                .frame(width: 80)
            Text(String(format: "%.1f", 1 + engine.marginPixels * 7 / 64))
                .font(.system(.caption))
                .frame(width: 28, alignment: .trailing)
        }
        .help("How sharply pitch locks to the nearest note vs. blends between them (inverse-distance power). Higher = sharper; lower = smoother. Pitch is continuous everywhere — no hard edges.")
    }

    /// Tonic is owned by the Pitch Pad scale state, so it's read-only here.
    private var tonicReadout: some View {
        HStack(spacing: 6) {
            Text("Tonic").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("\(pitchPad.tonicMidi) (\(Scale.noteName(for: pitchPad.tonicMidi)))")
                .font(.system(.caption))
                .lineLimit(1)
        }
        .help("Set on the Pitch Pad tab.")
    }

    private var footer: some View {
        HStack {
            Text(engine.performanceMode
                 ? "Perform: click / drag anywhere to play (glides between notes). Faint side strings are octave repeats."
                 : "Edit: drag a note = move  ·  drag its edge = resize  ·  drag empty space = play  ·  Shift-click = add  ·  Right-click = delete  ·  Faint side strings are octave repeats (read-only)")
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Sounding readout

/// Live frequency / nearest-note / cents readout for the active touch, tinted in
/// the pitch's hue. Observes only `SoundingState`, so per-tick glide updates
/// re-render this capsule alone.
private struct StringSoundingReadout: View {
    @ObservedObject var sounding: SoundingState
    let tonicMidi: Int

    var body: some View {
        let ratio = sounding.ratio
        let text: String = ratio.map { r in
            let fractionalMidi = Double(tonicMidi) + 12.0 * log2(r)
            let freq = 440.0 * pow(2.0, (fractionalMidi - 69.0) / 12.0)
            let nearest = Int(fractionalMidi.rounded())
            let cents = Int(((fractionalMidi - Double(nearest)) * 100.0).rounded())
            let hz = freq >= 1000 ? String(format: "%.0f", freq)
                                  : String(format: "%.1f", freq)
            let centsStr = cents > 0 ? "+\(cents)¢" : "\(cents)¢"
            return "\(hz) Hz (\(Scale.noteName(for: nearest)) \(centsStr))"
        } ?? "000.0 Hz"
        let color: Color = ratio.map {
            pitchColor(forRatio: $0, lightness: 0.85, chroma: 0.18)
        } ?? .clear
        return Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(Color(white: 0.12).opacity(ratio == nil ? 0 : 1)))
            .opacity(ratio == nil ? 0 : 1)
            .fixedSize()
    }
}

// MARK: - Pad surface

private struct StringPadSurface: View {
    @ObservedObject var engine: PitchPadEngine
    @Binding var arrangement: StringArrangement
    let degrees: [(ratio: Double, label: String)]
    let tonicMidi: Int

    @State private var activeTouchId: Int? = nil
    @State private var touchCounter: Int = 0
    /// The note being edited (moved or resized), and which edge if resizing.
    @State private var editGrab: StringGrab = .none
    /// Pixel delta (note centre − click) captured at mouse-down for a move.
    @State private var moveOffset: CGPoint = .zero

    private let edgePad: CGFloat = 16
    private let handleHitRadius: CGFloat = 9
    private let minHeight: Double = 0.02

    /// Inverse-distance blend power, mapped from the Sharpness slider.
    private var blendPower: Double { 1.0 + Double(engine.marginPixels) * 7.0 / 64.0 }

    /// Hexagon width in pixels — a fraction of the per-column spacing, so the
    /// columns never overlap however many octave-repeats are shown.
    private func boxWidth(_ width: CGFloat, columns T: Int) -> CGFloat {
        min(width / CGFloat(max(1, T)) * 0.72, 120)
    }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            let T = max(1, arrangement.totalColumns)
            let bw = boxWidth(size.width, columns: T)
            let columns = stringColumns(arrangement, width: size.width)
            // All placements (base + octave-repeat ghosts). `body` does NOT
            // re-run during a glide (fills live on the separate `SoundingState`).
            let placements = stringPlacements(arrangement: arrangement,
                                              degrees: degrees,
                                              size: size, boxWidth: bw)
            let basePlacements = placements.filter { !$0.isGhost }
            // Perform mode: a clean playing surface — no gridlines, no labels,
            // and the octave-repeat ghosts styled identically to the editable
            // strings.
            let perform = engine.performanceMode

            ZStack(alignment: .topLeading) {
                Color.black

                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)

                    // Vertical "wires" for every column (hidden in perform).
                    if !perform {
                        for col in columns {
                            var line = Path()
                            line.move(to: CGPoint(x: col.x, y: 0))
                            line.addLine(to: CGPoint(x: col.x, y: size.height))
                            ctx.stroke(line,
                                       with: .color(.white.opacity(col.isGhost ? 0.05 : 0.12)),
                                       lineWidth: 1)
                        }
                    }

                    for p in placements {
                        let dim = !perform && p.isGhost
                        let hue = pitchColor(forRatio: p.ratio, lightness: 0.82,
                                             chroma: 0.20).opacity(dim ? 0.4 : 1.0)
                        ctx.stroke(Path(closedPolygon: stringShapePolygon(p)),
                                   with: .color(hue),
                                   lineWidth: dim ? 1.5 : 2)
                        if !perform {
                            ctx.draw(
                                Text(p.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(p.isGhost ? 0.5 : 1.0)),
                                at: CGPoint(x: p.columnX, y: p.rect.midY))
                        }
                    }
                }

                // Dynamic layer: live sounding fills (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: stringFillCells(placements),
                              edgePad: edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                StringPadMouseCapture(
                    onMouseDown: { pt in
                        handleDown(at: toLocal(pt), placements: placements,
                                   base: basePlacements, size: size)
                    },
                    onMouseDragged: { pt in
                        handleDrag(at: toLocal(pt), placements: placements, size: size)
                    },
                    onMouseUp: { handleUp() },
                    onRightMouseDown: { pt in
                        handleRightDown(at: toLocal(pt), base: basePlacements)
                    }
                )
            )
        }
    }

    // MARK: Interactions

    private func handleDown(at pt: CGPoint, placements: [StringPlacement],
                            base: [StringPlacement], size: CGSize) {
        // Perform mode: play only (no editing). Anywhere on the surface.
        if engine.performanceMode {
            playAt(pt, placements: placements)
            return
        }

        // Edit mode: editing is always on (no modifier needed).
        let shift = NSEvent.modifierFlags.contains(.shift)
        let grab = stringGrab(at: pt, placements: base, handleRadius: handleHitRadius)

        // Shift on empty space → add a note on the nearest base string.
        if shift, grab == .none {
            addNote(at: pt, size: size)
            return
        }

        // On a note → move / resize.
        if grab != .none {
            editGrab = grab
            if case .move(let id) = grab,
               let p = base.first(where: { $0.noteID == id }) {
                moveOffset = CGPoint(x: p.columnX - pt.x, y: p.rect.midY - pt.y)
            }
            if let ratio = grabbedRatio(grab, placements: base) {
                beginSounding(id: grabbedID(grab), ratio: ratio)
            }
            return
        }

        // Empty space → play (so you can hear while arranging).
        playAt(pt, placements: placements)
    }

    /// Sound the pitch resolved at `pt` (base + ghost hexagons; ghosts sound
    /// octave-shifted).
    private func playAt(_ pt: CGPoint, placements: [StringPlacement]) {
        guard let hit = polyPitchAt(point: pt,
                                    cells: stringResolverCells(placements),
                                    power: blendPower) else { return }
        beginSounding(weights: hit.weights, ratio: hit.ratio)
    }

    private func handleDrag(at pt: CGPoint, placements: [StringPlacement],
                            size: CGSize) {
        switch editGrab {
        case .move(let id):
            guard let idx = noteIndex(id) else { return }
            arrangement.notes[idx].stringIndex = nearestBaseString(
                toX: pt.x + moveOffset.x, arrangement: arrangement, width: size.width)
            arrangement.notes[idx].centerY = clamp01(Double((pt.y + moveOffset.y) / size.height))
            return
        case .resizeTop(let id):
            guard let idx = noteIndex(id) else { return }
            let note = arrangement.notes[idx]
            let bottom = note.bottomY
            let newTop = min(clamp01(Double(pt.y / size.height)), bottom - minHeight)
            arrangement.notes[idx].height = bottom - newTop
            arrangement.notes[idx].centerY = (newTop + bottom) / 2
            return
        case .resizeBottom(let id):
            guard let idx = noteIndex(id) else { return }
            let note = arrangement.notes[idx]
            let top = note.topY
            let newBottom = max(clamp01(Double(pt.y / size.height)), top + minHeight)
            arrangement.notes[idx].height = newBottom - top
            arrangement.notes[idx].centerY = (top + newBottom) / 2
            return
        case .none:
            break
        }
        // Playing.
        guard let touch = activeTouchId,
              let hit = polyPitchAt(point: pt,
                                    cells: stringResolverCells(placements),
                                    power: blendPower) else { return }
        engine.glide(touchId: touch, ratio: hit.ratio, weights: hit.weights)
    }

    private func handleUp() {
        if let touch = activeTouchId { engine.noteOff(touchId: touch) }
        activeTouchId = nil
        editGrab = .none
        moveOffset = .zero
    }

    /// Right-click deletes a (base) note. Disabled in perform mode.
    private func handleRightDown(at pt: CGPoint, base: [StringPlacement]) {
        if engine.performanceMode { return }
        let grab = stringGrab(at: pt, placements: base, handleRadius: handleHitRadius)
        let id: UUID?
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): id = i
        case .none: id = nil
        }
        guard let noteID = id, let idx = noteIndex(noteID) else { return }
        arrangement.notes.remove(at: idx)
    }

    private func addNote(at pt: CGPoint, size: CGSize) {
        guard !degrees.isEmpty, arrangement.stringCount > 0 else { return }
        let si = nearestBaseString(toX: pt.x, arrangement: arrangement, width: size.width)
        let centerY = clamp01(Double(pt.y / size.height))
        // Pitch: borrow the nearest existing note's degree/octave, else lowest.
        let nearest = arrangement.notes
            .filter(\.enabled)
            .min { abs($0.centerY - centerY) < abs($1.centerY - centerY) }
        let degreeIndex = nearest.map { min($0.degreeIndex, degrees.count - 1) } ?? 0
        arrangement.notes.append(StringNote(degreeIndex: max(0, degreeIndex),
                                            octave: nearest?.octave ?? 0,
                                            stringIndex: si, centerY: centerY,
                                            height: nearest?.height ?? 0.3))
    }

    // MARK: Helpers

    private func beginSounding(weights: [String: Double], ratio: Double) {
        let touch = nextTouchId()
        activeTouchId = touch
        engine.noteOn(touchId: touch, ratio: ratio, weights: weights)
    }

    private func beginSounding(id: String?, ratio: Double) {
        beginSounding(weights: id.map { [$0: 1.0] } ?? [:], ratio: ratio)
    }

    private func grabbedID(_ grab: StringGrab) -> String? {
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): return i.uuidString
        case .none: return nil
        }
    }

    private func grabbedRatio(_ grab: StringGrab,
                              placements: [StringPlacement]) -> Double? {
        let id: UUID?
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): id = i
        case .none: id = nil
        }
        return id.flatMap { nid in placements.first { $0.noteID == nid }?.ratio }
    }

    private func noteIndex(_ id: UUID) -> Int? {
        arrangement.notes.firstIndex(where: { $0.id == id })
    }

    private func toLocal(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x - edgePad, y: pt.y - edgePad)
    }

    private func nextTouchId() -> Int {
        touchCounter &+= 1
        return touchCounter
    }
}

// MARK: - Editor

/// Groups the notes **by string** (column), one card per editable base string
/// (shown even if empty). A note is moved to another string by dragging its grip
/// handle onto that string's card (`.onDrop` reassigns its `stringIndex`).
private struct StringPadEditor: View {
    @Binding var arrangement: StringArrangement
    let degrees: [(ratio: Double, label: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Strings (\(arrangement.stringCount))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { arrangement.stringCount += 1 } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a new string on the right.")
            }
            Divider()
            if degrees.isEmpty {
                Text("No scale — add pitches on the Pitch Pad tab.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<max(0, arrangement.stringCount), id: \.self) { i in
                        sectionCard(index: i)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08)))
    }

    private func noteIDs(forString i: Int) -> [UUID] {
        arrangement.notes
            .filter { $0.stringIndex == i }
            .sorted { $0.centerY < $1.centerY }
            .map(\.id)
    }

    @ViewBuilder
    private func sectionCard(index i: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("String \(i + 1)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Button { addNote(toString: i) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Add a note to this string.")
                if arrangement.stringCount > 1 {
                    Button { deleteString(i) } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this string.")
                }
            }
            ForEach(noteIDs(forString: i), id: \.self) { id in
                StringEditorRow(arrangement: $arrangement, noteID: id, degrees: degrees)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.12)))
        .onDrop(of: [.plainText], isTargeted: nil) { receive($0, toString: i) }
    }

    /// Receive a note dragged from another string's card: set its `stringIndex`.
    private func receive(_ providers: [NSItemProvider], toString i: Int) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let uuid = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                if let idx = arrangement.notes.firstIndex(where: { $0.id == uuid }) {
                    arrangement.notes[idx].stringIndex = i
                }
            }
        }
        return true
    }

    private func addNote(toString i: Int) {
        arrangement.notes.append(StringNote(degreeIndex: 0, stringIndex: i,
                                            centerY: 0.5, height: 0.3))
    }

    /// Remove string `i` and shift higher strings down.
    private func deleteString(_ i: Int) {
        guard arrangement.stringCount > 1 else { return }
        arrangement.notes.removeAll { $0.stringIndex == i }
        for idx in arrangement.notes.indices where arrangement.notes[idx].stringIndex > i {
            arrangement.notes[idx].stringIndex -= 1
        }
        arrangement.stringCount -= 1
    }
}

private struct StringEditorRow: View {
    @Binding var arrangement: StringArrangement
    let noteID: UUID
    let degrees: [(ratio: Double, label: String)]

    private var index: Int? {
        arrangement.notes.firstIndex(where: { $0.id == noteID })
    }

    var body: some View {
        if let idx = index {
            row(note: arrangement.notes[idx], idx: idx)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func row(note: StringNote, idx: Int) -> some View {
        HStack(spacing: 4) {
            // Grip — drag onto another string's card to move the note there.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .onDrag { NSItemProvider(object: noteID.uuidString as NSString) }

            // Colored chip = enable/disable toggle.
            Button {
                arrangement.notes[idx].enabled.toggle()
            } label: {
                let hue = noteRatio(note, degrees: degrees).map {
                    pitchColor(forRatio: $0, lightness: 0.68, chroma: 0.15)
                } ?? .gray
                Circle()
                    .fill(note.enabled ? hue : .clear)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(
                        note.enabled ? Color.black.opacity(0.7) : hue,
                        lineWidth: note.enabled ? 1 : 2))
            }
            .buttonStyle(.plain)
            .help(note.enabled ? "Disable" : "Enable")

            // Sargam name (e.g. "S", "r", "M", "S'").
            Text(noteName(note, degrees: degrees))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 26, alignment: .leading)

            // Note picker (sargam; the scale's own label shown alongside).
            Menu {
                ForEach(Array(degrees.enumerated()), id: \.offset) { i, deg in
                    Button("\(degreeSargam(deg))  (\(deg.label))") {
                        arrangement.notes[idx].degreeIndex = i
                    }
                }
            } label: {
                Image(systemName: "pencil").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Octave stepper.
            Stepper(value: Binding(
                get: { arrangement.notes.indices.contains(idx)
                       ? arrangement.notes[idx].octave : 0 },
                set: { if arrangement.notes.indices.contains(idx) {
                    arrangement.notes[idx].octave = max(-3, min(3, $0)) } }
            ), in: -3...3) {
                Text(octaveLabel(note.octave))
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 18, alignment: .trailing)
            }
            .controlSize(.mini)
            .fixedSize()

            Spacer(minLength: 0)

            Button {
                if let i = index { arrangement.notes.remove(at: i) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .opacity(note.enabled ? 1 : 0.55)
    }

    private func octaveLabel(_ o: Int) -> String {
        o == 0 ? "0" : (o > 0 ? "+\(o)" : "\(o)")
    }
}

// MARK: - Mouse capture (mirrors PadMouseCapture in PitchPadView)

/// AppKit-backed mouse capture so drag events arrive at full resolution
/// (SwiftUI's `DragGesture` coalesces moves on macOS, making a glide stutter).
/// Reports left press/drag/up plus right-click; modifier state is read from
/// `NSEvent.modifierFlags` in the handlers.
private struct StringPadMouseCapture: NSViewRepresentable {
    let onMouseDown: (CGPoint) -> Void
    let onMouseDragged: (CGPoint) -> Void
    let onMouseUp: () -> Void
    let onRightMouseDown: (CGPoint) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onRightMouseDown = onRightMouseDown
        return v
    }

    func updateNSView(_ v: CaptureView, context: Context) {
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onRightMouseDown = onRightMouseDown
    }

    final class CaptureView: NSView {
        var onMouseDown: ((CGPoint) -> Void)?
        var onMouseDragged: ((CGPoint) -> Void)?
        var onMouseUp: (() -> Void)?
        var onRightMouseDown: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            onMouseDragged?(convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            onMouseUp?()
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightMouseDown?(convert(event.locationInWindow, from: nil))
        }
    }
}

// MARK: - Local helpers

private func clamp01(_ x: Double) -> Double { min(max(0, x), 1) }
