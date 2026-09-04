import XCTest
@testable import TarabdaarCore

/// The 12-TET preset as rationals in the scale model.
final class ScalePresetTests: XCTestCase {

    /// Every tempered degree is within 0.0001 ¢ of `2^(k/12)`, both terms fit
    /// the scale-sync blob's 14-bit field, and the scale survives the blob
    /// byte-exactly — so the scale that reaches the iPad is the one the Mac
    /// plays.
    func testEqualTemperedRatiosAreTemperedAndWireSafe() {
        let ratios = ScalePreset.equalTemperedRatios
        XCTAssertEqual(ratios.count, 12)
        for (k, r) in ratios.enumerated() {
            XCTAssertLessThanOrEqual(r.num, 16383, "degree \(k) numerator")
            XCTAssertLessThanOrEqual(r.den, 16383, "degree \(k) denominator")
            XCTAssertGreaterThan(r.den, 0)
            let cents = 1200 * log2(Double(r.num) / Double(r.den))
            XCTAssertEqual(cents, Double(k) * 100, accuracy: 1e-4, "degree \(k)")
        }
        let state = SyncedScaleState(points: ScalePreset.equalTempered.pitchScale.points,
                                     tonicMidi: 62, tonicCents: 0,
                                     marginPixels: 0, layout: .fretPad)
        let decoded = PitchScaleSysEx.decodeBlob(PitchScaleSysEx.encodeBlob(state))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.points.map { [$0.num, $0.den] },
                       state.points.map { [$0.num, $0.den] })
    }
}
