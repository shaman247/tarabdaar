import QuartzCore
import StarpadCore
import SwiftUI

/// The iPad Pitch Pad — the instrument's playing surface (replacing the
/// piano keyboard). Touch position resolves to a JI ratio via the shared
/// soft-Voronoi `pitchAt`; `PitchPadEngine` pins a MIDI note and bends to
/// the ratio, while its 60 Hz tilt loop overlays aftertouch / CC from the
/// `DimensionMapping` matrix. Scale editing lives on StarpadMac
/// and syncs here over USB-MIDI SysEx (the iPad is perform-only); the MAP
/// (dimension-matrix) editor is reached via the toolbar.
struct PitchPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    /// Source of the live calibrated tilt values shown in the toolbar
    /// (and the DimensionMapping host driving pad expression).
    @ObservedObject var noteManager: NoteManager
    /// Mac→iPad scale-sync receiver; drives the toolbar's sync indicator.
    @ObservedObject var scaleSync: ScaleSyncReceiver
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          onShowMapping: onShowMapping, onRecalibrate: onRecalibrate)
            PitchPadSurfaceIOS(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Shared pad toolbar (iPad)

/// The common iPad pad toolbar — PANIC / MAP, the scale-sync indicator, live
/// tilt meters, the sounding readout, the (read-only) synced tonic, and
/// recalibrate. Shared by all three iPad playing surfaces.
struct PadToolbarIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    /// When set (Fret Pad), a REC toggle records play strokes for offline
    /// assist fitting (see `FretGestureRecorder`).
    var recorder: FretGestureRecorder? = nil
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("PANIC", color: .red) { engine.panic() }
            button("MAP", color: .orange, action: onShowMapping)
            if let recorder {
                RecToggleIOS(recorder: recorder)
            }
            ScaleSyncIndicator(scaleSync: scaleSync)
            Spacer(minLength: 12)
            TiltBars(tilts: noteManager.currentTilt)
            Spacer(minLength: 12)
            PadSoundingReadout(sounding: engine.sounding, tonicMidi: engine.tonicMidi)
            // Tonic is set on the Mac and synced over, so it's read-only here.
            Text("Tonic \(Scale.noteName(for: engine.tonicMidi))")
                .font(.caption2).foregroundColor(.gray)
                .fixedSize()
            Button(action: onRecalibrate) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption).foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black)
    }

    private func button(_ title: String, color: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.7))
                .cornerRadius(6)
        }
    }
}

// MARK: - Sounding readout

/// Compact live Hz / note / cents readout for the active touch, tinted
/// in its OKLCH hue. Observes only `SoundingState`, so the per-tick ratio
/// updates re-render just this label.
private struct PadSoundingReadout: View {
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
        } ?? ""
        let color: Color = ratio.map {
            pitchColor(forRatio: $0, lightness: 0.85, chroma: 0.18)
        } ?? .clear
        return Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: 150, alignment: .trailing)
    }
}

// MARK: - Stroke-recording toggle (Fret Pad)

/// REC button for the iPad Fret Pad: records play strokes (raw movements +
/// fret context) to the app's **Documents/FretRecordings/** folder as JSONL —
/// visible in the Files app and Finder's device browser — for fitting the
/// drag-assist parameters to real playing (`tools/fretpad_fit.py`).
private struct RecToggleIOS: View {
    @ObservedObject var recorder: FretGestureRecorder

    var body: some View {
        Button {
            recorder.setRecording(!recorder.isRecording)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(recorder.isRecording ? "REC \(recorder.strokeCount)" : "REC")
                    .font(.caption).fontWeight(.bold).monospacedDigit()
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((recorder.isRecording ? Color.red : Color.gray)
                .opacity(recorder.isRecording ? 0.45 : 0.25))
            .cornerRadius(6)
        }
    }
}

// MARK: - Scale-sync indicator

/// Mac→iPad scale-sync status: a green dot once the Mac has pushed a scale,
/// gray until then.
struct ScaleSyncIndicator: View {
    @ObservedObject var scaleSync: ScaleSyncReceiver

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(scaleSync.syncCount > 0 ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(scaleSync.syncCount > 0 ? "synced" : "no sync")
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Tilt bars

/// The three calibrated tilt axes (-1…+1) shown as horizontal center-zero
/// meters, side by side. Driven by `NoteManager.currentTilt`, which the
/// note manager refreshes from the motion source each tick.
private struct TiltBars: View {
    let tilts: [Double]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 2) {
                    Text("T\(i + 1)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                    TiltMeter(value: i < tilts.count ? tilts[i] : 0)
                        .frame(width: 64, height: 6)
                }
            }
        }
    }
}

