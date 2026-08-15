// swamhost — headless AU host for SWAM Violin 3 (aumu Svl3 AuMo)
// Usage:
//   swamhost dump                      — print the full parameter tree
//   swamhost render score.json out.wav — offline-render a MIDI score
//
// Score JSON:
// {
//   "sampleRate": 48000, "duration": 8.0,
//   "params": [{"address": 123, "value": 0.0} | {"id": "reverbMix", "value": 0.0}],
//   "events": [{"t": 0.5, "midi": [144, 60, 100]}, ...]
// }

import Foundation
import AVFoundation
import AudioToolbox

struct ScoreEvent: Decodable { let t: Double; let midi: [UInt8] }
struct ParamSet: Decodable { let address: UInt64?; let id: String?; let value: Double }
struct Score: Decodable {
    let sampleRate: Double?
    let duration: Double
    let params: [ParamSet]?
    let events: [ScoreEvent]
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let desc = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0x53766C33,      // 'Svl3'
    componentManufacturer: 0x41754D6F, // 'AuMo'
    componentFlags: 0, componentFlagsMask: 0)

func instantiate() -> AVAudioUnit {
    var result: AVAudioUnit?
    let sema = DispatchSemaphore(value: 0)
    AVAudioUnit.instantiate(with: desc, options: []) { unit, err in
        if let err = err { fail("instantiate failed: \(err)") }
        result = unit
        sema.signal()
    }
    sema.wait()
    guard let unit = result else { fail("no unit") }
    return unit
}

