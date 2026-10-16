import XCTest
@testable import TarabdaarCore

final class FretDragAssistTests: XCTestCase {
    /// Field updates preserve the receding check and pause timing of the physical stroke.
    func testFieldUpdatesDoNotBecomePointerMoves() throws {
        let live = assist()
        let reference = assist()
        for a in [live, reference] {
            a.begin(touchId: 1, x: 100, y: 50, uncorrectedLog: 0, time: 0)
            _ = a.move(touchId: 1, x: 125, y: 50, uncorrectedLog: 0.1, time: 0.01)
        }
        for n in 1...40 {
            let time = 0.01 + Double(n) * 0.01
            let raw = 0.1 - Double(n) * 0.001
            let refreshed = try XCTUnwrap(live.tick(time: time, regionLogs: [1: [.row5: raw]]).first).output
            let settled = try XCTUnwrap(reference.tick(time: time).first).output
            XCTAssertEqual(refreshed.stopGate, settled.stopGate)
            XCTAssertEqual(refreshed.weights, settled.weights,
                           "warp must not reset lastMoveTime or accelerate the idle speed decay")
        }
    }

    private func assist() -> FretDragAssist {
        let a = FretDragAssist()
        a.setContext(placements: [FretPlacement(id: "f", segmentID: UUID(),
            isGhost: false, ratio: 1, name: "", x: 100, topY: 0, bottomY: 100)],
            snapDistance: 24)
        return a
    }

    /// Amount zero is an exact bypass through onsets, reversals, moves and settle ticks.
    func testZeroAmountPreservesRawPitch() {
        let a = assist()
        a.settings[.amount] = 0
        a.begin(touchId: 1, x: 95, y: 50, uncorrectedLog: -0.04, time: 0)
        for n in 1...120 {
            let x = 95 + sin(Double(n) * 0.2) * 10
            let raw = (x - 100) / 200
            let t = Double(n) / 60
            let moved = a.move(touchId: 1, x: x, y: 50, uncorrectedLog: raw, time: t)
            XCTAssertEqual(moved.log2Pitch.bitPattern, raw.bitPattern)
            XCTAssertEqual(a.tick(time: t + 0.005)[0].output.log2Pitch.bitPattern, raw.bitPattern)
            XCTAssertTrue(moved.weights.isEmpty)
        }
    }

    /// Live controls reach stationary touches, preserve per-touch state and obey the slew bound.
    func testHeldTouchRespondsToRadiusAmountAndDisable() {
        let a = assist()
        a.settings[.radius] = 0
        a.settings[.slew] = 120
        a.begin(touchId: 1, x: 90, y: 50, uncorrectedLog: -0.05, time: 0)
        a.begin(touchId: 2, x: 110, y: 50, uncorrectedLog: 0.05, time: 0)
        let step = 1.0 / 60
        var previous = [1: -0.05, 2: 0.05]
        for n in 1...240 {
            if n == 20 { a.settings[.radius] = 1.75; a.settings[.amount] = 0.5 }
            if n == 120 { a.settings[.amount] = 0 }
            for (id, out) in a.tick(time: Double(n) * step) {
                XCTAssertLessThanOrEqual(abs(out.log2Pitch - previous[id]!),
                                        a.slewCap * step + 1e-12)
                previous[id] = out.log2Pitch
                let raw = id == 1 ? -0.05 : 0.05
                if n < 20 { XCTAssertEqual(out.log2Pitch, raw) }
                if n == 119 { XCTAssertEqual(out.log2Pitch, raw * 0.5, accuracy: 1e-10) }
                if n == 240 { XCTAssertEqual(out.log2Pitch, raw, accuracy: 1e-10) }
            }
        }
    }

    /// Sustained movement closes the pause gate; a held pause opens it after the configured delay.
    func testMovementAndPauseGate() {
        let a = assist()
        a.settings[.turnGain] = 0
        a.begin(touchId: 1, x: 60, y: 50, uncorrectedLog: -0.1, time: 0)
        var t = 0.0
        for n in 1...10 {
            t = Double(n) / 60
            let raw = -0.1 + Double(n) * 0.005
            let out = a.move(touchId: 1, x: 60 + Double(n) * 3, y: 50,
                             uncorrectedLog: raw, time: t)
            XCTAssertEqual(out.stopGate, 0)
            XCTAssertEqual(out.log2Pitch, raw)
        }
        for n in 1...60 {
            let out = a.tick(time: t + Double(n) / 60)[0].output
            if n < 6 { XCTAssertEqual(out.stopGate, 0) }
            if n == 60 { XCTAssertEqual(out.log2Pitch, 0, accuracy: 1e-10) }
        }
    }
    /// Each row corrects against its own assigned frets and keeps separate state on vertical transitions.
    func testIndependentRowCorrection() {
        let degrees = [(ratio: 1.0, label: "a"), (ratio: 2.0, label: "b")]
        let layout = FretArrangement(segments: [.init(degreeIndex: 0, row: .row1),
                                               .init(degreeIndex: 1, row: .row3),
                                               .init(degreeIndex: 0, row: .row2),
                                               .init(degreeIndex: 1, row: .row2)], ghostExtentOctaves: 0)
        let frets = fretPlacements(arrangement: layout, degrees: degrees, size: CGSize(width: 100, height: 420))
        let a = FretDragAssist()
        a.setContext(placements: frets, snapDistance: 100)
        let logs: [FretRegion: Double] = [.row1: 0.08, .row3: 0.95, .row2: 0.6]
        let regions: [FretRegion] = [.row1, .row3, .row2]
        for (id, region) in regions.enumerated() {
            let y = (region.topY + region.bottomY) / 2 * 420
            a.begin(touchId: id, x: 70, y: y, uncorrectedLog: logs[region]!, time: 0, regionLogs: logs)
        }
        var result: [Int: Double] = [:]
        for n in 1...90 {
            for (id, out) in a.tick(time: Double(n) / 60) { result[id] = out.log2Pitch }
        }
        XCTAssertEqual(result[0]!, 0, accuracy: 1e-10)
        XCTAssertEqual(result[1]!, 1, accuracy: 1e-10)
        XCTAssertEqual(result[2]!, 1, accuracy: 1e-10)
        let y = (FretRegion.row2.topY + FretRegion.row2.bottomY) / 2 * 420
        let moved = a.move(touchId: 0, x: 70, y: y, uncorrectedLog: 0.6, time: 1.51, regionLogs: logs)
        XCTAssertEqual(moved.log2Pitch, 1, accuracy: 1e-10)
    }
}
