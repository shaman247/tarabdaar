import Foundation
import QuartzCore

/// THE FRET-PAD TOUCH PIPELINE both surfaces play through. Each row interior and
/// overlap resolves its own onset snap, field pitch and slewed drag correction.
/// An overlap uses the union of its neighbors; boundary blends include snap and correction.
/// Drags never re-snap. Release. And the
/// 60 Hz settle tick while any touch is down, which glides the assist's
/// output and feeds the stroke recorder. Owns the per-touch snap offsets,
/// the assist and the timer; a surface keeps only its pointer model and
/// its own overlays (`onTick` carries the settle output to them).
public final class FretTouchPlayer {
    /// The frets as the surface has them at this moment.
    public struct Context {
        public var placements: [FretPlacement]
        public var size: CGSize
        public var snapDistance: CGFloat
        public var ghostExtentOctaves: Double
        public var warp: Double

        public init(placements: [FretPlacement], size: CGSize,
                    snapDistance: CGFloat, ghostExtentOctaves: Double,
                    warp: Double) {
            self.placements = placements
            self.size = size
            self.snapDistance = snapDistance
            self.ghostExtentOctaves = ghostExtentOctaves
            self.warp = warp
        }
    }

    public let assist = FretDragAssist()
    /// The engine the notes go to and the recorder that captures strokes —
    /// the surface binds them before its first event.
    public weak var engine: PitchPadEngine?
    public weak var recorder: FretGestureRecorder?
    /// Per settle tick, after the glide (the iPad's indicators ride it).
    public var onTick: ((Int, FretDragAssist.Output) -> Void)?

    private struct Touch {
        var point: CGPoint
        /// Per-region log2 offsets captured at onset (0 if unsnapped).
        let offsets: [FretRegion: Double]
    }
    private var touches: [Int: Touch] = [:]
    private var timer: Timer?

    public init() {}

    deinit { timer?.invalidate() }

    public var isSounding: Bool { !assist.isEmpty }

    /// Onset at `pt` (band-local). False when there is nothing to play.
    @discardableResult
    public func begin(touchId: Int, at pt: CGPoint, context c: Context,
                      radiusPt: Double = 0,
                      time now: TimeInterval) -> Bool {
        guard let engine, let recorder,
              let onset = fretOnset(at: pt, placements: c.placements,
                                    snapDistance: c.snapDistance, warp: c.warp)
        else { return false }
        assist.settings = engine.fretAssistSettings
        touches[touchId] = Touch(point: pt, offsets: onset.offsets)
        engine.noteOn(touchId: touchId, ratio: pow(2, onset.pitch),
                      weights: onset.weights, radiusPt: radiusPt,
                      fretPosition: fretPosition(at: pt, placements: c.placements,
                                                 padHeight: c.size.height))
        assist.setContext(placements: c.placements, snapDistance: c.snapDistance)
        assist.begin(touchId: touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: onset.pitch, time: now, regionLogs: onset.logs)
        if recorder.isRecording {
            recorder.begin(touchId: touchId,
                           context: .snapshot(
                               placements: c.placements, size: c.size,
                               snapDistance: c.snapDistance,
                               ghostExtentOctaves: c.ghostExtentOctaves,
                               fieldWarp: c.warp, assist: assist),
                           offset: fretRegionValue(onset.offsets, atY: pt.y, placements: c.placements) ?? 0,
                           x: pt.x, y: pt.y, u: onset.pitch, o: onset.pitch, time: now,
                           regionLogs: onset.logs)
        }
        startTimerIfNeeded()
        return true
    }

    /// Drag to `pt`. nil for a touch that did not begin as a note, or off
    /// the frets.
    @discardableResult
    public func move(touchId: Int, at pt: CGPoint, context c: Context,
                     radiusPt: Double? = nil,
                     time now: TimeInterval) -> FretDragAssist.Output? {
        guard let engine, let recorder, var touch = touches[touchId] else { return nil }
        touch.point = pt
        let regionLogs = regionPitches(for: touch, context: c)
        guard let raw = fretRegionValue(regionLogs, atY: pt.y, placements: c.placements) else { return nil }
        touches[touchId] = touch
        assist.settings = engine.fretAssistSettings
        assist.setContext(placements: c.placements, snapDistance: c.snapDistance)
        let out = assist.move(touchId: touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: raw, time: now, regionLogs: regionLogs)
        engine.glide(touchId: touchId, ratio: pow(2.0, out.log2Pitch),
                     weights: out.weights,
                     fretPosition: fretPosition(at: pt, placements: c.placements,
                                                padHeight: c.size.height))
        if let radiusPt { engine.setTouchRadius(touchId: touchId, radiusPt: radiusPt) }
        recorder.sample(touchId: touchId, x: pt.x, y: pt.y,
                        u: raw, o: out.log2Pitch, time: now, regionLogs: regionLogs)
        return out
    }

    /// Re-evaluate held fingers when warp changes, without a new onset or
    /// a synthetic move that would disturb the assist's motion history.
    public func updateWarp(context c: Context, time now: TimeInterval) {
        guard !touches.isEmpty else { return }
        assist.setContext(placements: c.placements, snapDistance: c.snapDistance)
        tick(time: now, regionLogs: touches.mapValues { regionPitches(for: $0, context: c) })
    }

    private func regionPitches(for touch: Touch, context c: Context) -> [FretRegion: Double] {
        fretRegionFields(atX: touch.point.x, placements: c.placements, warp: c.warp)
            .reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value + (touch.offsets[entry.key] ?? 0)
            }
    }

    /// Release.
    public func end(touchId: Int, time now: TimeInterval) {
        touches.removeValue(forKey: touchId)
        engine?.noteOff(touchId: touchId)
        assist.end(touchId: touchId)
        recorder?.end(touchId: touchId, time: now)
        if assist.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Settle at the last pointer positions, optionally refreshing the field first.
    func tick(time now: TimeInterval, regionLogs: [Int: [FretRegion: Double]] = [:]) {
        if let engine { assist.settings = engine.fretAssistSettings }
        for (id, out) in assist.tick(time: now, regionLogs: regionLogs) {
            engine?.glide(touchId: id, ratio: pow(2.0, out.log2Pitch), weights: out.weights)
            recorder?.sampleTick(touchId: id, u: out.uncorrectedLog, o: out.log2Pitch, time: now,
                                 regionLogs: regionLogs[id])
            onTick?(id, out)
        }
    }

    /// The 60 Hz settle loop while any touch is down; it self-invalidates
    /// once nothing sounds.
    private func startTimerIfNeeded() {
        guard timer?.isValid != true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                     repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tick(time: CACurrentMediaTime())
            if self.assist.isEmpty { t.invalidate() }
        }
    }
}