/// A single center-zero bar: fill grows from the center toward the right
/// for positive values, toward the left for negative.
private struct TiltMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = max(-1.0, min(1.0, value))
            let barWidth = w * CGFloat(abs(clamped)) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.25))
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1)
                    .offset(x: w / 2 - 0.5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan)
                    .frame(width: barWidth)
                    .offset(x: clamped >= 0 ? w / 2 : w / 2 - barWidth)
            }
        }
    }
}

// MARK: - Pad surface

private struct PitchPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    /// Mirrors the Mac surface: memoize the seed list + Voronoi solve so
    /// a fill-only re-render doesn't re-solve the O(N²) cells.
    @State private var voronoiCache = VoronoiCache()
    @State private var seedsCache = SeedsCache()
    @State private var touchInfos: [TouchInfo] = []

    /// Padding inset (matches the Mac pad) so edge cell borders, discs,
    /// and labels have room instead of clipping at the bounds.
    private let edgePad: CGFloat = 24
    private var marginPixels: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(
                width: max(1, geo.size.width - 2 * edgePad),
                height: max(1, geo.size.height - 2 * edgePad)
            )
            let seeds = seedsCache.seeds(points: engine.scale.points) {
                computeDisplaySeeds(points: engine.scale.points)
            }
            let innerCells = voronoiCache.cells(
                seeds: seeds, width: size.width, height: size.height,
                inset: marginPixels, xMin: PadConstants.xLo, xMax: PadConstants.xHi
            )

            ZStack(alignment: .topLeading) {
                Color.black

                // Static layer: inner-polygon cell borders. The iPad is
                // always in "perform" mode — no control discs and no
                // octave boundary lines, just the cell outlines, the black
                // field, and the live sounding fills.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    for cell in innerCells where cell.polygon.count >= 3 {
                        ctx.stroke(Path(closedPolygon: cell.polygon),
                                   with: .color(pitchColor(
                                       forRatio: cell.seed.ratio,
                                       lightness: 0.82, chroma: 0.20)),
                                   lineWidth: 2)
                    }
                }

                // Dynamic layer: live sounding fills (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: innerCells, edgePad: edgePad)

                // Multitouch capture, inset to the logical pad area so
                // its reported fractions map straight to `[0, size]`.
                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in handle(ev, seeds: seeds, size: size, began: true) },
                    onTouchMoved: { ev in handle(ev, seeds: seeds, size: size, began: false) },
                    onTouchEnded: { id in engine.noteOff(touchId: id) }
                )
                .padding(edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func handle(_ ev: TouchEvent, seeds: [DisplaySeed], size: CGSize,
                        began: Bool) {
        let pt = CGPoint(x: ev.xFraction * size.width,
                         y: ev.yFraction * size.height)
        guard let hit = pitchAt(point: pt, seeds: seeds, size: size,
                                marginPixels: marginPixels) else { return }
        if began {
            engine.noteOn(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        } else {
            engine.glide(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        }
    }
}


// MARK: - Chord Pad (iPad)

/// The iPad Chord Pad — the hex-grid chord surface, the iPad counterpart of
/// the Mac [Chord Pad](../../docs/chord-pad.md) tab. Shown instead of the
/// Pitch Pad when the Mac pushes `layout == .chordPad` over the synced state.
/// Shares the same `PitchPadEngine` (real USB-MPE), `NoteManager` tilt
/// expression, and synced scale/tonic; perform-only, like the Pitch Pad.
struct ChordPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          onShowMapping: onShowMapping, onRecalibrate: onRecalibrate)
            ChordPadSurfaceIOS(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct ChordPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @State private var touchInfos: [TouchInfo] = []

    private var marginPixels: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width),
                              height: max(1, geo.size.height))
            let degrees = chordDegrees(from: engine.scale)
            let (a, origin, scale) = chordGridMetrics(cols: degrees.count + 1, size: size)
            let cells = chordCells(degrees: degrees, a: a, origin: origin)
            let R = chordHexCircumradius(a: a)

            ZStack(alignment: .topLeading) {
                Color.black

                // Static layer: faint outer hexes + pitch-colored inner hexes
                // with note-name labels, stretched to fill the surface.
                Canvas { ctx, _ in
                    for cell in cells {
                        ctx.stroke(Path(closedPolygon: chordStretch(
                            hexPolygon(center: cell.center, circumradius: R), by: scale)),
                                   with: .color(.white.opacity(0.12)), lineWidth: 1)
                    }
                    for cell in cells {
                        let hue = pitchColor(forRatio: cell.ratio,
                                             lightness: 0.82, chroma: 0.20)
                        ctx.stroke(Path(closedPolygon: chordStretch(innerHexPolygon(
                            center: cell.center, circumradius: R, inset: marginPixels),
                            by: scale)),
                                   with: .color(hue), lineWidth: 2)
                        ctx.draw(
                            Text(Scale.noteName(for: engine.tonicMidi + cell.semitones))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white),
                            at: chordStretch(cell.center, by: scale))
                    }
                }

                // Dynamic layer: live sounding fills (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: chordFillCells(cells, circumradius: R,
                                                    inset: marginPixels, scale: scale),
                              edgePad: 0)

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in handle(ev, cells: cells, size: size, scale: scale, began: true) },
                    onTouchMoved: { ev in handle(ev, cells: cells, size: size, scale: scale, began: false) },
                    onTouchEnded: { id in engine.noteOff(touchId: id) }
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func handle(_ ev: TouchEvent, cells: [ChordCell], size: CGSize,
                        scale: CGSize, began: Bool) {
        let screen = CGPoint(x: ev.xFraction * size.width,
                             y: ev.yFraction * size.height)
        let pt = chordUnstretch(screen, by: scale)
        guard let hit = chordPitchAt(point: pt, cells: cells,
                                     marginPixels: marginPixels) else { return }
        if began {
            engine.noteOn(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        } else {
            engine.glide(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        }
    }
}

// MARK: - String Pad (iPad)

/// The iPad String Pad — the box-plot / abacus surface, the iPad counterpart of
/// the Mac [String Pad](../../docs/string-pad.md) tab. Shown when the Mac pushes
/// `layout == .stringPad`. The note layout (`StringArrangement`) is its own state
/// (not derivable from the scale), synced from the Mac as a second SysEx message
/// and held by `ScaleSyncReceiver.stringArrangement`. Perform-only, like the
/// other pads — editing stays on the Mac. The pitch is constant inside each
/// hexagon and interpolates (inverse-distance) between, including across the
/// octave-repeat ghost strings.
struct StringPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    let arrangement: StringArrangement
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        // No top toolbar — the String Pad surface fills the whole screen and the
        // controls live in the bottom-left corner, which the rotated layout leaves
        // empty (the note band runs top-left → bottom-right).
        StringPadSurfaceIOS(engine: engine, arrangement: arrangement)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                StringPadControlsIOS(engine: engine, noteManager: noteManager,
                                     scaleSync: scaleSync,
                                     onShowMapping: onShowMapping,
                                     onRecalibrate: onRecalibrate)
                    .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
    }
}

