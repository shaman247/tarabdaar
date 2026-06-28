import AppKit
import StarpadCore
import SwiftUI

/// Alternative-to-keyboard interface for sound-design iteration. The
/// pad is a rectangle whose x-axis spans one octave from `1/1` (left,
/// tonic) to `2/1` (right) in log-frequency space. Each pitch in the
/// active scale is a `PitchPoint` placed at `(log2(ratio), y)`, where
/// `y` is arbitrary — used only by the layout. The rectangle is
/// partitioned into the Voronoi cells of those points; clicking inside
/// a cell plays its pitch, dragging glides smoothly through whatever
/// cells the cursor crosses, and shift-click toggles a pitch at the
/// cursor (add if empty space, remove if on top of an existing point).
///
/// Each outer cell contains an **inner polygon** inset by a fixed
/// pixel margin. Inside the inner polygon the cell's exact ratio
/// plays; in the strip between two cells' inner polygons (a "soft
/// zone" `2 × margin` pixels wide centered on the bisector) the
/// played ratio is a log-frequency interpolation between the two
/// pitches, so crossing a boundary glides instead of snapping.
///
/// The right-hand editor lists the same scale with per-row text fields
/// for `num/den` and a slider for `y`. Both surfaces share the same
/// `@Published` `engine.scale`, so an edit anywhere re-renders the
/// Voronoi map immediately.
struct PitchPadView: View {
    @ObservedObject var engine: PitchPadEngine
    /// Drives the "Save As…" name prompt. The text field binds to
    /// `saveName`; committing calls `engine.saveScale`.
    @State private var showingSaveDialog = false
    @State private var saveName = ""

