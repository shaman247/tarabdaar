import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Fret warp preserves horizontal continuity, live touch identity and layout compatibility.
final class FretWarpTests: XCTestCase {

    /// Boundary blends preserve union anchors and continuity of warped, snapped and corrected touches.
    func testRegionBoundariesStayContinuousThroughTheTouchPipeline() throws {
        let degrees = scaleDegrees(from: PitchScale.defaultJI)
        var arrangement = FretArrangement.defaultArrangement(degrees: degrees)
        for degree in [0, 2, 5, 7] { arrangement.toggle(degreeIndex: degree, row: .lower) }
        for degree in [1, 6] { arrangement.toggle(degreeIndex: degree, row: .upper) }
        let size = CGSize(width: 1000, height: 420)
        let frets = fretPlacements(arrangement: arrangement, degrees: degrees, size: size)
        let n = try XCTUnwrap(frets.first { !$0.isGhost && $0.degreeIndex == 11 && $0.row == .bottom })
        let x = n.x - 3
        let epsilon = 1e-5
        for snap in [0.0, 60.0] {
            for lower in FretRegion.allCases.dropLast() {
                let boundary = lower.topY * size.height
                let halfWidth = FretRegion.transitionHalfWidth * size.height
                func onset(_ y: Double) throws -> (pitch: Double, logs: [FretRegion: Double]) {
                    let result = try XCTUnwrap(fretOnset(at: CGPoint(x: x, y: y),
                        placements: frets, snapDistance: snap, warp: 0.8))
                    return (result.pitch, result.logs)
                }
                let start = try onset(boundary + halfWidth)
                let end = try onset(boundary - halfWidth)
                let middle = try onset(boundary)
                XCTAssertEqual(middle.pitch, (start.pitch + end.pitch) / 2, accuracy: 1e-12)
                for y in [boundary - halfWidth, boundary, boundary + halfWidth] {
                    XCTAssertEqual(try onset(y - epsilon).pitch, try onset(y + epsilon).pitch,
                                   accuracy: 1e-5, "warp and onset offsets must both blend")
                }
                let assist = FretDragAssist()
                assist.setContext(placements: frets, snapDistance: 60)
                assist.begin(touchId: 1, x: x, y: boundary + epsilon,
                    uncorrectedLog: try onset(boundary + epsilon).pitch, time: 0, regionLogs: middle.logs)
                var before: FretDragAssist.Output?
                for tick in 1...180 { before = assist.tick(time: Double(tick) / 60).first?.output }
                let after = assist.move(touchId: 1, x: x, y: boundary - epsilon,
                    uncorrectedLog: try onset(boundary - epsilon).pitch, time: 3.01, regionLogs: middle.logs)
                XCTAssertEqual(try XCTUnwrap(before).log2Pitch, after.log2Pitch, accuracy: 1e-5,
                               "settled per-region corrections must blend when a held touch crosses")
                let back = assist.move(touchId: 1, x: x, y: boundary + epsilon,
                    uncorrectedLog: try onset(boundary + epsilon).pitch, time: 3.02, regionLogs: middle.logs)
                XCTAssertEqual(after.log2Pitch, back.log2Pitch, accuracy: 1e-5)
            }
        }
    }

    /// Warp retunes every held endpoint and preserves onset identity, offsets and octave through later ticks.
    func testHeldTouchesFollowWarpWithoutMovingOrRetriggering() throws {
        let state = OutboundPlayState()
        let engine = PitchPadEngine(state: state)
        engine.fretAssistSettings[.amount] = 0
        engine.octaveShift = 1
        let recorder = FretGestureRecorder()
        let player = FretTouchPlayer()
        player.engine = engine
        player.recorder = recorder
        let frets = [
            FretPlacement(id: "left", segmentID: UUID(), isGhost: false,
                          ratio: 1, name: "", x: 0, topY: 0, bottomY: 100),
            FretPlacement(id: "right", segmentID: UUID(), isGhost: false,
                          ratio: 2, name: "", x: 100, topY: 0, bottomY: 100)
        ]
        var context = FretTouchPlayer.Context(placements: frets,
            size: CGSize(width: 100, height: 100), snapDistance: 10,
            ghostExtentOctaves: 0, warp: 0)
        let points = [CGPoint(x: 25, y: 50), CGPoint(x: 75, y: 50)]
        // One snapped onset, one free onset; both glide to unsnapped endpoints.
        for (id, x) in [5.0, 50.0].enumerated() {
            XCTAssertTrue(player.begin(touchId: id, at: CGPoint(x: x, y: 50),
                                       context: context, radiusPt: 40, time: 0))
            XCTAssertNotNil(player.move(touchId: id, at: points[id], context: context, time: 0.1))
        }
        defer { for id in 0..<2 { player.end(touchId: id, time: 2) } }
        let before = try XCTUnwrap(state.snapshotFrame(timestampUs: 0)).touches
        engine.octaveShift = -1
        for (n, warp) in [0.5, 1.0, 0.0].enumerated() {
            context.warp = warp
            let time = 0.2 + Double(n) * 0.1
            player.updateWarp(context: context, time: time)
            let updated = try XCTUnwrap(state.snapshotFrame(timestampUs: 0)).touches
            XCTAssertEqual(updated.count, before.count)
            for id in 0..<2 {
                let field = try XCTUnwrap(fretFieldLog(at: points[id], placements: frets, warp: warp))
                let delta = 12 * (field - Double(points[id].x) / 100)
                XCTAssertEqual(Double(updated[id].pitch), Double(before[id].pitch) + delta, accuracy: 1e-5)
                XCTAssertEqual(updated[id].id, before[id].id)
                XCTAssertEqual(updated[id].onsetSeq, before[id].onsetSeq)
                XCTAssertEqual(updated[id].radius, before[id].radius)
                XCTAssertEqual(updated[id].fretPosition, before[id].fretPosition)
            }
            player.tick(time: time + 0.01)
            XCTAssertNil(state.snapshotFrame(timestampUs: 0), "settling must not restore the old field pitch")
        }
        player.end(touchId: 0, time: 0.6)
        _ = state.snapshotFrame(timestampUs: 0)
        context.warp = 1
        player.updateWarp(context: context, time: 0.7)
        let remaining = try XCTUnwrap(state.snapshotFrame(timestampUs: 0)).touches
        XCTAssertEqual(remaining.map(\.id), [before[1].id], "warp must not revive released touches")
    }

