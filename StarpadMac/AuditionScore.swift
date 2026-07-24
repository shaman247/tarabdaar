import AppKit
import AVFoundation
import Foundation
import StarpadCore

/// JSON score format for autonomous "play and record" auditions. A
/// script can be dropped into the watched inbox; the runner plays it,
/// records the post-FX output to a sibling WAV file, and writes a
/// `.done` (or `.error`) marker so an external watcher (e.g., Claude
/// iterating on sound-design parameters) can synchronize.
///
/// Schema:
/// ```
/// {
///   "name": "viola-glide-test",
///   "tailSeconds": 2.0,
///   "events": [
///     {"at": 0.0,  "kind": "tilt",    "axis": 0, "value": 0.4},
///     {"at": 0.0,  "kind": "noteOn",  "id": 1, "note": 60, "keyY": 0.5},
///     {"at": 1.0,  "kind": "glide",   "id": 1, "note": 64},
///     {"at": 2.0,  "kind": "noteOff", "id": 1}
///   ]
/// }
/// ```
///
/// `rawBend` sends a raw 14-bit pitch bend to the hosted AU on channel `id`
/// (1–15); `value` = bend in SEMITONES, mapped assuming a ±2 st bend range
/// (set it via RPN `cc` events at score start to be sure). NOTE: a bend is
/// dropped unless the channel already has an active note — send it AFTER the
/// `rawNote`. Use it to play microtonal (non-ET) pitches: a `rawNote` at the
/// nearest semitone + a `rawBend` of the cents offset.
///
/// Events are dispatched from a dedicated high-QoS scheduler thread (MIDI
/// straight to the AU, off-main); the old per-event main-queue `asyncAfter`
/// dropped closely-spaced notes under recording load.
struct AuditionScore: Decodable {
    let name: String?
    let tailSeconds: Double?
    let events: [AuditionEvent]

    var totalDuration: Double {
        let last = events.map(\.at).max() ?? 0
        return last + (tailSeconds ?? 2.0)
    }
}

struct AuditionEvent: Decodable {
    let at: Double
    let kind: String
    let id: Int?
    let note: Int?
    let keyY: Double?
    let axis: Int?
    let index: Int?
    /// For `"kind":"voiceParam"` — name of the Mac-side parameter to
    /// set (see `AppController.setVoiceParam`). Also reused for
    /// `"kind":"preset"`.
    let param: String?
    /// For `"kind":"tilt"` / `"slider"` — 0..1 or -1..1 axis value.
    /// For `"kind":"strike"` — peak-G value driving the velocity LUT
    /// (Config.velocityMinG..velocityMaxG, log-mapped to MIDI velocity
    /// 1..127). 0.1g ≈ v75; 0.5g ≈ v127.
    /// For `"kind":"voiceParam"` — the parameter's new value in its
    /// natural units (Hz, cents, 0..1 fraction, etc.).
    /// For `"kind":"cc"` — the CC value 0..127.
    let value: Double?
    /// For `"kind":"cc"` — the MIDI CC number (e.g. 11 = Expression). Sent
    /// to the hosted AU on the master channel + every member channel so it
    /// reaches whatever channel a note is on (SWAM Viola needs CC11 to
    /// sound — the simulator/Mac pad has no tilt to drive it).
    let cc: Int?
}

/// Watches `~/Music/Starpad-Auditions/inbox/` for `.json` scores and
/// runs them serially through an `IPadSimulator`, recording post-FX
/// audio to a sibling `.wav` and writing a `.done` marker on completion.
final class AuditionRunner: ObservableObject {
    private let simulator: IPadSimulator
    private let audio: AudioEngine
    private let fileManager = FileManager.default

    private let inboxURL: URL
    private let outputsURL: URL

    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1

    private var queue: [URL] = []
    private var processing = false

    /// Most recently completed audition path. Set on main; SwiftUI reads.
    @Published var lastCompletedURL: URL?
    @Published var lastError: String?
    @Published var isRunning: Bool = false

    init(simulator: IPadSimulator, audio: AudioEngine) {
        self.simulator = simulator
        self.audio = audio
        let root = Self.resolveAuditionsRoot()
        self.inboxURL = root.appendingPathComponent("inbox", isDirectory: true)
        self.outputsURL = root.appendingPathComponent("outputs", isDirectory: true)
    }

    /// Resolve where audition scores live. Priority:
    ///   1. `STARPAD_AUDITIONS_DIR` env var (absolute path)
    ///   2. `<repo>/auditions/` discovered via `#filePath` — works for
    ///      developer debug builds where the source file location is
    ///      meaningful; release builds with stripped source paths fall
    ///      through to (3).
    ///   3. `~/Library/Application Support/Starpad/Auditions/` — sane
    ///      fallback for any non-dev case.
    private static func resolveAuditionsRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["STARPAD_AUDITIONS_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let here = URL(fileURLWithPath: #filePath)
        // <repo>/StarpadMac/AuditionScore.swift  → up twice → <repo>
        let repo = here.deletingLastPathComponent().deletingLastPathComponent()
        let repoAuditions = repo.appendingPathComponent("auditions", isDirectory: true)
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("CLAUDE.md").path) {
            return repoAuditions
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport
            .appendingPathComponent("Starpad", isDirectory: true)
            .appendingPathComponent("Auditions", isDirectory: true)
    }