/// The String Pad's controls, relocated from the (removed) top toolbar into the
/// **bottom-left corner** of the iPad surface — the region the rotated layout
/// leaves empty. A compact cluster overlaid on the playing surface; taps on the
/// buttons hit the cluster, everything else falls through to the surface.
private struct StringPadControlsIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                button("PANIC", color: .red) { engine.panic() }
                button("MAP", color: .orange, action: onShowMapping)
                Button(action: onRecalibrate) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption).foregroundColor(.blue)
                }
                ScaleSyncIndicator(scaleSync: scaleSync)
            }
            TiltBars(tilts: noteManager.currentTilt)
            HStack(spacing: 8) {
                PadSoundingReadout(sounding: engine.sounding, tonicMidi: engine.tonicMidi)
                // Tonic is set on the Mac and synced over, so it's read-only here.
                Text("Tonic \(Scale.noteName(for: engine.tonicMidi))")
                    .font(.caption2).foregroundColor(.gray)
                    .fixedSize()
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func button(_ title: String, color: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.7))
                .cornerRadius(6)
        }
    }
}

/// One resolved hexagon lane for the iPad fill: a stable `id` (the
/// `SoundingState`/`VoronoiCell` key), its live `ratio`, and its screen-space
/// polygon (already tilted by the rotation angle).
private struct DiagCell {
    let id: String
    let ratio: Double
    let polygon: [CGPoint]
}