    /// The byte-null end of the knob: amount 0 leaves every position alone.
    func testWarpZeroIsIdentity() {
        for t in stride(from: -0.5, through: 1.5, by: 0.1) {
            XCTAssertEqual(fretWarp(t, amount: 0), t, accuracy: 1e-12)
        }
    }

    /// The arrangement sync carries only pitch/row pairs and migrates cached legacy formats.
    func testArrangementBlobIsWarpFree() {
        let a = FretArrangement(
            segments: [FretSegment(degreeIndex: 2, row: .middle)],
            ghostExtentOctaves: 0.75)
        let blob = FretArrangementSysEx.encodeBlob(a)
        XCTAssertEqual(blob[0], 3, "the first byte is the ghost extent in quarter octaves")
        XCTAssertEqual(blob.count,
                       3 + 2 * a.segments.count
                         + 2 * FretArrangement.droneCount,
                       "no version byte, no trailing warp byte")
        let decoded = FretArrangementSysEx.decodeBlob(blob)!
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments[0].row, .middle)
        for end in 0..<blob.count {
            XCTAssertNil(FretArrangementSysEx.decodeBlob(Array(blob.prefix(end))))
        }
        XCTAssertEqual(decoded.ghostExtentOctaves, 0.75)
        var invalidRow = blob
        invalidRow[4] = 0
        XCTAssertNil(FretArrangementSysEx.decodeBlob(invalidRow))
        let oldPair: [UInt8] = [3, 3, 1, 2, 0, 32, 31, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(FretArrangementSysEx.decodeBlob(oldPair)?.segments.first?.row, .top)
    }
    /// Cached three-row masks do not become assignments in the new intermediate rows.
    func testLegacyRowBlobMigration() throws {
        let old: [UInt8] = [3, 5, 3, 0, 1, 31, 1, 2, 0, 2, 3, 31, 0, 0, 0, 0, 0, 0]
        let decoded = try XCTUnwrap(FretArrangementSysEx.decodeBlob(old))
        XCTAssertEqual(decoded.segments.map(\.row), [.bottom, .middle, .top])
        let new = FretArrangement(segments: [.init(degreeIndex: 2, row: .lower), .init(degreeIndex: 3, row: .upper)])
        XCTAssertEqual(FretArrangementSysEx.decodeBlob(FretArrangementSysEx.encodeBlob(new))?.segments.map(\.row), [.lower, .upper])
        let masked: [UInt8] = [8, 1, 2, 0, 0, 0, 0, 127, 1, 31, 1, 0, 0, 0, 127, 0, 0]
        XCTAssertEqual(FretArrangementSysEx.decodeBlob(masked)?.segments.map(\.degreeIndex), [0])
    }

    /// Within a region the warp is monotone and every assigned pitch stays exact.
    func testWarpMonotonicity() throws {
        let frets = [FretPlacement(id: "a", segmentID: UUID(), isGhost: false, ratio: 1,
                                  name: "", x: 0, topY: 0, bottomY: 100),
                     FretPlacement(id: "b", segmentID: UUID(), isGhost: false, ratio: 2,
                                  name: "", x: 100, topY: 0, bottomY: 100)]
        var previous = -Double.infinity
        for n in 0...100 {
            let t = Double(n) / 100
            let pitch = try XCTUnwrap(fretFieldLog(at: CGPoint(x: t * 100, y: 50), placements: frets, warp: 1))
            XCTAssertGreaterThanOrEqual(pitch, previous)
            XCTAssertEqual(pitch, fretWarp(t, amount: 1), accuracy: 1e-12)
            previous = pitch
        }
    }
}
