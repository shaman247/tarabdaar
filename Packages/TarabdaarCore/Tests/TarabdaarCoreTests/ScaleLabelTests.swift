import XCTest
@testable import TarabdaarCore

/// ONE NAMING: every named pitch reads the scale's own label — nothing falls
/// back to a second, fixed vocabulary.
final class ScaleLabelTests: XCTestCase {

    private let defaultDegrees = scaleDegrees(from: PitchScale.defaultJI)

    /// The fret labels ARE the scale's labels, in scale order.
    func testNamesComeFromTheScale() {
        let arrangement = FretArrangement.defaultArrangement(degrees: defaultDegrees)
        let placements = fretPlacements(arrangement: arrangement,
                                        degrees: defaultDegrees,
                                        size: CGSize(width: 1000, height: 400))
        let base = placements.filter { !$0.isGhost }
            .sorted { $0.ratio < $1.ratio }.map(\.name)
        XCTAssertEqual(base, defaultDegrees.map(\.label))

        // a custom scale renames everything, frets and drones alike
        let scale = PitchScale(points: [
            PitchPoint(num: 1, den: 1, y: 0.5, label: "do"),
            PitchPoint(num: 3, den: 2, y: 0.5, label: "sol"),
            PitchPoint(num: 5, den: 4, y: 0.5, label: ""),   // blank → ratio
        ])
        let degrees = scaleDegrees(from: scale)
        XCTAssertEqual(degrees.map(\.label), ["do", "5/4", "sol"])
        XCTAssertEqual(scaleLabel(degree: 2, octave: -1, degrees: degrees), "sol,")
        XCTAssertEqual(scaleLabel(forRatio: 1.25, degrees: degrees), "5/4")
        // A degree index the scale no longer has is skipped, never renamed.
        XCTAssertEqual(scaleLabel(degree: 7, degrees: degrees), "—")
    }
}