    init(controller: AppController) {
        self.engine = controller.pitchPad
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                PitchPadSurface(engine: engine)
                    .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PitchPadEditor(engine: engine)
                    .frame(width: 280)
            }
            footer
        }
        .padding(12)
        .alert("Save Scale", isPresented: $showingSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = saveName.trimmingCharacters(in: .whitespaces)
                // Reject empty and the reserved Default name so the
                // bundled default can't be shadowed by a user file.
                guard !trimmed.isEmpty, trimmed != ScaleStore.defaultName else { return }
                engine.saveScale(name: trimmed)
            }
        } message: {
            Text("Enter a name for this scale.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            scaleMenu
            snapControls
            Toggle("Perform", isOn: $engine.performanceMode)
                .toggleStyle(.button)
                .help("Hide the pitch discs and octave / cell lines for a clean playing surface.")
            Spacer()
            SoundingReadout(sounding: engine.sounding, tonicMidi: engine.tonicMidi)
            marginControl
            velocityControl
            tonicControl
        }
    }

    /// Save / load / delete saved scales. The saved-scale list is read
    /// from disk each time the menu is built; the toolbar re-renders
    /// (and so re-reads) whenever `currentScaleName` changes, i.e. after
    /// every save / load / delete, so the list stays current.
    private var scaleMenu: some View {
        Menu {
            Button("Save As…") {
                saveName = engine.currentScaleName ?? ""
                showingSaveDialog = true
            }
            if let name = engine.currentScaleName {
                Button("Save “\(name)”") { engine.saveScale(name: name) }
            }
            Divider()
            Button("Reset to Default") { engine.resetToDefault() }
            Menu("Scales") {
                ForEach(ScalePreset.allCases) { preset in
                    Button(preset.label) { engine.loadPreset(preset) }
                }
            }

            let saved = ScaleStore.savedScaleNames()
            if !saved.isEmpty {
                Divider()
                Section("Load") {
                    ForEach(saved, id: \.self) { name in
                        Button {
                            engine.loadScale(name: name)
                        } label: {
                            if engine.currentScaleName == name {
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
                        Button(name, role: .destructive) { engine.deleteScale(name: name) }
                    }
                }
            }
        } label: {
            Label(engine.currentScaleName ?? "Scale", systemImage: "music.note.list")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var snapControls: some View {
        HStack(spacing: 4) {
            Text("Prime ≤").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // Picker snaps to the actual primes — a continuous slider
            // would invite landing on composites like 4 that mean
            // nothing as a prime-limit cap.
            Picker("", selection: $engine.primeLimit) {
                ForEach([2, 3, 5, 7, 11, 13, 17, 19, 23], id: \.self) { p in
                    Text("\(p)").tag(p)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 60)
        }
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
            .frame(width: 120)
            Text("\(engine.velocity)")
                .font(.system(.caption))
                .frame(width: 28, alignment: .trailing)
        }
    }

    /// Soft margin around each cell boundary. 0 = rigid Voronoi (no
    /// interpolation, every cursor position plays its cell's exact
    /// ratio); higher = wider interpolation strip between cells.
    private var marginControl: some View {
        HStack(spacing: 6) {
            Text("Margin").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: $engine.marginPixels, in: 0...64)
                .frame(width: 100)
            Text("\(Int(engine.marginPixels.rounded()))")
                .font(.system(.caption))
                .frame(width: 24, alignment: .trailing)
        }
        .help("Half-width of the soft interpolation zone between cells, in pixels. 0 = rigid Voronoi cells.")
    }

    private var tonicControl: some View {
        HStack(spacing: 6) {
            Text("Tonic MIDI").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Stepper(value: Binding(
                get: { engine.tonicMidi },
                set: { engine.tonicMidi = max(24, min(96, $0)) }
            ), in: 24...96) {
                Text("\(engine.tonicMidi) (\(Scale.noteName(for: engine.tonicMidi)))")
                    .font(.system(.caption))
                    .lineLimit(1)
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Text("Click = play  ·  Drag handle = move  ·  Shift+click = add / remove  ·  Shift+drag = x-snap  ·  Cmd+drag = y-snap")
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

}

/// Live frequency / nearest-semitone / cents-off readout for the
/// currently-sounding touch. Its own view observing only
/// `SoundingState`, so the per-tick ratio updates during a glide
/// re-render this small capsule and nothing else in the toolbar. The
/// capsule is rendered at all times with a placeholder string when
/// silent and `.opacity(0)`, so it reserves the same toolbar height
/// whether a note is sounding or not — toggling between the two used
/// to nudge the pad's height by a couple pixels, which dragged every
/// handle vertically. Text is tinted with the OKLCH color of the
/// active pitch.
private struct SoundingReadout: View {
    @ObservedObject var sounding: SoundingState
    let tonicMidi: Int

    var body: some View {
        let ratio = sounding.ratio
        let info: SoundingInfo = ratio.map {
            SoundingInfo.from(ratio: $0, tonicMidi: tonicMidi)
        } ?? SoundingInfo(hzString: "000.00",
                          noteString: "X0",
                          centsString: "+0¢")
        let textColor: Color = ratio.map {
            pitchColor(forRatio: $0, lightness: 0.85, chroma: 0.18)
        } ?? .clear
        return Text("\(info.hzString) Hz (\(info.noteString) \(info.centsString))")
            .font(.system(size: 11))
            .foregroundStyle(textColor)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(
                Color(white: 0.12).opacity(ratio == nil ? 0 : 1)
            ))
            .opacity(ratio == nil ? 0 : 1)
            .fixedSize()
    }
}

// MARK: - Sounding-pitch readout

/// Snapshot of what the user is hearing: absolute frequency, the
/// nearest 12-TET note name, and how many cents sharp/flat. Derived
/// from `tonicMidi` plus the current ratio so the values stay correct
/// as the user retunes either side.
private struct SoundingInfo {
    let hzString: String
    let noteString: String
    let centsString: String

    static func from(ratio: Double, tonicMidi: Int) -> SoundingInfo {
        let semisAboveTonic = 12.0 * log2(ratio)
        let fractionalMidi = Double(tonicMidi) + semisAboveTonic
        let frequency = 440.0 * pow(2.0, (fractionalMidi - 69.0) / 12.0)
        let nearest = Int(fractionalMidi.rounded())
        let centsInt = Int(((fractionalMidi - Double(nearest)) * 100.0).rounded())
        let hz = frequency >= 1000
            ? String(format: "%.1f", frequency)
            : String(format: "%.2f", frequency)
        let cents = centsInt > 0 ? "+\(centsInt)¢" : "\(centsInt)¢"
        return SoundingInfo(
            hzString: hz,
            noteString: Scale.noteName(for: nearest),
            centsString: cents
        )
    }
}

// MARK: - Pad surface

private struct PitchPadSurface: View {
    @ObservedObject var engine: PitchPadEngine
    @State private var activeTouchId: Int? = nil
    /// The display seed the active touch is currently sounding (by
    /// `DisplaySeed.id`). Drives the cell-highlight glow so the user
    /// can see what's making noise. A ghost cell and its base cell
    /// have distinct ids, so the correct octave lights up.
    /// When non-nil, mouse drags reposition this pitch's handle
    /// instead of gliding between cells.
    @State private var draggingPitchID: UUID? = nil
    /// Shift-click on a handle is ambiguous between "remove" and
    /// "start a snap-drag." We resolve it at mouseUp: if any drag
    /// movement happened, treat it as a drag (and clear this); if
    /// not, treat it as the original remove gesture.
    @State private var pendingRemoveID: UUID? = nil
    /// Pixel delta (handle position − click position) captured at
    /// mouseDown. Applied during drag so the handle moves WITH the
    /// cursor instead of teleporting to it — clicking a handle no
    /// longer slams its y to whatever row the click landed on.
    @State private var dragOffsetPixel: CGPoint = .zero
    /// Fraction the dragged pitch had at mouseDown. Used to anchor
    /// the "original pitch" gridline so the user always has a
    /// reference back to where they started, even when the engine's
    /// Tenney/prime filters would exclude it.
    @State private var dragOriginalFraction: (num: Int, den: Int)? = nil
    /// Set to true on each drag tick when shift is held — drives
    /// vertical-gridline visibility. Re-evaluated per move so the
    /// user can tap shift mid-drag and have x-snap engage.
    @State private var snapping: Bool = false
    /// Set to true on each drag tick when command is held — drives
    /// horizontal-gridline visibility / y-snap. Independent of shift.
    @State private var snappingY: Bool = false
    /// The gridline fraction the cursor is currently snapping to.
    /// nil means shift+drag is in pass-through (free drag) mode
    /// because the cursor isn't aimed at any gridline.
    @State private var snapTargetFraction: (num: Int, den: Int)? = nil
    /// The y-snap row (one of `yGridPositions`) the cursor is
    /// nearest to. nil when command isn't held.
    @State private var snapTargetY: Double? = nil
    @State private var hoveredId: UUID? = nil
    @State private var touchCounter: Int = 0
    /// Memoizes the Voronoi solve across `body` re-evals so a render
    /// triggered only by a fill-weight change doesn't re-solve the
    /// cells. Held in `@State` so the reference survives re-renders;
    /// its fields aren't observed, so reading/updating it during a
    /// render doesn't loop.
    @State private var voronoiCache = VoronoiCache()
    /// Memoizes `displaySeeds()` on the scale points (same rationale).
    @State private var seedsCache = SeedsCache()
    /// Transient drag scratch (most recent cursor point). Kept off
    /// `@State` so updating it every mouse tick does NOT re-render the
    /// surface — it's only read back by `flagsChanged` to re-evaluate
    /// the snap at the current position. Held in `@State` as a
    /// reference whose fields aren't observed.
    @State private var dragScratch = DragScratch()

    /// Pixel radius around a handle that counts as "click on handle".
    private let handleHitRadius: CGFloat = 14

    /// Half-width of the soft interpolation zone around each cell
    /// boundary, in pixels. Each cell's inner polygon is the outer
    /// polygon inset by this distance; the strip between two cells'
    /// inner polygons is `2 × marginPixels` wide, centered on the
    /// shared bisector. Inside the inner polygon the cell's exact
    /// ratio plays; in the strip the ratio is a log-frequency lerp
    /// between the two cells based on perpendicular distance to the
    /// bisector.
    ///
    /// Sourced from `engine.marginPixels` so the toolbar's Margin
    /// slider mutates a single observed value and triggers a redraw.
    private var marginPixels: CGFloat { CGFloat(engine.marginPixels) }

    /// Seven y-snap positions: center plus three equal-spaced rungs
    /// in each direction. 1/6 spacing reaches the top and bottom
    /// edges so a snapped handle can sit anywhere along the column.
    private let yGridPositions: [Double] = (0...6).map { Double($0) / 6.0 }

    /// Log-frequency bounds the pad's width maps onto. The base octave
    /// is `[0, 1]` (1/1 … 2/1); the pad extends half an octave past
    /// each end so the scale's notes appear repeated in the flanking
    /// half-octaves. The scale itself is still only defined over the
    /// base octave — the flanks are read-only ghosts.
    private let xLo: Double = -0.5
    private let xHi: Double = 1.5
    private var xSpan: Double { xHi - xLo }

    /// Log-frequency `logX` → pixel x within the logical pad area.
    private func xToPixel(_ logX: Double, width: CGFloat) -> CGFloat {
        CGFloat((logX - xLo) / xSpan) * width
    }

    /// Pixel x → log-frequency `logX`.
    private func pixelToX(_ px: CGFloat, width: CGFloat) -> Double {
        xLo + Double(px / width) * xSpan
    }

    /// Base scale points plus their ghost repeats that fall within the
    /// pad's extended x-range. Memoized on the scale points so the
    /// per-render (`body`) and per-event (`pitchAt`) calls reuse one
    /// array — during a glide the scale is constant, so this avoids
    /// rebuilding the seeds (and their id strings) every tick.
    private func displaySeeds() -> [DisplaySeed] {
        seedsCache.seeds(points: engine.scale.points) { computeDisplaySeeds() }
    }

    /// Each base point (octaveShift 0) may spawn a ghost one octave
    /// down and/or up; ghosts that land outside `[xLo, xHi]` are
    /// dropped, as are ghosts that coincide (within ~5 cents) with an
    /// existing base point — which prevents degenerate duplicate seeds
    /// at the octave boundary when a scale lists both 1/1 and 2/1. Ids
    /// are stable across renders. Disabled notes are not in the scale,
    /// so they contribute neither seeds nor ghosts.
    private func computeDisplaySeeds() -> [DisplaySeed] {
        let base = engine.scale.points.filter(\.enabled)
        var seeds: [DisplaySeed] = []
        seeds.reserveCapacity(base.count * 2)
        for p in base {
            for shift in [-1, 0, 1] {
                let logX = p.xFraction + Double(shift)
                if logX < xLo - 1e-9 || logX > xHi + 1e-9 { continue }
                if shift != 0 {
                    let coincides = base.contains {
                        abs($0.xFraction - logX) < 0.004   // ~5 cents
                    }
                    if coincides { continue }
                }
                seeds.append(DisplaySeed(
                    id: DisplaySeed.makeID(p.id, shift: shift),
                    sourceID: p.id,
                    octaveShift: shift,
                    ratio: p.ratio * pow(2.0, Double(shift)),
                    y: p.y,
                    label: p.displayLabel,
                    ratioString: p.ratioString
                ))
            }
        }
        return seeds
    }

    var body: some View {
        GeometryReader { geo in
            // The pad's playing area is inset by `edgePad` from the
            // view bounds so the thicker inner-polygon borders along
            // the rect edges, the edge handles, and the labels above
            // edge points all have room to render instead of being
            // clipped. All interaction math stays in logical
            // `[0, size]` space; `edgePad` is applied only at the
            // render boundary (a Canvas translate + a `+edgePad`
            // offset on label/handle positions) and at the input
            // boundary (mouse points are translated back by
            // `-edgePad` before reaching the handlers).
            let edgePad: CGFloat = 24
            let size = CGSize(
                width: max(1, geo.size.width - 2 * edgePad),
                height: max(1, geo.size.height - 2 * edgePad)
            )
            // Seeds = base scale points + octave-repeat ghosts in the
            // flanking half-octaves. Inset Voronoi cells: each polygon
            // is the outer Voronoi cell pulled in by `marginPixels` on
            // every bisector edge. Only the inner polygons are drawn —
            // the outer cells are implied by the gaps between them.
            let seeds = displaySeeds()
            // Memoized: the cell geometry depends only on the seeds,
            // size, and margin — NOT on the sounding fill. While the
            // user glides through a soft region the fill weights change
            // every tick (re-running `body`), but the seeds don't, so
            // the cache returns the prior cells instead of re-solving
            // the O(N²) Voronoi (and re-allocating its polygons) each
            // frame.
            let innerCells = voronoiCache.cells(
                seeds: seeds,
                width: size.width,
                height: size.height,
                inset: marginPixels,
                xMin: xLo, xMax: xHi
            )
            ZStack(alignment: .topLeading) {
                Color.black

                // 1. STATIC layer: octave boundaries + inner-polygon
                // outlines + (when dragging) snap gridlines. None of
                // this depends on what's sounding, so it isn't redrawn
                // while gliding — the live fills are a separate
                // `CellFillsView` overlay below.
                Canvas { ctx, _ in
                    // Shift logical (0,0) to (edgePad, edgePad) so edge
                    // strokes draw inside the canvas bounds, not at the
                    // clip seam.
                    ctx.translateBy(x: edgePad, y: edgePad)

                    // 1·. Octave boundaries — faint full-height lines at
                    // 1/1 (logX 0) and 2/1 (logX 1) marking the base
                    // octave the scale is defined over. Drawn under the
                    // cells so the bright borders read on top. Hidden in
                    // performance mode.
                    if !engine.performanceMode {
                        for boundary in [0.0, 1.0] {
                            let bx = xToPixel(boundary, width: size.width)
                            var line = Path()
                            line.move(to: CGPoint(x: bx, y: 0))
                            line.addLine(to: CGPoint(x: bx, y: size.height))
                            ctx.stroke(line, with: .color(.white.opacity(0.75)),
                                       lineWidth: 1)
                        }
                    }

                    // 1a. Inner polygon border — an inset outline that
                    // marks the boundary of the "exact pitch" zone,
                    // tinted with the pitch's hue. The interior fill is
                    // drawn by `CellFillsView` only while sounding. Shown
                    // in performance mode too — the cell outlines stay.
                    for cell in innerCells where cell.polygon.count >= 3 {
                        ctx.stroke(Path(closedPolygon: cell.polygon),
                                   with: .color(pitchColor(
                                       forRatio: cell.seed.ratio,
                                       lightness: 0.82, chroma: 0.20)),
                                   lineWidth: 2)
                    }

                    // 1b. Snap gridlines for "simple" fractions, shown
                    // only while shift+dragging. The Tenney/prime
                    // sliders in the toolbar control which fractions
                    // qualify as snap targets.
                    if snapping {
                        var targets = engine.snapTargets()
                        // The dragged pitch's starting fraction is
                        // always a snap target — append it if the
                        // filters would otherwise exclude it. The line
                        // for it gets a distinct color below.
                        let originalKey: (Int, Int)? = dragOriginalFraction
                            .map { ($0.num, $0.den) }
                        if let orig = dragOriginalFraction,
                           !targets.contains(where: {
                               $0.num == orig.num && $0.den == orig.den
                           }) {
                            targets.append(orig)
                        }
                        let snapKey: (Int, Int)? = snapTargetFraction
                            .map { ($0.num, $0.den) }
                        for frac in targets {
                            let xF = log2(Double(frac.num) / Double(frac.den))
                            let x = xToPixel(xF, width: size.width)
                            let isOriginal = (frac.num == originalKey?.0
                                              && frac.den == originalKey?.1)
                            let isSnapping = (frac.num == snapKey?.0
                                              && frac.den == snapKey?.1)
                            // Both the dragged-pitch's own line ("you
                            // started here") and the gridline the
                            // cursor is currently snapping to get the
                            // pitch's OKLCH hue + thicker stroke.
                            let isHighlighted = isOriginal || isSnapping
                            let cx = complexity(num: frac.num, den: frac.den)
                            let heightFrac = max(
                                0.15,
                                1.0 - Double(cx - 2) * 0.05
                            )
                            // Each gridline is drawn as two equal-
                            // length strips: one from the top down
                            // and one from the bottom up. When
                            // heightFrac > 0.5 the strips overlap and
                            // the line reads as continuous; below
                            // that, the center stays open so complex
                            // ratios only catch the cursor near the
                            // edges of the pad.
                            let strip = CGFloat(heightFrac) * size.height
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: 0))
                            line.addLine(to: CGPoint(x: x, y: strip))
                            line.move(to: CGPoint(x: x, y: size.height - strip))
                            line.addLine(to: CGPoint(x: x, y: size.height))
                            let lineColor: Color = isHighlighted
                                ? pitchColor(forRatio: Double(frac.num)
                                                       / Double(frac.den),
                                             lightness: 0.85, chroma: 0.18)
                                : .white.opacity(0.7)
                            ctx.stroke(line, with: .color(lineColor),
                                       lineWidth: isHighlighted ? 2.2 : 1.4)
                        }
                    }

                    // 1c. Y-snap gridlines, shown only while command
                    // is held during a drag. All 7 lines span the
                    // full pad width since y is layout-only — no
                    // complexity-based length. The active one (the
                    // snap target) takes the dragged pitch's OKLCH
                    // hue + thicker stroke, mirroring the vertical
                    // highlight.
                    if snappingY {
                        let activeY = snapTargetY
                        let ratio = engine.sounding.ratio
                        for yFrac in yGridPositions {
                            let py = CGFloat(yFrac) * size.height
                            var line = Path()
                            line.move(to: CGPoint(x: 0, y: py))
                            line.addLine(to: CGPoint(x: size.width, y: py))
                            let isActive = activeY.map {
                                abs($0 - yFrac) < 1e-6
                            } ?? false
                            let lineColor: Color
                            if isActive, let r = ratio {
                                lineColor = pitchColor(
                                    forRatio: r,
                                    lightness: 0.85, chroma: 0.18
                                )
                            } else if isActive {
                                lineColor = Color.cyan
                            } else {
                                lineColor = .white.opacity(0.7)
                            }
                            ctx.stroke(line, with: .color(lineColor),
                                       lineWidth: isActive ? 2.2 : 1.4)
                        }
                    }
                }

                // 1d. DYNAMIC layer: the live cell fills. Observes only
                // `SoundingState`, so when a glide changes the weights
                // every tick this is the *only* thing that re-renders —
                // the static Canvas above, the discs, and the toolbar
                // stay put.
                CellFillsView(sounding: engine.sounding,
                              cells: innerCells, edgePad: edgePad)

                // 2. Pitch control points — one colored disc per
                // base-octave seed, filled with the pitch's own hue,
                // with the label centered inside. Octave-repeat ghosts
                // get no disc (their cells still play). The base-octave
                // fraction floats above the disc only while that control
                // point is being clicked / dragged.
                ForEach(engine.performanceMode ? [] : seeds.filter { !$0.isGhost }) { seed in
                    let x = xToPixel(seed.logX, width: size.width) + edgePad
                    let y = CGFloat(seed.y) * size.height + edgePad
                    let isDragging = draggingPitchID == seed.sourceID
                    let isHovered = hoveredId == seed.sourceID
                    let active = isDragging || isHovered
                    let diameter: CGFloat = isDragging ? 30 : 26

                    if isDragging {
                        Text(seed.ratioString)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color(white: 0.12)))
                            .position(x: x, y: y - diameter / 2 - 11)
                    }

                    Circle()
                        // Match the cell's border/fill hue so the disc
                        // reads as part of the same pitch.
                        .fill(pitchColor(forRatio: seed.ratio,
                                         lightness: 0.82, chroma: 0.20))
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            // Only a white ring on hover / drag — no
                            // border at rest.
                            if active {
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                            }
                        }
                        .overlay {
                            Text(seed.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6),
                                        radius: 1, x: 0, y: 0.5)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                        }
                        .position(x: x, y: y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                PadMouseCapture(
                    onMouseDown: { pt, shift in
                        handleDown(at: toLocal(pt, pad: edgePad), shift: shift, in: size)
                    },
                    onMouseDragged: { pt in
                        handleDrag(at: toLocal(pt, pad: edgePad), in: size)
                    },
                    onMouseUp: {
                        handleUp()
                    },
                    onMouseMoved: { pt in
                        let h = nearestPitchPointID(at: toLocal(pt, pad: edgePad),
                                                    in: size,
                                                    threshold: handleHitRadius)
                        if h != hoveredId { hoveredId = h }
                    },
                    onFlagsChanged: {
                        handleFlagsChanged(in: size)
                    },
                    onRightMouseDown: { pt in
                        handleRightDown(at: toLocal(pt, pad: edgePad), in: size)
                    }
                )
            )
        }
    }

    // MARK: Interactions

    private func handleDown(at pt: CGPoint, shift: Bool, in size: CGSize) {
        dragScratch.lastPoint = pt
        if shift {
            if let id = nearestPitchPointID(at: pt, in: size,
                                            threshold: handleHitRadius + 4),
               let hit = engine.scale.points.first(where: { $0.id == id }) {
                // Shift on a handle is ambiguous between "remove" and
                // "start a snap-drag." Defer commitment to mouseUp:
                // the first drag move will clear `pendingRemoveID`,
                // turning the gesture into a snap-drag.
                pendingRemoveID = id
                draggingPitchID = id
                beginHandleDrag(pitch: hit, clickPoint: pt, in: size)
                beginSounding(weights: [DisplaySeed.makeID(hit.id, shift: 0): 1.0], ratio: hit.ratio)
            } else {
                // Shift on empty space adds a pitch at the click
                // position, then enters drag mode on the new pitch so
                // the user can keep holding shift and snap-drag it to
                // the desired simple fraction. The scale is defined
                // only over the base octave, so a click in a flanking
                // half-octave folds back into `[0, 1)` (its pitch
                // class) rather than creating an out-of-octave point.
                let rawLogX = pixelToX(pt.x, width: size.width)
                let foldedX = rawLogX - floor(rawLogX)
                let yF = clamp01(Double(pt.y / size.height))
                let ratio = pow(2.0, foldedX)
                let (n, d) = bestFraction(ratio)
                let new = PitchPoint(num: n, den: d, y: yF)
                engine.scale.points.append(new)
                draggingPitchID = new.id
                // New pitch is created AT the cursor, so no offset
                // and no meaningful "original position" to anchor.
                dragOffsetPixel = .zero
                dragOriginalFraction = nil
                beginSounding(weights: [DisplaySeed.makeID(new.id, shift: 0): 1.0], ratio: new.ratio)
            }
            return
        }
        // Click on a handle → free drag, also sounding so the user
        // can fine-tune by ear.
        if let id = nearestPitchPointID(at: pt, in: size,
                                        threshold: handleHitRadius),
           let hit = engine.scale.points.first(where: { $0.id == id }) {
            draggingPitchID = id
            beginHandleDrag(pitch: hit, clickPoint: pt, in: size)
            beginSounding(weights: [DisplaySeed.makeID(hit.id, shift: 0): 1.0], ratio: hit.ratio)
            return
        }
        // Click in empty space → play the cell's pitch, blended across
        // up to three cells if the click landed in a soft margin or
        // triple junction.
        guard let hit = pitchAt(at: pt, in: size) else { return }
        beginSounding(weights: hit.weights, ratio: hit.ratio)
    }

    /// Right-click on a disc disables its note (drops it from the
    /// scale; it stays in the editor's Disabled section to re-enable).
    private func handleRightDown(at pt: CGPoint, in size: CGSize) {
        guard let id = nearestPitchPointID(at: pt, in: size,
                                           threshold: handleHitRadius),
              let i = engine.scale.points.firstIndex(where: { $0.id == id })
        else { return }
        engine.scale.points[i].enabled = false
    }

    private func beginHandleDrag(pitch p: PitchPoint, clickPoint: CGPoint,
                                 in size: CGSize) {
        let handlePos = pointPixel(p, in: size)
        dragOffsetPixel = CGPoint(
            x: handlePos.x - clickPoint.x,
            y: handlePos.y - clickPoint.y
        )
        dragOriginalFraction = (num: p.num, den: p.den)
    }

    private func handleDrag(at pt: CGPoint, in size: CGSize) {
        dragScratch.lastPoint = pt
        evaluateDrag(at: pt, in: size)
    }

    /// Re-fire the drag-tick logic at the most recent cursor point.
    /// Called when the modifier flags change mid-drag so snap state
    /// updates immediately without waiting for the next mouse move.
    /// We also re-anchor the click-relative offset to the handle's
    /// *current* position — so toggling command (which locks the
    /// pitch) doesn't smear the handle when the modifier flips.
    private func handleFlagsChanged(in size: CGSize) {
        guard draggingPitchID != nil || activeTouchId != nil else { return }
        reanchorOffsetToHandle(at: dragScratch.lastPoint, in: size)
        evaluateDrag(at: dragScratch.lastPoint, in: size)
    }

    private func reanchorOffsetToHandle(at cursor: CGPoint, in size: CGSize) {
        guard let dragID = draggingPitchID,
              let idx = engine.scale.points.firstIndex(where: { $0.id == dragID })
        else { return }
        let handlePos = pointPixel(engine.scale.points[idx], in: size)
        dragOffsetPixel = CGPoint(
            x: handlePos.x - cursor.x,
            y: handlePos.y - cursor.y
        )
    }

    private func evaluateDrag(at pt: CGPoint, in size: CGSize) {
        // Re-check modifier state every tick so the user can press
        // or release shift / command and snap engages / disengages
        // accordingly. Command takes priority over shift: while
        // command is held the pitch is **locked** (only y can change)
        // and the vertical gridlines hide regardless of shift.
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        let isHandleDrag = draggingPitchID != nil
        // Guard the writes: in cell-glide mode both are false every
        // tick, and re-assigning unchanged `@State` would still
        // re-render the whole surface each frame.
        let wantSnapping = shiftHeld && isHandleDrag && !commandHeld
        let wantSnappingY = commandHeld && isHandleDrag
        if snapping != wantSnapping { snapping = wantSnapping }
        if snappingY != wantSnappingY { snappingY = wantSnappingY }

        if let dragID = draggingPitchID,
           let idx = engine.scale.points.firstIndex(where: { $0.id == dragID }) {
            // Any drag movement → cancel the deferred remove (this is
            // a drag, not a click).
            pendingRemoveID = nil
            // Apply the click-relative offset so the handle moves
            // *with* the cursor instead of jumping to it.
            let targetX = pt.x + dragOffsetPixel.x
            let targetY = pt.y + dragOffsetPixel.y
            // Base points live in the base octave, so clamp the
            // dragged x to `[0, 1]` in log-frequency even though the
            // pad extends past it for the ghost flanks.
            let rawXF = clamp01(pixelToX(targetX, width: size.width))
            let rawYF = clamp01(Double(targetY / size.height))

            // Y-snap: command snaps to the nearest of `yGridPositions`.
            // Otherwise the cursor's y carries through unchanged.
            let yF: Double
            if commandHeld {
                let snapped = yGridPositions.min { lhs, rhs in
                    abs(lhs - rawYF) < abs(rhs - rawYF)
                } ?? 0.5
                snapTargetY = snapped
                yF = snapped
            } else {
                snapTargetY = nil
                yF = rawYF
            }
            engine.scale.points[idx].y = yF

            // Pitch lock: while command is held, num/den don't change
            // and there's no x-snap target to highlight. Y already
            // updated above; nothing more to do.
            if commandHeld {
                snapTargetFraction = nil
                return
            }

            // X update — with shift-snap when the cursor is over a
            // gridline whose drawn extent reaches the (post-y-snap)
            // handle position, free continued-fraction otherwise. The
            // hit x is taken from the base-octave-clamped `rawXF` so
            // snapping is evaluated at the handle's actual position.
            let hitPoint = CGPoint(
                x: xToPixel(rawXF, width: size.width),
                y: CGFloat(yF) * size.height
            )
            let n: Int, d: Int, targetRatio: Double
            if shiftHeld, let target = snapTargetUnder(at: hitPoint, in: size) {
                snapTargetFraction = (num: target.num, den: target.den)
                n = target.num
                d = target.den
                targetRatio = Double(n) / Double(d)
            } else {
                snapTargetFraction = nil
                let ratio = pow(2.0, rawXF)
                let bf = bestFraction(ratio)
                n = bf.num
                d = bf.den
                targetRatio = ratio
            }
            engine.scale.points[idx].num = n
            engine.scale.points[idx].den = d
            if let touch = activeTouchId {
                engine.glide(touchId: touch, ratio: targetRatio)
            }
            return
        }
        // Cell-glide mode: the ratio comes from `pitchAt`, which
        // returns the cell's exact ratio inside an inner polygon and a
        // log-frequency blend across two (soft margin) or three (triple
        // junction) cells otherwise. The fills cross-fade by the same
        // per-seed weights.
        guard let touch = activeTouchId,
              let hit = pitchAt(at: pt, in: size) else { return }
        engine.glide(touchId: touch, ratio: hit.ratio, weights: hit.weights)
    }

    private func handleUp() {
        // Shift-click-without-drag on a handle commits to remove.
        if let removeID = pendingRemoveID,
           let idx = engine.scale.points.firstIndex(where: { $0.id == removeID }) {
            engine.scale.points.remove(at: idx)
        }
        pendingRemoveID = nil
        if let touch = activeTouchId {
            engine.noteOff(touchId: touch)
        }
        activeTouchId = nil
        // `engine.noteOff` already clears `sounding.weights` once the
        // last touch lifts.
        draggingPitchID = nil
        dragOffsetPixel = .zero
        dragOriginalFraction = nil
        snapTargetFraction = nil
        snapTargetY = nil
        snapping = false
        snappingY = false
    }

    /// Returns the nearest snap-target gridline (by x distance) whose
    /// drawn extent reaches the cursor's y. Shorter (complex) lines
    /// drop out as the cursor moves down — the user has to raise the
    /// cursor toward the top of the pad to make complex ratios
    /// eligible, while 1/1 (full height) stays a candidate
    /// everywhere. The dragged pitch's starting fraction is included
    /// even when it falls outside the engine's filter.
    private func snapTargetUnder(at pt: CGPoint, in size: CGSize)
        -> (num: Int, den: Int)?
    {
        var targets = engine.snapTargets()
        if let orig = dragOriginalFraction,
           !targets.contains(where: { $0.num == orig.num && $0.den == orig.den }) {
            targets.append(orig)
        }
        var best: (num: Int, den: Int)? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for frac in targets {
            // Same two-strip eligibility as the Canvas — the cursor
            // counts as "over" the line if it falls inside the top
            // strip OR the bottom strip. For heightFrac > 0.5 the
            // strips union covers the entire pad; for shorter lines
            // (complex ratios) only the top/bottom edges qualify.
            let cx = complexity(num: frac.num, den: frac.den)
            let heightFrac = max(0.15, 1.0 - Double(cx - 2) * 0.05)
            let strip = CGFloat(heightFrac) * size.height
            let inTopStrip = pt.y <= strip
            let inBotStrip = pt.y >= size.height - strip
            if !inTopStrip && !inBotStrip { continue }
            let xF = log2(Double(frac.num) / Double(frac.den))
            let lineX = xToPixel(xF, width: size.width)
            let dx = abs(lineX - pt.x)
            if dx < bestDist {
                bestDist = dx
                best = frac
            }
        }
        return best
    }

    private func beginSounding(weights: [String: Double], ratio: Double) {
        let touch = nextTouchId()
        activeTouchId = touch
        engine.noteOn(touchId: touch, ratio: ratio, weights: weights)
    }

    // MARK: Geometry

    /// Translate a mouse point from view space (where the capture
    /// overlay reports it) into the pad's logical `[0, size]` space by
    /// removing the edge padding. All interaction math downstream
    /// assumes logical coordinates.
    private func toLocal(_ pt: CGPoint, pad: CGFloat) -> CGPoint {
        CGPoint(x: pt.x - pad, y: pt.y - pad)
    }

    private func pointPixel(_ p: PitchPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: xToPixel(p.xFraction, width: size.width),
                y: CGFloat(p.y) * size.height)
    }

    private func nearestPitchPointID(at pt: CGPoint, in size: CGSize,
                                     threshold: CGFloat) -> UUID? {
        var bestID: UUID? = nil
        var bestDist: CGFloat = threshold
        for p in engine.scale.points where p.enabled {
            let pos = pointPixel(p, in: size)
            let dx = pos.x - pt.x
            let dy = pos.y - pt.y
            let d = sqrt(dx*dx + dy*dy)
            if d < bestDist {
                bestDist = d
                bestID = p.id
            }
        }
        return bestID
    }

    /// Resolves a cursor position to the ratio that should sound and a
    /// per-seed weight map (keyed by `DisplaySeed.id`, summing to 1)
    /// used both to blend the pitch and to cross-fade the cell fills.
    ///
    /// Soft Voronoi. For seeds `s, s'`, the signed distance from the
    /// cursor to their bisector — positive on `s`'s side — is
    /// `h(s,s') = (d_s'² − d_s²) / (2·|s−s'|)`. For each seed,
    /// `raw_s = max(0, margin + min_{s'} h(s,s'))` is how far the
    /// cursor has penetrated past `s`'s inner-polygon edge along its
    /// most-binding bisector; weights are `raw_s` normalized. This:
    ///   • inside an inner polygon → the owner's raw ≥ margin and every
    ///     other raw is 0, so weight = 1 on a single pitch;
    ///   • in a 2-cell margin (quadrilateral) → exactly two non-zero
    ///     weights, reducing to the linear `(margin±h)/2margin` blend;
    ///   • in a 3-cell triangle (triple junction) → three non-zero
    ///     weights, e.g. ⅓ each at the Voronoi vertex.
    /// It is continuous everywhere — the owner's `raw ≥ margin > 0`
    /// keeps the normalizing sum positive — so the old discontinuity
    /// where the single "closest bisector" flipped between A–B and A–C
    /// inside the triangle is gone. The played pitch is
    /// `2 ^ Σ wₛ·log2(ratioₛ)`.
    private func pitchAt(at pt: CGPoint, in size: CGSize)
        -> (ratio: Double, weights: [String: Double])?
    {
        let seeds = displaySeeds()
        guard !seeds.isEmpty else { return nil }

        var positions: [CGPoint] = []
        var dist2s: [Double] = []
        positions.reserveCapacity(seeds.count)
        dist2s.reserveCapacity(seeds.count)
        for s in seeds {
            let pos = CGPoint(x: xToPixel(s.logX, width: size.width),
                              y: CGFloat(s.y) * size.height)
            let dx = Double(pos.x - pt.x)
            let dy = Double(pos.y - pt.y)
            positions.append(pos)
            dist2s.append(dx*dx + dy*dy)
        }

        var nearestIdx = 0
        for i in 1..<seeds.count where dist2s[i] < dist2s[nearestIdx] {
            nearestIdx = i
        }

        let m = Double(marginPixels)
        // Rigid Voronoi (no soft margin) or a lone seed → exact pitch.
        if m <= 0 || seeds.count == 1 {
            return (seeds[nearestIdx].ratio, [seeds[nearestIdx].id: 1.0])
        }

        var raw = [Double](repeating: 0, count: seeds.count)
        var sum = 0.0
        for s in 0..<seeds.count {
            let ps = positions[s]
            let ds2 = dist2s[s]
            var minH = Double.greatestFiniteMagnitude
            for j in 0..<seeds.count where j != s {
                let dx = Double(positions[j].x - ps.x)
                let dy = Double(positions[j].y - ps.y)
                let len = (dx*dx + dy*dy).squareRoot()
                if len == 0 { continue }
                let h = (dist2s[j] - ds2) / (2 * len)
                if h < minH { minH = h }
            }
            let r = max(0, m + minH)
            raw[s] = r
            sum += r
        }
        guard sum > 0 else {
            return (seeds[nearestIdx].ratio, [seeds[nearestIdx].id: 1.0])
        }

        var weights: [String: Double] = [:]
        var logSum = 0.0
        for s in 0..<seeds.count where raw[s] > 0 {
            let w = raw[s] / sum
            weights[seeds[s].id] = w
            logSum += w * seeds[s].logX
        }
        return (pow(2, logSum), weights)
    }

    private func nextTouchId() -> Int {
        touchCounter &+= 1
        return touchCounter
    }
}

