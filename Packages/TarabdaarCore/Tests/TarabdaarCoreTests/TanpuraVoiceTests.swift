import XCTest
@testable import TarabdaarCore
import SarangiKit

/// Tanpura voice wiring guards (2026-08-04 port):
///  - the JI slot grid covers every scale degree across the drone/fret
///    ratio range (×0.25 … ×4 of the tonic) — so a mapped drone pitch and
///    every fret pitch always has a mounted slot;
///  - the `tp_*` registry group exists, is all-`.live`, and its defaults
///    match the wiring's resting values (the unified apply pushes every
///    live param at startup — a drifted default would silently retrim the
///    voice).
final class TanpuraVoiceTests: XCTestCase {

    func testSlotGridCoversScaleAndDroneRange() {
        let tonic = 220.0
        let ratios = [1.0, 9.0 / 8.0, 5.0 / 4.0, 4.0 / 3.0, 3.0 / 2.0,
                      5.0 / 3.0, 15.0 / 8.0]
        let freqs = TanpuraVoiceSource.slotFrequencies(tonicHz: tonic,
                                                      scaleRatios: ratios)
        XCTAssertEqual(freqs, freqs.sorted())
        XCTAssertEqual(freqs.count, Set(freqs).count, "duplicate slots")
        // bounds: the drone-ratio wire range (0.25 … 4.0 on the sync blob)
        XCTAssertGreaterThanOrEqual(freqs.first!, tonic * 0.25 - 1e-9)
        XCTAssertLessThanOrEqual(freqs.last!, tonic * 4.0 + 1e-9)
        // every degree in octaves −2…+1 is present exactly
        for o in -2...1 {
            for r in ratios {
                let f = r * pow(2.0, Double(o)) * tonic
                XCTAssertTrue(freqs.contains { abs($0 - f) < 1e-9 },
                              "missing slot for ratio \(r) octave \(o)")
            }
        }
        // the default drone targets (low Sa · low Pa · Sa) land on slots,
        // including through the document's millihertz quantization
        for dr in FretArrangement.defaultDroneRatios {
            let hz = (dr * tonic * 1000).rounded() / 1000
            let nearest = freqs.min { abs(log2($0 / hz)) < abs(log2($1 / hz)) }!
            XCTAssertLessThan(abs(log2(nearest / hz)) * 1200, 1.0,
                              "drone ratio \(dr) misses the grid")
        }
        // degenerate inputs stay safe
        XCTAssertTrue(TanpuraVoiceSource.slotFrequencies(tonicHz: 0,
                                                         scaleRatios: ratios).isEmpty)
        XCTAssertTrue(TanpuraVoiceSource.slotFrequencies(tonicHz: tonic,
                                                         scaleRatios: []).isEmpty)
    }

    func testTanpuraRegistryGroup() {
        let group = ParamRegistry.groups.first { $0.name == "Tanpura" }
        XCTAssertNotNil(group, "Tanpura group missing from ParamRegistry")
        let keys = Set(group!.params.map(\.key))
        XCTAssertEqual(keys, ["tp_gain", "tp_drone_level",
                              "tp_drone_cycle", "tp_pluck_level",
                              "tp_rel_t60",
                              "tp_shape_align", "tp_shape_focus",
                              "tp_shape_quiet", "tp_shape_spread"])
        for spec in group!.params {
            XCTAssertEqual(spec.apply, .live,
                           "\(spec.key): tanpura params all route .live — the tp_shape_* trio schedules its own debounced internal rebuild, never the String override-dict path")
        }
        // resting defaults the unified apply pushes at startup must match
        // the wiring's own initial values (AudioEngine) / the artifact trim
        XCTAssertEqual(ParamRegistry.spec("tp_gain")!.def, 0.02)
        XCTAssertEqual(ParamRegistry.spec("tp_drone_level")!.def, 1.0)
        XCTAssertEqual(ParamRegistry.spec("tp_drone_cycle")!.def, 2.5)
        XCTAssertEqual(ParamRegistry.spec("tp_pluck_level")!.def, 1.0)
        XCTAssertEqual(ParamRegistry.spec("tp_rel_t60")!.def, 0.4)
        // the shaping trio rests at 0 = the PHYSICAL tanpura (buildEngine
        // then skips the transform entirely, and the startup default push
        // must not schedule a seconds-long rebuild)
        XCTAssertEqual(ParamRegistry.spec("tp_shape_align")!.def, 0.0)
        XCTAssertEqual(ParamRegistry.spec("tp_shape_focus")!.def, 0.0)
        XCTAssertEqual(ParamRegistry.spec("tp_shape_quiet")!.def, 0.0)
        XCTAssertEqual(ParamRegistry.spec("tp_shape_spread")!.def, 0.0)
        // and tp_gain's default IS the artifact's fitted trim
        if let p = Presets.tanpuraParams() {
            XCTAssertEqual(p.gain, ParamRegistry.spec("tp_gain")!.def,
                           accuracy: 1e-12,
                           "tp_gain default drifted from tanpura_live.json `gain`")
        }
    }
}
