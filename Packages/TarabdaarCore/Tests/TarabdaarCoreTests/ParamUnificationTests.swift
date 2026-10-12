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
        for control in FretAssistControl.allCases {
            let spec = ParamRegistry.spec(control.key)!
            guard case .fretAssist(let routed) = spec.target else {
                XCTFail("\(control.key) does not reach the pad assist")
                continue
            }
            XCTAssertEqual(routed, control)
            XCTAssertEqual(spec.apply, .live)
            XCTAssertEqual(MapTarget.from(storageKey: MapTarget(paramKey: spec.key).storageKey)?.paramKey,
                           spec.key)
        }
    }

    /// DEFAULT = ENGINE TRUTH: for a key the artifact does not carry, the
    /// value that actually plays is the engine's code fallback, so the
    /// authored default must equal it or the Parameters tab lies.
    func testAuthoredDefaultsMatchEngineFallbacks() throws {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        // A neutral live knob is not re-pushed on publication: its mapper
        // must already sound the same onset that the registry advertises.
        let mapper = BowControlMapper()
        mapper.touchOn(1, pitchSemis: 64)
        var snapshot = BowControlMapper.PolySnapshot(count: 1)
        mapper.snapshotPoly(into: &snapshot)
        XCTAssertEqual(snapshot.slots[0].attackSharpness,
                       ParamRegistry.spec("bow_attack_sharpness")?.def)
        // Mirrors the fallbacks in BowControls.swift (init/updateLiveParams).
        let engineFallback: [String: Double] = [
            "bow_fit_body": 0,             // BowTables.buildOpenString
            "bow_jt_dual_pluck_level": 0.5, // BowEngine
            "bow_body_tail_seed": 1.0,      // BowTables.buildOpenString
        ]
        for (key, expect) in engineFallback where bp.num[key] == nil {
            let spec = try XCTUnwrap(ParamRegistry.spec(key), key)
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
        let perNoteKeys: Set<String> = [
            "bow_jt_dual_mm",
            "bow_jt_pluck",
            "bow_jt_pluck_decay_ms",
            "bow_jt_pulse",
            "bow_jt_pulse_attack_ms",
            "bow_jt_pulse_decay_ms",
            "bow_attack_sharpness",
            "bow_release_t60",
            "bow_grip_beta",
            "bow_grip_v_db",
            "bow_grip_db",
            "bow_grip_thresh",
            "bow_grip_release",
            "bow_grip_wait_ms",
            "bow_grip_confirm_ms",
            "bow_grip_ms",
            "bow_grip_rel_ms",
            "bow_grip_hold_ms",
            "bow_vib_cents",
            "bow_vib_hz",
            "ctl_strike_window",
            "ctl_fret_assist_amount",
            "ctl_fret_assist_radius",
            "ctl_fret_assist_still_px",
            "ctl_fret_assist_dwell_ms",
            "ctl_fret_assist_ramp_ms",
            "ctl_fret_assist_settle_ms",
            "ctl_fret_assist_slew",
            "ctl_fret_assist_turn",
            "ctl_fret_assist_turn_ms",
            "ctl_fret_assist_release_px",
            "ctl_glide_on",
            "ctl_glide_grace",
            "ctl_glide_rate",
            "ctl_glide_held",
            "ctl_glide_catchup",
            "ctl_glide_over",
            "bow_drift_cents",
            "bow_drift_hz",
            "bow_drift_db",
            "bow_drift_force_db",
            "bow_glide_dip_db",
            "bow_glide_dip_rate",
            "bow_slide_noise",
            "bow_slide_acc",
            "bow_slide_dull",
            "bow_slide_rate",
            "tp_rel_t60",
            "st_rel_t60",
        ]
        for (group, params) in ParamRegistry.groups {
            for p in params {
                let expected: ParamScope =
                    perNoteKeys.contains(p.key)
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
