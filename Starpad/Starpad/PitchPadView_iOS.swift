import QuartzCore
import StarpadCore
import SwiftUI

/// The iPad's playing surface is the Fret Pad (`FretPadViewIOS`, below). Touch
/// position resolves to a pitch via `FretPadGeometry`; `PitchPadEngine` pins a
/// MIDI note and bends, while a 60 Hz loop streams the RAW tilt report
/// (`TiltAxisWire` CCs 16/17/18) — the iPad knows nothing about what the
/// tilts mean; the Mac evaluates its own bindings. Scale + fret editing
/// live on StarpadMac and sync here over USB-MIDI SysEx (the iPad is
/// perform-only). The MAP dimension-matrix editor was deleted 2026-07-24
/// along with the iPad's parameter mapping.

// MARK: - Shared pad toolbar (iPad)

/// The common iPad pad toolbar — PANIC, an optional REC toggle, the
/// scale-sync indicator, live
/// tilt meters, the sounding readout, the (read-only) synced tonic, and
/// recalibrate. Shared by the playing surface.
struct PadToolbarIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    /// When set (Fret Pad), a REC toggle records play strokes for offline
    /// assist fitting (see `FretGestureRecorder`).
    var recorder: FretGestureRecorder? = nil
    var onRecalibrate: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("PANIC", color: .red) { engine.panic() }
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

// MARK: - Tilt pad

/// The three calibrated tilt axes (-1…+1) shown as a single X-Y square:
/// tilt 1 on x, tilt 2 on y (up = positive), and the dot's color sweeping
/// purple → cyan → orange as tilt 3 goes -1 → 0 → +1 (cyan at neutral).
/// Driven by `NoteManager.currentTilt`, which the note manager refreshes
/// from the motion source each tick.
private struct TiltBars: View {
    let tilts: [Double]

    private func tilt(_ i: Int) -> Double {
        max(-1.0, min(1.0, i < tilts.count ? tilts[i] : 0))
    }

    var body: some View {
        let t3 = tilt(2)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.25))
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: h)
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: w, height: 1)
                Circle()
                    .fill(Color(hue: 0.5 - t3 * 0.35, saturation: 0.9,
                                brightness: 1.0))
                    .frame(width: 7, height: 7)
                    .position(x: (1 + CGFloat(tilt(0))) / 2 * w,
                              y: (1 - CGFloat(tilt(1))) / 2 * h)
            }
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - Fret Pad (iPad)