private struct StringPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: StringArrangement
    @State private var touchInfos: [TouchInfo] = []

    /// Inverse-distance blend power, mapped from the synced `marginPixels`
    /// (the String Pad's Sharpness), matching the Mac.
    private var blendPower: Double { 1.0 + Double(engine.marginPixels) * 7.0 / 64.0 }

    /// Mirror the Mac's String Pad layout on the iPad, **rotated by the
    /// configurable angle** `arrangement.rotationDegrees` (0–40°). The iPad uses
    /// the **same** shared `stringPlacements` geometry as the Mac — identical note
    /// heights, the band layout, and octave-repeat ghost strings — so the two
    /// **correspond**; only the rotation differs (the Mac stays upright). The
    /// hexagons are NOT stretched, so they keep their Mac sizes.
    ///
    /// Built directly in screen space (no `rotationEffect`): `stringPlacements`
    /// lays the upright layout out in a logical box, then every hexagon polygon is
    /// rotated about the box centre onto the screen centre. Touches resolve in the
    /// same screen space (no inverse transform, no nested-UIView hit-testing
    /// concern). Enough octave-repeat ghost strings are added to span the rotated
    /// width so the strings reach across the surface.
    private func diagonalFillCells(size: CGSize,
                                   degrees: [(ratio: Double, label: String)]) -> [DiagCell] {
        let w = max(1, size.width), h = max(1, size.height)
        let sc = max(0, arrangement.stringCount)
        guard sc > 0, !degrees.isEmpty else { return [] }

        let theta = min(40, max(0, arrangement.rotationDegrees)) * .pi / 180
        let cT = CGFloat(cos(theta)), sT = CGFloat(sin(theta))

        // Keep the Mac's column density (so the hexagons keep their proportions),
        // adding octave-repeat ghost strings until the columns span the rotated
        // width. Height stays the screen height so note heights match the Mac.
        let baseCols = max(1, arrangement.totalColumns)
        let spacing = w / CGFloat(baseCols)
        let acrossExtent = w * cT + h * sT
        let needCols = Int((acrossExtent / spacing).rounded(.up)) + 2
        let ghosts = max(arrangement.ghostStringsPerSide, (needCols - sc + 1) / 2)

        var filled = arrangement
        filled.ghostStringsPerSide = ghosts
        let lw = CGFloat(sc + 2 * ghosts) * spacing
        let lh = h
        let boxW = spacing * 0.72

        let placements = stringPlacements(arrangement: filled, degrees: degrees,
                                          size: CGSize(width: lw, height: lh), boxWidth: boxW)

        // Rotate the upright layout about its centre onto the screen centre.
        // (+theta leans the strings top-right → bottom-left — the opposite of the
        // previous build.)
        let cx = w / 2, cy = h / 2, hx = lw / 2, hy = lh / 2
        func rot(_ p: CGPoint) -> CGPoint {
            let dx = p.x - hx, dy = p.y - hy
            return CGPoint(x: cx + dx * cT - dy * sT, y: cy + dx * sT + dy * cT)
        }

        return placements.map { p in
            DiagCell(id: p.id, ratio: p.ratio, polygon: stringShapePolygon(p).map(rot))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let degrees = scaleDegrees(from: engine.scale)
            let cells = diagonalFillCells(size: size, degrees: degrees)

            ZStack(alignment: .topLeading) {
                Color.black

                // The iPad is always in perform mode: a clean playing surface —
                // no gridlines, no labels. It mirrors the Mac layout (same notes
                // and sizes), rotated by the configured angle (see
                // `diagonalFillCells`). Drawn directly in screen space, so the
                // Canvas clips any overscan to the screen.
                Canvas { ctx, _ in
                    for cell in cells {
                        let hue = pitchColor(forRatio: cell.ratio, lightness: 0.82, chroma: 0.20)
                        ctx.stroke(Path(closedPolygon: cell.polygon),
                                   with: .color(hue), lineWidth: 2)
                    }
                }

                CellFillsView(sounding: engine.sounding,
                              cells: cells.map(voronoiCell), edgePad: 0)

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in handle(ev, cells: cells, size: size, began: true) },
                    onTouchMoved: { ev in handle(ev, cells: cells, size: size, began: false) },
                    onTouchEnded: { id in engine.noteOff(touchId: id) }
                )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func voronoiCell(_ cell: DiagCell) -> VoronoiCell {
        let seed = DisplaySeed(id: cell.id, sourceID: UUID(), octaveShift: 0,
                               ratio: cell.ratio, y: 0, label: "", ratioString: "")
        return VoronoiCell(seed: seed, polygon: cell.polygon)
    }

    private func handle(_ ev: TouchEvent, cells: [DiagCell], size: CGSize, began: Bool) {
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let resolver = cells.map { (id: $0.id, ratio: $0.ratio, polygon: $0.polygon) }
        guard let hit = polyPitchAt(point: pt, cells: resolver, power: blendPower) else { return }
        if began {
            engine.noteOn(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        } else {
            engine.glide(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        }
    }
}

// MARK: - Fret Pad (iPad)

/// The iPad Fret Pad — the fret-ribbon surface, the iPad counterpart of the
/// Mac [Fret Pad](../../docs/fret-pad.md) tab. Shown when the Mac pushes
/// `layout == .fretPad`. The segment layout (`FretArrangement`) is its own
/// state (the vertical snap zones aren't derivable from the scale), synced as
/// a third SysEx message and held by `ScaleSyncReceiver.fretArrangement`.
/// Perform-only — editing stays on the Mac.
///
/// Playing matches the Mac: a touch **starting** within the synced Snap
/// distance of a fret *and* inside its vertical extent snaps to its exact
/// pitch; starting above/below approaches the note freely; drags glide
/// continuously (per-touch constant log-offset from a snapped onset — never
/// re-snaps). Fully multitouch: each finger keeps its own snap offset.
struct FretPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    let arrangement: FretArrangement
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    /// Records play strokes to Documents/FretRecordings/ for offline fitting
    /// of the drag-assist parameters (toolbar REC toggle).
    @StateObject private var recorder = FretGestureRecorder()

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          recorder: recorder,
                          onShowMapping: onShowMapping, onRecalibrate: onRecalibrate)
            FretPadSurfaceIOS(engine: engine, arrangement: arrangement,
                              recorder: recorder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct FretPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: FretArrangement
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder
    @State private var touchInfos: [TouchInfo] = []
    /// Per-touch constant log2 offset captured at a snapped onset: the drag
    /// plays `2^(rawLog(x) + offset)`, so the snapped pitch is exact at the
    /// onset point and finger movement glides relative to it. 0 for
    /// unsnapped (approach) touches; cleared on touch end.
    @State private var snapOffsets: [Int: Double] = [:]
    /// Drag assist ("magnetic" intonation at stops/turns — see
    /// `FretDragAssist`), fully per-touch. The timer drives the settle while
    /// fingers rest (no touchesMoved events arrive then).
    @State private var assist = FretDragAssist()
    @State private var assistTimer: Timer? = nil
    /// Tap legato (see `FretLegato`): for very fast phrases the player taps
    /// notes instead of dragging; consecutive taps glide as one voice.
    @State private var legato = FretLegato()

    private let edgePad: CGFloat = 12
    /// Horizontal onset-snap half-width in px — the synced `marginPixels`
    /// (the Mac Fret Pad's Snap slider). 0 = fretless.
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            let degrees = scaleDegrees(from: engine.scale)
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: size)

            ZStack(alignment: .topLeading) {
                Color.black

                // The iPad is always in perform mode: fret lines only — no
                // octave gridlines, labels, or endpoint handles, and the
                // octave-repeat ghosts styled identically to the base frets.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    for p in placements {
                        let hue = pitchColor(forRatio: p.ratio,
                                             lightness: 0.82, chroma: 0.20)
                        var line = Path()
                        line.move(to: CGPoint(x: p.x, y: p.topY))
                        line.addLine(to: CGPoint(x: p.x, y: p.bottomY))
                        ctx.stroke(line, with: .color(hue), lineWidth: 1.5)
                    }
                }

                // Dynamic layer: live sounding glow (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: fretFillCells(placements), edgePad: edgePad)

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in began(ev, placements: placements, size: size) },
                    onTouchMoved: { ev in moved(ev, placements: placements, size: size) },
                    onTouchEnded: { id in
                        let now = CACurrentMediaTime()
                        snapOffsets.removeValue(forKey: id)
                        assist.end(touchId: id)
                        // Legato: the voice owner's release is deferred by
                        // the grace window (the timer sends the real
                        // note-off); non-owners' noteOff is a no-op after a
                        // takeover anyway.
                        if !(arrangement.legato && legato.touchEnded(id, time: now)) {
                            engine.noteOff(touchId: id)
                        }
                        recorder.end(touchId: id, time: now)
                        if assist.isEmpty && legato.isIdle {
                            assistTimer?.invalidate()
                            assistTimer = nil
                        }
                    }
                )
                .padding(edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// Onset: snap when within the Snap distance of a fret AND inside its
    /// vertical extent, else play the raw x-mapped pitch (the approach path).
    /// Registers the touch with the drag assist and starts its settle timer.
    private func began(_ ev: TouchEvent, placements: [FretPlacement], size: CGSize) {
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let rawLog = fretLogRatio(atX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width)
        let offset: Double
        let onsetLog: Double
        let weights: [String: Double]
        if snapDistance > 0,
           let hit = fretSnap(at: pt, placements: placements,
                              snapDistance: snapDistance) {
            offset = log2(hit.ratio) - rawLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
        } else {
            offset = 0
            onsetLog = rawLog
            weights = [:]
        }
        snapOffsets[ev.touchId] = offset

        let now = CACurrentMediaTime()
        var sentLog = onsetLog
        var tookOver = false
        if arrangement.legato, let prev = legato.tapBegan(ev.touchId, time: now),
           engine.transferTouch(from: prev.touch, to: ev.touchId) {
            // Legato takeover: no re-articulation — glide from the previous
            // note's pitch onto this tap over the ramp.
            tookOver = true
            legato.startRamp(fromLog: prev.log, onsetLog: onsetLog, time: now)
            sentLog = onsetLog + legato.offset(ev.touchId, time: now)
            engine.glide(touchId: ev.touchId, ratio: pow(2.0, sentLog),
                         weights: weights)
        }
        if !tookOver {
            engine.noteOn(touchId: ev.touchId, ratio: pow(2.0, onsetLog),
                          weights: weights)
        }
        legato.noteOutput(ev.touchId, log: sentLog)

        assist.setContext(placements: placements, snapDistance: snapDistance,
                          ghostExtentOctaves: arrangement.ghostExtentOctaves,
                          width: size.width)
        assist.begin(touchId: ev.touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: rawLog + offset, time: now)
        if recorder.isRecording {
            recorder.begin(touchId: ev.touchId,
                           context: strokeContext(placements: placements, size: size),
                           offset: offset, x: pt.x, y: pt.y,
                           u: rawLog + offset, o: sentLog, time: now)
        }
        startAssistTimerIfNeeded()
    }

    /// Snapshot the geometry + live assist settings for a recorded stroke.
    private func strokeContext(placements: [FretPlacement],
                               size: CGSize) -> FretGestureRecorder.Context {
        FretGestureRecorder.Context(
            frets: placements.map {
                .init(id: $0.id, log2Ratio: log2($0.ratio),
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

    /// Drag: continuous glide — raw x-mapped pitch plus this touch's constant
    /// onset offset, then the drag assist's slewed correction on top
    /// (magnetic at stops/turns, transparent while gliding). Never re-snaps
    /// mid-drag; the assist is continuous.
    private func moved(_ ev: TouchEvent, placements: [FretPlacement], size: CGSize) {
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let rawLog = fretLogRatio(atX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width)
        let offset = snapOffsets[ev.touchId] ?? 0
        assist.setContext(placements: placements, snapDistance: snapDistance,
                          ghostExtentOctaves: arrangement.ghostExtentOctaves,
                          width: size.width)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: ev.touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: rawLog + offset, time: now)
        let final = out.log2Pitch + legato.offset(ev.touchId, time: now)
        engine.glide(touchId: ev.touchId, ratio: pow(2.0, final),
                     weights: out.weights)
        legato.noteOutput(ev.touchId, log: final)
        recorder.sample(touchId: ev.touchId, x: pt.x, y: pt.y,
                        u: rawLog + offset, o: final, time: now)
    }

    /// 60 Hz settle loop while any touch is down (stops emit no touch
    /// events). Captures only the class objects (never the view struct); the
    /// assist reuses the context set on the last touch event.
    private func startAssistTimerIfNeeded() {
        // The timer self-invalidates when idle (it can't nil this @State),
        // so check validity, not just presence.
        guard assistTimer?.isValid != true else { return }
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
            if assist.isEmpty && legato.isIdle { timer.invalidate() }
        }
    }
}

