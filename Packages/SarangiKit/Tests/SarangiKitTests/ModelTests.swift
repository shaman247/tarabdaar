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
        XCTAssertEqual(p.eModes.count, 6)
        // 23 = the previous 27 − the 4 F_* reverb params (block-F reverb was
        // replaced by the per-voice FX rack `FXRack`, edited in the FX tab; the
        // F_* group is gone). The drone (4 params) was dropped earlier.
        XCTAssertEqual(ParamSpec.all.count, 23)
    }

    func testNoteNameRoundTrip() {
        XCTAssertEqual(NoteName.parse("A4")!, 440.0, accuracy: 1e-6)
        XCTAssertEqual(NoteName.parse("Eb4")!, 311.127, accuracy: 0.01)
        XCTAssertEqual(NoteName.parse("D4")!, 293.665, accuracy: 0.01)
    }
}
