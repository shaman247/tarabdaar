import XCTest
import SarangiKit
@testable import TarabdaarCore

/// THE FX RACK IS ONE INSERT, FOUR POINTS — the registry describes the
/// insert once (`ParamRegistry.fxTemplate`) and instantiates it at every
/// point (`ParamRegistry.fxPoints`). These pin the two things that
/// refactor can silently break:
///
///  * **KEY SYNC** — every derived `fx_<point>_<knob>` key must parse via
///    `FXPoint.parse` + `FXSettings.apply(field:)`, or the FX tab would
///    show a slider that does nothing (`AudioEngine` routes by the `fx_`
///    prefix and never validates the suffix).
///  * **THE RESTING RACK** — every default must equal `FXSettings()`, or
///    the startup resting push would ARM the rack and the byte-null
///    contract (`ByteNullContractTests`, `TarafRemovalParityTests`) would
///    fall over.
final class FXRackTests: XCTestCase {

    /// The exact key surface presets carry — pinned literally so a
    /// template edit that renames a knob fails here, not in a user's file.
    private static let knobs = ["eq_on"]
        + (1...10).map { "eq_b\($0)" }
        + ["rev_on", "rev_type", "rev_mix", "rev_size", "rev_cut"]

    func testTheInsertIsDescribedOnceAndInstantiatedAtEveryPoint() {
        XCTAssertEqual(ParamRegistry.fxTemplate.map(\.knob), Self.knobs)
        XCTAssertEqual(ParamRegistry.fxPoints.count, FXPoint.allCases.count)

        let fx = ParamRegistry.all.filter { $0.key.hasPrefix("fx_") }
        XCTAssertEqual(fx.count,
                       ParamRegistry.fxPoints.count * Self.knobs.count)
        var expected: [String] = []
        for pt in ParamRegistry.fxPoints {
            expected += Self.knobs.map { pt.keyPrefix + $0 }
        }
        XCTAssertEqual(fx.map(\.key), expected)
        // every derived spec knows where it came from
        for p in fx {
            let ins = p.insert
            XCTAssertEqual(p.group, ParamRegistry.fxGroupName, p.key)
            XCTAssertEqual(p.apply, .live, p.key)
            XCTAssertEqual(p.scope, .global, p.key)
            XCTAssertEqual(ins?.point.keyPrefix.appending(ins?.knob ?? ""),
                           p.key)
        }
        // and nothing else in the registry pretends to be an insert
        for p in ParamRegistry.all where !p.key.hasPrefix("fx_") {
            XCTAssertNil(p.insert, p.key)
        }
    }

    /// A derived spec is read OUT OF CONTEXT in the tilt / composite
    /// menus (one flat list per group), so its label must name its point —
    /// four unpickable "EQ 125 Hz (dB)" rows was the trap. Inside the
    /// Parameters tab's insert section the bare `knobLabel` shows instead.
    func testDerivedLabelsNameTheirPointAndStayUnique() {
        var seen = Set<String>()
        for p in ParamRegistry.all where p.insert != nil {
            let ins = p.insert!
            XCTAssertTrue(p.label.contains(ins.point.name), p.key)
            XCTAssertTrue(p.label.hasSuffix(ins.knobLabel), p.key)
            XCTAssertTrue(seen.insert(p.label).inserted,
                          "duplicate menu label \(p.label)")
        }
    }

    /// The registry's point list IS the engine's — same order, same
    /// prefixes (`SarangiKit.FXPoint.keyPrefix`).
    func testPointsMatchTheEnginesInsertPoints() {
        for (spec, point) in zip(ParamRegistry.fxPoints, FXPoint.allCases) {
            XCTAssertEqual(spec.index, point.rawValue)
            XCTAssertEqual(spec.keyPrefix, point.keyPrefix)
        }
    }

    /// KEY SYNC: every registry FX key reaches an `FXSettings` field.
    func testEveryRegistryFXKeyReachesTheSettings() {
        var s = FXSettings()
        for p in ParamRegistry.all where p.insert != nil {
            let parsed = FXPoint.parse(key: p.key)
            XCTAssertNotNil(parsed, "\(p.key) does not parse as an FX key")
            XCTAssertEqual(parsed?.0.rawValue, p.insert?.point.index, p.key)
            XCTAssertEqual(parsed?.1, p.insert?.knob, p.key)
            XCTAssertTrue(s.apply(field: p.insert!.knob, value: p.def),
                          "\(p.key): FXSettings has no field \(p.insert!.knob)")
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

    /// The Parameters tab and paramdoc both render a group through
    /// `insertSections`: flat rows, then one section per insert point.
    func testInsertSectionsSplitTheRackIntoFourPoints() {
        let fx = ParamRegistry.groups.first { $0.name == ParamRegistry.fxGroupName }
        let split = ParamRegistry.insertSections(of: fx?.params ?? [])
        XCTAssertTrue(split.flat.isEmpty)
        XCTAssertEqual(split.inserts.count, 4)
        XCTAssertEqual(split.inserts.map(\.point.keyPrefix),
                       ParamRegistry.fxPoints.map(\.keyPrefix))
        for section in split.inserts {
            XCTAssertEqual(section.params.count,
                           ParamRegistry.fxTemplate.count)
            for p in section.params {
                XCTAssertTrue(p.key.hasPrefix(section.point.keyPrefix))
            }
        }
        // an ordinary group is all flat rows
        let bow = ParamRegistry.groups.first { $0.name == "Bow stroke" }
        let plain = ParamRegistry.insertSections(of: bow?.params ?? [])
        XCTAssertTrue(plain.inserts.isEmpty)
        XCTAssertEqual(plain.flat.count, bow?.params.count)
    }

    /// The point of the refactor: the tab's TOP-LEVEL row count drops by
    /// the 60 knobs the inserts now hide, while `all` still answers every
    /// key (presets, tilt targets, `param.` audition routes).
    func testTheRackCostsFourDisplayRowsNotSixtyFour() {
        let rows = ParamRegistry.groups.reduce(0) { n, g in
            let s = ParamRegistry.insertSections(of: g.params)
            return n + s.flat.count + s.inserts.count
        }
        XCTAssertEqual(rows, ParamRegistry.all.count - 64 + 4)
        XCTAssertNotNil(ParamRegistry.spec("fx_voice_eq_b3"))
        XCTAssertNotNil(ParamRegistry.spec("fx_global_rev_cut"))
    }
}
