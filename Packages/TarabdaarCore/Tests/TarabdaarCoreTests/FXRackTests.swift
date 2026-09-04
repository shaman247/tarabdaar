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
    private static let knobs = ["eq_on"]
        + (1...10).map { "eq_b\($0)" }
        + ["rev_on", "rev_type", "rev_mix", "rev_size", "rev_cut"]

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
}
