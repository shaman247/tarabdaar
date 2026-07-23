import AppKit
import QuartzCore
import StarpadCore
import SwiftUI

/// The **Fret Pad** tab — a fourth 2D playing surface: the scale's pitches as
/// vertical **frets** whose **x-position is their pitch** (`log2(ratio)` across
/// the ribbon, like the Pitch Pad's x-axis). A touch that **starts** within the
/// Snap distance of a fret *and* inside its vertical extent snaps to that
/// fret's exact pitch; starting above/below it (or in open space) plays the raw
/// x-mapped pitch — the approach path. After onset the drag is always
/// continuous (raw pitch plus the constant offset captured at the snap), so a
/// snapped note stays true while meend/vibrato move relative to it.
///
/// Frets are editable: drag an endpoint to set a fret's vertical extent (its
/// snap zone), drag the line to move it, shift-click to add a fret on the
/// nearest degree, right-click to delete. The base octave sits in the centre;
/// the ribbon extends `ghostExtentOctaves` past it each side (default 0.5 →
/// a 2-octave ribbon) with read-only octave-repeat ghost copies. Reuses
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
    /// The shared scale + tonic source (read-only here; edit on the Pitch Pad).
    @ObservedObject var pitchPad: PitchPadEngine
    /// Records play strokes (raw events + context) for offline fitting of the
    /// drag-assist parameters (`tools/fretpad_fit.py`).
    @StateObject private var recorder = FretGestureRecorder()

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
            FretPadSurface(engine: engine,
                           arrangement: $controller.fretArrangement,
                           degrees: degrees,
                           recorder: recorder)
                .aspectRatio(Config.iPadSurfaceAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Panic") { engine.panic() }
            Button("Reset to Scale") {
                controller.fretArrangement = .defaultArrangement(degrees: degrees)
            }
            .help("Rebuild the default fret layout: one fret per scale degree — S/P centered, natural degrees in the bottom half, komal/tivra in the top half.")
            octaveControl
            Toggle("Legato", isOn: $controller.fretArrangement.legato)
                .toggleStyle(.button)
                .help("Tap legato: consecutive taps become one continuous voice — a tap while the previous note sounds (or within ~120 ms of its release) glides to the new pitch instead of retriggering. Mono, last-note priority while on. For very fast phrases, tap the notes instead of dragging.")
            Toggle("Perform", isOn: $engine.performanceMode)
                .toggleStyle(.button)
                .help("Clean playing surface: editing off, octave gridlines + labels + endpoint handles hidden, octave-repeat frets shown identically to the editable ones.")
            recordControl
            Spacer()
            FretSoundingReadout(sounding: engine.sounding,
                                tonicMidi: pitchPad.tonicMidi)
            snapControl
            velocityControl
            tonicReadout
        }
    }

    /// How far the ribbon extends past the base octave on each side, in
    /// octaves (fractional). 0.5 = a 2-octave ribbon.
    private var octaveControl: some View {
        HStack(spacing: 4) {
            Text("Octave ±").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Stepper(value: $controller.fretArrangement.ghostExtentOctaves,
                    in: 0...2, step: 0.25) {
                Text(String(format: "%.2f", controller.fretArrangement.ghostExtentOctaves))
                    .font(.system(.caption).monospacedDigit())
                    .frame(width: 30, alignment: .trailing)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .help("How far the ribbon extends past the base octave on each side, in octaves (read-only octave-repeat fret copies). 0.5 = a 2-octave ribbon; 1 = 3 octaves.")
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
                    .font(.system(.caption).monospacedDigit())
            }
        }
        .toggleStyle(.button)
        .help("Record play strokes (raw movements + fret context) to Application Support/Starpad/FretRecordings/ as JSONL, for fitting the drag-assist parameters to your real playing (tools/fretpad_fit.py). Play naturally: glides into stops, direction changes near notes, vibrato, fast runs.")
    }

    /// Horizontal snap distance in pixels, backed by `engine.marginPixels`
    /// (0–64). 0 = fretless (no onset snapping at all).
    private var snapControl: some View {
        HStack(spacing: 6) {
            Text("Snap").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: $engine.marginPixels, in: 0...64)
                .frame(width: 80)
            Text("\(Int(engine.marginPixels.rounded())) px")
                .font(.system(.caption).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
        .help("How close (horizontally) a touch must start to a fret to snap to its pitch. Only applies within the fret's vertical extent, and only at touch onset — drags glide continuously. 0 = fretless.")
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
                 ? "Perform: start on a fret (inside its height) to snap to its pitch; start above/below it to approach the note freely. Drags always glide continuously."
                 : "Edit: drag a fret = move  ·  drag an endpoint = set its extent  ·  drag empty space = play  ·  Shift-click = add a fret  ·  Right-click = delete  ·  Faint frets are octave repeats (read-only)")
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
private struct FretSoundingReadout: View {
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
    /// Pixel delta (segment mid-y − click) captured at mouse-down for a move.
    @State private var moveOffsetY: CGFloat = 0
    /// Constant log2 offset captured at a snapped onset: the drag plays
    /// `2^(rawLog(x) + snapOffsetLog)`, so the snapped pitch is exact at the
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

    private let edgePad: CGFloat = 16
    private let handleHitRadius: CGFloat = 9
    private let minHeight: Double = 0.02

    /// Horizontal onset-snap half-width in pixels (the Snap slider).
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // All placements (base + octave-repeat ghosts). `body` does NOT
            // re-run during a glide (fills live on the separate `SoundingState`).
            let placements = fretPlacements(arrangement: arrangement,
                                            degrees: degrees, size: size)
            let basePlacements = placements.filter { !$0.isGhost }
            // Perform mode: a clean playing surface — no gridlines, labels, or
            // handles, and the ghosts styled identically to the editable frets.
            let perform = engine.performanceMode
            let extent = max(0, arrangement.ghostExtentOctaves)

            ZStack(alignment: .topLeading) {
                Color.black

                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)

                    // Octave boundaries — every integer log2 within the
                    // visible ribbon (hidden in perform).
                    if !perform {
                        let lo = Int((-extent).rounded(.up))
                        let hi = Int((1 + extent).rounded(.down))
                        for k in lo...hi {
                            let x = fretX(forLogRatio: Double(k),
                                          ghostExtentOctaves: extent,
                                          width: size.width)
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: 0))
                            line.addLine(to: CGPoint(x: x, y: size.height))
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
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(p.isGhost ? 0.5 : 1.0)),
                                at: CGPoint(x: p.x, y: max(8, p.topY - 12)))
                        }
                    }
                }

                // Dynamic layer: live sounding glow (observes SoundingState).
                CellFillsView(sounding: engine.sounding,
                              cells: fretFillCells(placements),
                              edgePad: edgePad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(
                FretPadMouseCapture(
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

    private func handleDown(at pt: CGPoint, placements: [FretPlacement],
                            base: [FretPlacement], size: CGSize) {
        // Perform mode: play only (no editing). Anywhere on the surface.
        if engine.performanceMode {
            playAt(pt, placements: placements, size: size)
            return
        }

        // Edit mode: editing is always on (no modifier needed).
        let shift = NSEvent.modifierFlags.contains(.shift)
        let grab = fretGrab(at: pt, placements: base, handleRadius: handleHitRadius)

        // Shift on empty space → add a fret on the nearest degree.
        if shift, grab == .none {
            addSegment(at: pt, size: size)
            return
        }

        // On a fret → move / resize (sound its exact pitch while adjusting).
        if grab != .none {
            editGrab = grab
            if case .move(let id) = grab,
               let p = base.first(where: { $0.segmentID == id }) {
                moveOffsetY = (p.topY + p.bottomY) / 2 - pt.y
            }
            if let p = grabbedPlacement(grab, base: base) {
                snapOffsetLog = 0
                beginSounding(weights: [p.id: 1.0], ratio: p.ratio)
            }
            return
        }

        // Empty space → play (so you can hear while arranging).
        playAt(pt, placements: placements, size: size)
    }

    /// Sound the pitch at `pt`: snapped to a fret when the onset lands within
    /// `snapDistance` of one **and** inside its vertical extent, otherwise the
    /// raw x-mapped pitch (the approach path). With legato on, a tap while
    /// the previous note sounds (or is in its release grace window) takes the
    /// voice over and glides instead of retriggering. Registers the touch
    /// with the drag assist and starts the settle/legato timer.
    private func playAt(_ pt: CGPoint, placements: [FretPlacement], size: CGSize) {
        let rawLog = fretLogRatio(atX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width)
        let onsetLog: Double
        let weights: [String: Double]
        if snapDistance > 0,
           let hit = fretSnap(at: pt, placements: placements,
                              snapDistance: snapDistance) {
            snapOffsetLog = log2(hit.ratio) - rawLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
        } else {
            snapOffsetLog = 0
            onsetLog = rawLog
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

        assist.setContext(placements: placements, snapDistance: snapDistance,
                          ghostExtentOctaves: arrangement.ghostExtentOctaves,
                          width: size.width)
        assist.begin(touchId: touch, x: pt.x, y: pt.y,
                     uncorrectedLog: rawLog + snapOffsetLog, time: now)
        if recorder.isRecording {
            recorder.begin(touchId: touch,
                           context: strokeContext(placements: placements, size: size),
                           offset: snapOffsetLog, x: pt.x, y: pt.y,
                           u: rawLog + snapOffsetLog,
                           o: sentLog, time: now)
        }
        startAssistTimer()
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

    private func handleDrag(at pt: CGPoint, placements: [FretPlacement],
                            size: CGSize) {
        switch editGrab {
        case .move(let id):
            guard let idx = segmentIndex(id) else { return }
            let h = arrangement.segments[idx].height
            var mid = Double((pt.y + moveOffsetY) / size.height)
            mid = min(max(h / 2, mid), 1 - h / 2)
            arrangement.segments[idx].topY = mid - h / 2
            arrangement.segments[idx].bottomY = mid + h / 2
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
        // Playing: continuous glide — raw x-mapped pitch plus the constant
        // offset captured at a snapped onset, then the drag assist's slewed
        // correction on top (magnetic at stops/turns, transparent while
        // gliding). Never re-snaps mid-drag; the assist is continuous.
        guard let touch = activeTouchId else { return }
        let rawLog = fretLogRatio(atX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width)
        assist.setContext(placements: placements, snapDistance: snapDistance,
                          ghostExtentOctaves: arrangement.ghostExtentOctaves,
                          width: size.width)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: touch, x: pt.x, y: pt.y,
                              uncorrectedLog: rawLog + snapOffsetLog, time: now)
        let final = out.log2Pitch + legato.offset(touch, time: now)
        engine.glide(touchId: touch, ratio: pow(2.0, final),
                     weights: out.weights)
        legato.noteOutput(touch, log: final)
        recorder.sample(touchId: touch, x: pt.x, y: pt.y,
                        u: rawLog + snapOffsetLog, o: final, time: now)
    }

    private func handleUp() {
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
        moveOffsetY = 0
        snapOffsetLog = 0
    }

    /// Right-click deletes a (base) fret. Disabled in perform mode.
    private func handleRightDown(at pt: CGPoint, base: [FretPlacement]) {
        if engine.performanceMode { return }
        let grab = fretGrab(at: pt, placements: base, handleRadius: handleHitRadius)
        let id: UUID?
        switch grab {
        case .move(let i), .resizeTop(let i), .resizeBottom(let i): id = i
        case .none: id = nil
        }
        guard let segmentID = id, let idx = segmentIndex(segmentID) else { return }
        arrangement.segments.remove(at: idx)
    }

    /// Shift-click: add a fret for the degree whose pitch is nearest the click
    /// x (circular within the octave), with a default-height extent centered
    /// on the click y.
    private func addSegment(at pt: CGPoint, size: CGSize) {
        guard !degrees.isEmpty else { return }
        let rawLog = fretLogRatio(atX: pt.x,
                                  ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                  width: size.width)
        let folded = rawLog - rawLog.rounded(.down)
        var bestIndex = 0
        var bestDist = Double.infinity
        for (i, deg) in degrees.enumerated() {
            let d0 = abs(log2(deg.ratio) - folded)
            let d = min(d0, 1 - d0)
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        let cy = clamp01(Double(pt.y / size.height))
        let half = 0.075
        arrangement.segments.append(FretSegment(degreeIndex: bestIndex,
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
