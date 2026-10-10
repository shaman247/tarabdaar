import XCTest
@testable import TarabdaarCore

/// Chromatic tuning variants preserve the default layout and exact wire ratios.
final class ScalePresetTests: XCTestCase {

    /// All chromatic presets retain default labels/layout and their intended tuning through scale sync.
    func testChromaticVariantsKeepDefaultLayoutAndTuningOverSync() throws {
        let fifthRatios = (-5...6).map { exponent -> Double in
            let ratio = pow(1.5, Double(exponent))
            return ratio / pow(2, floor(log2(ratio)))
        }.sorted()
        let defaults = PitchScale.defaultJI.points
        for (preset, expectedCents) in [
            (ScalePreset.justIntonation, defaults.map { 1200 * log2($0.ratio) }),
            (.equalTempered, (0..<12).map { Double($0) * 100 }),
            (.pythagorean, fifthRatios.map { 1200 * log2($0) }),
        ] {
            let points = preset.pitchScale.points
            for (k, point) in points.enumerated() {
                XCTAssertEqual(1200 * log2(point.ratio), expectedCents[k],
                               accuracy: preset == .equalTempered ? 1e-4 : 1e-10,
                               "\(preset) degree \(k)")
            }
        }
        for preset in [ScalePreset.justIntonation, .justIntonationMa, .equalTempered,
                       .pythagorean, .pythagoreanMa] {
            let points = preset.pitchScale.points
            XCTAssertEqual(points.count, 12)
            XCTAssertEqual(points.map(\.label), defaults.map(\.label))
            XCTAssertEqual(points.map(\.y), defaults.map(\.y))
            XCTAssertEqual(points.map(\.enabled), defaults.map(\.enabled))
            for (k, point) in points.enumerated() {
                XCTAssertGreaterThan(point.num, 0)
                XCTAssertGreaterThan(point.den, 0)
                XCTAssertLessThanOrEqual(point.num, 16383, "\(preset) degree \(k) numerator")
                XCTAssertLessThanOrEqual(point.den, 16383, "\(preset) degree \(k) denominator")
            }
            let state = SyncedScaleState(points: points, tonicMidi: 62, tonicCents: 0,
                                         marginPixels: 0, layout: .fretPad)
            let decoded = try XCTUnwrap(PitchScaleSysEx.decodeBlob(PitchScaleSysEx.encodeBlob(state)))
            XCTAssertEqual(decoded.points.map { [$0.num, $0.den] },
                           points.map { [$0.num, $0.den] })
            XCTAssertEqual(decoded.points.map(\.label), points.map(\.label))
        }
    }

    /// Ma rotations preserve Sa and Ma while reproducing every base interval measured upward from Ma.
    func testMaRotationsPreserveIntervalsAboveMa() {
        for (variant, base) in [(ScalePreset.justIntonationMa, ScalePreset.justIntonation),
                                (.pythagoreanMa, .pythagorean)] {
            let points = variant.pitchScale.points
            XCTAssertEqual([points[0].num, points[0].den], [1, 1])
            XCTAssertEqual([points[5].num, points[5].den], [4, 3])
            XCTAssertEqual(points.map(\.ratio), points.map(\.ratio).sorted())
            for (relativeDegree, original) in base.pitchScale.points.enumerated() {
                let saDegree = (relativeDegree + 5) % 12
                let rotated = points[saDegree]
                let octave = saDegree < 5 ? 2 : 1
                // Divide the rotated pitch above Ma by 4/3 and compare exact fractions.
                XCTAssertEqual(rotated.num * octave * 3 * original.den,
                               rotated.den * 4 * original.num,
                               "\(variant) interval \(relativeDegree) above Ma")
                XCTAssertEqual(gcd(rotated.num, rotated.den), 1)
                XCTAssertGreaterThanOrEqual(rotated.ratio, 1)
                XCTAssertLessThan(rotated.ratio, 2)
            }
        }
    }
}
