import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The String source's control and FX caches are written from every control
/// thread at once (link queue, main thread, evaluator timers).
final class ControlCacheConcurrencyTests: XCTestCase {
    /// Concurrent writes, including an engine swap under them, must neither
    /// crash nor leave a key unowned.
    func testConcurrentSetControlAndFXParamDoNotRace() {
        let src = StringVoiceSource()
        let keys = ["bow_jt_lp", "bow_jt_damp", "bow_tone_tilt", "bow_gain",
                    "bow_jt_sel", "bow_jt_evolve", "bow_bal", "bow_jt_couple"]
        let fxKey = "fx_voice_rev_mix"
        let curve = [EQPoint(hz: 200, db: 3), EQPoint(hz: 3000, db: -4)]
        let workers = 8
        let rounds = 2000
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in 0..<rounds {
                let key = keys[(w + i) % keys.count]
                XCTAssertTrue(src.setControl(key, Double(i % 7) * 0.1))
                if i % 3 == 0 { _ = src.setFXParam(fxKey, Double(i % 5) * 0.2) }
                if i % 50 == 0 { src.setEQCurve(.voice, i % 100 == 0 ? curve : []) }
                if i % 97 == 0 { src.setEngine(nil) }
            }
        }
        // Every key is still owned and a final write lands on a sane cache.
        for key in keys {
            XCTAssertTrue(src.setControl(key, 0.5))
        }
    }
}
