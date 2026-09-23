import Foundation
import QuartzCore

/// THE FRET-PAD TOUCH PIPELINE both surfaces play through. Onset: snap
/// within the Snap distance of a fret inside its extent, else the field
/// pitch. Drag: the field pitch plus the touch's onset offset, then the
/// drag assist's slewed correction — never a re-snap. Release. And the
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

    /// Per-touch log2 offset captured at a snapped onset (0 if unsnapped).
    private var snapOffsets: [Int: Double] = [:]
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
              let fieldLog = fretFieldLog(at: pt, placements: c.placements,
                                          warp: c.warp)
        else { return false }   // no frets — nothing to play
        let offset: Double
        let onsetLog: Double
        let weights: [String: Double]
        if c.snapDistance > 0,
           let hit = fretSnap(at: pt, placements: c.placements,
                              snapDistance: c.snapDistance) {
            offset = log2(hit.ratio) - fieldLog
            onsetLog = log2(hit.ratio)
            weights = [hit.id: 1.0]
        } else {
            offset = 0
            onsetLog = fieldLog
            weights = [:]
        }
        snapOffsets[touchId] = offset
        engine.noteOn(touchId: touchId, ratio: pow(2.0, onsetLog),
                      weights: weights,
                      radiusPt: radiusPt,
                      fretPosition: fretPosition(at: pt, placements: c.placements,
                                                 padHeight: c.size.height))
        assist.setContext(placements: c.placements, snapDistance: c.snapDistance)
        assist.begin(touchId: touchId, x: pt.x, y: pt.y,
                     uncorrectedLog: fieldLog + offset, time: now)
        if recorder.isRecording {
            recorder.begin(touchId: touchId,
                           context: .snapshot(
                               placements: c.placements, size: c.size,
                               snapDistance: c.snapDistance,
                               ghostExtentOctaves: c.ghostExtentOctaves,
                               fieldWarp: c.warp, assist: assist),
                           offset: offset, x: pt.x, y: pt.y,
                           u: fieldLog + offset, o: onsetLog, time: now)
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
        guard let engine, let recorder,
              let offset = snapOffsets[touchId],
              let fieldLog = fretFieldLog(at: pt, placements: c.placements,
                                          warp: c.warp)
        else { return nil }
        assist.setContext(placements: c.placements, snapDistance: c.snapDistance)
        let out = assist.move(touchId: touchId, x: pt.x, y: pt.y,
                              uncorrectedLog: fieldLog + offset, time: now)
        engine.glide(touchId: touchId, ratio: pow(2.0, out.log2Pitch),
                     weights: out.weights,
                     fretPosition: fretPosition(at: pt, placements: c.placements,
                                                padHeight: c.size.height))
        if let radiusPt { engine.setTouchRadius(touchId: touchId, radiusPt: radiusPt) }
        recorder.sample(touchId: touchId, x: pt.x, y: pt.y,
                        u: fieldLog + offset, o: out.log2Pitch, time: now)
        return out
    }

    /// Release.
    public func end(touchId: Int, time now: TimeInterval) {
        snapOffsets.removeValue(forKey: touchId)
        engine?.noteOff(touchId: touchId)
        assist.end(touchId: touchId)
        recorder?.end(touchId: touchId, time: now)
        if assist.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The 60 Hz settle loop while any touch is down; it self-invalidates
    /// once nothing sounds.
    private func startTimerIfNeeded() {
        guard timer?.isValid != true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                     repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = CACurrentMediaTime()
            for (id, out) in self.assist.tick(time: now) {
                self.engine?.glide(touchId: id, ratio: pow(2.0, out.log2Pitch),
                                   weights: out.weights)
                self.recorder?.sampleTick(touchId: id, o: out.log2Pitch, time: now)
                self.onTick?(id, out)
            }
            if self.assist.isEmpty { t.invalidate() }
        }
    }
}
