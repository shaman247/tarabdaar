import XCTest
@testable import SarangiKit

/// Locks the bin↔harmonic math of the Live-tab harmonic analyzer: a ringing
/// `CombString`'s one-period buffer, DFT'd, peaks at the driven harmonic.
final class BankAnalyzerTests: XCTestCase {
    let sr = 44100.0

    /// Build a one-string raw snapshot from a comb after driving it, so the
    /// analyzer sees real ringing buffer state.
    private func snapshot(f0: Double, drive: (Int) -> Double, samples: Int) -> BankRawSnapshot {
        var comb = CombString(f0: f0, t60: 2.0, sr: sr, bright: 0.6)
        for n in 0..<samples { _ = comb.process(drive(n)) }
        let str = StringRawSnapshot(freq: sr / Double(comb.period), isBright: false,
                                    group: .scale, outWeight: 1.0,
                                    period: comb.period, buffer: comb.bufferCopy())
        return BankRawSnapshot(sr: sr, strings: [str],
                               inputRing: [Double](repeating: 0, count: 2048),
                               playedWeight: 0, playedF0: 0, playedActive: false)
    }

    /// The fundamental dominates when driven by an impulse train at f0.
    func testFundamentalPeaks() {
        let f0 = 220.0
        let L = Int((sr / f0).rounded())
        let snap = snapshot(f0: f0, drive: { $0 % L == 0 ? 1.0 : 0.0 }, samples: L * 200)
        let a = BankAnalyzer.analyze(snap)
        let cells = a.cells.filter { $0.columnIndex == 1 }   // column 0 is Played
        let top = cells.max { $0.magnitude < $1.magnitude }
        XCTAssertNotNil(top, "string should ring")
        XCTAssertEqual(top!.harmonic, 1, "impulse-at-period drive → fundamental dominates")
        XCTAssertEqual(top!.freqHz, sr / Double(L), accuracy: 1.0)
    }

    /// Driving at the 3rd harmonic's period makes harmonic 3 the loudest.
    func testThirdHarmonicPeaks() {
        let f0 = 180.0
        let L = Int((sr / f0).rounded())
        // A sinusoid at 3·f0 lands on the comb's 3rd harmonic.
        let snap = snapshot(f0: f0, drive: { sin(2.0 * Double.pi * 3.0 * f0 * Double($0) / sr) },
                            samples: L * 300)
        let a = BankAnalyzer.analyze(snap)
        let cells = a.cells.filter { $0.columnIndex == 1 }
        let top = cells.max { $0.magnitude < $1.magnitude }
        XCTAssertNotNil(top)
        XCTAssertEqual(top!.harmonic, 3, "drive at 3·f0 → 3rd harmonic dominates")
    }

    /// A silent comb produces no bands (idle → dark).
    func testSilenceIsEmpty() {
        let snap = snapshot(f0: 200.0, drive: { _ in 0.0 }, samples: 100)
        let a = BankAnalyzer.analyze(snap)
        XCTAssertTrue(a.cells.allSatisfy { $0.columnIndex == 0 },
                      "no sympathetic cells when the comb never rang")
        XCTAssertEqual(a.columns.count, 2, "Played + one string column, always present")
    }

    /// The played-note column emits harmonics of the played pitch from the ring.
    func testPlayedNoteHarmonics() {
        let f0 = 261.0
        var ring = [Double](repeating: 0, count: 2048)
        for n in ring.indices { ring[n] = sin(2.0 * Double.pi * f0 * Double(n) / sr) }
        let snap = BankRawSnapshot(sr: sr, strings: [], inputRing: ring,
                                   playedWeight: 1.0, playedF0: f0, playedActive: true)
        let a = BankAnalyzer.analyze(snap)
        let played = a.cells.filter { $0.columnIndex == 0 }
        let top = played.max { $0.magnitude < $1.magnitude }
        XCTAssertNotNil(top)
        XCTAssertEqual(top!.harmonic, 1)
        XCTAssertEqual(top!.freqHz, f0, accuracy: 0.5)
    }
}
