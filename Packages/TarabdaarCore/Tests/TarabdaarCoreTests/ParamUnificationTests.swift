import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The one registry: integrity of the flat spec list, authored defaults that
/// equal the engine fallbacks, the scope audit, and tilt-target round-trip.
final class ParamUnificationTests: XCTestCase {

    // MARK: - Registry integrity

    /// Keys are unique, ranges contain their default, `storedKeys` is exactly
    /// the non-rebuild set, and `inPlaceKeys` carries no `.live` key (which
    /// would be meaningless and would garble the timing story the docs tell).
    func testRegistryIntegrity() {
        var seen = Set<String>()
        for p in ParamRegistry.all {
            XCTAssertTrue(seen.insert(p.key).inserted,
                          "duplicate parameter key \(p.key)")
            XCTAssertTrue(p.def >= p.lo && p.def <= p.hi,
                          "\(p.key) default \(p.def) outside \(p.lo)…\(p.hi)")
        }
        XCTAssertEqual(Set(ParamRegistry.storedKeys.map(\.key)),
                       Set(ParamRegistry.all.filter { $0.apply != .rebuild }
                            .map(\.key)))
        for key in ParamRegistry.inPlaceKeys {
            XCTAssertNotEqual(ParamRegistry.spec(key)?.apply, .live,
                              "\(key) is .live — it does not belong in "
                              + "inPlaceKeys")
        }
    }

    /// DEFAULT = ENGINE TRUTH: for a key the artifact does not carry, the
    /// value that actually plays is the engine's code fallback, so the
    /// authored default must equal it or the Parameters tab lies.
    func testAuthoredDefaultsMatchEngineFallbacks() throws {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // Mirrors the fallbacks in BowControls.swift (init/updateLiveParams).
        let engineFallback: [String: Double] = [
            "bow_draw_min_ms": bp.num["bow_draw_ms"] ?? 1.0, // follows the draw
            "bow_attack_bite": 0.0,
            "bow_attack_bite_ms": 60.0,
            "bow_attack_thresh": 0.5,
            "bow_attack_fms": 15.0,
            "bow_attack_vel": 0.0,
            "bow_settle_sharp": 0.0,
            "bow_body_tail_seed": 1.0,      // BowTables.buildOpenString
        ]
        for (key, expect) in engineFallback {
            let spec = try XCTUnwrap(ParamRegistry.spec(key), key)
            XCTAssertNil(bp.num[key],
                         "\(key) grew an artifact value — this pin covers "
                         + "artifact-absent keys only; re-derive the def")
            XCTAssertEqual(spec.def, expect, accuracy: 1e-12,
                           "\(key): authored default \(spec.def) is not what "
                           + "the engine plays (\(expect)) — the Parameters "
                           + "tab would lie about the sound")
        }
    }

    /// THE SCOPE AUDIT: per-note = a mechanism with per-note control state
    /// (onset clocks, envelopes, phases, blend windows); everything else is
    /// a shared mechanism. A new parameter must be classified deliberately.
    func testScopeClassificationMatchesTheMechanisms() {
        let perNoteGroups: Set<String> = [
            "Articulation", "Liveness", "Strike blend", "Glide",
        ]
        let perNoteExtras: Set<String> = ["tp_rel_t60", "st_rel_t60"]
        for (group, params) in ParamRegistry.groups {
            for p in params {
                let expected: ParamScope =
                    perNoteGroups.contains(group) || perNoteExtras.contains(p.key)
                    ? .perNote : .global
                XCTAssertEqual(p.scope, expected,
                               "\(p.key) in \(group): scope \(p.scope) — "
                               + "classify deliberately (see ParamScope)")
            }
        }
    }

    /// A parameter tilt target round-trips through its storage key; an
    /// unknown or malformed key resolves to nothing rather than a dead target.
    func testParameterTargetsRoundTripAndRejectUnknownKeys() {
        let t = MapTarget(paramKey: "bow_vib_cents")
        XCTAssertEqual(MapTarget.from(storageKey: t.storageKey)?.paramKey,
                       "bow_vib_cents")
        XCTAssertNil(MapTarget.from(storageKey: "param:bow_jaw_gain"))
        XCTAssertNil(MapTarget.from(storageKey: "nonsense"))
    }
}
