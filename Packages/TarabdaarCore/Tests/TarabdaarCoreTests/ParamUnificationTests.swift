import XCTest
import SarangiKit
@testable import TarabdaarCore

/// The one registry: unique keys, defaults equal engine fallbacks, scope classification, in-place keys, stored keys, ranges contain defaults, targets round-trip.
final class ParamUnificationTests: XCTestCase {

    // MARK: - Registry integrity

    func testKeysAreUnique() {
        var seen = Set<String>()
        for p in ParamRegistry.all {
            XCTAssertTrue(seen.insert(p.key).inserted,
                          "duplicate parameter key \(p.key)")
        }
    }

    func testStoredKeysAreExactlyTheNonRebuildParameters() {
        XCTAssertEqual(Set(ParamRegistry.storedKeys.map(\.key)),
                       Set(ParamRegistry.all.filter { $0.apply != .rebuild }
                            .map(\.key)))
    }

    /// DEFAULT = ENGINE TRUTH (2026-08-19). A `.rebuild` parameter's
    /// authored default is what the Parameters tab DISPLAYS for an
    /// untouched row, but the engine runs artifact + overrides only — for
    /// a key the artifact does not carry, the value that actually plays is
    /// the ENGINE code fallback (`bp.v(key, fallback)` in
    /// `BowControlFilter` / the table builders). The two drifted apart
    /// once (bite showed 2.0 while the engine ran 0; sharp-draw showed the
    /// offline fit's 8 ms while the engine followed the 60 ms draw): the
    /// tab lied about the sound. This pins def == engine fallback for the
    /// artifact-absent articulation/liveness keys — change one side, keep
    /// the other in step (or ship the key in the artifact).
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

    /// THE SCOPE AUDIT (2026-08-23): per-note = the parameter drives a
    /// mechanism with PER-NOTE control state (onset clocks, envelopes,
    /// phases, walks, blend windows) — exactly the note-scoped groups
    /// plus the plucked voices' per-note releases. Everything else is a
    /// shared mechanism = global. Pinned here so a new parameter must be
    /// classified deliberately (a mis-defaulted `.global` on a per-note
    /// group fails loudly).
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

    /// `inPlaceKeys` covers build scalars that can land on the running
    /// kernel — `.rebuild` keys, plus `.hybrid` ones whose above-headroom
    /// push is still an in-place constant (`bow_vib_cents`). A `.live`
    /// key in the list would be meaningless (live already applies
    /// instantly) and would garble the timing story the docs tell.
    func testInPlaceKeysCarryNoLiveStrategy() {
        for key in ParamRegistry.inPlaceKeys {
            XCTAssertNotEqual(ParamRegistry.spec(key)?.apply, .live,
                              "\(key) is .live — it does not belong in "
                              + "inPlaceKeys")
        }
    }

    func testRangesContainTheAuthoredDefault() {
        for p in ParamRegistry.all {
            XCTAssertTrue(p.def >= p.lo && p.def <= p.hi,
                          "\(p.key) default \(p.def) outside \(p.lo)…\(p.hi)")
        }
    }

    // MARK: - Composites

    // MARK: - Tilt targets

    func testParameterTargetsRoundTripAndRejectUnknownKeys() {
        let t = MapTarget(paramKey: "bow_vib_cents")
        XCTAssertEqual(MapTarget.from(storageKey: t.storageKey)?.paramKey,
                       "bow_vib_cents")
        XCTAssertNil(MapTarget.from(storageKey: "param:bow_jaw_gain"))
        XCTAssertNil(MapTarget.from(storageKey: "nonsense"))
    }

    // MARK: - Binding defaults + migration

}
