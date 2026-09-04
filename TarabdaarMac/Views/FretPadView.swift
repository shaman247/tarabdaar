import AppKit
import Combine
import QuartzCore
import TarabdaarCore
import SwiftUI

/// The **Fret Pad** tab — the playing surface: freely positioned vertical
/// **frets** over a continuous pitch **field** (`fretFieldLog`). A touch
/// starting within the Snap distance of a fret and inside its extent snaps to
/// it; elsewhere it plays the field pitch; drags are continuous (field plus
/// the onset offset). Editing: drag an endpoint to set the extent, drag the
/// line to move, shift-click to add on the nearest degree, right-click to
/// delete. Plays through `controller.fretPad`, reads the scale + tonic from
/// `controller.pitchPad`; the arrangement syncs to the iPad's `FretPadViewIOS`
/// as the `FRET_ARRANGEMENT` TLP event. See [docs/fret-pad.md](../../docs/fret-pad.md).
struct FretPadView: View {
    @ObservedObject var controller: AppController
    /// The note emitter (`fretPad`): velocity, `marginPixels`, `sounding`.
    @ObservedObject var engine: PitchPadEngine
    /// The scale + tonic source, edited on this tab.
    @ObservedObject var pitchPad: PitchPadEngine
    /// Records play strokes for offline assist fitting (`tools/fretpad_fit.py`).
    @StateObject private var recorder = FretGestureRecorder()
    /// Drives the "Save As…" name prompt for the scale menu.
    @State private var showingSaveDialog = false
    @State private var saveName = ""
    /// The same, for the fret-layout menu.
    @State private var showingLayoutSaveDialog = false
    @State private var layoutSaveName = ""

    init(controller: AppController) {
        self.controller = controller
        self.engine = controller.fretPad
        self.pitchPad = controller.pitchPad
    }