/// The iPad Fret Pad — the free-fret surface, the iPad counterpart of the
/// Mac [Fret Pad](../../docs/fret-pad.md) tab. Shown when the Mac pushes
/// `layout == .fretPad`. The segment layout (`FretArrangement`) is its own
/// state (fret positions and snap zones aren't derivable from the scale),
/// synced as a third SysEx message and held by
/// `ScaleSyncReceiver.fretArrangement`. Perform-only — editing stays on the
/// Mac.
///
/// Playing matches the Mac: frets are freely positioned and the pitch is the
/// continuous fret **field** (`fretFieldLog` — exact on a fret, interpolated
/// between them); a touch **starting** within the synced Snap distance of a
/// fret *and* inside its vertical extent snaps to its exact pitch; starting
/// elsewhere approaches the note freely; drags glide continuously (per-touch
/// constant log-offset from a snapped onset — never re-snaps). Fully
/// multitouch: each finger keeps its own snap offset.
struct FretPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var noteManager: NoteManager
    @ObservedObject var scaleSync: ScaleSyncReceiver
    let arrangement: FretArrangement
    var onRecalibrate: () -> Void

    /// Records play strokes to Documents/FretRecordings/ for offline fitting
    /// of the drag-assist parameters (toolbar REC toggle).
    @StateObject private var recorder = FretGestureRecorder()

    var body: some View {
        VStack(spacing: 0) {
            PadToolbarIOS(engine: engine, noteManager: noteManager, scaleSync: scaleSync,
                          recorder: recorder,
                          onRecalibrate: onRecalibrate)
            // The drone buttons live INSIDE the surface (drawn as an
            // overlay, hit-tested in the surface's own touch handler) so
            // the surface keeps its full width — a separate side column
            // made the whole right edge dead space and swallowed touches
            // aimed at the rightmost fret.
            FretPadSurfaceIOS(engine: engine, arrangement: arrangement,
                              recorder: recorder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Visual layer for the drone buttons (rects: the shared
/// `droneButtonRects` in StarpadCore) (display only — presses are
/// hit-tested in the surface's UIKit touch handler, never via SwiftUI
/// gestures, so button touches and melody multitouch can't interfere).
private struct DroneButtonsVisualIOS: View {
    let ratios: [Double]
    let held: Set<Int>
    let size: CGSize
    let edgePad: CGFloat

    var body: some View {
        let rects = droneButtonRects(size: size)
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { i in
                let ratio = i < ratios.count ? ratios[i] : 1.0
                let hue = pitchColor(forRatio: ratio, lightness: 0.75,
                                     chroma: 0.17)
                let r = rects[i]
                RoundedRectangle(cornerRadius: 10)
                    .fill(hue.opacity(held.contains(i) ? 0.9 : 0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(hue.opacity(0.8), lineWidth: 1)
                    )
                    .overlay(
                        Text(sargamName(forRatio: ratio))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .frame(width: r.width, height: r.height)
                    .offset(x: edgePad + r.minX, y: edgePad + r.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FretPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: FretArrangement
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureRecorder
    @State private var touchInfos: [TouchInfo] = []
    /// Per-touch constant log2 offset captured at a snapped onset: the drag
    /// plays `2^(fieldLog + offset)`, so the snapped pitch is exact at the
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
    /// Touches currently holding a drone button (touchId → button index).
    /// Drone presses are hit-tested HERE, in the surface's own UIKit touch
    /// handler — not via SwiftUI gestures — so the surface keeps its full
    /// width and only the 4 button rectangles are claimed; everything
    /// around/below them plays normally.
    @State private var droneTouches: [Int: Int] = [:]

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

                // Drone buttons (display only — presses are hit-tested in
                // `began` below): right edge, top → vertical center.
                DroneButtonsVisualIOS(ratios: arrangement.droneRatios,
                                      held: Set(droneTouches.values),
                                      size: size, edgePad: edgePad)

                TouchOverlayView(
                    touches: $touchInfos,
                    onTouchBegan: { ev in began(ev, placements: placements, size: size) },
                    onTouchMoved: { ev in moved(ev, placements: placements, size: size) },
                    onTouchEnded: { id in
                        let now = CACurrentMediaTime()
                        // Drone touch: release the button (unless another
                        // finger still holds the same one) and skip the
                        // note path entirely.
                        if let d = droneTouches.removeValue(forKey: id) {
                            if !droneTouches.values.contains(d) {
                                engine.setDrone(d, pressed: false)
                            }
                            return
                        }
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
    /// vertical extent, else play the fret-field pitch (the approach path).
    /// Registers the touch with the drag assist and starts its settle timer.
    private func began(_ ev: TouchEvent, placements: [FretPlacement], size: CGSize) {
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        // Drone buttons first: a touch starting inside a button rect is a
        // drone press, not a note. (Melody drags that WANDER into a button
        // keep playing — only onsets are claimed.)
        if let d = droneButtonRects(size: size).firstIndex(where: { $0.contains(pt) }) {
            let alreadyHeld = droneTouches.values.contains(d)
            droneTouches[ev.touchId] = d
            if !alreadyHeld { engine.setDrone(d, pressed: true) }
            return
        }
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }   // no frets — nothing to play
        let offset: Double
        let onsetLog: Double
        let weights: [String: Double]
        if snapDistance > 0,
           let hit = fretSnap(at: pt, placements: placements,
                              snapDistance: snapDistance) {
            offset = log2(hit.ratio) - fieldLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
        } else {
            offset = 0
            onsetLog = fieldLog
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

        assist.setContext(placements: placements, snapDistance: snapDistance)
        assist.begin(touchId: ev.touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + offset, time: now)
        if recorder.isRecording {
            recorder.begin(touchId: ev.touchId,
                           context: strokeContext(placements: placements, size: size),
                           offset: offset, x: pt.x, y: pt.y,
                           u: fieldLog + offset, o: sentLog, time: now)
        }
        startAssistTimerIfNeeded()
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

    /// Drag: continuous glide — the fret-field pitch plus this touch's
    /// constant onset offset, then the drag assist's slewed correction on top
    /// (magnetic at stops/turns, transparent while gliding). Never re-snaps
    /// mid-drag; the field and assist are continuous.
    private func moved(_ ev: TouchEvent, placements: [FretPlacement], size: CGSize) {
        // A finger holding a drone button never glides.
        guard droneTouches[ev.touchId] == nil else { return }
        let pt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        guard let fieldLog = fretFieldLog(at: pt, placements: placements)
        else { return }
        let offset = snapOffsets[ev.touchId] ?? 0
        assist.setContext(placements: placements, snapDistance: snapDistance)
        let now = CACurrentMediaTime()
        let out = assist.move(touchId: ev.touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: fieldLog + offset, time: now)
        let final = out.log2Pitch + legato.offset(ev.touchId, time: now)
        engine.glide(touchId: ev.touchId, ratio: pow(2.0, final),
                     weights: out.weights)
        legato.noteOutput(ev.touchId, log: final)
        recorder.sample(touchId: ev.touchId, x: pt.x, y: pt.y,
                        u: fieldLog + offset, o: final, time: now)
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

