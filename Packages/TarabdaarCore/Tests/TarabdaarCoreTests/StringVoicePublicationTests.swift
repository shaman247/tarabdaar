import XCTest
import SarangiKit
@testable import TarabdaarCore

final class StringVoicePublicationTests: XCTestCase {
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
        XCTAssertEqual(compact.jtFollowerRow, retained.jtFollowerRow)
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