    /// The scale's enabled degrees, low→high, the frets draw their pitch from.
    private var degrees: [(ratio: Double, label: String)] {
        scaleDegrees(from: pitchPad.scale)
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                FretPadSurface(engine: engine,
                               arrangement: $controller.fretArrangement,
                               degrees: degrees,
                               warp: controller.fretFieldWarp,
                               recorder: recorder,
                               joyCon: controller.joyCon,
                               chordActive: controller.strumChord,
                               onChordTap: { controller.tapChord($0) })
                    .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scale list editor — edits `pitchPad.scale`, which the
                // frets and the whole app read from.
                if !engine.performanceMode {
                    ScaleListEditor(engine: pitchPad)
                        .frame(width: 280)
                }
            }
            footer
        }
        .padding(12)
        .alert("Save Scale", isPresented: $showingSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = saveName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != ScaleStore.defaultName else { return }
                pitchPad.saveScale(name: trimmed)
            }
        } message: {
            Text("Enter a name for this scale.")
        }
        .alert("Save Fret Layout", isPresented: $showingLayoutSaveDialog) {
            TextField("Name", text: $layoutSaveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { controller.saveFretLayout(name: layoutSaveName) }
        } message: {
            Text("Enter a name for this fret layout (positions and snap "
                 + "zones — the scale is saved separately).")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            scaleMenu
            layoutMenu
            Button("Reset to Scale") {
                controller.loadFretLayout(preset: .keyboard)
            }
            .help("Rebuild the default fret layout (C Keyboard) from the current scale: 7 evenly-spaced svara columns, komal/tivra stacked above their shuddha partner — a piano keyboard's key spacing.")
            octaveControl
            Toggle("Perform", isOn: $engine.performanceMode)
                .toggleStyle(.button)
                .help("Clean playing surface: editing off, octave gridlines + labels + endpoint handles hidden, octave-repeat frets shown identically to the editable ones, and the scale editor hidden.")
            recordControl
            Spacer()
            SoundingReadout(sounding: engine.sounding,
                            tonicFractionalMidi: pitchPad.tonicFractionalMidi,
                            style: .capsule)
            snapControl
            warpControl
            velocityControl
            primeLimitControl
            tonicControl
        }
    }

    /// Save / load / delete scales + built-in presets, editing `pitchPad.scale`.
    private var scaleMenu: some View {
        Menu {
            Button("Save As…") {
                saveName = pitchPad.currentScaleName ?? ""
                showingSaveDialog = true
            }
            if let name = pitchPad.currentScaleName {
                Button("Save “\(name)”") { pitchPad.saveScale(name: name) }
            }
            Divider()
            // Full factory reset: the default scale AND the C Keyboard layout.
            Button("Reset to Default") {
                pitchPad.resetToDefault()
                controller.loadFretLayout(preset: .keyboard)
            }
            Menu("Scales") {
                ForEach(ScalePreset.allCases) { preset in
                    Button(preset.label) { pitchPad.loadPreset(preset) }
                }
            }

            let saved = ScaleStore.savedScaleNames()
            if !saved.isEmpty {
                Divider()
                Section("Load") {
                    ForEach(saved, id: \.self) { name in
                        Button {
                            pitchPad.loadScale(name: name)
                        } label: {
                            if pitchPad.currentScaleName == name {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(saved, id: \.self) { name in
                        Button(name, role: .destructive) { pitchPad.deleteScale(name: name) }
                    }
                }
            }
        } label: {
            Label(pitchPad.currentScaleName ?? "Scale", systemImage: "music.note.list")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Save / load / delete fret layouts (`controller.fretArrangement`) —
    /// state separate from the scale; built-ins rebuild from the loaded scale.
    private var layoutMenu: some View {
        Menu {
            Button("Save As…") {
                layoutSaveName = controller.fretLayoutName ?? ""
                showingLayoutSaveDialog = true
            }
            if let name = controller.fretLayoutName {
                Button("Save “\(name)”") { controller.saveFretLayout(name: name) }
            }
            Divider()
            Menu("Built-in") {
                ForEach(FretLayoutPreset.allCases) { preset in
                    Button(preset.label) { controller.loadFretLayout(preset: preset) }
                        .help(preset.summary)
                }
            }

            let saved = FretArrangementStore.savedNames()
            if !saved.isEmpty {
                Divider()
                Section("Load") {
                    ForEach(saved, id: \.self) { name in
                        Button {
                            controller.loadFretLayout(name: name)
                        } label: {
                            if controller.fretLayoutName == name {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(saved, id: \.self) { name in
                        Button(name, role: .destructive) {
                            controller.deleteFretLayout(name: name)
                        }
                    }
                }
            }
        } label: {
            Label(controller.fretLayoutName ?? "Layout",
                  systemImage: "rectangle.split.3x1")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fret layouts: save the current fret positions under a name, load a saved one, or start from a built-in (C Equal Freq / C Keyboard). Layouts are independent of the scale — a layout loads onto whatever scale is active.")
    }

    /// Prime-limit cap for the scale editor's scroll-stepping snap targets.
    private var primeLimitControl: some View {
        HStack(spacing: 4) {
            Text("Prime ≤").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)
            Picker("", selection: $pitchPad.primeLimit) {
                ForEach([2, 3, 5, 7, 11, 13, 17, 19, 23], id: \.self) { p in
                    Text("\(p)").tag(p)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 56)
        }
        .help("Prime-limit cap for the scale editor's scroll-to-next-gridline snap targets.")
    }

    /// Flank past the base band each side, in band-widths.
    private var octaveControl: some View {
        HStack(spacing: 4) {
            Text("Octave ±").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)
            Stepper(value: $controller.fretArrangement.ghostExtentOctaves,
                    in: 0...2, step: 0.25) {
                Text(String(format: "%.2f", controller.fretArrangement.ghostExtentOctaves))
                    .font(.padCaption.monospacedDigit())
                    .frame(width: Typography.scaledWidth(30), alignment: .trailing)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .help("How far the surface extends past the base fret layout on each side, in band-widths (read-only octave-repeat copies of the whole layout). 0.5 = half a band of flank each side.")
    }

    /// Record play strokes to JSONL for offline assist fitting.
    private var recordControl: some View {
        Toggle(isOn: Binding(get: { recorder.isRecording },
                             set: { recorder.setRecording($0) })) {
            HStack(spacing: 4) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(recorder.isRecording ? "Rec \(recorder.strokeCount)" : "Rec")
                    .font(.padCaption.monospacedDigit())
            }
        }
        .toggleStyle(.button)
        .help("Record play strokes (raw movements + fret context) to Application Support/Tarabdaar/FretRecordings/ as JSONL, for fitting the drag-assist parameters to your real playing (tools/fretpad_fit.py). Play naturally: glides into stops, direction changes near notes, vibrato, fast runs.")
    }

    /// Horizontal onset-snap distance in px (`engine.marginPixels`); 0 = fretless.
    private var snapControl: some View {
        ParamSliderRow(label: "Snap", value: $engine.marginPixels,
                       range: 0...64,
                       readout: "\(Int(engine.marginPixels.rounded())) px",
                       spacing: 6, sliderWidth: 80,
                       readoutFont: .padCaption.monospacedDigit(),
                       readoutWidth: Typography.scaledWidth(36))
        .help("How close (horizontally) a touch must start to a fret to snap to its pitch. Only applies within the fret's vertical extent, and only at touch onset — drags glide continuously. 0 = fretless.")
    }

    /// `ctl_fret_warp` (bindable, relayed to the iPad): the slider edits the
    /// RESTING value; a binding's output rides on top.
    private var warpControl: some View {
        ParamSliderRow(
            label: "Warp",
            value: Binding(
                get: { controller.paramValue("ctl_fret_warp") },
                set: { controller.setParamValue("ctl_fret_warp", $0) }),
            range: 0...1,
            readout: "\(Int((controller.fretFieldWarp * 100).rounded())) %",
            spacing: 6, sliderWidth: 80,
            readoutFont: .padCaption.monospacedDigit(),
            readoutWidth: Typography.scaledWidth(36))
        .help("How strongly the frets warp the pitch space around them (the ctl_fret_warp parameter — also on the Parameters tab, bindable to a tilt/stick axis for live morphing): 0 = linear (pitch moves at a constant rate between frets); higher = pitch plateaus near each fret and transitions quickly through the middle, so a straight slide between two frets traces a logistic curve. The readout shows the LIVE value (binding included). Out of Perform mode the contour lines show the resulting territories.")
    }

    private var velocityControl: some View {
        ParamSliderRow(
            label: "Velocity",
            value: Binding(
                get: { Double(engine.velocity) },
                set: { engine.velocity = Int($0.rounded()) }),
            range: 1...127,
            readout: "\(engine.velocity)",
            spacing: 6, sliderWidth: 90,
            readoutWidth: Typography.scaledWidth(28))
    }

    /// The tonic, edited here only: **Hz** (the app's one absolute pitch) and
    /// **Note** (a menu within half an octave, keeping the cents offset). The
    /// Hz field is a plain `TextField` — a scroll-wheel `ScrollableField`
    /// crashes the app here; do not add scroll-stepping.
    private var tonicControl: some View {
        HStack(spacing: 6) {
            Text("Tonic").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)

            TextField("", value: Binding(
                get: { pitchPad.tonicHz },
                set: { pitchPad.setTonic(hz: $0) }
            ), format: .number.precision(.fractionLength(0...2)))
                .frame(width: Typography.scaledWidth(64))
                .textFieldStyle(.roundedBorder).font(.padCaption)
                .help("Tonic frequency in Hz — the app's one absolute pitch; everything else is relative to it.")

            Picker("", selection: Binding(
                get: { pitchPad.tonicMidi },
                set: { pitchPad.setTonic(midi: $0) }
            )) {
                ForEach(tonicNoteChoices, id: \.self) { m in
                    Text(Scale.noteName(for: m)).tag(m)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: Typography.scaledWidth(64))
            .help("Tonic note — the notes within half an octave of the current one, which re-centers on each pick. The cents offset is kept, so a fine tuning survives a change of note.")

            Text(tonicCentsLabel)
                .font(.padCaption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Typography.scaledWidth(44), alignment: .leading)
                .lineLimit(1)
        }
    }

    /// A tritone either side of the current tonic, clipped to `tonicNoteRange`
    /// — deliberately short; the Hz field covers anything further.
    private var tonicNoteChoices: [Int] {
        let lo = max(PitchPadEngine.tonicNoteRange.lowerBound, pitchPad.tonicMidi - 6)
        let hi = min(PitchPadEngine.tonicNoteRange.upperBound, pitchPad.tonicMidi + 6)
        return Array(lo...hi)
    }

    /// "+12.0¢" — the tonic's offset from its note anchor, blank when exact.
    private var tonicCentsLabel: String {
        let c = pitchPad.tonicCents
        return abs(c) < 0.05 ? "" : String(format: "%+.1f¢", c)
    }

    private var footer: some View {
        HStack {
            Text(engine.performanceMode
                 ? "Perform: start on a fret (inside its height) to snap to its pitch; start elsewhere to approach the note freely (pitch interpolates between frets). Drags always glide continuously."
                 : "Edit: drag a fret = move (any direction)  ·  drag an endpoint = set its extent  ·  drag empty space = play  ·  Shift-click = add a fret  ·  Right-click = delete  ·  Faint frets are octave repeats (read-only)")
                .font(.padCaption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Pad surface

private struct FretPadSurface: View {
    @ObservedObject var engine: PitchPadEngine
    @Binding var arrangement: FretArrangement
    let degrees: [(ratio: Double, label: String)]
    /// The LIVE fret warp (`controller.fretFieldWarp`, binding included).
    let warp: Double
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder
    /// NOT `@ObservedObject` (stick axes publish at input rate); only
    /// `$connectedName` is tapped via `onReceive`.
    let joyCon: JoyConInput
    /// The active strum chord and the chord bar's tap route.
    let chordActive: ChordSelection?
    let onChordTap: (ChordSelection) -> Void

    /// While a Joy-Con is attached its arrows pluck the drones, so the
    /// on-screen buttons hide (visual + hit-test).
    @State private var joyConConnected = false

    @State private var activeTouchId: Int? = nil
    @State private var touchCounter: Int = 0
    /// The segment being edited (moved or resized), and which endpoint.
    @State private var editGrab: FretGrab = .none
    /// Pixel delta (segment x/mid-y − click) captured at mouse-down for a move.
    @State private var moveOffsetX: CGFloat = 0
    @State private var moveOffsetY: CGFloat = 0
    /// The touch pipeline (onset, drag, settle tick, release).
    @State private var player = FretTouchPlayer()
    /// Drone button currently held (hit-tested in `handleDown`).
    @State private var droneDown: Int? = nil

    private let edgePad: CGFloat = 16
    private let handleHitRadius: CGFloat = 9
    private let minHeight: Double = 0.02

    /// Horizontal onset-snap half-width in pixels (the Snap slider).
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space (the iPad's too).
            let band = fretPadBandRect(in: size)
            // `body` does NOT re-run during a glide (fills live on `SoundingState`).
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: band.size)
            let basePlacements = placements.filter { !$0.isGhost }
            let chordCells = chordBarCells(arrangement: arrangement,
                                           degrees: degrees,
                                           chords: scaleChords(degrees: degrees),
                                           size: size)
            // Perform mode: no gridlines, labels or handles.
            let perform = engine.performanceMode
            let extent = max(0, arrangement.ghostExtentOctaves)

            ZStack(alignment: .topLeading) {
                Color.black

                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    // Band border — the playable strip against the dead space.
                    ctx.strokeFretBand(band)
                    ctx.translateBy(x: band.minX, y: band.minY)

                    // Octave-band boundaries (hidden in perform).
                    if !perform {
                        let lo = Int((-extent).rounded(.up))
                        let hi = Int((1 + extent).rounded(.down))
                        for k in lo...hi {
                            let x = fretPixelX(forBandX: Double(k),
                                               ghostExtentOctaves: extent,
                                               width: band.width)
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: 0))
                            line.addLine(to: CGPoint(x: x, y: band.height))
                            ctx.stroke(line, with: .color(.white.opacity(0.10)),
                                       lineWidth: 1)
                        }
                        // Pitch-field contours: territory boundaries plus
                        // fainter quarter-pitch lines.
                        for c in fretFieldContours(placements: placements,
                                                   size: band.size,
                                                   warp: warp) {
                            guard c.points.count >= 2 else { continue }
                            var line = Path()
                            line.move(to: c.points[0])
                            for p in c.points.dropFirst() { line.addLine(to: p) }
                            ctx.stroke(
                                line,
                                with: .color(.white.opacity(c.isBoundary ? 0.28 : 0.10)),
                                lineWidth: 1)
                        }
                    }

                    for p in placements {
                        let dim = !perform && p.isGhost
                        let hue = pitchColor(forRatio: p.ratio, lightness: 0.82,
                                             chroma: 0.20).opacity(dim ? 0.45 : 1.0)
                        ctx.stroke(p.linePath, with: .color(hue), lineWidth: dim ? 1 : 1.5)
                        if !perform {
                            if !p.isGhost {
                                for y in [p.topY, p.bottomY] {
                                    let r: CGFloat = 2.5
                                    let dot = CGRect(x: p.x - r, y: y - r,
                                                     width: 2 * r, height: 2 * r)
                                    ctx.fill(Path(ellipseIn: dot),
                                             with: .color(.white.opacity(0.85)))
                                }
                            }
                            ctx.draw(
                                Text(p.name)
                                    .font(.padSmall(12, weight: .semibold))
                                    .foregroundColor(.white.opacity(p.isGhost ? 0.5 : 1.0)),
                                at: CGPoint(x: p.x, y: max(8, p.topY - 12)))
                        }
                    }
                }

                // Dynamic layer: live sounding glow (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: fretFillCells(placements),
                              edgePad: edgePad)
                    .offset(x: band.minX, y: band.minY)

                // The chord bar (display only; clicks hit-tested in handleDown).
                ChordBarVisual(cells: chordCells, active: chordActive,
                               edgePad: edgePad, cornerRadius: 5,
                               fontSize: 12)

                // Drone buttons (display only). Hidden while a Joy-Con is
                // attached (its arrows pluck the drones).
                if !joyConConnected {
                    DroneButtonsVisual(ratios: arrangement.droneRatios,
                                       degrees: degrees,
                                       held: droneDown.map { [$0] } ?? [],
                                       size: size, edgePad: edgePad,
                                       cornerRadius: 8, fontSize: 12)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onReceive(joyCon.$connectedName.receive(on: DispatchQueue.main)) {
                joyConConnected = ($0 != nil)
            }
            .overlay(
                FretPadMouseCapture(
                    onMouseDown: { pt in
                        handleDown(at: toLocal(pt), placements: placements,
                                   base: basePlacements, size: size, band: band,
                                   chordCells: chordCells)
                    },
                    onMouseDragged: { pt in
                        handleDrag(at: toLocal(pt), placements: placements,
                                   band: band)
                    },
                    onMouseUp: { handleUp() },
                    onRightMouseDown: { pt in
                        handleRightDown(at: toLocal(pt), base: basePlacements,
                                        band: band)
                    }
                )
            )
        }
    }

    // MARK: Interactions

    private func handleDown(at spt: CGPoint, placements: [FretPlacement],
                            base: [FretPlacement], size: CGSize, band: CGRect,
                            chordCells: [ChordBarCell]) {
        // Drone buttons first (full-surface coords): a click starting in a
        // button is a drone press. Skipped while hidden (Joy-Con attached).
        if !joyConConnected,
           let d = droneButtonRects(size: size).firstIndex(where: { $0.contains(spt) }) {
            droneDown = d
            engine.setDrone(d, pressed: true)
            return
        }
        // Chord bar: a click in a cell toggles the strum chord (selection only).
        if let cell = chordCells.first(where: { $0.rect.contains(spt) }) {
            onChordTap(ChordSelection(degree: cell.degreeIndex,
                                      octave: cell.octaveShift))
            return
        }
        // Notes and edits live in the band; the space above/below is dead.
        guard band.contains(spt) else { return }
        // Band-local coordinates from here on — the frets' space.
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        // Perform mode: play only (no editing). Anywhere in the band.
        if engine.performanceMode {
            playAt(pt, placements: placements, size: band.size)
            return
        }

        // Edit mode: editing is always on (no modifier needed).
        let shift = NSEvent.modifierFlags.contains(.shift)
        let grab = fretGrab(at: pt, placements: base, handleRadius: handleHitRadius)

        // Shift on empty space → add a fret on the nearest degree.
        if shift, grab == .none {
            addSegment(at: pt, placements: placements, size: band.size)
            return
        }

        // On a fret → move / resize (sound its exact pitch while adjusting).
        if grab != .none {
            editGrab = grab
            if case .move(let id) = grab,
               let p = base.first(where: { $0.segmentID == id }) {
                moveOffsetX = p.x - pt.x
                moveOffsetY = (p.topY + p.bottomY) / 2 - pt.y
            }
            if let p = grabbedPlacement(grab, base: base) {
                beginSounding(weights: [p.id: 1.0], ratio: p.ratio)
            }
            return
        }

        // Empty space → play (so you can hear while arranging).
        playAt(pt, placements: placements, size: band.size)
    }

    /// Sound the pitch at `pt` (snapped or field) through the player.
    private func playAt(_ pt: CGPoint, placements: [FretPlacement], size: CGSize) {
        player.engine = engine
        player.recorder = recorder
        let touch = nextTouchId()
        guard player.begin(touchId: touch, at: pt,
                           context: playContext(placements: placements, size: size),
                           time: CACurrentMediaTime()) else { return }
        activeTouchId = touch
    }

    private func playContext(placements: [FretPlacement],
                             size: CGSize) -> FretTouchPlayer.Context {
        FretTouchPlayer.Context(placements: placements, size: size,
                                snapDistance: snapDistance,
                                ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                warp: warp)
    }

    private func handleDrag(at spt: CGPoint, placements: [FretPlacement],
                            band: CGRect) {
        // A press holding a drone button never glides or edits.
        guard droneDown == nil else { return }
        // Band-local; a drag may wander out (the field clamps, edits clamp 0..1).
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        let size = band.size
        switch editGrab {
        case .move(let id):
            guard let idx = segmentIndex(id) else { return }
            let h = arrangement.segments[idx].height
            var mid = Double((pt.y + moveOffsetY) / size.height)
            mid = min(max(h / 2, mid), 1 - h / 2)
            arrangement.segments[idx].topY = mid - h / 2
            arrangement.segments[idx].bottomY = mid + h / 2
            // A move drags x too (clamped to the base band).
            arrangement.segments[idx].x = clamp01(fretBandX(
                atPixelX: pt.x + moveOffsetX,
                ghostExtentOctaves: arrangement.ghostExtentOctaves,
                width: size.width))
            return
        case .resizeTop(let id):
            guard let idx = segmentIndex(id) else { return }
            let bottom = arrangement.segments[idx].bottomY
            arrangement.segments[idx].topY =
                min(clamp01(Double(pt.y / size.height)), bottom - minHeight)
            return
        case .resizeBottom(let id):
            guard let idx = segmentIndex(id) else { return }
            let top = arrangement.segments[idx].topY
            arrangement.segments[idx].bottomY =
                max(clamp01(Double(pt.y / size.height)), top + minHeight)
            return
        case .none:
            break
        }
        // Playing: the player glides (field pitch + onset offset + the
        // assist's slewed correction; never a re-snap mid-drag).
        guard let touch = activeTouchId else { return }
        player.move(touchId: touch, at: pt,
                    context: playContext(placements: placements, size: size),
                    time: CACurrentMediaTime())
    }

    private func handleUp() {
        if let d = droneDown {
            droneDown = nil
            engine.setDrone(d, pressed: false)
            return
        }
        if let touch = activeTouchId {
            // an edit-mode sounding never went through `playAt`: bind here too
            player.engine = engine
            player.recorder = recorder
            player.end(touchId: touch, time: CACurrentMediaTime())
        }
        activeTouchId = nil
        editGrab = .none
        moveOffsetX = 0
        moveOffsetY = 0
    }

    /// Right-click deletes a (base) fret. Disabled in perform mode.
    private func handleRightDown(at spt: CGPoint, base: [FretPlacement],
                                 band: CGRect) {
        if engine.performanceMode { return }
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        let grab = fretGrab(at: pt, placements: base, handleRadius: handleHitRadius)
        let id: UUID?
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): id = i
        case .none: id = nil
        }
        guard let segmentID = id, let idx = segmentIndex(segmentID) else { return }
        arrangement.segments.remove(at: idx)
    }

    /// Shift-click: add a fret at the click, on the degree nearest the field
    /// pitch there (circular within the octave), default extent.
    private func addSegment(at pt: CGPoint, placements: [FretPlacement],
                            size: CGSize) {
        guard !degrees.isEmpty else { return }
        let fieldLog = fretFieldLog(at: pt, placements: placements,
                                    warp: warp) ?? 0
        let folded = fieldLog - fieldLog.rounded(.down)
        var bestIndex = 0
        var bestDist = Double.infinity
        for (i, deg) in degrees.enumerated() {
            let d0 = abs(log2(deg.ratio) - folded)
            let d = min(d0, 1 - d0)
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        let x = clamp01(fretBandX(atPixelX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width))
        let cy = clamp01(Double(pt.y / size.height))
        let half = 0.075
        arrangement.segments.append(FretSegment(degreeIndex: bestIndex, x: x,
                                                topY: clamp01(cy - half),
                                                bottomY: clamp01(cy + half)))
    }

    // MARK: Helpers

    private func beginSounding(weights: [String: Double], ratio: Double) {
        let touch = nextTouchId()
        activeTouchId = touch
        engine.noteOn(touchId: touch, ratio: ratio, weights: weights)
    }

    private func grabbedPlacement(_ grab: FretGrab,
                                  base: [FretPlacement]) -> FretPlacement? {
        let id: UUID?
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): id = i
        case .none: id = nil
        }
        return id.flatMap { gid in base.first { $0.segmentID == gid } }
    }

    private func segmentIndex(_ id: UUID) -> Int? {
        arrangement.segments.firstIndex(where: { $0.id == id })
    }

    private func toLocal(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x - edgePad, y: pt.y - edgePad)
    }

    private func nextTouchId() -> Int {
        touchCounter &+= 1
        return touchCounter
    }
}

// MARK: - Mouse capture

/// AppKit mouse capture so drags arrive at full resolution (SwiftUI's
/// `DragGesture` coalesces moves and a glide stutters).
private struct FretPadMouseCapture: NSViewRepresentable {
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

// MARK: - Scale list editor

/// The scale's notes as an editable list (enable chip, name, `num/den`,
/// y-position, add / sort). Edits `engine.scale` (the shared `pitchPad`).
private struct ScaleListEditor: View {
    @ObservedObject var engine: PitchPadEngine

    var body: some View {
        // Active scale = enabled notes; disabled ones are parked below.
        let enabled = engine.scale.points.filter(\.enabled)
        let disabled = engine.scale.points.filter { !$0.enabled }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Scale (\(enabled.count))")
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    engine.scale.points.sort { $0.xFraction < $1.xFraction }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Sort scale by pitch (low → high)")
                Button {
                    addPitchInLargestGap()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a pitch in the largest x-gap")
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(enabled) { p in
                        ScaleEditorRow(engine: engine, pointID: p.id)
                    }
                    if !disabled.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("Disabled (\(disabled.count))")
                            .font(.padCaption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        ForEach(disabled) { p in
                            ScaleEditorRow(engine: engine, pointID: p.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08)))
    }

    private func addPitchInLargestGap() {
        let xs = engine.scale.points
            .filter(\.enabled)
            .map(\.xFraction)
            .sorted()
        var sentinel = xs
        if sentinel.first ?? 1 > 0 { sentinel.insert(0, at: 0) }
        if sentinel.last ?? 0 < 1 { sentinel.append(1) }
        var bestGap = 0.0
        var bestMid = 0.5
        for i in 1..<sentinel.count {
            let gap = sentinel[i] - sentinel[i-1]
            if gap > bestGap {
                bestGap = gap
                bestMid = (sentinel[i] + sentinel[i-1]) / 2
            }
        }
        let ratio = pow(2.0, bestMid)
        let (n, d) = bestFraction(ratio)
        engine.scale.points.append(PitchPoint(num: n, den: d, y: 0.5))
    }
}

private struct ScaleEditorRow: View {
    @ObservedObject var engine: PitchPadEngine
    let pointID: UUID

    /// Resolve our point by id on each access — rows survive sort / remove.
    private var currentIndex: Int? {
        engine.scale.points.firstIndex(where: { $0.id == pointID })
    }

    var body: some View {
        if let idx = currentIndex {
            let p = engine.scale.points[idx]
            row(point: p, index: idx)
        } else {
            EmptyView()
        }
    }

    private func ratioBinding() -> Binding<String> {
        Binding(
            get: {
                guard let i = currentIndex else { return "" }
                let p = engine.scale.points[i]
                return formatRatio(num: p.num, den: p.den)
            },
            set: { _ in }
        )
    }
    private func yBinding() -> Binding<String> {
        Binding(
            get: {
                guard let i = currentIndex else { return "" }
                return formatY(engine.scale.points[i].y)
            },
            set: { _ in }
        )
    }
    private func labelBinding() -> Binding<String> {
        Binding(
            get: {
                guard let i = currentIndex else { return "" }
                return engine.scale.points[i].label
            },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func row(point p: PitchPoint, index idx: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                if let i = currentIndex { engine.scale.points[i].enabled.toggle() }
            } label: {
                let hue = pitchColor(forRatio: p.ratio, lightness: 0.68, chroma: 0.15)
                Circle()
                    .fill(p.enabled ? hue : .clear)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(
                        p.enabled ? Color.black.opacity(0.7) : hue,
                        lineWidth: p.enabled ? 1 : 2))
            }
            .buttonStyle(.plain)
            .help(p.enabled ? "Disable (remove from the scale)"
                            : "Enable (add to the scale)")

            ScrollableField(
                text: labelBinding(),
                onScrollStep: { _ in },
                onCommit: { txt in commitLabel(txt) }
            )
            .frame(width: Typography.scaledWidth(56), height: 20)

            ScrollableField(
                text: ratioBinding(),
                onScrollStep: { dir in incrementPitch(by: dir) },
                onCommit: { txt in commitRatio(txt) }
            )
            .frame(width: Typography.scaledWidth(56), height: 20)

            ScrollableField(
                text: yBinding(),
                onScrollStep: { dir in incrementY(by: dir) },
                onCommit: { txt in commitY(txt) }
            )
            .frame(width: Typography.scaledWidth(48), height: 20)

            Spacer(minLength: 0)

            Button {
                if let i = currentIndex {
                    engine.scale.points.remove(at: i)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .opacity(p.enabled ? 1 : 0.55)
    }

    // MARK: - Formatting helpers

    private func formatRatio(num: Int, den: Int) -> String { "\(num)/\(den)" }
    /// Internal y is [0, 1], 0 at the top; user-facing y is [-3, 3], 0 centre.
    private func formatY(_ y: Double) -> String {
        let userY = 3 - 6 * y
        return String(format: "%.1f", userY)
    }

    // MARK: - Scroll increments

    private func incrementPitch(by direction: Int) {
        guard let i = currentIndex else { return }
        let curXF = engine.scale.points[i].xFraction
        let sorted = engine.snapTargets().sorted {
            log2(Double($0.num) / Double($0.den))
                < log2(Double($1.num) / Double($1.den))
        }
        let pick: (num: Int, den: Int)?
        if direction > 0 {
            pick = sorted.first {
                log2(Double($0.num) / Double($0.den)) > curXF + 1e-9
            }
        } else {
            pick = sorted.last {
                log2(Double($0.num) / Double($0.den)) < curXF - 1e-9
            }
        }
        guard let n = pick else { return }
        engine.scale.points[i].num = n.num
        engine.scale.points[i].den = n.den
    }

    private func incrementY(by direction: Int) {
        guard let i = currentIndex else { return }
        let curUserY = 3 - 6 * engine.scale.points[i].y
        let stepped = curUserY + Double(direction) * 0.2
        let clamped = max(-3.0, min(3.0, stepped))
        engine.scale.points[i].y = (3 - clamped) / 6
    }

    // MARK: - Commit handlers

    private func commitRatio(_ txt: String) {
        let parts = txt.split(separator: "/", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var nNew: Int? = nil
        var dNew: Int? = nil
        if parts.count == 2,
           let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 {
            nNew = n; dNew = d
        } else if let r = Double(txt), r > 0 {
            let (n, d) = bestFraction(r)
            nNew = n; dNew = d
        }
        if let n = nNew, let d = dNew, let i = currentIndex {
            let ratio = Double(n) / Double(d)
            let (fn, fd) = (ratio >= 1.0 && ratio < 2.0)
                ? (n, d)
                : octaveFolded(num: n, den: d)
            engine.scale.points[i].num = fn
            engine.scale.points[i].den = fd
        }
    }

    private func commitY(_ txt: String) {
        if let userY = Double(txt), let i = currentIndex {
            let clamped = max(-3.0, min(3.0, userY))
            engine.scale.points[i].y = (3 - clamped) / 6
        }
    }

    private func commitLabel(_ txt: String) {
        guard let i = currentIndex else { return }
        engine.scale.points[i].label = txt.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Scrollable editable text field

/// An `NSTextField` that emits ±1 step events on scroll-wheel (deltas
/// accumulate to one step per detent) and still edits as plain text.
private struct ScrollableField: NSViewRepresentable {
    @Binding var text: String
    let onScrollStep: (Int) -> Void
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScrollableField
        init(_ p: ScrollableField) { parent = p }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let f = obj.object as? NSTextField {
                parent.onCommit(f.stringValue)
            }
        }
    }

    func makeNSView(context: Context) -> AccumField {
        let f = AccumField()
        f.delegate = context.coordinator
        f.stringValue = text
        f.font = NSFont.monospacedDigitSystemFont(ofSize: Typography.scaled(11), weight: .regular)
        f.alignment = .center
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.usesSingleLineMode = true
        f.lineBreakMode = .byClipping
        f.onScrollStep = onScrollStep
        return f
    }

    func updateNSView(_ f: AccumField, context: Context) {
        if f.currentEditor() == nil && f.stringValue != text {
            f.stringValue = text
        }
        f.onScrollStep = onScrollStep
        context.coordinator.parent = self
    }

    final class AccumField: NSTextField {
        var onScrollStep: ((Int) -> Void)?
        private var accum: CGFloat = 0
        private let threshold: CGFloat = 1.0

        override func scrollWheel(with event: NSEvent) {
            accum += event.scrollingDeltaY
            while abs(accum) >= threshold {
                let sign = accum > 0 ? 1 : -1
                onScrollStep?(sign)
                accum -= CGFloat(sign) * threshold
            }
        }
    }
}
