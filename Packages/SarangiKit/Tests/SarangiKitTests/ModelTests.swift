import XCTest
@testable import SarangiKit

final class ModelTests: XCTestCase {

    /// TARAB BANK LAYOUT. `RagaTuning.buildSpecs` generates the tarab
    /// whenever the scale sync regenerates the layout, so its degree/gain/
    /// t60 law is live Starpad behaviour. The golden was exported from the
    /// offline `raga.build_strings` (detune off); it is kept as a plain
    /// regression fixture now that there is no upstream to track. Its first
    /// 15 rows are the chromatic choir, REMOVED 2026-07-25 — dropped from
    /// the golden here rather than regenerating the fixture. The detune
    /// chorus died with the scale-defined pitch model the same day.
    /// NO-DUPLICATES LAW (2026-07-26): the pool is one string per pitch,
    /// sorted low → high, each historic Sa/Pa doubling folded into its
    /// strongest twin (higher gain, then longer t60) — so the SAME fold is
    /// applied to the fixture here before comparing.
    func testBuildStringsParity() throws {
        guard let url = Bundle.module.url(forResource: "raga_banks", withExtension: "json", subdirectory: "Goldens"),
              let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let banks = obj["banks"] as? [String: [[Any]]]
        else { throw XCTSkip("raga_banks.json missing — run gen_goldens.py") }

        for (idStr, allRows) in banks {
            let m = meta[idStr] as! [String: Any]
            let tonic = (m["tonic"] as! NSNumber).doubleValue
            let intervals = (m["intervals"] as! [NSNumber]).map { $0.intValue }
            // skip the removed chromatic choir, then fold + sort like the
            // generator (duplicate pitches are exact unisons detune-off)
            // 2026-08-01 coherence rev: the generator's CROWD t60s were
            // DELIBERATELY shortened ~×0.6 (the long wash decoupled from
            // the playing and read as a pad behind the voice); the three
            // drone anchors (Sa 0.95/7 · low Sa 0.95/9 · low Pa 0.85/8)
            // keep their fitted ring. The fixture stays the historical
            // export; its rows are mapped through the same shortening,
            // keyed by (gain, t60) since the anchors share t60 values
            // with shortened crowd rows. Every fold below is decided by
            // GAIN (no same-pitch collision ties on it), so the remap
            // can't flip a fold.
            func newT60(_ g: Double, _ t: Double) -> Double {
                switch (g, t) {
                case (0.85, 5.0): return 3.0   // scale-tuned mid
                case (0.90, 7.0): return 4.5   // Pa doubling
                case (0.80, 7.0): return 4.5   // low choir
                case (0.75, 7.0): return 4.5   // low vadi
                case (0.70, 3.5): return 2.5   // upper repeats
                default: return t              // the drone anchors
                }
            }
            var best: [Int: (f: Double, g: Double, t: Double)] = [:]
            for row in allRows.dropFirst(15) {
                let f = (row[0] as! NSNumber).doubleValue
                let g = (row[1] as! NSNumber).doubleValue
                let tRaw = (row[2] as! NSNumber).doubleValue
                let t = newT60(g, tRaw)
                let key = Int((1200.0 * log2(f / tonic)).rounded())
                if let w = best[key], (w.g, w.t) >= (g, t) { continue }
                best[key] = (f, g, t)
            }
            let rows = best.values.sorted { $0.f < $1.f }
            let swift = RagaTuning.buildStrings(tonic: tonic, intervals: intervals)

            XCTAssertEqual(swift.count, rows.count, "raga \(idStr) string count")
            for (i, row) in rows.enumerated() where i < swift.count {
                XCTAssertEqual(swift[i].freq, row.f, accuracy: 0.01, "raga \(idStr) string \(i) freq")
                XCTAssertEqual(swift[i].gain, row.g, accuracy: 1e-9)
                XCTAssertEqual(swift[i].t60, row.t, accuracy: 1e-9)
            }
        }
    }

    func testNoteNameRoundTrip() {
        XCTAssertEqual(NoteName.parse("A4")!, 440.0, accuracy: 1e-6)
        XCTAssertEqual(NoteName.parse("Eb4")!, 311.127, accuracy: 0.01)
        XCTAssertEqual(NoteName.parse("D4")!, 293.665, accuracy: 0.01)
    }
}
