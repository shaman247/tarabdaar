import XCTest
import SarangiKit
@testable import TarabdaarCore

/// THE FX RACK IS ONE INSERT, FOUR POINTS — the registry describes the insert
/// once and instantiates it at every point. These pin the two things a
/// refactor can silently break: KEY SYNC (every derived `fx_<point>_<knob>`
/// key must reach an `FXSettings` field, or the tab shows a dead slider) and
/// THE RESTING RACK (every default must be `FXSettings()`, or the startup push
/// arms the rack and the byte-null contract falls over).
final class FXRackTests: XCTestCase {

    /// The exact key surface presets carry — pinned literally so a template
    /// edit that renames a knob fails here, not in a user's file.
    private static let knobs = ["eq_on", "eq_amount",
                                "rev_on", "rev_type", "rev_mix", "rev_size", "rev_cut"]

    /// KEY SYNC: the derived keys are exactly one insert per engine point, in
    /// the engine's own order, and every one reaches an `FXSettings` field.
    func testEveryRegistryFXKeyReachesTheSettings() throws {
        XCTAssertEqual(ParamRegistry.fxTemplate.map(\.knob), Self.knobs)
        XCTAssertEqual(ParamRegistry.fxPoints.count, FXPoint.allCases.count)
        for (spec, point) in zip(ParamRegistry.fxPoints, FXPoint.allCases) {
            XCTAssertEqual(spec.index, point.rawValue)
            XCTAssertEqual(spec.keyPrefix, point.keyPrefix)
        }

        let fx = ParamRegistry.all.filter { $0.key.hasPrefix("fx_") }
        var expected: [String] = []
        for pt in ParamRegistry.fxPoints {
            expected += Self.knobs.map { pt.keyPrefix + $0 }
        }
        XCTAssertEqual(fx.map(\.key), expected)

        var s = FXSettings()
        for p in fx {
            let ins = try XCTUnwrap(p.insert, p.key)
            XCTAssertEqual(p.group, ParamRegistry.fxGroupName, p.key)
            XCTAssertEqual(p.apply, .live, p.key)
            XCTAssertEqual(p.scope, .global, p.key)
            XCTAssertEqual(ins.point.keyPrefix + ins.knob, p.key)
            let parsed = FXPoint.parse(key: p.key)
            XCTAssertEqual(parsed?.0.rawValue, ins.point.index, p.key)
            XCTAssertEqual(parsed?.1, ins.knob, p.key)
            XCTAssertTrue(s.apply(field: ins.knob, value: p.def),
                          "\(p.key): FXSettings has no field \(ins.knob)")
        }
        // and nothing else in the registry pretends to be an insert
        for p in ParamRegistry.all where !p.key.hasPrefix("fx_") {
            XCTAssertNil(p.insert, p.key)
        }
    }

    /// THE RESTING RACK: pushing every default leaves the settings at
    /// `FXSettings()` — inactive, byte-null.
    func testDefaultsAreTheRestingSettings() {
        for pt in ParamRegistry.fxPoints {
            var s = FXSettings()
            for k in ParamRegistry.fxTemplate {
                XCTAssertTrue(s.apply(field: k.knob, value: k.def),
                              pt.key(k.knob))
            }
            XCTAssertEqual(s, FXSettings(), "\(pt.name) rests armed")
            XCTAssertFalse(s.isActive)
        }
    }

    /// THE CURVE IS INFERRED FROM THE POINTS: at either insert rate the
    /// fitted cascade passes through every point and holds the end gains
    /// flat beyond them; no points, or amount 0, is the identity.
    func testCurvePassesThroughItsPointsAndHoldsOutside() {
        let sets: [[EQPoint]] = [
            [EQPoint(hz: 500, db: 0), EQPoint(hz: 1000, db: 6), EQPoint(hz: 2000, db: 0)],
            [EQPoint(hz: 100, db: -6), EQPoint(hz: 8000, db: 6)],
            [EQPoint(hz: 1000, db: 4)],
            [EQPoint(hz: 200, db: 6), EQPoint(hz: 400, db: 0),
             EQPoint(hz: 4000, db: 0), EQPoint(hz: 8000, db: -8)],
            (0..<10).map { EQPoint(hz: 31.5 * pow(2, Double($0)),
                                   db: [3, -2, 4, 0, -6, 5, 2, -3, 1, 0][$0]) },
        ]
        for sr in [96_000.0, 48_000.0] {
            for pts in sets {
                let d = EQCurve.design(pts, sr: sr)
                XCTAssertLessThanOrEqual(d.sections.count, EQCurve.maxSections)
                for p in pts {
                    XCTAssertEqual(d.magnitudeDB(at: p.hz, sr: sr), p.db, accuracy: 0.3,
                                   "\(sr) Hz: \(p.hz) Hz")
                }
                // held flat from an octave beyond each end, within the
                // curve's own 20 Hz…20 kHz range
                let lo = pts.first!, hi = pts.last!
                for hz in [lo.hz / 4, lo.hz / 2] where hz >= EQCurve.minHz {
                    XCTAssertEqual(d.magnitudeDB(at: hz, sr: sr), lo.db, accuracy: 0.5,
                                   "\(sr) Hz: below the first point at \(hz) Hz")
                }
                for hz in [hi.hz * 2, hi.hz * 4] where hz <= EQCurve.maxHz {
                    XCTAssertEqual(d.magnitudeDB(at: hz, sr: sr), hi.db, accuracy: 0.5,
                                   "\(sr) Hz: above the last point at \(hz) Hz")
                }
            }
        }
        XCTAssertTrue(EQCurve.design([], sr: 96_000).isIdentity)
        XCTAssertTrue(EQCurve.design(sets[0], sr: 96_000).scaled(by: 0).isIdentity)
        // the normaliser: sorted, clamped, merged, capped
        let messy = [EQPoint(hz: 5000, db: 20), EQPoint(hz: 5, db: -3),
                     EQPoint(hz: 5010, db: 2)]
        XCTAssertEqual(EQCurve.normalize(messy),
                       [EQPoint(hz: 20, db: -3), EQPoint(hz: 5000, db: 2)])
    }
}
