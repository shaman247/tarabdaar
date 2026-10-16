import AVFoundation
import Foundation
import SarangiKit

/// One bounded mixer capture per launch; copying is the only work in the tap.
final class PluckDiagnosticCapture {
    static let duration: Double = 20
    private let lock = NSLock()
    private let eventLock = NSLock()
    private let pcm: AVAudioPCMBuffer
    private var started = false
    private var stopped = false
    private var frames = 0
    private var firstHostTime: UInt64?
    private var firstSampleTime: AVAudioFramePosition?
    private var formatErrors = 0
    private var expectedSampleTime: AVAudioFramePosition?
    private var timeline = [Int64](repeating: 0, count: 4096 * 3)
    private var timelineCount = 0
    private var discontinuities = 0
    private var missingFrames: Int64 = 0
    private var repeatedFrames: Int64 = 0
    private var events: [[String: Any]] = []
    private var states: [[String: Any]] = []
    private var acceptingEvents = false

    init(format: AVAudioFormat, seconds: Double = PluckDiagnosticCapture.duration) {
        precondition(format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved)
        pcm = AVAudioPCMBuffer(pcmFormat: format,
                              frameCapacity: AVAudioFrameCount(format.sampleRate * seconds))!
        // Touch every page before the audio callback uses it.
        for channel in 0..<Int(format.channelCount) {
            pcm.floatChannelData![channel].initialize(repeating: 0, count: Int(pcm.frameCapacity))
        }
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        eventLock.lock()
        acceptingEvents = true
        eventLock.unlock()
        return true
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped, frames < Int(pcm.frameCapacity) else { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == pcm.format.channelCount,
              buffer.format.sampleRate == pcm.format.sampleRate,
              let input = buffer.floatChannelData else {
            formatErrors += 1
            return
        }
        if frames == 0 {
            firstHostTime = time.isHostTimeValid ? time.hostTime : nil
            firstSampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        }
        let count = min(Int(buffer.frameLength), Int(pcm.frameCapacity) - frames)
        if time.isSampleTimeValid {
            if let expectedSampleTime, time.sampleTime != expectedSampleTime {
                let gap = time.sampleTime - expectedSampleTime
                discontinuities += 1
                missingFrames += max(0, gap)
                repeatedFrames += max(0, -gap)
            }
            expectedSampleTime = time.sampleTime + Int64(buffer.frameLength)
            if timelineCount < 4096 {
                let index = timelineCount * 3
                timeline[index] = Int64(frames)
                timeline[index+1] = time.sampleTime
                timeline[index+2] = Int64(count)
                timelineCount += 1
            }
        }
        for channel in 0..<Int(pcm.format.channelCount) {
            pcm.floatChannelData![channel].advanced(by: frames)
                .update(from: input[channel], count: count)
        }
        frames += count
    }

    func recordEvent(_ event: [String: Any]) {
        eventLock.lock()
        defer { eventLock.unlock() }
        // Control-thread allocation never holds the audio-copy lock.
        if acceptingEvents, events.count < 1024 { events.append(event) }
    }

    func recordState(_ state: [String: Any]) {
        eventLock.lock()
        defer { eventLock.unlock() }
        if acceptingEvents, states.count < 100 { states.append(state) }
    }

    /// Freezes storage before handing it to the file writer; subsequent taps are inert.
    func finish() -> (AVAudioPCMBuffer, [String: Any]) {
        lock.lock()
        stopped = true
        pcm.frameLength = AVAudioFrameCount(frames)
        var info: [String: Any] = [
            "frames": frames, "capacityFrames": pcm.frameCapacity,
            "sampleRate": pcm.format.sampleRate, "channels": pcm.format.channelCount,
            "formatErrors": formatErrors,
            "tapDiscontinuities": discontinuities,
            "tapMissingFrames": missingFrames,
            "tapRepeatedFrames": repeatedFrames,
            "firstHostTime": firstHostTime as Any? ?? NSNull(),
            "firstSampleTime": firstSampleTime as Any? ?? NSNull()
        ]
        lock.unlock()
        // Storage is frozen. Allocate the report outside the audio-copy lock.
        // Timestamp gaps are reported, never silently treated as contiguous audio.
        info["tapTimeline"] = (0..<timelineCount).map { index in
            ["fileFrame": timeline[index*3], "sampleTime": timeline[index*3+1],
             "frames": timeline[index*3+2]]
        }
        eventLock.lock()
        acceptingEvents = false
        info["events"] = events
        info["stripPlucks"] = events.filter { $0["row"] != nil }
        info["states"] = states
        eventLock.unlock()
        return (pcm, info)
    }
}

extension AudioEngine {
    func installPluckDiagnosticCapture(format: AVAudioFormat) {
        guard let directory = ProcessInfo.processInfo.environment["TARABDAAR_PLUCK_CAPTURE_DIR"],
              !directory.isEmpty else { return }
        let capture = PluckDiagnosticCapture(format: format)
        pluckCapture = capture
        NSLog("Tarabdaar: first strip pluck or fret onset will capture 20 seconds of mixer output to %@", directory)
    }

