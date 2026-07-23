import XCTest
@testable import SarangiKit

final class ModelTests: XCTestCase {

    /// The 37-string bank layout must structurally match raga.build_strings
    /// (ratios/gains/t60/bright/culling), validated with detune disabled.
    func testBuildStringsParity() throws {
        guard let url = Bundle.module.url(forResource: "raga_banks", withExtension: "json", subdirectory: "Goldens"),
              let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let banks = obj["banks"] as? [String: [[Any]]]
        else { throw XCTSkip("raga_banks.json missing — run gen_goldens.py") }

        for (idStr, rows) in banks {
            let m = meta[idStr] as! [String: Any]
            let tonic = (m["tonic"] as! NSNumber).doubleValue
            let intervals = (m["intervals"] as! [NSNumber]).map { $0.intValue }
            let swift = RagaTuning.buildStrings(tonic: tonic, intervals: intervals, detune: false)

            XCTAssertEqual(swift.count, rows.count, "raga \(idStr) string count")
            for (i, row) in rows.enumerated() where i < swift.count {
                let f = (row[0] as! NSNumber).doubleValue
                let g = (row[1] as! NSNumber).doubleValue
                let t = (row[2] as! NSNumber).doubleValue
                let br = (row[3] as! NSNumber).boolValue
                XCTAssertEqual(swift[i].freq, f, accuracy: 0.01, "raga \(idStr) string \(i) freq")
                XCTAssertEqual(swift[i].gain, g, accuracy: 1e-9)
                XCTAssertEqual(swift[i].t60, t, accuracy: 1e-9)
                XCTAssertEqual(swift[i].bright, br, "raga \(idStr) string \(i) bright")
            }
        }
    }

    func testPresetDefaultsAndRanges() {
        let p = SarangiParams.defaults
        for d in ParamSpec.all {
            XCTAssertEqual(p[d.id], d.default, accuracy: 1e-12, "default \(d.id)")
            XCTAssertTrue(d.default >= d.lo && d.default <= d.hi, "\(d.id) default in range")
        }
        // The v57 instrument's live surface (2026-07-12 simplification):
        // bank 10 (B_* incl. web quartet + damp + spread) + tap pair
        // + jawari trio (N_jaw_raga/chrom/lp, the row+buzz-mid adoption)
        // + drone quintet (mix_drone + D_*) + main_gain + E_lp + room trio.
        XCTAssertEqual(ParamSpec.all.count, 25)
    }

    /// Regression guard: the app must be able to load the CURRENT fitted
    /// models (offline fit rounds rewrite these JSONs — a schema drift here
    /// is exactly the "model load failed" app failure of 2026-07-06, when
    /// an array-valued jitter key broke a whole-dict NSNumber cast).
    func testFittedModelsLoad() throws {
        let root = FileManager.default.currentDirectoryPath + "/../params/"
        for name in ["violin_model.json", "sarangi_model.json", "sarangi_model_v57.json"] {
            let path = root + name
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let m = try ViolinModel(url: URL(fileURLWithPath: path))
            XCTAssertGreaterThan(m.hMax, 0, name)
            if name.hasPrefix("sarangi_model") {
                // keys the live synth reads must survive the round-trip
                XCTAssertNotNil(m.jitter["f0_fast_cents_rms"], name)
                XCTAssertNotNil(m.jitter["symp_k"], name)
                // voice mechanisms (2026-07-06): corner FM + vpol + srcfm
                XCTAssertNotNil(m.jitter["corner_cents_rms"], name)
                XCTAssertNotNil(m.jitter["vpol_r"], name)
                XCTAssertNotNil(m.jitter["src_fm_cents_rms"], name)
            }
        }
    }

    /// The Loudness picker's three depths must behave: raw = identity,
    /// surface = inversion without the comp table, full subtracts it.
    func testExprEqModes() throws {
        let root = FileManager.default.currentDirectoryPath + "/../params/"
        let path = root + "sarangi_model_v57.json"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let m = try ViolinModel(url: URL(fileURLWithPath: path))
        let eq = ExprEqualizer(model: m)
        eq.setComp(midis: [55.0, 87.0], db: [6.0, 6.0])
        let args = (midi: 69.0, expr: 0.4, press: 0.55, pos: 0.55)
        eq.mode = .raw
        XCTAssertEqual(eq.equalize(midi: args.midi, expr: args.expr,
                                   press: args.press, pos: args.pos),
                       args.expr)
        eq.mode = .surface
        let surf = eq.equalize(midi: args.midi, expr: args.expr,
                               press: args.press, pos: args.pos)
        eq.mode = .full
        let full = eq.equalize(midi: args.midi, expr: args.expr,
                               press: args.press, pos: args.pos)
        // a +6 dB measured excess must lower the equalized expr
        XCTAssertLessThan(full, surf)
    }

