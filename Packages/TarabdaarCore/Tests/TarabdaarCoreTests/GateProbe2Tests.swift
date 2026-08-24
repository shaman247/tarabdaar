import XCTest
import SarangiKit
@testable import TarabdaarCore
final class GateProbe2Tests: XCTestCase {
    private func run(_ evolve: Double?) throws {
        let src = StringVoiceSource()
        guard let e = StringVoiceSource.buildEngine(
            tonicHz: 328.9,
            strings: Presets.state(.sarangiPilu).resolvedStrings,
            mapper: src.mapper,
            overrides: ["bow_jt_async": 0, "bow_jt_threads": 0])
        else { throw XCTSkip("no json") }
        src.setEngine(e, crossfadeMs: 0)
        if let ev = evolve { src.setJtEvolve(ev) }
        for sec in 1...10 {
            var left = 48000
            while left > 0 {
                _ = src.renderForTesting(frames: 4096)
                left -= 4096
            }
            let g = src.jtGateProbe()!
            let evLabel = evolve == nil ? "def" : "0.0"
            let ringS = String(format: "%.2f", g.ringR)
            let drvS = String(format: "%.2f", g.driveR)
            print("ev=" + evLabel + " t=\(sec)s asleep=\(g.asleep)/\(g.total) ringx" + ringS + " drivex" + drvS)
        }
    }
    func testEvolveNeutral() throws { try run(nil) }
    func testEvolveZero() throws { try run(0.0) }
}
