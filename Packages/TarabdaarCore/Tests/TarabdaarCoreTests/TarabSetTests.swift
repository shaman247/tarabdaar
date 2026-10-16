import XCTest
import SarangiKit
@testable import TarabdaarCore

/// Bank persistence, independent radiation, physical routing and registry defaults.
final class TarabSetTests: XCTestCase {

    private func bp() throws -> BowParams {
        guard let bp = Presets.bowedStringParams() else {
            throw XCTSkip("bowed_string.json not available in this bundle")
        }
        return bp
    }

    /// Old banks migrate once without losing custom scale pitches or mapped identities.
    func testBankMigrationPreservesTuningAndMappings() throws {
        let scale = [1.0, 1.123, 1.25, 4.0/3, 1.5, 5.0/3]
        let custom = StringSpec(degree: 1, octave: -1, gain: 0.8, t60: 6)
        let sa = StringSpec(degree: 0, gain: 0.9, t60: 7)
        let duplicate = StringSpec(degree: 0, gain: 0.6, t60: 3, set: .chromatic)
        let old = InstrumentState(tonicHz: 330, scaleRatios: scale,
            strings: [custom, sa, duplicate],
            droneStringIds: [custom.id, duplicate.id, sa.id],
            strumStringIds: [custom.id, duplicate.id], schemaVersion: 4)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["strings"] = (object["strings"] as! [[String: Any]]).map { row in
            var legacy = row; legacy.removeValue(forKey: "followsScale"); return legacy
        }
        let moved = try JSONDecoder().decode(InstrumentState.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(moved.strings(in: .raga).count, 12)
        XCTAssertTrue(moved.strings(in: .raga).allSatisfy(\.followsScale))
        XCTAssertEqual(moved.strings(in: .chromatic).map(\.id), [custom.id, sa.id])
        XCTAssertEqual(moved.droneStringIds, [custom.id, sa.id, sa.id])
        XCTAssertEqual(moved.strumStringIds, [custom.id, sa.id])
        XCTAssertEqual(moved.droneStringFreqs, old.droneStringFreqs)
        XCTAssertEqual(moved.droneStringChromatic, [true, true, true])
        XCTAssertEqual(moved.strings.first { $0.id == custom.id }?.t60, custom.t60)
        let back = try JSONDecoder().decode(InstrumentState.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(back.strings, moved.strings, "reopening must not seed another raga bank")
        XCTAssertEqual(back.droneStringIds, moved.droneStringIds)
    }

    /// Default raga rows use the physical solver and equal-pitch drone targets retain bank identity.
    func testDefaultRagaBankAndDroneIdentity() throws {
        let state = Presets.state(.sarangiPilu)
        XCTAssertEqual(state.strings(in: .raga).map { $0.ratio(in: state.scaleRatios) },
            [0.5, 0.75] + state.scaleRatios + [2])
        let source = StringVoiceSource()
        let engine = try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: state.tonicHz,
            strings: state.resolvedStrings, mapper: source.mapper,
            overrides: ["bow_jt_dual_row": 31])) // retired preset selector cannot override bank ownership
        XCTAssertEqual(engine.jtDualRows.count, 12)
        for string in state.strings(in: .raga) {
            let hz = string.resolved(tonic: state.tonicHz, scaleRatios: state.scaleRatios).freq
            let row = try XCTUnwrap(engine.droneRow(forExactHz: hz, chromatic: false))
            XCTAssertTrue(engine.jtDualRows.contains(row))
            let legacy = try XCTUnwrap(engine.droneRow(forExactHz: hz, chromatic: true))
            XCTAssertNotEqual(row, legacy)
            XCTAssertFalse(engine.jtDualRows.contains(legacy))
        }
    }