    func start() {
        try? fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: outputsURL, withIntermediateDirectories: true)
        beginWatching()
        scan()
    }

    func stop() {
        dirSource?.cancel()
        dirSource = nil
        if dirFD >= 0 { close(dirFD); dirFD = -1 }
    }

    deinit { stop() }

    private func beginWatching() {
        dirFD = open(inboxURL.path, O_EVTONLY)
        guard dirFD >= 0 else {
            NSLog("Starpad audition: failed to open \(inboxURL.path) for watching")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        src.resume()
        dirSource = src
    }

    /// Scan the inbox for unprocessed `.json` files. A score is "done"
    /// when a sibling `<name>.done` file exists, so the watcher is
    /// idempotent across app restarts.
    func scan() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: inboxURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let jsons = urls.filter { $0.pathExtension == "json" }
            .filter { !fileManager.fileExists(atPath: $0.deletingPathExtension()
                .appendingPathExtension("done").path) }
            .filter { !fileManager.fileExists(atPath: $0.deletingPathExtension()
                .appendingPathExtension("error").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for u in jsons where !queue.contains(u) { queue.append(u) }
        runNextIfIdle()
    }

    private func runNextIfIdle() {
        guard !processing, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        processing = true
        isRunning = true
        run(scoreAt: url) { [weak self] in
            self?.processing = false
            self?.isRunning = false
            self?.runNextIfIdle()
        }
    }

    /// Wait for a file's size to be stable across two stat calls (~150ms
    /// apart) so we don't read a partially-written score. Heredocs and
    /// `>` redirects truncate-then-fill, which triggers the watcher mid-
    /// write; an atomic rename-into-inbox would avoid this, but we
    /// can't force external writers to use one.
    private func waitForStableFile(_ url: URL, attempts: Int = 8) -> Bool {
        var prev: Int64 = -1
        for _ in 0..<attempts {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? -1
            if size > 0 && size == prev { return true }
            prev = size
            Thread.sleep(forTimeInterval: 0.15)
        }
        return prev > 0
    }

    private func run(scoreAt url: URL, completion: @escaping () -> Void) {
        guard waitForStableFile(url) else {
            writeError(for: url, message: "file size never stabilized")
            completion()
            return
        }
        let score: AuditionScore
        do {
            let data = try Data(contentsOf: url)
            score = try JSONDecoder().decode(AuditionScore.self, from: data)
        } catch {
            writeError(for: url, message: "parse failed: \(error)")
            completion()
            return
        }

        let baseName = score.name ?? url.deletingPathExtension().lastPathComponent
        let wavURL = outputsURL.appendingPathComponent("\(baseName).wav")

        // Reset simulator state so the new audition starts clean.
        simulator.panic()
        simulator.setTilt(axis: 0, value: 0)
        simulator.setTilt(axis: 1, value: 0)
        simulator.setTilt(axis: 2, value: 0)

        do {
            try audio.startRecording(to: wavURL)
        } catch {
            writeError(for: url, message: "record-start failed: \(error)")
            completion()
            return
        }

        let startWall = Date()
        // Precise scheduler on a dedicated high-QoS thread. The previous
        // per-event `DispatchQueue.main.asyncAfter` dropped/bunched closely
        // spaced note events under recording load (random note dropouts in
        // fast passages). Here one background thread walks the sorted events,
        // sleeps to each event's wall-clock offset, and fires it: MIDI events
        // go straight to the hosted AU (realtime-safe, off-main), everything
        // else hops to main.
        let sorted = score.events.sorted { $0.at < $1.at }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for ev in sorted {
                guard let self else { return }
                let dt = startWall.addingTimeInterval(max(0.0, ev.at)).timeIntervalSinceNow
                if dt > 0 { Thread.sleep(forTimeInterval: dt) }
                if Self.isMIDIEvent(ev.kind) {
                    self.sendMIDIEvent(ev)
                } else {
                    DispatchQueue.main.async { self.apply(event: ev) }
                }
            }
        }

        let total = score.totalDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            guard let self else { return }
            self.simulator.panic()
            // stopRecording writes the complete WAV synchronously, so the file
            // is fully readable by the time the `.done` marker is written.
            self.audio.stopRecording()
            let elapsed = Date().timeIntervalSince(startWall)
            self.writeDone(for: url, wav: wavURL, elapsed: elapsed)
            self.lastCompletedURL = wavURL
            completion()
        }
    }

    /// MIDI-only event kinds — sent straight to the hosted AU and safe to
    /// fire off the main thread (the precise scheduler does this).
    static func isMIDIEvent(_ kind: String) -> Bool {
        kind == "rawNote" || kind == "rawNoteOff" || kind == "rawBend" || kind == "cc"
    }

    /// Raw MIDI straight to the hosted AU (realtime-safe; callable off-main).
    private func sendMIDIEvent(_ event: AuditionEvent) {
        switch event.kind {
        case "rawNote":
            // Raw MIDI note straight to the hosted AU — BYPASSES the NoteManager
            // (no glide, no tilt-CC). `id` = MIDI channel (1–15), `value` = vel.
            guard let note = event.note else { return }
            let rch = UInt8(max(1, min(15, event.id ?? 1)))
            let rvel = UInt8(max(1, min(127, Int(event.value ?? 90))))
            audio.sendHostedMIDI(status: 0x90 | rch,
                                 data1: UInt8(max(0, min(127, note))), data2: rvel)
        case "rawNoteOff":
            guard let note = event.note else { return }
            let rch = UInt8(max(1, min(15, event.id ?? 1)))
            audio.sendHostedMIDI(status: 0x80 | rch,
                                 data1: UInt8(max(0, min(127, note))), data2: 0)
        case "rawBend":
            // Raw 14-bit pitch bend to the hosted AU on channel `id` (1–15).
            // `value` = bend in SEMITONES; mapped assuming the AU's pitch-bend
            // range is ±2 st (set it via RPN `cc` events at score start to be
            // sure). 8192 = center. Use to play microtonal (non-ET) pitches:
            // pair with a `rawNote` at the nearest semitone + the cents offset.
            let rch = UInt8(max(1, min(15, event.id ?? 1)))
            let semis = event.value ?? 0.0
            let norm = max(-1.0, min(1.0, semis / 2.0))        // ±2 st range
            let bend = max(0, min(16383, Int((norm * 8191.0).rounded()) + 8192))
            audio.sendHostedMIDI(status: 0xE0 | rch,
                                 data1: UInt8(bend & 0x7F), data2: UInt8((bend >> 7) & 0x7F))
        case "cc":
            guard let ccNum = event.cc, let v = event.value else { return }
            let val = UInt8(max(0, min(127, Int(v))))
            let num = UInt8(max(0, min(127, ccNum)))
            for ch in UInt8(0)...UInt8(15) {
                audio.sendHostedMIDI(status: 0xB0 | ch, data1: num, data2: val)
            }
        default:
            break
        }
    }

    private func apply(event: AuditionEvent) {
        if Self.isMIDIEvent(event.kind) { sendMIDIEvent(event); return }
        switch event.kind {
        case "noteOn":
            guard let id = event.id, let note = event.note else { return }
            simulator.noteOn(id: id, midiNote: note, keyY: event.keyY ?? 0.5)
        case "noteOff":
            guard let id = event.id else { return }
            simulator.noteOff(id: id)
        case "glide":
            guard let id = event.id, let note = event.note else { return }
            simulator.glide(id: id, toNote: note, keyY: event.keyY ?? 0.5)
        case "tilt":
            guard let axis = event.axis, let v = event.value else { return }
            simulator.setTilt(axis: axis, value: v)
        case "slider":
            guard let idx = event.index, let v = event.value else { return }
            simulator.setSlider(index: idx, value: v)
        case "strike":
            guard let v = event.value else { return }
            simulator.motion.strikeForce = max(0.001, v)
        case "voiceParam":
            guard let name = event.param, let v = event.value else { return }
            simulator.controller?.setVoiceParam(name: name, value: v)
        case "padOn":
            // Drive the actual Mac Pitch Pad (PitchPadEngine, the user's
            // playing path) — loud SWAM via its CC11, and the real sym drive.
            // `value` = ratio relative to the pad tonic (default 1.0).
            guard let id = event.id else { return }
            simulator.controller?.pitchPad.noteOn(touchId: id, ratio: event.value ?? 1.0)
        case "padGlide":
            // Bend a held Pitch Pad note to a new ratio (sends pitch bend) —
            // the sym halo should re-couple to the bent pitch.
            guard let id = event.id else { return }
            simulator.controller?.pitchPad.glide(touchId: id, ratio: event.value ?? 1.0)
        case "padOff":
            guard let id = event.id else { return }
            simulator.controller?.pitchPad.noteOff(touchId: id)
        default:
            NSLog("Starpad audition: unknown kind \(event.kind)")
        }
    }

    private func writeDone(for scoreURL: URL, wav: URL, elapsed: TimeInterval) {
        let marker = scoreURL.deletingPathExtension().appendingPathExtension("done")
        let stats = audio.lastRecordingStats
        var body: [String: Any] = [
            "wav": wav.path,
            "elapsedSeconds": elapsed,
            "framesWritten": stats.frames,
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let err = stats.error { body["recordingError"] = err }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted) {
            try? data.write(to: marker)
        }
    }

    private func writeError(for scoreURL: URL, message: String) {
        let marker = scoreURL.deletingPathExtension().appendingPathExtension("error")
        let body: [String: Any] = [
            "error": message,
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted) {
            try? data.write(to: marker)
        }
        DispatchQueue.main.async { self.lastError = message }
    }

    var inboxPath: String { inboxURL.path }
    var outputsPath: String { outputsURL.path }
}