func dumpParams(_ unit: AVAudioUnit) {
    guard let tree = unit.auAudioUnit.parameterTree else { fail("no parameter tree") }
    for p in tree.allParameters {
        let flags = p.flags
        let writable = flags.contains(.flag_IsWritable) ? "w" : "-"
        print("addr=\(p.address)\tid=\(p.identifier)\tname=\(p.displayName)\tval=\(p.value)\tmin=\(p.minValue)\tmax=\(p.maxValue)\tunit=\(p.unitName ?? String(p.unit.rawValue))\t\(writable)\tkeyPath=\(p.keyPath)")
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: swamhost dump | swamhost render score.json out.wav") }

let unit = instantiate()
let au = unit.auAudioUnit

if args[1] == "dump" {
    dumpParams(unit)
    exit(0)
}

guard args[1] == "render", args.count == 4 else { fail("usage: swamhost render score.json out.wav") }

let score = try! JSONDecoder().decode(Score.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let sr = score.sampleRate ?? 48000

// Give the plugin time to finish loading its instrument model.
Thread.sleep(forTimeInterval: 2.0)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

// Apply parameter overrides before rendering.
if let sets = score.params, !sets.isEmpty {
    guard let tree = au.parameterTree else { fail("no parameter tree for param sets") }
    for s in sets {
        var param: AUParameter?
        if let a = s.address { param = tree.parameter(withAddress: a) }
        if param == nil, let id = s.id {
            param = tree.allParameters.first { $0.identifier == id || $0.displayName == id }
        }
        guard let p = param else { fail("param not found: \(s)") }
        p.value = AUValue(s.value)
        FileHandle.standardError.write("set \(p.displayName) (addr \(p.address)) = \(p.value)\n".data(using: .utf8)!)
    }
}

let engine = AVAudioEngine()
engine.attach(unit)
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
engine.connect(unit, to: engine.mainMixerNode, format: fmt)
engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
try! engine.start()

// Prefer the classic v2 path for v2-wrapped plugins; fall back to the v3 schedule block.
let v2Unit: AudioUnit? = unit.audioUnit
let scheduleMIDI: (AUEventSampleTime, UInt8, Int, UnsafePointer<UInt8>) -> Void
if let v2 = v2Unit {
    scheduleMIDI = { time, _, length, bytes in
        let offset = UInt32(max(0, time - AUEventSampleTimeImmediate))
        let s = UInt32(bytes[0])
        let d1 = length > 1 ? UInt32(bytes[1]) : 0
        let d2 = length > 2 ? UInt32(bytes[2]) : 0
        MusicDeviceMIDIEvent(v2, s, d1, d2, offset)
    }
} else if let block = au.scheduleMIDIEventBlock {
    scheduleMIDI = { time, cable, length, bytes in block(time, cable, length, bytes) }
} else { fail("no MIDI path") }

let totalFrames = AVAudioFramePosition(score.duration * sr)
let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
let outFile = try! AVAudioFile(forWriting: URL(fileURLWithPath: args[3]),
                               settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: sr,
                                          AVNumberOfChannelsKey: 2,
                                          AVLinearPCMBitDepthKey: 32,
                                          AVLinearPCMIsFloatKey: true],
                               commonFormat: .pcmFormatFloat32, interleaved: false)

// Renders the score once into `samples` (appending); returns the output peak.
func renderOnce(into samples: inout [[Float]]) -> Float {
    // Warmup: render and discard 3 s so the plugin's async model load completes
    // before any score MIDI is sent (early events are silently dropped while loading).
    var warmup = AVAudioFramePosition(3.0 * sr)
    while warmup > 0 {
        let blockFrames = AVAudioFrameCount(min(512, warmup))
        guard (try! engine.renderOffline(blockFrames, to: buf)) == .success else { fail("warmup render failed") }
        warmup -= AVAudioFramePosition(blockFrames)
        RunLoop.current.run(until: Date())
    }

    let events = score.events.map { (frame: AVAudioFramePosition($0.t * sr), bytes: $0.midi) }
        .sorted { $0.frame < $1.frame }
    var evIdx = 0
    var rendered: AVAudioFramePosition = 0
    var peak: Float = 0
    samples = [[], []]

    while rendered < totalFrames {
        let blockFrames = AVAudioFrameCount(min(512, totalFrames - rendered))
        while evIdx < events.count && events[evIdx].frame < rendered + AVAudioFramePosition(blockFrames) {
            let ev = events[evIdx]
            let offset = AUEventSampleTime(ev.frame - rendered)
            ev.bytes.withUnsafeBufferPointer { ptr in
                scheduleMIDI(AUEventSampleTimeImmediate + offset, 0, ptr.count, ptr.baseAddress!)
            }
            evIdx += 1
        }
        let status = try! engine.renderOffline(blockFrames, to: buf)
        guard status == .success else { fail("render status \(status)") }
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(buf.frameLength) {
                samples[ch].append(p[i])
                peak = max(peak, abs(p[i]))
            }
        }
        rendered += AVAudioFramePosition(blockFrames)
        RunLoop.current.run(until: Date())
    }
    return peak
}

var samples: [[Float]] = [[], []]
var attempt = 0
while true {
    attempt += 1
    let peak = renderOnce(into: &samples)
    FileHandle.standardError.write("attempt \(attempt): peak \(peak)\n".data(using: .utf8)!)
    if peak > 1e-5 || attempt >= 5 { break }
    // Silent render: let the plugin finish loading, send all-notes-off, retry.
    let panic: [UInt8] = [0xB0, 123, 0]
    panic.withUnsafeBufferPointer { scheduleMIDI(AUEventSampleTimeImmediate, 0, $0.count, $0.baseAddress!) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
}

let writeBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(samples[0].count))!
writeBuf.frameLength = AVAudioFrameCount(samples[0].count)
for ch in 0..<2 {
    samples[ch].withUnsafeBufferPointer { src in
        writeBuf.floatChannelData![ch].update(from: src.baseAddress!, count: src.count)
    }
}
try! outFile.write(from: writeBuf)
FileHandle.standardError.write("wrote \(samples[0].count) frames to \(args[3])\n".data(using: .utf8)!)
if #available(macOS 15.0, *) { outFile.close() }
exit(0)
