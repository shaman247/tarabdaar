import XCTest
import SarangiKit
@testable import TarabdaarCore

/// TARAF VARIANCE BENCH (2026-08-15) — measurement harness, not a guard.
///
/// User report: some taraf notes randomly ring very loudly WITH buzz —
/// most commonly Pa and high Sa, usually after playing or gliding
/// through several other notes. Suspected mechanism (the tanpura
/// analog): the long-t60 anchor rows accumulate charge across a phrase,
/// re-excitation lands on ringing modal state (phase lottery), and past
/// the graze knee the jawari contact hardens into the loud buzz regime.
///
/// Skip-gated: set TARAF_BENCH_DIR to a writable directory and the
/// sweep renders each scenario on a FRESH engine (serial jt — the async
/// pool is not bit-reproducible) and dumps mono f64 raw files plus a
/// manifest.json with per-scenario event sample-times for offline
/// analysis. Not a regression test; nothing asserts beyond finiteness.
final class TarafVarianceBench: XCTestCase {

    private let sr = 48000.0
    private let block = 4096

    private struct Ev: Codable {
        let t: Int          // sample index
        let kind: String    // on/off/glideStart/glideEnd/cc
        let note: Double
    }
    private struct Scenario: Codable {
        let name: String
        let sr: Double
        let events: [Ev]
        let frames: Int
    }

    private final class Rig {
        let src = StringVoiceSource()
        var buf: [Double] = []
        var events: [Ev] = []
        var cursor: Int { buf.count }

        init?(overrides: [String: Double]) {
            guard let e = StringVoiceSource.buildEngine(
                tonicHz: 328.9,
                strings: Presets.state(.sarangiPilu).resolvedStrings,
                mapper: src.mapper, overrides: overrides)
            else { return nil }
            src.setEngine(e, crossfadeMs: 0)
        }

        func pump(seconds: Double, block: Int) {
            let frames = Int(seconds * 48000.0)
            var done = 0
            while done < frames {
                let n = min(block, frames - done)
                let (l, r) = src.renderForTesting(frames: n)
                for i in 0..<n {
                    buf.append(0.5 * (Double(l[i]) + Double(r[i])))
                }
                done += n
            }
        }

        func mark(_ kind: String, _ note: Double) {
            events.append(Ev(t: cursor, kind: kind, note: note))
        }
    }

    /// Strike the target exactly the same way in every scenario so the
    /// windows are directly comparable: bow 0.8 s, lift, ring 3.2 s.
    private func strikeTarget(_ rig: Rig, note: UInt8, tail: Double = 3.2) {
        rig.mark("on", Double(note))
        rig.src.mapper.midi(0x90, note, 100)
        rig.pump(seconds: 0.8, block: block)
        rig.mark("off", Double(note))
        rig.src.mapper.midi(0x80, note, 0)
        rig.pump(seconds: tail, block: block)
    }

    func testVarianceSweep() throws {
        guard let dir = ProcessInfo.processInfo
            .environment["TARAF_BENCH_DIR"] else {
            throw XCTSkip("set TARAF_BENCH_DIR to run the taraf variance bench")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out,
                                                withIntermediateDirectories: true)
        // Serial jt = bit-reproducible renders (the async pool is not).
        let ov: [String: Double] = ["bow_jt_async": 0, "bow_jt_threads": 0]

        var manifest: [Scenario] = []
        func run(_ name: String, _ body: (Rig) -> Void) throws {
            guard let rig = Rig(overrides: ov) else {
                throw XCTSkip("bowed_string.json not available")
            }
            rig.src.mapper.midi(0xB0, 11, 64)
            rig.pump(seconds: 0.25, block: block)   // noise-floor window
            body(rig)
            XCTAssertTrue(rig.buf.allSatisfy(\.isFinite), "\(name): non-finite")
            let data = rig.buf.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: out.appendingPathComponent("\(name).f64"))
            manifest.append(Scenario(name: name, sr: sr, events: rig.events,
                                     frames: rig.buf.count))
            print("  bench \(name): \(rig.buf.count) frames")
        }

        // Targets: Pa (fifth), high Sa (octave), and a non-kin control.
        // Tonic 328.9 Hz ≈ midi 64 (the shared test tonic).
        let targets: [(tag: String, note: UInt8)] =
            [("pa", 71), ("sahi", 76), ("nonkin", 70)]

