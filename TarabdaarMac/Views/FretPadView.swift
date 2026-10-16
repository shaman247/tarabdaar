import AppKit
import Combine
import QuartzCore
import TarabdaarCore
import SwiftUI

/// The **Fret Pad** tab — the playing surface: frequency-aligned vertical
/// **frets** over a continuous pitch **field** (`fretFieldLog`). A touch
/// starting within the Snap distance of a fret and inside its extent snaps to
/// it; elsewhere it plays the field pitch; drags are continuous (field plus
/// the onset offset). Editing: drag a fret vertically, shift-click to add on
/// the nearest degree, option-right-click to delete. Right-click toggles the matching raga string. Plays through
/// `controller.fretPad`, reads the scale + tonic from
/// `controller.pitchPad`; the arrangement syncs to the iPad's `FretPadViewIOS`
/// as the `FRET_ARRANGEMENT` TLP event. See [docs/fret-pad.md](../../docs/fret-pad.md).
struct FretPadView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var audio: AudioEngine
    /// The note emitter (`fretPad`): `marginPixels`, `sounding`.
    @ObservedObject var engine: PitchPadEngine
    /// The scale + tonic source, edited on this tab.
    @ObservedObject var pitchPad: PitchPadEngine
    /// Records play strokes for offline assist fitting (`tools/fretpad_fit.py`).
    @ObservedObject private var recorder: FretGestureRecorder
    /// Drives the "Save As…" name prompt for the scale menu.
    @State private var showingSaveDialog = false
    @State private var saveName = ""
    /// The same, for the fret-layout menu.
    @State private var showingLayoutSaveDialog = false
    @State private var layoutSaveName = ""

    init(controller: AppController) {
        self.controller = controller
        self.audio = controller.audio
        self.engine = controller.fretPad
        self.pitchPad = controller.pitchPad
        self.recorder = controller.fretRecorder
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
                               chordActive: controller.strumChord,
                               onChordTap: { controller.tapChord($0) },
                               tarafBank: audio.tarafBank,
                               pluckTaraf: { revision, row in
                                   audio.pluckTaraf(revision: revision, row: row)
                               })
                    .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scale list editor — edits `pitchPad.scale`, which the
                // frets and the whole app read from.
                if !engine.performanceMode {
                    ScaleListEditor(engine: pitchPad)
                        .frame(width: 280)
                }
            }
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
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Panic") { engine.panic() }
                scaleMenu
                layoutMenu
                Button("Reset to Scale") {
                    controller.loadFretLayout(preset: .pilu)
                }
                Toggle("Perform", isOn: $engine.performanceMode)
                    .toggleStyle(.button)
                recordControl
                Spacer()
                SoundingReadout(sounding: engine.sounding,
                                tonicFractionalMidi: pitchPad.tonicFractionalMidi,
                                style: .capsule)
            }
            HStack(spacing: 12) {
                octaveControl
                snapControl
                warpControl
                Spacer()
                tonicControl
            }
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
            // Full factory reset: the default scale AND the Pilu layout.
            Button("Reset to Default") {
                pitchPad.resetToDefault()
                controller.loadFretLayout(preset: .pilu)
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

    /// Total octave span in tenth-octave steps.
    private var octaveControl: some View {
        HStack(spacing: 6) {
            Text("Octaves").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: Binding(
                get: { 1 + 2 * controller.fretArrangement.ghostExtentOctaves },
                set: { controller.fretArrangement.ghostExtentOctaves = ($0 - 1) / 2 }),
                   in: 1...5, step: 0.1)
                .frame(width: 80)
                .accessibilityLabel("Octaves")
            Text(String(format: "%.1f", 1 + 2 * controller.fretArrangement.ghostExtentOctaves))
                .font(.padCaption.monospacedDigit())
                .frame(width: Typography.scaledWidth(24), alignment: .trailing)
        }
    }

    /// Record play strokes to JSONL for offline assist fitting.
    private var recordControl: some View {
        Toggle(isOn: Binding(get: { recorder.isRecording },
                             set: { on in
                                 if on { recorder.setRecording(true) }
                                 else { recorder.stop(waitForRemote: controller.linkStatus.isUp && !controller.linkStatus.isStale) }
                             })) {
            HStack(spacing: 4) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(recorder.isFinishing ? "Saving \(recorder.strokeCount)"
                     : recorder.isRecording ? "Rec \(recorder.strokeCount)" : "Rec")
                    .font(.padCaption.monospacedDigit())
            }
        }
        .toggleStyle(.button)
        .disabled(recorder.isFinishing)
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
        .help("How strongly the frets warp the pitch space around them (the ctl_fret_warp parameter — also on the Parameters tab, bindable to a tilt/stick axis for live morphing): 0 = linear (pitch moves at a constant rate between frets); higher = pitch plateaus near each fret and transitions quickly through the middle, so a straight slide between two frets traces a logistic curve. The readout shows the LIVE value (binding included).")
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
    /// The active strum chord and the chord bar's tap route.
    let chordActive: ChordSelection?
    let onChordTap: (ChordSelection) -> Void
    let tarafBank: TarafBank
    let pluckTaraf: (UInt32, UInt8) -> Void

    @State private var activeTouchId: Int? = nil
    @State private var touchCounter: Int = 0
    /// The touch pipeline (onset, drag, settle tick, release).
    @State private var player = FretTouchPlayer()

    private let edgePad: CGFloat = 16
    private let handleHitRadius: CGFloat = 9

    /// Horizontal onset-snap half-width in pixels (the Snap slider).
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space (the iPad's too).
            let band = fretPadBandRect(in: size)
            // `body` does NOT re-run during a glide (fills live on `SoundingState`).
            let placements = fretPlacements(
                arrangement: arrangement,
                degrees: degrees, size: band.size)
            let editPlacements = engine.performanceMode ? placements : fretPlacements(
                arrangement: arrangement, degrees: degrees, size: band.size, includeUnassigned: true)
            let chordCells = chordBarCells(arrangement: arrangement,
                                           degrees: degrees,
                                           chords: scaleChords(degrees: degrees),
                                           size: size)
            // Perform mode hides assignment candidates and labels.
            let perform = engine.performanceMode

            ZStack(alignment: .topLeading) {
                Color.black

                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    ctx.fillFretBand(band)
                    ctx.translateBy(x: band.minX, y: band.minY)

                    ctx.strokeFretPitchGrid(degrees: degrees,
                                            ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                            size: band.size)

                    for p in editPlacements.sorted(by: { !$0.isEnabled && $1.isEnabled }) {
                        let dim = !perform && p.isGhost
                        let hue = (p.isEnabled
                            ? pitchColor(forRatio: p.ratio, lightness: 0.82, chroma: 0.20)
                            : Color.gray.opacity(0.35)).opacity(dim ? 0.45 : 1.0)
                        ctx.stroke(p.linePath, with: .color(hue), lineWidth: dim ? 1 : 1.5)
                    }

                    if !perform {
                        let columns = Dictionary(grouping: editPlacements, by: \.ratio)
                        for ratio in columns.keys.sorted() {
                            guard let column = columns[ratio], let p = column.first else { continue }
                            let enabled = column.contains { $0.isEnabled }
                            let ghost = column.allSatisfy { $0.isGhost }
                            let hue = (enabled
                                ? pitchColor(forRatio: ratio, lightness: 0.82, chroma: 0.20)
                                : Color.gray.opacity(0.35)).opacity(ghost ? 0.45 : 1.0)
                            let label = ctx.resolve(
                                Text(p.name)
                                    .font(.padSmall(12, weight: .semibold))
                                    .foregroundColor(hue))
                            let halfWidth = label.measure(in: band.size).width / 2
                            ctx.draw(label,
                                at: CGPoint(x: max(halfWidth, min(p.x, band.width - halfWidth)),
                                            y: band.height + 8),
                                anchor: .top)
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

            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: warp) { _ in
                player.updateWarp(context: playContext(placements: placements, size: band.size),
                                  time: CACurrentMediaTime())
            }
            .overlay(
                FretPadMouseCapture(
                    onMouseDown: { pt in
                        handleDown(at: toLocal(pt), placements: placements,
                                   editable: editPlacements, size: size, band: band,
                                   chordCells: chordCells)
                    },
                    onMouseDragged: { pt in
                        handleDrag(at: toLocal(pt), placements: placements,
                                   band: band)
                    },
                    onMouseUp: { handleUp() }
                )
            )
            .overlay(alignment: .topLeading) {
                TarafPluckStrip(bank: tarafBank, scale: engine.scale, pluck: pluckTaraf)
                    .frame(width: band.width)
                    .offset(x: edgePad + band.minX,
                            y: edgePad + band.minY - TarafPluckStrip.height)
            }
        }
    }

    // MARK: Interactions

    private func handleDown(at spt: CGPoint, placements: [FretPlacement],
                            editable: [FretPlacement], size: CGSize, band: CGRect,
                            chordCells: [ChordBarCell]) {
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

        if let fret = fretAssignment(at: pt, placements: editable, hitRadius: handleHitRadius) {
            arrangement.toggle(degreeIndex: fret.degreeIndex, row: fret.row)
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
        // Band-local; a drag may wander out (the field clamps, edits clamp 0..1).
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        let size = band.size
        // Playing: the player glides (field pitch + onset offset + the
        // assist's slewed correction; never a re-snap mid-drag).
        guard let touch = activeTouchId else { return }
        player.move(touchId: touch, at: pt,
                    context: playContext(placements: placements, size: size),
                    time: CACurrentMediaTime())
    }

    private func handleUp() {
        if let touch = activeTouchId {
            player.engine = engine
            player.recorder = recorder
            player.end(touchId: touch, time: CACurrentMediaTime())
        }
        activeTouchId = nil
    }

    // MARK: Helpers

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

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        return v
    }

    func updateNSView(_ v: CaptureView, context: Context) {
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
    }

    final class CaptureView: NSView {
        var onMouseDown: ((CGPoint) -> Void)?
        var onMouseDragged: ((CGPoint) -> Void)?
        var onMouseUp: (() -> Void)?

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

    }
}

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
                onScrollStep: { _ in },
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
