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
    var onShowMapping: () -> Void
    var onRecalibrate: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("PANIC", color: .red) { engine.panic() }
            button("MAP", color: .orange, action: onShowMapping)
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
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          onShowMapping: onShowMapping, onRecalibrate: onRecalibrate)
            StringPadSurfaceIOS(engine: engine, arrangement: arrangement)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct StringPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: StringArrangement
    @State private var touchInfos: [TouchInfo] = []

    private let edgePad: CGFloat = 16
    /// Inverse-distance blend power, mapped from the synced `marginPixels`
    /// (the String Pad's Sharpness), matching the Mac.
    private var blendPower: Double { 1.0 + Double(engine.marginPixels) * 7.0 / 64.0 }

    private func boxWidth(_ width: CGFloat, columns T: Int) -> CGFloat {
        min(width / CGFloat(max(1, T)) * 0.72, 120)
    }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            let T = max(1, arrangement.totalColumns)
            let bw = boxWidth(size.width, columns: T)
            let degrees = scaleDegrees(from: engine.scale)
            let placements = stringPlacements(arrangement: arrangement, degrees: degrees,
                                              size: size, boxWidth: bw)

            ZStack(alignment: .topLeading) {
                Color.black

                // The iPad is always in perform mode: a clean playing surface —
                // no gridlines, no labels, and the octave-repeat ghosts styled
                // identically to the main octave.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    for p in placements {
                        let hue = pitchColor(forRatio: p.ratio, lightness: 0.82, chroma: 0.20)
                        ctx.stroke(Path(closedPolygon: stringShapePolygon(p)),
                                   with: .color(hue), lineWidth: 2)
                    }
                }

                CellFillsView(sounding: engine.sounding,
                              cells: stringFillCells(placements), edgePad: edgePad)

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in handle(ev, placements: placements, size: size, began: true) },
                    onTouchMoved: { ev in handle(ev, placements: placements, size: size, began: false) },
                    onTouchEnded: { id in engine.noteOff(touchId: id) }
                )
                .padding(edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func handle(_ ev: TouchEvent, placements: [StringPlacement], size: CGSize,
                        began: Bool) {
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        guard let hit = polyPitchAt(point: pt, cells: stringResolverCells(placements),
                                    power: blendPower) else { return }
        if began {
            engine.noteOn(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        } else {
            engine.glide(touchId: ev.touchId, ratio: hit.ratio, weights: hit.weights)
        }
    }
}