    /// Input can arrive from the link queue; graph/state inspection stays on main.
    func recordPlayingDiagnosticEvent(kind: String, id: UInt16, pitchSemis: Double? = nil) {
        guard let capture = pluckCapture else { return }
        var event: [String: Any] = ["kind": kind, "touchID": id,
                                   "uptime": ProcessInfo.processInfo.systemUptime]
        if let pitchSemis { event["pitchSemis"] = pitchSemis }
        let recordedEvent = event
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if kind == "touchOn" { self.armPluckDiagnosticCapture(capture) }
            capture.recordEvent(recordedEvent)
        }
    }

    func armPluckDiagnosticCapture(_ capture: PluckDiagnosticCapture) {
        guard capture.start() else { return }
        var info = pluckDiagnosticState()
        info["startedAt"] = ISO8601DateFormatter().string(from: Date())
        info["armedUptime"] = ProcessInfo.processInfo.systemUptime
        info["executable"] = Bundle.main.executableURL?.path ?? "unknown"
        info["tap"] = "mainMixerNode output, before device; float32, no normalization"
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TARABDAAR_PLUCK_CAPTURE_DIR"]!,
                            isDirectory: true)
        let stem = "pluck-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"
        // Periodic control snapshots locate mappings, held notes and overloads
        // during a phrase instead of relying on the two silent endpoints.
        for index in 1...80 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.25) { [weak self] in
                if let self { capture.recordState(self.pluckDiagnosticState()) }
            }
        }
        // Extra wall time lets the final tap buffer arrive. File IO is off the render thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureFinishDelay) { [weak self] in
            let (pcm, captureInfo) = capture.finish()
            var report = info
            report["capture"] = captureInfo
            report["after"] = self?.pluckDiagnosticState() ?? [:]
            let completedReport = report
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let wav = directory.appendingPathComponent(stem + ".wav")
                    // The writer is released before reporting completion, flushing the WAV header.
                    do {
                        var settings = pcm.format.settings
                        settings[AVLinearPCMIsNonInterleaved] = false
                        let file = try AVAudioFile(forWriting: wav, settings: settings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
                        try file.write(from: pcm)
                    }
                    let data = try JSONSerialization.data(withJSONObject: completedReport, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: directory.appendingPathComponent(stem + ".json"), options: .atomic)
                    NSLog("Tarabdaar: pluck capture saved %@", wav.path)
                } catch {
                    NSLog("Tarabdaar: pluck capture failed: %@", String(describing: error))
                }
            }
        }
    }

    private static var captureFinishDelay: Double { PluckDiagnosticCapture.duration + 2 }

    private func pluckDiagnosticState() -> [String: Any] {
        lock.lock()
        let held = heldTouchOrder.map(Int.init)
        let drones = droneHeld
        let main = mainInstrumentStorage.rawValue
        let drone = droneVoiceModeStorage.rawValue
        lock.unlock()
        var result: [String: Any] = [
            "uptime": ProcessInfo.processInfo.systemUptime,
            "controls": stringVoiceSource?.diagnosticControls() ?? [:],
            "fx": stringVoiceSource?.diagnosticFX() ?? [:],
            "structuralOverrides": stringVoiceOverrides,
            "heldTouchIDs": held, "heldDrones": drones,
            "mainInstrument": main, "droneVoice": drone,
            "bankRevision": tarafBank.revision,
            "bank": tarafBank.rows.map { ["row": Int($0.id), "frequencyHz": Double($0.frequency), "flags": Int($0.flags)] },
            "outputSampleRate": engine.outputNode.outputFormat(forBus: 0).sampleRate,
            "outputPresentationLatency": engine.outputNode.presentationLatency
        ]
        if let source = stringVoiceSource {
            var bow = BowControlMapper.PolySnapshot(count: BowControlMapper.maxSlots)
            source.mapper.snapshotPoly(into: &bow)
            result["bow"] = ["expression": bow.expr, "pressure": bow.press,
                              "position": bow.pos, "tiltDb": bow.tiltDb,
                              "slots": bow.slots.map { ["frequencyHz": $0.f0Target,
                                  "gate": $0.gate, "expressionScale": $0.exprScale] }]
            let render = source.renderStats()
            result["render"] = ["maxMsSinceLastPoll": render.maxMs,
                                "overruns": render.overruns, "callbacks": render.callbacks]
            if let stats = source.jtStats() {
                result["worker"] = ["drops": stats.drops, "flatSamples": stats.flat,
                                    "fill": stats.fill, "async": stats.on]
            }
            result["dualSolver"] = source.currentEngine()?.jtDualStats() ?? []
        }
        #if os(macOS)
        result["outputDeviceID"] = currentOutputDevice
        result["outputBufferFrames"] = outputBufferFrames
        #endif
        return result
    }
}