        for (tag, note) in targets {
            // 1. Solo strike from silence at the two expression levels
            //    (CC11 32 = the pads' resting median, 64 = a loud bow).
            for cc in [UInt8(32), UInt8(64)] {
                try run("solo_\(tag)_e\(cc)") { rig in
                    rig.src.mapper.midi(0xB0, 11, cc)
                    self.strikeTarget(rig, note: note)
                }
            }

            // 2. Repeated strikes at irregular gaps — the re-excitation
            //    lottery on the target's own rows (tanpura REPLUCK twin).
            try run("rep_\(tag)") { rig in
                let gaps = [1.13, 1.41, 1.87, 1.19, 1.63]
                for (i, g) in ([0.0] + gaps).enumerated() {
                    if g > 0 { rig.pump(seconds: g, block: self.block) }
                    rig.mark("on", Double(note))
                    rig.src.mapper.midi(0x90, note, 100)
                    rig.pump(seconds: 0.6, block: self.block)
                    rig.mark("off", Double(note))
                    rig.src.mapper.midi(0x80, note, 0)
                    _ = i
                }
                rig.pump(seconds: 3.2, block: self.block)
            }

            // 3. A four-note phrase (Sa Re Ga ma), then the identical
            //    target strike; six timing variants expose the phase
            //    lottery in what the phrase leaves ringing.
            for k in 0..<6 {
                try run("phrase_\(tag)_\(k)") { rig in
                    let phrase: [UInt8] = [64, 66, 68, 69]
                    let stretch = [1.0, 1.13, 1.41, 1.87, 1.19, 1.63][k]
                    for (i, n) in phrase.enumerated() {
                        let dur = 0.42 * stretch
                            * (1.0 + 0.11 * Double((i + k) % 3))
                        rig.mark("on", Double(n))
                        rig.src.mapper.midi(0x90, n, 100)
                        rig.pump(seconds: dur, block: self.block)
                        rig.mark("off", Double(n))
                        rig.src.mapper.midi(0x80, n, 0)
                        rig.pump(seconds: 0.06, block: self.block)
                    }
                    rig.pump(seconds: 0.2, block: self.block)
                    self.strikeTarget(rig, note: note)
                }
            }

            // 4. A glide from Sa up to the target (the Fret Pad touch
            //    path — full-resolution meend through every row's kin
            //    corridor), hold, lift; four glide speeds.
            for k in 0..<4 {
                try run("glide_\(tag)_\(k)") { rig in
                    let dur = [1.0, 1.45, 1.9, 2.35][k]
                    let from = 64.0, to = Double(note)
                    rig.mark("glideStart", from)
                    rig.src.mapper.touchOn(1, pitchSemis: from, velocity: 0.8)
                    let steps = Int(dur * self.sr) / self.block
                    for s in 0..<steps {
                        let x = Double(s + 1) / Double(steps)
                        rig.src.mapper.touchGlide(1, pitchSemis:
                            from + (to - from) * x)
                        rig.pump(seconds: Double(self.block) / self.sr,
                                 block: self.block)
                    }
                    rig.mark("glideEnd", to)
                    rig.pump(seconds: 0.7, block: self.block)
                    rig.mark("off", to)
                    rig.src.mapper.touchOff(1)
                    rig.pump(seconds: 3.2, block: self.block)
                }
            }
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest)
            .write(to: out.appendingPathComponent("manifest.json"))
    }

    /// Governor calibration sweep (`bow_jt_gov` / `bow_jt_gov_ref`):
    /// find the graze-target reference where a solo strike is untouched
    /// but the phrase pile-up is capped. Renders the decisive scenarios
    /// at gov 1 across ref values, plus a gov-0 control.
    func testGovSweep() throws {
        guard let dir = ProcessInfo.processInfo
            .environment["TARAF_BENCH_GOV"] else {
            throw XCTSkip("set TARAF_BENCH_GOV to run the governor sweep")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out,
                                                withIntermediateDirectories: true)
        var manifest: [Scenario] = []
        func run(_ name: String, cc: UInt8, ov: [String: Double],
                 _ body: (Rig) -> Void) throws {
            guard let rig = Rig(overrides: ov) else {
                throw XCTSkip("bowed_string.json not available")
            }
            rig.src.mapper.midi(0xB0, 11, cc)
            rig.pump(seconds: 0.25, block: block)
            body(rig)
            XCTAssertTrue(rig.buf.allSatisfy(\.isFinite), "\(name): non-finite")
            let data = rig.buf.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: out.appendingPathComponent("\(name).f64"))
            manifest.append(Scenario(name: name, sr: sr, events: rig.events,
                                     frames: rig.buf.count))
            print("  bench \(name): \(rig.buf.count) frames")
        }
        func phraseThenTarget(_ rig: Rig, note: UInt8, k: Int) {
            let phrase: [UInt8] = [64, 66, 68, 69]
            let stretch = [1.0, 1.41][k]
            for (i, n) in phrase.enumerated() {
                let dur = 0.42 * stretch * (1.0 + 0.11 * Double((i + k) % 3))
                rig.mark("on", Double(n))
                rig.src.mapper.midi(0x90, n, 100)
                rig.pump(seconds: dur, block: block)
                rig.mark("off", Double(n))
                rig.src.mapper.midi(0x80, n, 0)
                rig.pump(seconds: 0.06, block: block)
            }
            rig.pump(seconds: 0.2, block: block)
            strikeTarget(rig, note: note)
        }
        let base: [String: Double] = ["bow_jt_async": 0, "bow_jt_threads": 0]
        var configs: [(tag: String, ov: [String: Double])] =
            [("off", base)]
        for ref in [12.0, 24.0, 48.0, 96.0, 192.0] {
            var ov = base
            ov["bow_jt_gov"] = 1.0
            ov["bow_jt_gov_ref"] = ref
            configs.append(("r\(Int(ref))", ov))
        }
        for (tag, ov) in configs {
            try run("gsolo64_\(tag)", cc: 64, ov: ov) { rig in
                self.strikeTarget(rig, note: 76)
            }
            try run("gsolo124_\(tag)", cc: 124, ov: ov) { rig in
                self.strikeTarget(rig, note: 76)
            }
            for k in 0..<2 {
                try run("gphrase124_\(tag)_\(k)", cc: 124, ov: ov) { rig in
                    phraseThenTarget(rig, note: 76, k: k)
                }
            }
            try run("gphrasepa64_\(tag)", cc: 64, ov: ov) { rig in
                phraseThenTarget(rig, note: 71, k: 0)
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest)
            .write(to: out.appendingPathComponent("manifest.json"))
    }

    /// Hot-expression sweep: the CC11 axis is ±16 dB in real playing —
    /// the graze knee sits at an absolute amplitude, so the buzz-regime
    /// flip should appear only once (expression × accumulation) crosses
    /// it. Solo strikes at each level are the control.
    func testHotSweep() throws {
        guard let dir = ProcessInfo.processInfo
            .environment["TARAF_BENCH_HOT"] else {
            throw XCTSkip("set TARAF_BENCH_HOT to run the hot sweep")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out,
                                                withIntermediateDirectories: true)
        let ov: [String: Double] = ["bow_jt_async": 0, "bow_jt_threads": 0]

        var manifest: [Scenario] = []
        func run(_ name: String, cc: UInt8, _ body: (Rig) -> Void) throws {
            guard let rig = Rig(overrides: ov) else {
                throw XCTSkip("bowed_string.json not available")
            }
            rig.src.mapper.midi(0xB0, 11, cc)
            rig.pump(seconds: 0.25, block: block)
            body(rig)
            XCTAssertTrue(rig.buf.allSatisfy(\.isFinite), "\(name): non-finite")
            let data = rig.buf.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: out.appendingPathComponent("\(name).f64"))
            manifest.append(Scenario(name: name, sr: sr, events: rig.events,
                                     frames: rig.buf.count))
            print("  bench \(name): \(rig.buf.count) frames")
        }

        for (tag, note) in [("pa", UInt8(71)), ("sahi", UInt8(76))] {
            for cc in [UInt8(90), UInt8(110), UInt8(124)] {
                try run("hsolo_\(tag)_e\(cc)", cc: cc) { rig in
                    self.strikeTarget(rig, note: note)
                }
                for k in 0..<3 {
                    try run("hphrase_\(tag)_e\(cc)_\(k)", cc: cc) { rig in
                        let phrase: [UInt8] = [64, 66, 68, 69]
                        let stretch = [1.0, 1.41, 1.87][k]
                        for (i, n) in phrase.enumerated() {
                            let dur = 0.42 * stretch
                                * (1.0 + 0.11 * Double((i + k) % 3))
                            rig.mark("on", Double(n))
                            rig.src.mapper.midi(0x90, n, 100)
                            rig.pump(seconds: dur, block: self.block)
                            rig.mark("off", Double(n))
                            rig.src.mapper.midi(0x80, n, 0)
                            rig.pump(seconds: 0.06, block: self.block)
                        }
                        rig.pump(seconds: 0.2, block: self.block)
                        self.strikeTarget(rig, note: note)
                    }
                }
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest)
            .write(to: out.appendingPathComponent("manifest.json"))
    }
}
