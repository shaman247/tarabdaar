import XCTest
import SarangiKit
@testable import TarabdaarCore

final class StringVoicePublicationTests: XCTestCase {
    /// Saved contact geometry settles before publication without an idle chime or bus-meter spike.
    func testCachedGeometryPublishesSilently() throws {
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        let overrides = ["bow_jt_threads": 0.0, "bow_jt_async": 0.0]
        for (evolution, register) in [(0.0, 0.0), (0.3, 0.4)] {
            let source = StringVoiceSource()
            source.setControl("bow_jtc_evolve", evolution)
            source.setControl("bow_jt_ev_reg", register)
            source.setBusMeter(true)
            let engine = try XCTUnwrap(source.buildEngine(tonicHz: 328.9,
                strings: strings, overrides: overrides))
            source.setEngine(engine, crossfadeMs: 0)
            var outputPeak = 0.0, busPeak = 0.0
            for _ in 0..<94 {
                let (l, r) = source.renderForTesting(frames: 256)
                for i in l.indices {
                    outputPeak = max(outputPeak, abs(Double(l[i])), abs(Double(r[i])),
                                     abs(Double(l[i]) + Double(r[i])))
                }
                let levels = source.busLevels()
                busPeak = max(busPeak, levels.voice, levels.chromatic, levels.raga)
            }
            XCTAssertLessThan(outputPeak, 1e-4, "Saved geometry produces an idle chime")
            XCTAssertLessThan(busPeak, 1e-4, "Saved geometry contaminates the bus maxima")
        }
    }