    /// Factory expansion preserves existing identities and mappings while custom layouts round-trip unchanged.
    func testFactoryExpansionPreservesCustomizations() throws {
        let scale = Presets.state(.sarangiPilu).scaleRatios
        var rows = [0, 3, 4, 6, 0].enumerated().map { i, degree in
            StringSpec(degree: degree, octave: i == 4 ? 1 : 0, gain: 0.85, t60: 4)
        }
        rows[1].gain = 0.4; rows[1].enabled = false
        let old = InstrumentState(tonicHz: 328.9, scaleRatios: scale, strings: rows,
            droneStringIds: [rows[0].id, rows[1].id, nil], strumStringIds: [rows[4].id], schemaVersion: 5)
        let expanded = try JSONDecoder().decode(InstrumentState.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(expanded.strings(in: .raga).count, 12)
        for row in rows { XCTAssertEqual(expanded.strings.first { $0.id == row.id }, row) }
        XCTAssertEqual(expanded.droneStringIds, old.droneStringIds)
        XCTAssertEqual(expanded.strumStringIds, old.strumStringIds)
        let reopened = try JSONDecoder().decode(InstrumentState.self, from: JSONEncoder().encode(expanded))
        XCTAssertEqual(reopened.strings, expanded.strings)
        var custom = old
        custom.strings[1].degree = 1
        let kept = try JSONDecoder().decode(InstrumentState.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(Set(kept.strings.map(\.id)), Set(custom.strings.map(\.id)))
        XCTAssertEqual(kept.strings.count, custom.strings.count)
    }

    /// Pitch-class toggles preserve row settings and mappings across octaves, bridges and presets.
    func testFretRagaTogglePreservesIdentity() throws {
        let raga = StringSpec(degree: 0, gain: 0.25, t60: 7)
        let upper = StringSpec(degree: 0, octave: 1, gain: 0.6, t60: 5)
        let chromatic = StringSpec(degree: 0, gain: 0.8, t60: 3, set: .chromatic)
        var state = InstrumentState(tonicHz: 220, scaleRatios: [1, 1.5],
            strings: [raga, upper, chromatic], droneStringIds: [raga.id, nil, nil], strumStringIds: [raga.id])
        state.toggleRagaString(degree: 0, octave: -1)
        XCTAssertEqual(state.enabledRagaRatios, [])
        XCTAssertEqual(state.strings(in: .chromatic), [chromatic])
        XCTAssertEqual(state.droneStringIds[0], raga.id)
        XCTAssertEqual(state.strumStringIds, [raga.id])
        state = try JSONDecoder().decode(InstrumentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.enabledRagaRatios, [])
        state.toggleRagaString(degree: 0, octave: 2)
        XCTAssertEqual(state.strings.first { $0.id == raga.id }, raga)
        XCTAssertEqual(state.strings.first { $0.id == upper.id }, upper)
        XCTAssertEqual(state.enabledRagaRatios, [1, 2])
        state.strings[state.strings.firstIndex { $0.id == upper.id }!].enabled = false
        state.toggleRagaString(degree: 0, octave: 1)
        XCTAssertEqual(state.enabledRagaRatios, [], "one enabled octave makes the whole pitch class on")
        state.toggleRagaString(degree: 1, octave: -1)
        let added = try XCTUnwrap(state.strings.first { $0.set == .raga && $0.degree == 1 })
        XCTAssertEqual(added.octave, -1)
        state.toggleRagaString(degree: 1, octave: 1)
        state.toggleRagaString(degree: 1, octave: 0)
        XCTAssertEqual(state.strings.first { $0.id == added.id }, added)
        XCTAssertEqual(state.enabledRagaRatios, [0.75])
        XCTAssertEqual(state.strings.count, 4, "clicking octave copies must not create extra strings")
    }

    // MARK: - Model

    // MARK: - Row plan + tables

    /// Chromatic approximation and mix controls preserve raga tables and bank isolation.
    func testChromaticKnobsBakeOnlyChromaticRows() throws {
        var bp = try bp()
        let srk = 96000.0
        let rows: [(f: Double, gain: Double, t60: Double)] = [
            (f: 220.0, gain: 0.9, t60: 4.0), (f: 330.0, gain: 0.6, t60: 3.0),
            (f: 440.0, gain: 0.6, t60: 3.0),
        ]
        let flags = [false, true, true]
        let base = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp, chromatic: flags))
        XCTAssertTrue(base.hasChromatic)
        XCTAssertEqual(base.rowChromatic, flags)
        // The callback approximation leaves raga rows on their existing tables.
        let allRaga = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp))
        XCTAssertFalse(allRaga.hasChromatic)
        let ragaModes = Int(base.M[0]), contacts = Int(base.J)
        XCTAssertEqual(base.b.prefix(contacts), allRaga.b.prefix(contacts))
        XCTAssertEqual(base.rowForceScale[0], allRaga.rowForceScale[0])
        XCTAssertEqual(base.phiD.prefix(ragaModes), allRaga.phiD.prefix(ragaModes))
        XCTAssertEqual(base.ca.prefix(ragaModes), allRaga.ca.prefix(ragaModes))
        XCTAssertEqual(base.phiU.prefix(ragaModes * contacts), allRaga.phiU.prefix(ragaModes * contacts))
        XCTAssertEqual(base.q0.prefix(ragaModes), allRaga.q0.prefix(ragaModes))
        XCTAssertEqual(base.rowApex, [Double](repeating: bp.v("bow_jt_apex", 1e-5), count: 3))

        bp.num["bow_jtc_gain"] = 0.6
        bp.num["bow_jtc_norm"] = 0.8
        let moved = try XCTUnwrap(BowTables.buildJawariTables(
            rows: rows, srk: srk, bp: bp, chromatic: flags))
        // Neither bank's mix controls alter its contact geometry.
        XCTAssertEqual(moved.b, base.b)
        // raga row 0: untouched
        XCTAssertEqual(moved.rowForceScale[0], base.rowForceScale[0])
        // Chromatic normalization changes radiation scales; level is a separate multiplier.
        for r in 1...2 {
            XCTAssertNotEqual(moved.rowForceScale[r], base.rowForceScale[r])
            XCTAssertNotEqual(moved.rowOutputLevel[r], base.rowOutputLevel[r])
        }
        XCTAssertEqual(moved.rowOutputLevel[0], base.rowOutputLevel[0])
        XCTAssertEqual(moved.rowApex,
                       [Double](repeating: bp.v("bow_jt_apex", 1e-5), count: 3))
        XCTAssertEqual(moved.rowAlpha, base.rowAlpha)
        // The common output carrier is constant while either bank level moves.
        XCTAssertEqual(moved.phys, base.phys)
    }

    /// Either bank can be muted without changing the other bank's radiation or drive.
    func testIndependentBankLevels() throws {
        let base = try bp()
        let rows: [(f: Double, gain: Double, t60: Double)] = [(330, 0.9, 4), (561, 0.8, 3)]
        func tables(_ raga: Double, _ chromatic: Double) throws -> JtTables {
            var params = base
            params.num["bow_jt_gain"] = raga
            params.num["bow_jtc_gain"] = chromatic
            return try XCTUnwrap(BowTables.buildJawariTables(rows: rows, srk: 96000,
                bp: params, chromatic: [false, true]))
        }
        let reference = try tables(0.3, 0.3)
        for bank in 0..<2 {
            for level in [0.0, 0.0001, 0.15, 0.6, 3.0] {
                let t = try bank == 0 ? tables(level, 0.3) : tables(0.3, level)
                let other = 1 - bank
                XCTAssertEqual(t.phys, reference.phys, "a shared gain ramp would pump both banks")
                XCTAssertEqual(t.rowOutputGain[other], reference.rowOutputGain[other])
                XCTAssertEqual(t.rowForceScale[other], reference.rowForceScale[other])
                XCTAssertEqual(t.rowPinScale[other], reference.rowPinScale[other])
                XCTAssertEqual(t.phiD, reference.phiD, "a level edit must preserve excitation")
                XCTAssertEqual(t.rowCouplingNorm, reference.rowCouplingNorm,
                               "quiet output levels must not amplify physical feedback")
                if level > 0 {
                    XCTAssertEqual(t.rowForceScale[bank] * t.rowCplScale[bank],
                                   reference.rowForceScale[bank] * reference.rowCplScale[bank],
                                   accuracy: 1e-12)
                }
                XCTAssertEqual(t.rowOutputGain, reference.rowOutputGain)
                XCTAssertEqual(t.rowCplScale, reference.rowCplScale)
                XCTAssertEqual(t.rowOutputLevel[bank], level / 0.3, accuracy: 1e-12)
                XCTAssertEqual(t.rowOutputLevel[other], 1)
            }
        }
        let muted = try tables(0, 0)
        XCTAssertEqual(muted.rowOutputLevel, [0, 0])
        XCTAssertEqual(muted.rowOutputGain, reference.rowOutputGain)
        XCTAssertEqual(muted.rowCplScale, reference.rowCplScale)
        XCTAssertTrue(muted.phys.allSatisfy(\.isFinite))
    }

    /// Both physical backends retain a ringing row through an in-place mute of the other bank.
    func testBankMutePreservesOtherBankRender() throws {
        let strings = [ResolvedString(freq: 561, gain: 0.9, t60: 4),
                       ResolvedString(freq: 440, gain: 0.9, t60: 4, chromatic: true)]
        func render(chromatic: Bool, muteOther: Bool, muteOwn: Bool = false) throws -> [Float] {
            let source = StringVoiceSource()
            var overrides = ["bow_jt_async": 0.0, "bow_jt_threads": 0.0,
                             "bow_jt_couple": 0.0, "bow_jt_pluck": 0.03, "bow_rev_mix": 0.0]
            let engine = try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: 328.9,
                strings: strings, mapper: source.mapper, overrides: overrides))
            source.setEngine(engine, crossfadeMs: 0)
            let row = try XCTUnwrap(engine.droneRow(forExactHz: chromatic ? 440 : 561,
                                                  chromatic: chromatic))
            engine.pluckTaraf(row: row)
            var output = [Float]()
            for block in 0..<12 {
                if block == 3 && (muteOther || muteOwn) {
                    let muteChromatic = muteOwn ? chromatic : !chromatic
                    overrides[muteChromatic ? "bow_jtc_gain" : "bow_jt_gain"] = 0
                    XCTAssertTrue(source.applyLiveParams(tonicHz: 328.9, strings: strings,
                                                        overrides: overrides))
                }
                let (left, _) = source.renderForTesting(frames: 2048)
                output.append(contentsOf: left)
            }
            return output
        }
        for chromatic in [false, true] {
            let reference = try render(chromatic: chromatic, muteOther: false)
            let muted = try render(chromatic: chromatic, muteOther: true)
            XCTAssertGreaterThan(reference.map { abs($0) }.max() ?? 0, 1e-7)
            XCTAssertTrue(muted.allSatisfy(\.isFinite))
            let difference = zip(muted, reference).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertEqual(difference, 0, "muting the other bank changed an uncoupled ring")
            let ownMuted = try render(chromatic: chromatic, muteOther: false, muteOwn: true)
            let referenceTail = reference.suffix(2048).map { abs($0) }.max() ?? 0
            let mutedTail = ownMuted.suffix(2048).map { abs($0) }.max() ?? .infinity
            XCTAssertLessThan(mutedTail, referenceTail * 0.01, "the bank's own level failed to mute")
        }
    }

    /// Bank output levels cannot alter the voice through an enabled physical feedback loop.
    func testBankLevelsLeaveCoupledMotionUnchanged() throws {
        let strings = [ResolvedString(freq: 328.9, gain: 0.9, t60: 4),
                       ResolvedString(freq: 440, gain: 0.9, t60: 4, chromatic: true)]
        func render(mute: Bool) throws -> (audio: [Float], modes: [Float]) {
            let source = StringVoiceSource()
            var overrides = ["bow_jt_async": 0.0, "bow_jt_threads": 0.0, "bow_rev_mix": 0.0]
            let engine = try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: 328.9,
                strings: strings, mapper: source.mapper, overrides: overrides))
            source.setEngine(engine, crossfadeMs: 0)
            engine.setScopeArmed(true)
            XCTAssertTrue(source.setControl("bow_bal", -1))
            XCTAssertTrue(source.setControl("bow_jt_couple", 1))
            source.mapper.setAxis(expr: 0.35)
            source.mapper.touchOn(1, pitchSemis: 64)
            var output = [Float]()
            for block in 0..<24 {
                if block == 12 && mute {
                    overrides["bow_jt_gain"] = 0
                    overrides["bow_jtc_gain"] = 0
                    XCTAssertTrue(source.applyLiveParams(tonicHz: 328.9, strings: strings,
                                                        overrides: overrides))
                }
                let (left, _) = source.renderForTesting(frames: 2048)
                if block >= 12 { output.append(contentsOf: left) }
            }
            return (output, engine.scopeRows().flatMap(\.modes))
        }
        let reference = try render(mute: false), muted = try render(mute: true)
        XCTAssertGreaterThan(reference.audio.map { abs($0) }.max() ?? 0, 1e-7)
        let difference = zip(muted.audio, reference.audio).map { abs($0 - $1) }.max() ?? .infinity
        // The balance smoother approaches voice-only asymptotically.
        XCTAssertLessThan(difference, 1e-8)
        XCTAssertFalse(reference.modes.isEmpty)
        XCTAssertEqual(muted.modes, reference.modes, "bank levels changed coupled string motion")
    }

    // MARK: - Registry

    /// Chromatic table defaults match the engine, with matching bank level ranges and timing.
    func testChromaticBridgeDefaultsAreTheEngineTruth() throws {
        let bp = try bp()
        let specs = ParamRegistry.all.filter {
            $0.key.hasPrefix("bow_jtc_") && !$0.key.hasPrefix("bow_jtc_comp_")
        }
        XCTAssertEqual(Set(specs.map(\.key)),
                       Set(BowTables.chromaticBridgeDefaults.keys))
        for s in specs {
            XCTAssertNil(bp.num[s.key], "\(s.key) grew an artifact value — re-derive the contract")
            XCTAssertEqual(s.def, BowTables.chromaticBridgeDefaults[s.key]!, accuracy: 1e-15,
                           "\(s.key): registry default is not what the builder plays")
            let twin = "bow_jt_" + s.key.dropFirst("bow_jtc_".count)
            if s.key != "bow_jtc_evolve" {
                let twinSpec = try XCTUnwrap(ParamRegistry.spec(twin))
                XCTAssertEqual(s.lo, twinSpec.lo); XCTAssertEqual(s.hi, twinSpec.hi)
                XCTAssertEqual(s.apply, twinSpec.apply)
            }
            XCTAssertEqual(s.group, "Taraf · Chromatic")
            if s.apply != .live {
                XCTAssertTrue(ParamRegistry.inPlaceKeys.contains(s.key), "\(s.key) must land in place")
            }
            // the raga bridge's shipped value: artifact, else the builder fallback
            let shipped = bp.num[twin] ?? BowTables.chromaticBridgeDefaults[s.key]!
            XCTAssertEqual(s.def, shipped, accuracy: 1e-15,
                           "\(s.key) does not rest at the raga bridge's shipped \(twin)")
        }
        XCTAssertEqual(ParamRegistry.spec("bow_jtc_evolve")?.apply, .live)
    }
}
