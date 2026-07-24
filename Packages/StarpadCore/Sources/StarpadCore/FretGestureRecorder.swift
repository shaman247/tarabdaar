import CoreGraphics
import Foundation

// MARK: - Fret Pad gesture recorder
//
// Records real playing strokes on the Fret Pad so the drag-assist parameters
// (`FretDragAssist`) can be **fitted to the player's actual movements**
// offline (`tools/fretpad_fit.py`). Toggled from the Fret Pad toolbar's Rec
// button; one JSONL line per stroke:
//
//   {"v":2, "date":…, "offset":<onset snapOffsetLog>, "ctx":{frets, snap,
//    extent, width, height, assistParams}, "events":[[t,x,y,u,o,tick],…],
//    "endT":t}
//
// (v2 since the 2026-07-23 free-fret change: each ctx fret carries its pixel
// `x` and `u` is the fret-field pitch, not an x-mapping.)
//
//   t    seconds since the stroke began (CACurrentMediaTime-based)
//   x,y  surface-local px (same space as the recorded fret extents)
//   u    uncorrected log2 pitch (fret-field + onset offset) — the assist's
//        INPUT, so the fitter never re-derives onset snapping
//   o    the pitch actually played (post-assist), for verifying the fitter's
//        causal replica against the live Swift behavior
//   tick 0 = a real move event (fitter input), 1 = a 60 Hz settle-timer
//        sample (parity check only — replays regenerate their own ticks)
//
// Files land in `Application Support/Starpad/FretRecordings/` as
// `fret-strokes-<yyyyMMdd-HHmmss>.jsonl` (one file per Rec session, appended
// per stroke). Mac-side only for now; the class is platform-neutral.
public final class FretGestureRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    /// Strokes written in the current session (toolbar feedback).
    @Published public private(set) var strokeCount = 0

    /// Per-stroke geometry + settings snapshot, enough to replay offline.
    public struct Context: Codable {
        public struct FretRef: Codable {
            public var id: String
            public var log2Ratio: Double
            /// Pixel x of the fret line (frets are freely positioned — the
            /// assist's magnet basin is screen-px, so the fitter needs it).
            public var x: Double
            public var topY: Double
            public var bottomY: Double
            public var ghost: Bool

            public init(id: String, log2Ratio: Double, x: Double, topY: Double,
                        bottomY: Double, ghost: Bool) {
                self.id = id
                self.log2Ratio = log2Ratio
                self.x = x
                self.topY = topY
                self.bottomY = bottomY
                self.ghost = ghost
            }
        }

        public var frets: [FretRef]
        public var snapDistance: Double
        public var ghostExtentOctaves: Double
        public var width: Double
        public var height: Double
        /// The assist constants that were LIVE while recording (what the
        /// player felt), for the fitter's parity check.
        public var assistParams: [String: Double]

        public init(frets: [FretRef], snapDistance: Double,
                    ghostExtentOctaves: Double, width: Double, height: Double,
                    assistParams: [String: Double]) {
            self.frets = frets
            self.snapDistance = snapDistance
            self.ghostExtentOctaves = ghostExtentOctaves
            self.width = width
            self.height = height
            self.assistParams = assistParams
        }
    }

    private struct StrokeRecord: Codable {
        var v: Int
        var date: String
        var offset: Double
        var ctx: Context
        var events: [[Double]]
        var endT: Double
    }

    private struct ActiveStroke {
        var start: TimeInterval
        var ctx: Context
        var offset: Double
        var events: [[Double]]
        var lastX: Double
        var lastY: Double
        var lastU: Double
    }

    private var active: [Int: ActiveStroke] = [:]
    private var handle: FileHandle?

    /// Directory the session files land in. On the Mac: Application Support.
    /// On the iPad: the app's **Documents** folder (user-visible via the
    /// Files app and Finder's device browser — `UIFileSharingEnabled` — so
    /// recordings can be copied to the Mac for fitting).
    public static var dir: URL {
        #if os(iOS)
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FretRecordings", isDirectory: true)
        #else
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Starpad", isDirectory: true)
            .appendingPathComponent("FretRecordings", isDirectory: true)
        #endif
    }

    public init() {}

    /// Toggle recording. Turning it on opens a fresh session file; turning it
    /// off closes it (in-flight strokes are dropped — they'd be partial).
    public func setRecording(_ on: Bool) {
        guard on != isRecording else { return }
        if on {
            let fm = FileManager.default
            try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let stamp = Self.fileStamp.string(from: Date())
            let url = Self.dir.appendingPathComponent("fret-strokes-\(stamp).jsonl")
            fm.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            if handle == nil {
                NSLog("Starpad: FretGestureRecorder could not open \(url.path)")
                return
            }
            NSLog("Starpad: recording Fret Pad strokes to \(url.path)")
            strokeCount = 0
            isRecording = true
        } else {
            isRecording = false
            active.removeAll()
            try? handle?.close()
            handle = nil
        }
    }

    /// Register a play stroke at note-on (skip edit grabs).
    public func begin(touchId: Int, context: Context, offset: Double,
                      x: CGFloat, y: CGFloat, u: Double, o: Double,
                      time: TimeInterval) {
        guard isRecording else { return }
        var stroke = ActiveStroke(start: time, ctx: context, offset: offset,
                                  events: [], lastX: Double(x),
                                  lastY: Double(y), lastU: u)
        stroke.events.append([0, Double(x), Double(y), u, o, 0])
        active[touchId] = stroke
    }

    /// Record a drag event.
    public func sample(touchId: Int, x: CGFloat, y: CGFloat, u: Double,
                       o: Double, time: TimeInterval) {
        guard isRecording, var s = active[touchId] else { return }
        s.lastX = Double(x)
        s.lastY = Double(y)
        s.lastU = u
        s.events.append([time - s.start, Double(x), Double(y), u, o, 0])
        active[touchId] = s
    }

    /// Record a settle-timer sample (position unchanged — parity data only).
    public func sampleTick(touchId: Int, o: Double, time: TimeInterval) {
        guard isRecording, var s = active[touchId] else { return }
        s.events.append([time - s.start, s.lastX, s.lastY, s.lastU, o, 1])
        active[touchId] = s
    }

    /// Finish the stroke and append it to the session file.
    public func end(touchId: Int, time: TimeInterval) {
        guard var s = active.removeValue(forKey: touchId) else { return }
        guard isRecording, let handle else { return }
        s.events = s.events.map { $0.map { ($0 * 10000).rounded() / 10000 } }
        let record = StrokeRecord(v: 2, date: Self.dateStamp.string(from: Date()),
                                  offset: s.offset, ctx: s.ctx,
                                  events: s.events, endT: time - s.start)
        guard let data = try? JSONEncoder().encode(record) else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
        strokeCount += 1
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