    /// Returning a geometry control to neutral during construction reaches the published render.
    func testPublicationRefreshesGeometryChangedDuringBuild() throws {
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        let overrides = ["bow_jt_threads": 0.0, "bow_jt_async": 0.0]
        let source = StringVoiceSource()
        source.setControl("bow_jtc_evolve", 0)
        source.setControl("bow_jt_ev_reg", 0.4)
        let candidate = try XCTUnwrap(source.buildEngine(tonicHz: 328.9,
            strings: strings, overrides: overrides))
        let reference = try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: 328.9,
            strings: strings, mapper: BowControlMapper(), overrides: overrides.merging([
                "bow_jtc_evolve": 0, "bow_jt_ev_reg": 0.4
            ]) { _, latest in latest }))
        source.setControl("bow_jtc_evolve", 0.5)
        source.setControl("bow_jt_ev_reg", 0)
        source.setEngine(candidate, crossfadeMs: 0)
        reference.setJtEvolveRegister(0)
        reference.setJtEvolveChromatic(0.5)
        var expectedL = [Double](repeating: 0, count: 256), expectedR = expectedL
        var expectedPeak = 0.0
        for _ in 0..<24 {
            let actual = source.renderForTesting(frames: 256)
            expectedL.withUnsafeMutableBufferPointer { l in
                expectedR.withUnsafeMutableBufferPointer { r in
                    reference.render(frames: 256, outL: l.baseAddress!, outR: r.baseAddress!)
                }
            }
            XCTAssertEqual(actual.l, expectedL.map(Float.init))
            XCTAssertEqual(actual.r, expectedR.map(Float.init))
            expectedPeak = max(expectedPeak, expectedL.map { abs($0) }.max() ?? 0)
        }
        XCTAssertGreaterThan(expectedPeak, 1e-4, "The reference must exercise a moving bridge")
    }

    /// Discarding initialization tables preserves the bank, settle path and deterministic rendered output.
    func testCompactBuildTablesPreserveRuntimeState() throws {
        let strings = Presets.state(.sarangiPilu).resolvedStrings
        let overrides = ["bow_jt_threads": 0.0, "bow_jt_async": 0.0]
        func build(retain: Bool) throws -> BowEngine {
            try XCTUnwrap(StringVoiceSource.buildEngine(tonicHz: 328.9, strings: strings,
                mapper: BowControlMapper(), overrides: overrides, retainJawariTables: retain))
        }
        let retained = try build(retain: true), compact = try build(retain: false)
        let jawari = try XCTUnwrap(retained.tables.jt)
        XCTAssertNil(compact.tables.jt)
        XCTAssertEqual(compact.jtRowFreqs, retained.jtRowFreqs)
        XCTAssertEqual(compact.jtDualRows, retained.jtDualRows)
        XCTAssertEqual(compact.bodyResponse(points: 64).radDb, retained.bodyResponse(points: 64).radDb)
        let retainedMetadata: Set<String> = ["rowFreqs", "rowChromatic", "rowApex"]
        let discardedBytes = Mirror(reflecting: jawari).children.reduce(0) { bytes, child in
            guard !retainedMetadata.contains(child.label ?? "") else { return bytes }
            if let values = child.value as? [Double] { return bytes + values.count * MemoryLayout<Double>.stride }
            if let values = child.value as? [Int32] { return bytes + values.count * MemoryLayout<Int32>.stride }
            if let values = child.value as? [Int] { return bytes + values.count * MemoryLayout<Int>.stride }
            if let values = child.value as? [Bool] { return bytes + values.count * MemoryLayout<Bool>.stride }
            return bytes
        }
        print("Discarded jawari array payload: \(discardedBytes) bytes for \(jawari.rowFreqs.count) rows (allocator overhead excluded)")
        func render(_ engine: BowEngine) -> [Double] {
            engine.mapper.touchOn(1, pitchSemis: 64)
            let frames = 4096
            var left = [Double](repeating: 0, count: frames), right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    engine.render(frames: frames, outL: l.baseAddress!, outR: r.baseAddress!)
                }
            }
            return left + right
        }
        let full = render(retained)
        XCTAssertTrue(full.contains { abs($0) > 1e-6 })
        XCTAssertEqual(render(compact), full)
    }

    /// Failed and superseded lower-polyphony builds preserve held notes until accepted publication.
    func testRejectedBuildsPreserveMapperAllocation() throws {
        let source = StringVoiceSource()
        let initial = try XCTUnwrap(StringVoiceSource.buildEngine(
            tonicHz: 261.63, strings: [], mapper: source.mapper,
            overrides: ["bow_live_poly": 4]))
        for id in UInt16(1)...UInt16(4) {
            source.mapper.touchOn(id, pitchSemis: 60 + Double(id))
        }
        func heldPitches() -> [Double] {
            var snapshot = BowControlMapper.PolySnapshot(count: 4)
            source.mapper.snapshotPoly(into: &snapshot)
            return snapshot.slots.filter { $0.gate > 0 }.map(\.f0Target)
        }
        let held = heldPitches()
        XCTAssertEqual(held.count, 4, "Direct builds must still configure mapper polyphony")
        source.setEngine(initial, crossfadeMs: 0)

        let builds = EngineBuildCoordinator<BowEngine>()
        var worker: [() -> Void] = [], publication: [() -> Void] = []
        func requestLowerPolyphony(fails: Bool = false) {
            builds.request(scheduleBuild: { worker.append($0) },
                schedulePublication: { publication.append($0) }, build: {
                    guard let candidate = StringVoiceSource.buildEngine(
                        tonicHz: 261.63, strings: [], mapper: source.mapper,
                        overrides: ["bow_live_poly": 1], configureMapper: false)
                    else { XCTFail("The bank-free fixture must build"); return .failed }
                    return fails ? .failed : .ready(candidate)
                }, publish: { source.setEngine($0, crossfadeMs: 0) }, failed: {})
        }

        requestLowerPolyphony(fails: true)
        worker.removeFirst()()
        publication.removeFirst()()
        XCTAssertTrue(source.currentEngine() === initial)
        XCTAssertEqual(heldPitches(), held)

        requestLowerPolyphony()
        worker.removeFirst()()
        requestLowerPolyphony()
        publication.removeFirst()()
        XCTAssertTrue(source.currentEngine() === initial)
        XCTAssertEqual(heldPitches(), held)

        worker.removeFirst()()
        XCTAssertEqual(heldPitches(), held, "Construction must not alter the running mapper")
        publication.removeFirst()()
        XCTAssertEqual(source.currentEngine()?.maxPoly, 1)
        XCTAssertEqual(heldPitches(), Array(held.prefix(1)))
    }
}
