import Foundation
import StarpadDSP

/// Offline tanpura renderer.
///
///   tanpura-render spec.json [more-specs.json …] [-o out.wav] [--mono]
///   tanpura-render --print-defaults
///
/// Each spec is a `TanpuraRenderSpec` JSON: `{sampleRate?, durationSeconds,
/// seed?, params?, plucks: [{at, string, velocity}], out?}`. `-o` overrides
/// the output path when exactly one spec is given. Renders are
/// deterministic for a given (seed, params, plucks).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("tanpura-render: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func writeWAV(url: URL, left: [Float], right: [Float]?, sampleRate: Double) throws {
    let channels = right == nil ? 1 : 2
    let frames = left.count
    let bytesPerFrame = channels * 2
    let dataBytes = frames * bytesPerFrame

    var d = Data(capacity: 44 + dataBytes)
    func append(_ s: String) { d.append(s.data(using: .ascii)!) }
    func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

    append("RIFF"); appendU32(UInt32(36 + dataBytes)); append("WAVE")
    append("fmt "); appendU32(16); appendU16(1)
    appendU16(UInt16(channels)); appendU32(UInt32(sampleRate))
    appendU32(UInt32(sampleRate) * UInt32(bytesPerFrame))
    appendU16(UInt16(bytesPerFrame)); appendU16(16)
    append("data"); appendU32(UInt32(dataBytes))

    var pcm = [Int16](repeating: 0, count: frames * channels)
    func clip(_ x: Float) -> Int16 { Int16(max(-32768, min(32767, x * 32767))) }
    if let right {
        for f in 0..<frames {
            pcm[f * 2] = clip(left[f])
            pcm[f * 2 + 1] = clip(right[f])
        }
    } else {
        for f in 0..<frames { pcm[f] = clip(left[f]) }
    }
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: url)
}

func render(spec: TanpuraRenderSpec, outOverride: String?, mono: Bool) throws {
    guard let outPath = outOverride ?? spec.out else {
        fail("spec has no \"out\" and no -o was given")
    }
    let sr = spec.sampleRate ?? 44100
    let frames = Int(spec.durationSeconds * sr)
    guard frames > 0, frames < Int(sr) * 600 else {
        fail("durationSeconds out of range (0 < d < 600)")
    }

    let model = TanpuraModel(sampleRate: sr,
                             seed: spec.seed ?? 0x5EED_1A4B,
                             params: spec.params ?? TanpuraParams())
    for ev in spec.plucks {
        model.pluckAt(sample: Int64(ev.at * sr), string: ev.string, velocity: ev.velocity)
    }

    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    let block = 512
    left.withUnsafeMutableBufferPointer { lBuf in
        right.withUnsafeMutableBufferPointer { rBuf in
            var offset = 0
            while offset < frames {
                let n = min(block, frames - offset)
                model.renderAdd(intoL: lBuf.baseAddress! + offset,
                                intoR: rBuf.baseAddress! + offset,
                                frames: n)
                offset += n
            }
        }
    }
    if model.recoveryCount > 0 {
        FileHandle.standardError.write("tanpura-render: warning: \(model.recoveryCount) NaN recoveries\n".data(using: .utf8)!)
    }

    let url = URL(fileURLWithPath: outPath)
    if mono {
        var m = [Float](repeating: 0, count: frames)
        for f in 0..<frames { m[f] = 0.5 * (left[f] + right[f]) }
        try writeWAV(url: url, left: m, right: nil, sampleRate: sr)
    } else {
        try writeWAV(url: url, left: left, right: right, sampleRate: sr)
    }
    print(outPath)
}

// MARK: - Argument parsing

var specPaths: [String] = []
var outOverride: String? = nil
var mono = false
var printDefaults = false

var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "-o":
        guard let v = it.next() else { fail("-o needs a path") }
        outOverride = v
    case "--mono": mono = true
    case "--print-defaults": printDefaults = true
    case "-h", "--help":
        print("usage: tanpura-render spec.json [more-specs.json …] [-o out.wav] [--mono] | --print-defaults")
        exit(0)
    default:
        specPaths.append(arg)
    }
}

if printDefaults {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! enc.encode(TanpuraParams())
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

guard !specPaths.isEmpty else { fail("no spec files given (try --help)") }
if outOverride != nil && specPaths.count > 1 { fail("-o only valid with a single spec") }

for path in specPaths {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    let spec: TanpuraRenderSpec
    do {
        spec = try JSONDecoder().decode(TanpuraRenderSpec.self, from: data)
    } catch {
        fail("parse \(path): \(error)")
    }
    do {
        try render(spec: spec, outOverride: outOverride, mono: mono)
    } catch {
        fail("render \(path): \(error)")
    }
}