// MARK: - Editor

private struct PitchPadEditor: View {
    @ObservedObject var engine: PitchPadEngine

    var body: some View {
        // Active scale = enabled notes; disabled ones are parked below.
        let enabled = engine.scale.points.filter(\.enabled)
        let disabled = engine.scale.points.filter { !$0.enabled }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Scale (\(enabled.count))")
                    .font(.caption.weight(.bold))
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
                    // Identity by PitchPoint.id so rows survive sort /
                    // remove without leaking stale TextField content
                    // into the wrong row.
                    ForEach(enabled) { p in
                        EditorRow(engine: engine, pointID: p.id)
                    }
                    if !disabled.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("Disabled (\(disabled.count))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        ForEach(disabled) { p in
                            EditorRow(engine: engine, pointID: p.id)
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

private struct EditorRow: View {
    @ObservedObject var engine: PitchPadEngine
    let pointID: UUID

    /// Resolve our point by id on each access. Rows survive sort and
    /// remove operations on the underlying array without binding to a
    /// stale index.
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

    /// Text bindings read directly from the engine each render — no
    /// `@State` indirection — so a drag on the pad reflects in the
    /// row's text fields *the same frame* as it reflects in the pad.
    /// The setter is a no-op: typed input lives in the underlying
    /// `NSTextField` until commit, then `onCommit` writes the engine.
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
            // The colored chip doubles as the enable / disable toggle:
            // a solid hue fill when enabled, a hollow ring (same hue)
            // when disabled. Disabled notes drop out of the scale (no
            // cell/disc on the pad) but stay listed so they can be
            // toggled straight back in.
            Button {
                if let i = currentIndex { engine.scale.points[i].enabled.toggle() }
            } label: {
                let hue = pitchColor(forRatio: p.ratio, lightness: 0.68, chroma: 0.15)
                Circle()
                    .fill(p.enabled ? hue : .clear)
                    .frame(width: 14, height: 14)
                    // strokeBorder insets the ring so a 2px stroke
                    // stays within the frame instead of spilling past
                    // the leading edge and being clipped.
                    .overlay(Circle().strokeBorder(
                        p.enabled ? Color.black.opacity(0.7) : hue,
                        lineWidth: p.enabled ? 1 : 2))
            }
            .buttonStyle(.plain)
            .help(p.enabled ? "Disable (remove from the scale)"
                            : "Enable (add to the scale)")

            // Custom name — freeform; scroll does nothing here. Empty
            // falls back to the ratio on the pad (see `displayLabel`).
            ScrollableField(
                text: labelBinding(),
                onScrollStep: { _ in },
                onCommit: { txt in commitLabel(txt) }
            )
            .frame(width: 56, height: 20)

            ScrollableField(
                text: ratioBinding(),
                onScrollStep: { dir in incrementPitch(by: dir) },
                onCommit: { txt in commitRatio(txt) }
            )
            .frame(width: 56, height: 20)

            ScrollableField(
                text: yBinding(),
                onScrollStep: { dir in incrementY(by: dir) },
                onCommit: { txt in commitY(txt) }
            )
            .frame(width: 48, height: 20)

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
        // Dim a disabled row; the hollow chip already reads as "off"
        // and stays legible at this opacity.
        .opacity(p.enabled ? 1 : 0.55)
    }

    // MARK: - Formatting helpers

    private func formatRatio(num: Int, den: Int) -> String { "\(num)/\(den)" }
    /// Internal y is [0, 1] with 0 at the top. User-facing y is
    /// [-3, 3] with 0 at the center; integers correspond to the
    /// command-snap gridlines. Positive user-y = "above center" in
    /// the screen-up direction.
    private func formatY(_ y: Double) -> String {
        let userY = 3 - 6 * y
        return String(format: "%.1f", userY)
    }

    // MARK: - Scroll increments

    /// Scroll on the pitch field walks to the next/previous gridline
    /// fraction in the engine's snap-target list (filtered by prime
    /// limit, deduped at 10 cents).
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
            // The scale spans the half-open octave [1, 2); a typed
            // ratio outside that range folds to its pitch class by
            // ×/÷ 2 (and reduces). In-range input is left exactly as
            // typed so unreduced fractions like 6/4 are preserved.
            let ratio = Double(n) / Double(d)
            let (fn, fd) = (ratio >= 1.0 && ratio < 2.0)
                ? (n, d)
                : octaveFolded(num: n, den: d)
            engine.scale.points[i].num = fn
            engine.scale.points[i].den = fd
        }
        // No `ratioText` state to reset — the binding pulls straight
        // from the engine on the next render and `ScrollableField`'s
        // `updateNSView` syncs the field's stringValue automatically.
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

private func clamp01(_ x: Double) -> Double { min(max(0, x), 1) }

// MARK: - Transient drag scratch

/// Holds transient per-drag scratch that updates every mouse tick but
/// must not re-render the view (it's only read back on a modifier
/// change). A plain reference in `@State` — not observed.
final class DragScratch {
    var lastPoint: CGPoint = .zero
}

// MARK: - Mouse capture (mirrors KeyboardMouseCapture in SimulatorView)

/// AppKit-backed mouse capture so drag events arrive at full
/// resolution. SwiftUI's DragGesture coalesces moves on macOS, which
/// makes a glide stutter. Also tracks `mouseMoved` (without a drag in
/// progress) so the pad can show a hover halo around the nearest
/// pitch handle.
private struct PadMouseCapture: NSViewRepresentable {
    let onMouseDown: (CGPoint, Bool) -> Void
    let onMouseDragged: (CGPoint) -> Void
    let onMouseUp: () -> Void
    let onMouseMoved: (CGPoint) -> Void
    let onFlagsChanged: () -> Void
    let onRightMouseDown: (CGPoint) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onMouseMoved = onMouseMoved
        v.onFlagsChanged = onFlagsChanged
        v.onRightMouseDown = onRightMouseDown
        return v
    }

    func updateNSView(_ v: CaptureView, context: Context) {
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onMouseMoved = onMouseMoved
        v.onFlagsChanged = onFlagsChanged
        v.onRightMouseDown = onRightMouseDown
    }

    final class CaptureView: NSView {
        var onMouseDown: ((CGPoint, Bool) -> Void)?
        var onMouseDragged: ((CGPoint) -> Void)?
        var onMouseUp: (() -> Void)?
        var onMouseMoved: ((CGPoint) -> Void)?
        var onFlagsChanged: (() -> Void)?
        var onRightMouseDown: ((CGPoint) -> Void)?
        private var trackingArea: NSTrackingArea?
        /// Local NSEvent monitor for `flagsChanged`. Installed when
        /// the view is in a window so the SwiftUI layer hears about
        /// shift / command transitions immediately, not only on the
        /// next mouseMoved tick.
        private var flagsMonitor: Any?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area = trackingArea { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installFlagsMonitor()
            } else {
                removeFlagsMonitor()
            }
        }

        private func installFlagsMonitor() {
            if flagsMonitor != nil { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .flagsChanged
            ) { [weak self] event in
                self?.onFlagsChanged?()
                return event
            }
        }

        private func removeFlagsMonitor() {
            if let m = flagsMonitor {
                NSEvent.removeMonitor(m)
                flagsMonitor = nil
            }
        }

        deinit {
            removeFlagsMonitor()
        }

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

        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            onMouseMoved?(loc)
        }

        override func rightMouseDown(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            onRightMouseDown?(loc)
        }
    }
}

// MARK: - Scrollable editable text field

/// A small `NSTextField` wrapper that emits ±1 "step" events when the
/// user scrolls the wheel over it, while still letting them click to
/// edit the value as plain text. Scroll deltas accumulate so a
/// trackpad's many small events still emit one step per "click worth"
/// of motion (`threshold = 1.0` matches a typical mouse-wheel detent).
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
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.alignment = .center
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.usesSingleLineMode = true
        f.lineBreakMode = .byClipping
        f.onScrollStep = onScrollStep
        return f
    }

    func updateNSView(_ f: AccumField, context: Context) {
        // Don't clobber what the user is actively typing.
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
