import AppKit
import QuartzCore
import StarpadCore
import SwiftUI

/// The **Fret Pad** tab — the playing surface: the scale's pitches as vertical
/// **frets** positioned **freely** (each fret's x is its own layout state,
/// unrelated to its pitch). The playable pitch is a continuous **field**
/// interpolated from the frets (`fretFieldLog` — exact on a fret,
/// inverse-distance log-pitch blend between them). A touch that **starts**
/// within the Snap distance of a fret *and* inside its vertical extent snaps
/// to that fret's exact pitch; starting elsewhere plays the field pitch — the
/// approach path. After onset the drag is always continuous (field pitch plus
/// the constant offset captured at the snap), so a snapped note stays true
/// while meend/vibrato move relative to it.
///
/// Frets are editable: drag an endpoint to set a fret's vertical extent (its
/// snap zone), drag the line to move it (horizontally and vertically),
/// shift-click to add a fret on the nearest degree, right-click to delete.
/// The base layout sits in the central band; the surface extends
/// `ghostExtentOctaves` band-widths past it each side (default 0.5) with
/// read-only octave-repeat ghost copies of the whole layout. Reuses
/// `controller.fretPad` (a fourth `PitchPadEngine`) as the MPE emitter and
/// reads the scale + tonic from `controller.pitchPad`. **Runs on the iPad
/// too**: selecting this tab sets `ipadLayout = .fretPad`, and the arrangement
/// rides its own SysEx message (`FretArrangementSysEx`, subtype `0x03`) to the
/// iPad's `FretPadViewIOS` (always perform mode). See
/// [docs/fret-pad.md](../../docs/fret-pad.md).
struct FretPadView: View {
    @ObservedObject var controller: AppController
    /// The MPE emitter (the `fretPad` engine). Owns velocity / snap distance
    /// (`marginPixels`) / `sounding`; its own `scale` is unused here.
    @ObservedObject var engine: PitchPadEngine
    /// The scale + tonic source, edited right here (the Fret Pad is the only
    /// playing surface, so the scale selector + editor live on this tab).
    @ObservedObject var pitchPad: PitchPadEngine
    /// Records play strokes (raw events + context) for offline fitting of the
    /// drag-assist parameters (`tools/fretpad_fit.py`).
    @StateObject private var recorder = FretGestureRecorder()
    /// Drives the "Save As…" name prompt for the scale menu.
    @State private var showingSaveDialog = false
    @State private var saveName = ""

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
                               recorder: recorder)
                    .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scale selector's list editor (moved here from the old
                // Pitch Pad tab) — edits `pitchPad.scale`, which the frets and
                // the whole app read from. (The drone buttons live INSIDE the
                // surface — same placement as the iPad.)
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
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            scaleMenu
            Button("Reset to Scale") {
                controller.fretArrangement = .defaultArrangement(degrees: degrees)
            }
            .help("Rebuild the default fret layout: 7 evenly-spaced columns (one per svara, like the String Pad) — S/P centered, natural degrees in the bottom half, komal/tivra in the top half.")
            octaveControl
            Toggle("Legato", isOn: $controller.fretArrangement.legato)
                .toggleStyle(.button)
                .help("Tap legato: consecutive taps become one continuous voice — a tap while the previous note sounds (or within ~120 ms of its release) glides to the new pitch instead of retriggering. Mono, last-note priority while on. For very fast phrases, tap the notes instead of dragging.")
            Toggle("Perform", isOn: $engine.performanceMode)
                .toggleStyle(.button)
                .help("Clean playing surface: editing off, octave gridlines + labels + endpoint handles hidden, octave-repeat frets shown identically to the editable ones, and the scale editor hidden.")
            recordControl
            Spacer()
            FretSoundingReadout(sounding: engine.sounding,
                                tonicFractionalMidi: pitchPad.tonicFractionalMidi)
            snapControl
            velocityControl
            primeLimitControl
            tonicControl
        }
    }

    /// Save / load / delete saved scales + built-in scale presets. Edits the
    /// shared `pitchPad` scale, which the frets (and the tarab / iPad sync) read.
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
            Button("Reset to Default") { pitchPad.resetToDefault() }
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

    /// How far the ribbon extends past the base octave on each side, in
    /// octaves (fractional). 0.5 = a 2-octave ribbon.
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

    /// Record play strokes to a JSONL session file for offline fitting of the
    /// drag-assist parameters.
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
        .help("Record play strokes (raw movements + fret context) to Application Support/Starpad/FretRecordings/ as JSONL, for fitting the drag-assist parameters to your real playing (tools/fretpad_fit.py). Play naturally: glides into stops, direction changes near notes, vibrato, fast runs.")
    }

    /// Horizontal snap distance in pixels, backed by `engine.marginPixels`
    /// (0–64). 0 = fretless (no onset snapping at all).
    private var snapControl: some View {
        HStack(spacing: 6) {
            Text("Snap").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: $engine.marginPixels, in: 0...64)
                .frame(width: 80)
            Text("\(Int(engine.marginPixels.rounded())) px")
                .font(.padCaption.monospacedDigit())
                .frame(width: Typography.scaledWidth(36), alignment: .trailing)
        }
        .help("How close (horizontally) a touch must start to a fret to snap to its pitch. Only applies within the fret's vertical extent, and only at touch onset — drags glide continuously. 0 = fretless.")
    }

    private var velocityControl: some View {
        HStack(spacing: 6) {
            Text("Velocity").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(
                value: Binding(
                    get: { Double(engine.velocity) },
                    set: { engine.velocity = Int($0.rounded()) }
                ),
                in: 1...127
            )
            .frame(width: 90)
            Text("\(engine.velocity)")
                .font(.padCaption)
                .frame(width: Typography.scaledWidth(28), alignment: .trailing)
        }
    }

    /// The scale's tonic, edited HERE and only here — two controls onto the
    /// same value. **Hz**: the app's one absolute-frequency input, typed or
    /// scrolled for cents-level micro-adjustment. **Note**: a menu of the
    /// notes within half an octave of where the tonic sits (it re-centers on
    /// each pick), keeping the cents offset. Every other pitch (frets, tarab
    /// strings, drones) is a scale degree relative to this.
    private var tonicControl: some View {
        HStack(spacing: 6) {
            Text("Tonic").font(.padCaption2).foregroundStyle(.secondary).lineLimit(1)

            ScrollableField(
                text: Binding(get: { String(format: "%.2f", pitchPad.tonicHz) },
                              set: { _ in }),
                onScrollStep: { dir in
                    pitchPad.nudgeTonic(cents: Double(dir) * tonicScrollCents())
                },
                onCommit: { txt in
                    if let hz = Double(txt.trimmingCharacters(in: .whitespaces)) {
                        pitchPad.setTonic(hz: hz)
                    }
                }
            )
            .frame(width: Typography.scaledWidth(64), height: 20)
            .help("Tonic frequency in Hz — the app's one absolute pitch; everything else is relative to it. Scroll to micro-adjust: 1¢ per detent, ⌥ = 0.1¢, ⇧ = 10¢.")

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

    /// The note menu's contents: a tritone either side of the current tonic
    /// (13 semitones), clipped to `tonicNoteRange`. A deliberately SHORT list
    /// — retuning is a nudge to a neighbouring pitch, not a jump across the
    /// keyboard; the Hz field covers anything further.
    private var tonicNoteChoices: [Int] {
        let lo = max(PitchPadEngine.tonicNoteRange.lowerBound, pitchPad.tonicMidi - 6)
        let hi = min(PitchPadEngine.tonicNoteRange.upperBound, pitchPad.tonicMidi + 6)
        return Array(lo...hi)
    }

    /// Cents per scroll detent over the Hz field: 1¢, ⌥ = 0.1¢ fine,
    /// ⇧ = 10¢ coarse. Read live off the current modifier state.
    private func tonicScrollCents() -> Double {
        let mods = NSEvent.modifierFlags
        if mods.contains(.option) { return 0.1 }
        if mods.contains(.shift) { return 10.0 }
        return 1.0
    }

    /// "+12.0¢" — the tonic's offset from its note anchor, blank when exact.
    private var tonicCentsLabel: String {
        let c = pitchPad.tonicCents
        return abs(c) < 0.05 ? "" : String(format: "%+.1f¢", c)
    }

    // (The Drones menu is gone, 2026-07-25: the drone buttons pluck
    // sympathetic strings mapped in the Tarab tab; the button labels here
    // just display the mapped pitches, synced via the arrangement.)

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

// MARK: - Drone buttons

/// Visual layer for the drone buttons (display only — presses are
/// hit-tested in the surface's mouse handlers via the shared
/// `droneButtonRects`, so the surface keeps its full playing area and the
/// placement matches the iPad exactly). Right edge, top → vertical center:
/// press = the String voice's nearest jawari-taraf string swells and sings;
/// release = it rings out.
private struct DroneButtonsVisual: View {
    let ratios: [Double]
    /// The scale's degrees — the buttons are named from the scale like every
    /// other pitch in the app (`scaleLabel(forRatio:)`).
    let degrees: [(ratio: Double, label: String)]
    let held: Set<Int>
    let size: CGSize
    let edgePad: CGFloat

    var body: some View {
        let rects = droneButtonRects(size: size)
        ZStack(alignment: .topLeading) {
            ForEach(rects.indices, id: \.self) { i in
                let ratio = i < ratios.count ? ratios[i] : 1.0
                let hue = pitchColor(forRatio: ratio, lightness: 0.75,
                                     chroma: 0.17)
                let r = rects[i]
                RoundedRectangle(cornerRadius: 8)
                    .fill(hue.opacity(held.contains(i) ? 0.9 : 0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(hue.opacity(0.8), lineWidth: 1)
                    )
                    .overlay(
                        Text(scaleLabel(forRatio: ratio, degrees: degrees))
                            .font(.padSmall(12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: r.width, height: r.height)
                    .offset(x: edgePad + r.minX, y: edgePad + r.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sounding readout

/// Live frequency / nearest-note / cents readout for the active touch, tinted
/// in the pitch's hue. Observes only `SoundingState`, so per-tick glide
/// updates re-render this capsule alone.
private struct FretSoundingReadout: View {
    @ObservedObject var sounding: SoundingState
    let tonicFractionalMidi: Double

    var body: some View {
        let ratio = sounding.ratio
        let text: String = ratio.map { r in
            let fractionalMidi = tonicFractionalMidi + 12.0 * log2(r)
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
            .font(.padSmall(11).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(Color(white: 0.12).opacity(ratio == nil ? 0 : 1)))
            .opacity(ratio == nil ? 0 : 1)
            .fixedSize()
    }
}

// MARK: - Pad surface

private struct FretPadSurface: View {
    @ObservedObject var engine: PitchPadEngine
    @Binding var arrangement: FretArrangement
    let degrees: [(ratio: Double, label: String)]
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder

    @State private var activeTouchId: Int? = nil
    @State private var touchCounter: Int = 0
    /// The segment being edited (moved or resized), and which endpoint.
    @State private var editGrab: FretGrab = .none
    /// Pixel delta (segment x/mid-y − click) captured at mouse-down for a move.
    @State private var moveOffsetX: CGFloat = 0
    @State private var moveOffsetY: CGFloat = 0
    /// Constant log2 offset captured at a snapped onset: the drag plays
    /// `2^(fieldLog + snapOffsetLog)`, so the snapped pitch is exact at the
    /// onset point and finger movement glides relative to it.
    @State private var snapOffsetLog: Double = 0
    /// Drag assist ("magnetic" intonation at stops/turns — see
    /// `FretDragAssist`). The timer drives the settle while the mouse is
    /// held still (no drag events arrive then).
    @State private var assist = FretDragAssist()
    @State private var assistTimer: Timer? = nil
    /// Tap legato (see `FretLegato`): voice ownership, deferred releases,
    /// and the takeover glide ramp. The same timer drives release expiry.
    @State private var legato = FretLegato()
    /// Drone button currently held by the mouse (hit-tested in
    /// `handleDown` via the shared `droneButtonRects` — the buttons live
    /// inside the surface, matching the iPad).
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
            // The playable band — the frets' coordinate space, mirroring the
            // iPad exactly: the bordered half-height strip, dead space
            // above/below, drone buttons in full-surface coords.
            let band = fretPadBandRect(in: size)
            // All placements (base + octave-repeat ghosts). `body` does NOT
            // re-run during a glide (fills live on the separate `SoundingState`).
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: band.size)
            let basePlacements = placements.filter { !$0.isGhost }
            // Perform mode: a clean playing surface — no gridlines, labels, or
            // handles, and the ghosts styled identically to the editable frets.
            let perform = engine.performanceMode
            let extent = max(0, arrangement.ghostExtentOctaves)

            ZStack(alignment: .topLeading) {
                Color.black

                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    // Band border — the playable strip against the dead space.
                    ctx.stroke(Path(band),
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
                    ctx.translateBy(x: band.minX, y: band.minY)

                    // Octave-band boundaries — the edges between the base
                    // layout and its octave-repeat copies (hidden in perform).
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
                    }

                    for p in placements {
                        let dim = !perform && p.isGhost
                        let hue = pitchColor(forRatio: p.ratio, lightness: 0.82,
                                             chroma: 0.20).opacity(dim ? 0.45 : 1.0)
                        var line = Path()
                        line.move(to: CGPoint(x: p.x, y: p.topY))
                        line.addLine(to: CGPoint(x: p.x, y: p.bottomY))
                        ctx.stroke(line, with: .color(hue), lineWidth: dim ? 1 : 1.5)
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

                // Drone buttons (display only — presses are hit-tested in
                // handleDown): right edge, top → vertical center.
                DroneButtonsVisual(ratios: arrangement.droneRatios,
                                   degrees: degrees,
                                   held: droneDown.map { [$0] } ?? [],
                                   size: size, edgePad: edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                FretPadMouseCapture(
                    onMouseDown: { pt in
                        handleDown(at: toLocal(pt), placements: placements,
                                   base: basePlacements, size: size, band: band)
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
                            base: [FretPlacement], size: CGSize, band: CGRect) {
        // Drone buttons first (both modes, full-surface coords): a click
        // starting inside a button rect is a drone press, not a note or an
        // edit.
        if let d = droneButtonRects(size: size).firstIndex(where: { $0.contains(spt) }) {
            droneDown = d
            engine.setDrone(d, pressed: true)
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
                snapOffsetLog = 0
                beginSounding(weights: [p.id: 1.0], ratio: p.ratio)
            }
            return
        }

        // Empty space → play (so you can hear while arranging).
        playAt(pt, placements: placements, size: band.size)
    }

    /// Sound the pitch at `pt`: snapped to a fret when the onset lands within
    /// `snapDistance` of one **and** inside its vertical extent, otherwise the
    /// fret-field pitch (the approach path). With legato on, a tap while
    /// the previous note sounds (or is in its release grace window) takes the
    /// voice over and glides instead of retriggering. Registers the touch
    /// with the drag assist and starts the settle/legato timer.
    private func playAt(_ pt: CGPoint, placements: [FretPlacement], size: CGSize) {
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }   // no frets — nothing to play
        let onsetLog: Double
        let weights: [String: Double]
        if snapDistance > 0,
           let hit = fretSnap(at: pt, placements: placements,
                              snapDistance: snapDistance) {
            snapOffsetLog = log2(hit.ratio) - fieldLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
        } else {
            snapOffsetLog = 0
            onsetLog = fieldLog
            weights = [:]
        }

        let touch = nextTouchId()
        activeTouchId = touch
        let now = CACurrentMediaTime()
        var sentLog = onsetLog
        var tookOver = false
        if arrangement.legato, let prev = legato.tapBegan(touch, time: now),
           engine.transferTouch(from: prev.touch, to: touch) {
            // Legato takeover: no re-articulation — glide from the previous
            // note's pitch onto this tap over the ramp.
            tookOver = true
            legato.startRamp(fromLog: prev.log, onsetLog: onsetLog, time: now)
            sentLog = onsetLog + legato.offset(touch, time: now)
            engine.glide(touchId: touch, ratio: pow(2.0, sentLog), weights: weights)
        }
        if !tookOver {
            engine.noteOn(touchId: touch, ratio: pow(2.0, onsetLog), weights: weights)
        }
        legato.noteOutput(touch, log: sentLog)

        assist.setContext(placements: placements, snapDistance: snapDistance)
        assist.begin(touchId: touch, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + snapOffsetLog, time: now)
        if recorder.isRecording {
            recorder.begin(touchId: touch,
                           context: strokeContext(placements: placements, size: size),
                           offset: snapOffsetLog, x: pt.x, y: pt.y,
                           u: fieldLog + snapOffsetLog,
                           o: sentLog, time: now)
        }
        startAssistTimer()
    }

    /// Snapshot the geometry + live assist settings for a recorded stroke.
    private func strokeContext(placements: [FretPlacement],
                               size: CGSize) -> FretGestureRecorder.Context {
        FretGestureRecorder.Context(
            frets: placements.map {
                .init(id: $0.id, log2Ratio: log2($0.ratio), x: Double($0.x),
                      topY: Double($0.topY), bottomY: Double($0.bottomY),
                      ghost: $0.isGhost)
            },
            snapDistance: Double(snapDistance),
            ghostExtentOctaves: arrangement.ghostExtentOctaves,
            width: Double(size.width), height: Double(size.height),
            assistParams: ["speedFloor": assist.speedFloor,
                           "speedCeiling": assist.speedCeiling,
                           "speedTau": assist.speedTau,
                           "settleTau": assist.settleTau,
                           "radiusScale": assist.radiusScale,
                           "turnGain": assist.turnGain,
                           "turnTau": assist.turnTau])
    }

    /// 60 Hz settle loop while a play touch is down. Captures only the class
    /// objects (never the view struct); the assist reuses the context set on
    /// the last mouse event.
    private func startAssistTimer() {
        assistTimer?.invalidate()
        let assist = self.assist
        let engine = self.engine
        let recorder = self.recorder
        let legato = self.legato
        assistTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                           repeats: true) { timer in
            let now = CACurrentMediaTime()
            // Deferred legato release expired with no follow-up tap.
            if let dead = legato.expiredVoice(time: now) {
                engine.noteOff(touchId: dead)
            }
            for (id, out) in assist.tick(time: now) {
                let final = out.log2Pitch + legato.offset(id, time: now)
                engine.glide(touchId: id, ratio: pow(2.0, final),
                             weights: out.weights)
                legato.noteOutput(id, log: final)
                recorder.sampleTick(touchId: id, o: final, time: now)
            }
            // Nothing sounding, nothing pending — stop ticking.
            if assist.isEmpty && legato.isIdle { timer.invalidate() }
        }
    }

    private func handleDrag(at spt: CGPoint, placements: [FretPlacement],
                            band: CGRect) {
        // A press holding a drone button never glides or edits.
        guard droneDown == nil else { return }
        // Band-local coordinates — a drag may wander out of the band (the
        // field clamps, edit positions clamp to 0..1).
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
            // Frets are freely positioned — a move drags x too (clamped to
            // the base band).
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
        // Playing: continuous glide — the fret-field pitch plus the constant
        // offset captured at a snapped onset, then the drag assist's slewed
        // correction on top (magnetic at stops/turns, transparent while
        // gliding). Never re-snaps mid-drag; the field and assist are
        // continuous.
        guard let touch = activeTouchId else { return }
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }
        assist.setContext(placements: placements, snapDistance: snapDistance)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: touch, x: pt.x, y: pt.y,
                              uncorrectedLog: fieldLog + snapOffsetLog, time: now)
        let final = out.log2Pitch + legato.offset(touch, time: now)
        engine.glide(touchId: touch, ratio: pow(2.0, final),
                     weights: out.weights)
        legato.noteOutput(touch, log: final)
        recorder.sample(touchId: touch, x: pt.x, y: pt.y,
                        u: fieldLog + snapOffsetLog, o: final, time: now)
    }

    private func handleUp() {
        if let d = droneDown {
            droneDown = nil
            engine.setDrone(d, pressed: false)
            return
        }
        if let touch = activeTouchId {
            let now = CACurrentMediaTime()
            // Legato: defer the voice owner's release by the grace window so
            // the next tap can glide from it; the timer sends the real
            // note-off if none comes. Non-play touches fall through.
            if !(arrangement.legato && legato.touchEnded(touch, time: now)) {
                engine.noteOff(touchId: touch)
            }
            assist.end(touchId: touch)
            recorder.end(touchId: touch, time: now)
        }
        // Keep the timer alive while a deferred release is pending (it
        // self-invalidates when idle).
        if legato.isIdle {
            assistTimer?.invalidate()
            assistTimer = nil
        }
        activeTouchId = nil
        editGrab = .none
        moveOffsetX = 0
        moveOffsetY = 0
        snapOffsetLog = 0
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

    /// Shift-click: add a fret at the click position, on the degree whose
    /// pitch is nearest the field pitch there (circular within the octave),
    /// with a default-height extent centered on the click y.
    private func addSegment(at pt: CGPoint, placements: [FretPlacement],
                            size: CGSize) {
        guard !degrees.isEmpty else { return }
        let fieldLog = fretFieldLog(at: pt, placements: placements) ?? 0
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

// MARK: - Mouse capture (mirrors PadMouseCapture in PitchPadView)

/// AppKit-backed mouse capture so drag events arrive at full resolution
/// (SwiftUI's `DragGesture` coalesces moves on macOS, making a glide stutter).
/// Reports left press/drag/up plus right-click; modifier state is read from
/// `NSEvent.modifierFlags` in the handlers.
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

// MARK: - Scale list editor (moved from the old Pitch Pad tab)

/// The scale's notes as an editable list: per-row enable chip, custom name,
/// `num/den` ratio, and y-position, plus add / sort. Edits `engine.scale`
/// (the shared `pitchPad`), so a change re-renders the frets immediately and
/// flows to the tarab + iPad sync.
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
    /// Internal y is [0, 1] with 0 at the top. User-facing y is [-3, 3] with 0
    /// at the center; integers correspond to the command-snap gridlines.
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

/// A small `NSTextField` wrapper that emits ±1 "step" events when the user
/// scrolls the wheel over it, while still letting them click to edit as plain
/// text. Scroll deltas accumulate so a trackpad's many small events emit one
/// step per detent.
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