    func testNoteNameRoundTrip() {
        XCTAssertEqual(NoteName.parse("A4")!, 440.0, accuracy: 1e-6)
        XCTAssertEqual(NoteName.parse("Eb4")!, 311.127, accuracy: 0.01)
        XCTAssertEqual(NoteName.parse("D4")!, 293.665, accuracy: 0.01)
    }

    /// Voice-EQ bands must round-trip the python A_bands schema exactly
    /// ({type, f, gain_db, Q}) — the offline fit reads what the app copies.
    /// (Starpad: `VoiceEQBand` — upstream calls it `EQBand`, which here names
    /// the FX rack's band type.)
    func testEQBandPythonSchema() throws {
        let js = #"[{"type": "peak", "f": 860.0, "gain_db": -7.5, "Q": 2.0},"#
               + #" {"type": "low", "f": 160.0, "gain_db": 3.0}]"#
        let bands = try JSONDecoder().decode([VoiceEQBand].self, from: js.data(using: .utf8)!)
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(bands[0].kind, .peak)
        XCTAssertEqual(bands[0].gainDB, -7.5)
        XCTAssertTrue(bands[1].enabled)                 // default when absent
        // the de-horn default carves the honk band: the 860 band alone is
        // -7.5 dB at its centre; with neighbour overlap the combined cut is
        // deeper (RBJ peaking gain at f0 == gain_db exactly)
        let sr = 48000.0
        let solo = VoiceEQBand.dehornA[2].responseDB(at: 860.0, sr: sr)
        XCTAssertEqual(solo, -7.5, accuracy: 0.05)
        let combined = VoiceEQBand.dehornA.reduce(0.0) { $0 + $1.responseDB(at: 860.0, sr: sr) }
        XCTAssertLessThan(combined, solo)               // neighbours add cut
        XCTAssertGreaterThan(combined, -12.0)
        // clean export contains no app-only keys
        let out = VoiceEQBand.aBandsJSON(VoiceEQBand.dehornA)
        XCTAssertFalse(out.contains("enabled"))
        XCTAssertTrue(out.contains("\"gain_db\": -7.5"))
    }

    /// Voice-mechanism smoke: vpol (deterministic beat envelopes) audibly
    /// changes the deterministic render; corner FM renders finite in the
    /// live path; the srcfm replica stays bounded.
    func testVoiceMechanismsSmoke() throws {
        guard let url = Bundle.module.url(forResource: "violin_mini_model",
                                          withExtension: "json",
                                          subdirectory: "Goldens") else {
            throw XCTSkip("mini model golden missing")
        }
        var js = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        var jit = js["jitter"] as! [String: Any]
        jit["vpol_r"] = 0.3
        jit["vpol_cents"] = 3.0
        jit["corner_cents_rms"] = 2.0
        jit["corner_hz_lo"] = 60.0
        jit["corner_hz_hi"] = 260.0
        js["jitter"] = jit
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini_mech_test.json")
        try JSONSerialization.data(withJSONObject: js).write(to: tmp)
        let m0 = try ViolinModel(url: url)
        let m1 = try ViolinModel(url: tmp)

        func render(_ m: ViolinModel, det: Bool) -> [Double] {
            let s = ViolinSynth(model: m, block: 256, deterministic: det)
            var out = [Double](repeating: 0, count: 256)
            var acc: [Double] = []
            let c = ViolinControlFrame(f0: 220, expr: 0.8, press: 0.6,
                                       pos: 0.5, gate: true)
            for _ in 0..<80 {
                _ = s.process(c, into: &out)
                acc.append(contentsOf: out)
            }
            return acc
        }
        let y0 = render(m0, det: true)
        let y1 = render(m1, det: true)          // vpol only (deterministic)
        XCTAssertTrue(y1.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(zip(y0, y1).map { abs($0 - $1) }.max()!, 1e-6)
        let y2 = render(m1, det: false)         // + corner FM (live path)
        XCTAssertTrue(y2.allSatisfy { $0.isFinite })

        // srcfm replica: bounded cents, decays through silence
        var bank = SourceFMBank(partials: [(220.0, 1.0), (330.0, 0.8)],
                                depth: 8.0, sr: 48000)
        var buf = [Double](repeating: 0, count: 256)
        let tone = (0..<256).map { sin(2.0 * Double.pi * 220.0
                                       * Double($0) / 48000.0) }
        for _ in 0..<40 { bank.fill(&buf, from: tone, count: 256) }
        XCTAssertTrue(buf.allSatisfy { $0.isFinite && abs($0) <= 40.0 })
        XCTAssertGreaterThan(buf.map { abs($0) }.max()!, 1e-6)
    }
}
