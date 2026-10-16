import CoreGraphics
import Foundation

// MARK: - Fret Pad gesture recorder
//
// Records real playing strokes on the Fret Pad so the drag-assist parameters
// (`FretDragAssist`) can be **fitted to the player's actual movements**
// offline (`tools/fretpad_fit.py`). Toggled from the Fret Pad toolbar's Rec
// button; one JSONL line per stroke:
//
//   {"v":7, "date":…, "offset":<onset snapOffsetLog>, "ctx":{frets, snap,
//    extent, width, height, assistParams}, "events":[[t,x,y,u,o,tick,region1U,…,region15U],…],
//    "endT":t}
//
// Version 7 records fifteen independent equal-height rows with blended boundary corrections.
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
// Files land in `Application Support/Tarabdaar/FretRecordings/` as
// `fret-strokes-<yyyyMMdd-HHmmss>-<UUID>.jsonl` (one file per Rec session, appended
// per stroke). The iPad captures strokes in memory; only the Mac writes files.
public class FretGestureCapture: ObservableObject {
    @Published public private(set) var isRecording = false
    /// Completed fitting records, forwarded by the iPad without filesystem access.
    public var onStroke: ((Data) -> Void)?

    /// Per-stroke geometry + settings snapshot, enough to replay offline.
    public struct Context: Codable {
        public struct FretRef: Codable {
            public var id: String
            public var log2Ratio: Double
            /// Pixel x of the fret line, used by the assist's screen-pixel basin.
            public var x: Double
            public var topY: Double
            public var bottomY: Double
            public var row: Int?
            public var ghost: Bool

            public init(id: String, log2Ratio: Double, x: Double, topY: Double,
                        bottomY: Double, ghost: Bool, row: Int? = nil) {
                self.id = id
                self.log2Ratio = log2Ratio
                self.x = x
                self.topY = topY
                self.bottomY = bottomY
                self.row = row
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

    struct StrokeRecord: Codable {
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
        var lastRegionLogs: [Double]
        var lastU: Double
    }

    private var active: [Int: ActiveStroke] = [:]
    public init() {}

    public func setRecording(_ on: Bool) {
        guard isRecording != on else { return }
        isRecording = on
        active.removeAll()
    }

    func completed(_ data: Data) { onStroke?(data) }

    /// Register a play stroke at note-on.
    public func begin(touchId: Int, context: Context, offset: Double,
                      x: CGFloat, y: CGFloat, u: Double, o: Double,
                      time: TimeInterval, regionLogs: [FretRegion: Double] = [:]) {
        guard isRecording else { return }
        var stroke = ActiveStroke(start: time, ctx: context, offset: offset,
                                  events: [], lastX: Double(x),
                                  lastY: Double(y),
                                  lastRegionLogs: FretRegion.allCases.map { regionLogs[$0] ?? u }, lastU: u)
        stroke.events.append([0, Double(x), Double(y), u, o, 0] + stroke.lastRegionLogs)
        active[touchId] = stroke
    }

    /// Record a drag event.
    public func sample(touchId: Int, x: CGFloat, y: CGFloat, u: Double,
                       o: Double, time: TimeInterval, regionLogs: [FretRegion: Double] = [:]) {
        guard isRecording, var s = active[touchId] else { return }
        s.lastRegionLogs = FretRegion.allCases.map { regionLogs[$0] ?? u }
        s.lastX = Double(x)
        s.lastY = Double(y)
        s.lastU = u
        s.events.append([time - s.start, Double(x), Double(y), u, o, 0] + s.lastRegionLogs)
        active[touchId] = s
    }

    /// Record a settle-timer sample (position unchanged — parity data only).
    public func sampleTick(touchId: Int, u: Double, o: Double, time: TimeInterval,
                           regionLogs: [FretRegion: Double]? = nil) {
        guard isRecording, var s = active[touchId] else { return }
        s.lastU = u
        if let regionLogs {
            s.lastRegionLogs = FretRegion.allCases.map { regionLogs[$0] ?? s.lastU }
        }
        s.events.append([time - s.start, s.lastX, s.lastY, s.lastU, o, 1] + s.lastRegionLogs)
        active[touchId] = s
    }

    /// Finish the stroke and forward its complete fitting record.
    public func end(touchId: Int, time: TimeInterval) {
        guard var s = active.removeValue(forKey: touchId) else { return }
        guard isRecording else { return }
        s.events = s.events.map { $0.map { ($0 * 10000).rounded() / 10000 } }
        let record = StrokeRecord(v: 7, date: Self.dateStamp.string(from: Date()),
                                  offset: s.offset, ctx: s.ctx,
                                  events: s.events, endT: time - s.start)
        guard let data = try? JSONEncoder().encode(record) else { return }
        completed(data)
    }

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

#if os(macOS)
/// The Mac owns the recording session and stores both local and iPad strokes.
public final class FretGestureRecorder: FretGestureCapture {
    @Published public private(set) var strokeCount = 0
    @Published public private(set) var isFinishing = false
    private var handle: FileHandle?
    private let directory: URL

    public static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tarabdaar/FretRecordings", isDirectory: true)
    }

    public init(directory: URL = FretGestureRecorder.dir) {
        self.directory = directory
        super.init()
    }

    public override func setRecording(_ on: Bool) {
        guard isRecording != on, !isFinishing else { return }
        if on {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stamp = Self.fileStamp.string(from: Date())
                let url = directory.appendingPathComponent("fret-strokes-\(stamp)-\(UUID().uuidString).jsonl")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
                handle = try FileHandle(forWritingTo: url)
                strokeCount = 0
                super.setRecording(true)
            } catch {
                NSLog("Tarabdaar: cannot open fret recording: %@", String(describing: error))
            }
        } else {
            stop(waitForRemote: false)
        }
    }

    public func stop(waitForRemote: Bool) {
        guard isRecording else { return }
        isFinishing = waitForRemote
        super.setRecording(false)
        if !waitForRemote { finish() }
    }

    public func finish() {
        try? handle?.close()
        handle = nil
        isFinishing = false
    }

    /// Import only complete fitting records; transport fragments never become JSONL lines.
    public func appendRemote(_ data: Data) {
        guard isRecording || isFinishing,
              let record = try? JSONDecoder().decode(StrokeRecord.self, from: data),
              record.v == 7, !record.events.isEmpty,
              record.events.allSatisfy({ $0.count == 6 + FretRegion.allCases.count }),
              let canonical = try? JSONEncoder().encode(record) else { return }
        completed(canonical)
    }

    override func completed(_ data: Data) {
        guard isRecording || isFinishing, let handle else { return }
        do {
            try handle.write(contentsOf: data + Data([0x0A]))
            strokeCount += 1
        } catch {
            NSLog("Tarabdaar: cannot write fret recording: %@", String(describing: error))
            finish()
            setRecording(false)
        }
    }

    deinit { try? handle?.close() }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
#endif
