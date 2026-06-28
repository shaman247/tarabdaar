import AppKit
import StarpadCore
import SwiftUI

/// The **Chord Pad** tab — a second 2D playing surface built for chords. It's
/// a hex grid: every column is a stack of diatonic thirds (a chord) drawn from
/// the same scale the Pitch Pad uses, every row is a chord tone (7th, 5th,
/// 3rd, root, 3rd-below, 4th-below). Clicking a hex plays its note; dragging
/// glides/bends between hexes through the same soft-margin blend as the Pitch
/// Pad. Colors are pitch-class hues.
///
/// It reuses `controller.chordPad` (a second `PitchPadEngine`) purely as the
/// MPE emitter — fed `ratio = 2^(semitones/12)` per cell — and reads the
/// scale + tonic from `controller.pitchPad` (read-only here; edit scales on
/// the Pitch Pad tab). Mac-only; no iPad view, no sync. See
/// [docs/chord-pad.md](../../docs/chord-pad.md).
struct ChordPadView: View {
    /// The MPE emitter (the `chordPad` engine). Owns velocity / margin /
    /// `sounding`; its own `scale` is unused here.
    @ObservedObject var engine: PitchPadEngine
    /// The shared scale + tonic source. Observed so loading a scale (here or
    /// on the Pitch Pad tab) re-renders the grid live.
    @ObservedObject var pitchPad: PitchPadEngine

    init(controller: AppController) {
        self.engine = controller.chordPad
        self.pitchPad = controller.pitchPad
    }

    /// The grid's diatonic degrees, derived from the shared Pitch Pad scale.
    private var degrees: [Int] { chordDegrees(from: pitchPad.scale) }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            ChordPadSurface(engine: engine, degrees: degrees,
                            tonicMidi: pitchPad.tonicMidi)
                .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            scaleControl
            temperamentControl
            Spacer()
            ChordSoundingReadout(sounding: engine.sounding, tonicMidi: pitchPad.tonicMidi)
            degreesReadout
            marginControl
            velocityControl
            tonicReadout
        }
    }

    /// Loads a common scale preset (modes / major-minor / pentatonics) into
    /// the **shared** scale — the same one the Pitch Pad edits, so both pads
    /// stay in sync. The tonic comes from the Pitch Pad tab.
    private var scaleControl: some View {
        Menu {
            ForEach(ScalePreset.allCases) { preset in
                Button(preset.label) { pitchPad.loadPreset(preset) }
            }
        } label: {
            Label(pitchPad.currentScaleName ?? "Load Scale",
                  systemImage: "music.note.list")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Load a common scale into the shared Pitch Pad scale (modes, major/minor, pentatonics).")
    }

    /// 12-TET only for now; the picker is disabled, reserving the spot for a
    /// future just-intonation mode (per-column perfect intervals).
    private var temperamentControl: some View {
        HStack(spacing: 4) {
            Text("Tuning").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Picker("", selection: .constant(0)) {
                Text("12-TET").tag(0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 84)
            .disabled(true)
        }
        .help("Equal temperament. Just intonation (per-column perfect intervals) is planned.")
    }

    private var degreesReadout: some View {
        let n = degrees.count
        return Text(n > 0 ? "\(n)° → \(n + 1) cols" : "no scale")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .help("Diatonic degrees (from the Pitch Pad scale) and resulting columns.")
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
            .frame(width: 100)
            Text("\(engine.velocity)")
                .font(.system(.caption))
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var marginControl: some View {
        HStack(spacing: 6) {
            Text("Margin").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: $engine.marginPixels, in: 0...64)
                .frame(width: 90)
            Text("\(Int(engine.marginPixels.rounded()))")
                .font(.system(.caption))
                .frame(width: 24, alignment: .trailing)
        }
        .help("Half-width of the soft glide zone between hexes, in pixels. 0 = hard hex edges.")
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
            Text("Click a hex = play  ·  Drag = glide between chord tones  ·  Columns are diatonic chords, rows are chord tones (7th · 5th · 3rd · root · 3rd below · 4th below)")
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Sounding readout

/// Live frequency / nearest-note / cents readout for the active touch, tinted
/// in the pitch's hue. Observes only `SoundingState`, so per-tick glide
/// updates re-render this capsule alone.
private struct ChordSoundingReadout: View {
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

private struct ChordPadSurface: View {
    @ObservedObject var engine: PitchPadEngine
    let degrees: [Int]
    let tonicMidi: Int

    /// Single active mouse touch. The grid is mouse-driven (one press at a
    /// time), like the Pitch Pad surface.
    @State private var activeTouchId: Int? = nil
    @State private var touchCounter: Int = 0

    private var marginPixels: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width),
                              height: max(1, geo.size.height))
            // Cheap to rebuild (≤ ~54 cells) and — crucially — `body` does NOT
            // re-run during a glide: the fast-changing fills live on the
            // separate `SoundingState`, observed only by `CellFillsView`. So
            // this recomputes only when the scale, tonic, size, or margin
            // change, not per mouse tick.
            let cols = degrees.count + 1
            let (a, origin, scale) = chordGridMetrics(cols: cols, size: size)
            let cells = chordCells(degrees: degrees, a: a, origin: origin)
            let R = chordHexCircumradius(a: a)

            ZStack(alignment: .topLeading) {
                Color.black

                // Static layer: faint outer hex grid + pitch-colored inner
                // hexes with note-name labels, stretched to fill the surface.
                // Independent of what's sounding.
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
                        let name = Scale.noteName(for: tonicMidi + cell.semitones)
                        ctx.draw(
                            Text(name)
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
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                ChordPadMouseCapture(
                    onMouseDown: { pt in
                        handleDown(at: chordUnstretch(pt, by: scale), cells: cells)
                    },
                    onMouseDragged: { pt in
                        handleDrag(at: chordUnstretch(pt, by: scale), cells: cells)
                    },
                    onMouseUp: { handleUp() }
                )
            )
        }
    }

    private func handleDown(at pt: CGPoint, cells: [ChordCell]) {
        guard let hit = chordPitchAt(point: pt, cells: cells, marginPixels: marginPixels)
        else { return }
        let touch = nextTouchId()
        activeTouchId = touch
        engine.noteOn(touchId: touch, ratio: hit.ratio, weights: hit.weights)
    }

    private func handleDrag(at pt: CGPoint, cells: [ChordCell]) {
        guard let touch = activeTouchId,
              let hit = chordPitchAt(point: pt, cells: cells, marginPixels: marginPixels)
        else { return }
        engine.glide(touchId: touch, ratio: hit.ratio, weights: hit.weights)
    }

    private func handleUp() {
        if let touch = activeTouchId { engine.noteOff(touchId: touch) }
        activeTouchId = nil
    }

    private func nextTouchId() -> Int {
        touchCounter &+= 1
        return touchCounter
    }
}

// MARK: - Mouse capture (play-only; mirrors PadMouseCapture in PitchPadView)

/// AppKit-backed mouse capture so drag events arrive at full resolution
/// (SwiftUI's `DragGesture` coalesces moves on macOS, making a glide stutter).
/// Play-only: no modifier / hover / right-click handling — the Chord Pad has
/// no editing gestures.
private struct ChordPadMouseCapture: NSViewRepresentable {
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
