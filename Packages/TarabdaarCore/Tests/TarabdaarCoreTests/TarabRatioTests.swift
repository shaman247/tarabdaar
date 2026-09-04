import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Scale-defined tarab: degree resolution is deterministic to the bit, and the
/// pool invariant (pitch-sorted, one string per pitch per bridge) holds on
/// generation and on decode.
final class TarabRatioTests: XCTestCase {

    /// Resolution is tonic × degreeRatio × 2^octave on the millihertz grid —
    /// deterministic to the bit, which the drone press path's identity lookup
    /// on nominal Hz depends on.
    func testResolutionLaw() {
        let scale = RagaTuning.ratios(forIntervals: RagaTuning.raga(id: 3).intervals)
        for tonic in [161.3, 328.9, 440.0] {
            for d in scale.indices {
                for oct in -2...2 {
                    let s = StringSpec(degree: d, octave: oct, gain: 1, t60: 5)
                    let want = (scale[d] * pow(2.0, Double(oct)) * tonic * 1000).rounded() / 1000
                    XCTAssertEqual(s.resolved(tonic: tonic, scaleRatios: scale).freq, want)
                }
            }
        }
    }

    /// The generated default bank is pitch-sorted and one string per pitch PER
    /// BRIDGE — the raga set lists first, then the chromatic set, each sorted
    /// (a pitch may sit on both bridges).
    func testDefaultBankIsSortedAndDuplicateFree() {
        let state = Presets.state(.sarangiPilu)
        let sets = state.strings.map(\.set)
        XCTAssertEqual(sets, sets.sorted { $0 == .raga && $1 == .chromatic },
                       "raga bridge must list first")
        for set in TarabSet.allCases {
            let ratios = state.strings(in: set).map { $0.ratio(in: state.scaleRatios) }
            XCTAssertEqual(ratios, ratios.sorted(), "\(set) bank not sorted by pitch")
            XCTAssertEqual(Set(ratios).count, ratios.count, "\(set): duplicate pitches")
        }
    }

    /// A document with duplicate rows folds on decode: the strongest twin
    /// survives, the pool comes out sorted, and a drone button mapped to a
    /// dropped twin is re-pointed at the survivor.
    func testDecodeFoldsDuplicatesAndRemapsDrones() throws {
        var state = Presets.state(.sarangiPilu)
        // a weak twin of low Sa, mapped by drone slot 0, inserted out of order
        let weakTwin = StringSpec(degree: 0, octave: -1, gain: 0.80, t60: 7.0)
        let survivor = state.strings.first { $0.degree == 0 && $0.octave == -1 }!
        state.strings.insert(weakTwin, at: 0)
        state.droneStringIds[0] = weakTwin.id
        let decoded = try JSONDecoder().decode(
            InstrumentState.self, from: JSONEncoder().encode(state))
        for set in TarabSet.allCases {
            let ratios = decoded.strings(in: set).map { $0.ratio(in: decoded.scaleRatios) }
            XCTAssertEqual(ratios, ratios.sorted())
            XCTAssertEqual(Set(ratios).count, ratios.count)
        }
        XCTAssertFalse(decoded.strings.contains { $0.id == weakTwin.id },
                       "the weaker twin must fold away")
        XCTAssertEqual(decoded.droneStringIds[0], survivor.id,
                       "a drone mapped to the dropped twin must follow the survivor")
    }

}
