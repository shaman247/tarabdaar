import XCTest
@testable import TarabdaarCore

/// The pure half of the Joy-Con path: button edges out of per-bearer
/// snapshots, and the stick's deadband / circle-rim calibration laws.
final class JoyConMapperTests: XCTestCase {

    /// A snapshot bearer sends the whole held set every report: repeats are
    /// silent, each bearer keeps its own view, a reattach drops the stale
    /// snapshot, and a detach releases exactly what it held.
    func testButtonEdgesAndReleases() {
        let m = JoyConMapper()
        var edges = m.edges(.snapshot([.l]), from: .hid)
        XCTAssertEqual(edges.map(\.0), [.l])
        XCTAssertTrue(edges[0].1)
        XCTAssertTrue(m.edges(.snapshot([.l]), from: .hid).isEmpty, "60 Hz repeat retriggered")

        // one added, one removed, in the same report
        edges = m.edges(.snapshot([.zl]), from: .hid)
        XCTAssertEqual(Set(edges.map(\.0)), [.l, .zl])
        XCTAssertEqual(edges.first { $0.0 == .zl }?.1, true)
        XCTAssertEqual(edges.first { $0.0 == .l }?.1, false)

        // two bearers can be live at once (GameController + raw HID); one
        // going quiet must not release the other's presses
        _ = m.edges(.edge(.dpadUp, true), from: .gameController)
        XCTAssertEqual(m.buttonsDown, [.zl, .dpadUp])
        XCTAssertEqual(m.edges(.snapshot([]), from: .hid).map(\.0), [.zl])
        XCTAssertEqual(m.buttonsDown, [.dpadUp])
        XCTAssertEqual(m.release(source: .gameController).map(\.0), [.dpadUp])
        XCTAssertTrue(m.buttonsDown.isEmpty)

        // a reattach (new generation) drops the stale snapshot, so a button
        // held across the unplug reads as a fresh press, not a silent repeat
        _ = m.edges(.snapshot([.l]), from: .hid, generation: 1)
        edges = m.edges(.snapshot([.l]), from: .hid, generation: 2)
        XCTAssertEqual(edges.map(\.0), [.l])
        XCTAssertEqual(edges.map(\.1), [true])

        // HID full-mode handover: everything shown as down must be released
        // or the press sticks
        _ = m.edges(.edge(.sl, true), from: .gameController)
        let released = m.releaseAll()
        XCTAssertEqual(Set(released.map(\.0)), [.l, .sl])
        XCTAssertTrue(released.allSatisfy { !$0.1 })
        XCTAssertTrue(m.buttonsDown.isEmpty)
    }

    /// The deadzone pins a drifting neutral to exact centre and rescales what
    /// is left (continuous across the gate); a held stick sends nothing.
    func testDeadzoneGateAndChangeGate() {
        XCTAssertEqual(JoyConMapper.gate(0.05), 0)
        XCTAssertEqual(JoyConMapper.gate(-0.099), 0)
        XCTAssertEqual(JoyConMapper.gate(0.1), 0, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(1), 1, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(-1), -1, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(0.55), 0.5, accuracy: 1e-12)

        let m = JoyConMapper()
        let first = m.gateStick(x: 0.55, y: 0)
        XCTAssertEqual(first.axes?.x ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(first.active)
        XCTAssertNil(m.gateStick(x: 0.55, y: 0).axes, "a held stick sent an update")
        XCTAssertNil(m.gateStick(x: 0.5501, y: 0).axes, "sub-quantum wiggle sent")

        let rest = m.gateStick(x: 0.02, y: -0.02)
        XCTAssertEqual(rest.axes, SIMD2(0, 0))
        XCTAssertFalse(rest.active)
        XCTAssertNil(m.gateStick(x: 0.0, y: 0.0).axes)
        // a device removal parks the axes: the next value always sends
        m.resetStickSend()
        XCTAssertEqual(m.gateStick(x: 0.0, y: 0.0).axes, SIMD2(0, 0))
    }

    private func sweepRim(_ m: JoyConMapper, center: (Double, Double),
                          radius: Double, bins: Int = 64) {
        for i in 0..<bins {
            let a = 2 * Double.pi * Double(i) / Double(bins)
            _ = m.ingestRawStick(center.0 + radius * cos(a),
                                 center.1 + radius * sin(a))
        }
    }

    /// Two-phase capture: rest samples, then a full rim sweep is accepted and
    /// an unswept bin (a divide-by-~zero at runtime) discards the whole thing.
    func testCalibrationCapturesRestThenRim() {
        let m = JoyConMapper()
        m.beginCalibration()
        XCTAssertEqual(m.calPhase, .rest)
        for _ in 0..<30 {
            XCTAssertEqual(m.ingestRawStick(2100, 1900), .capturingRest)
        }
        XCTAssertEqual(m.calPhase, .range)
        sweepRim(m, center: (2100, 1900), radius: 900)
        guard case .accepted(let cal) = m.finishCalibration() else {
            return XCTFail("a full sweep must be accepted")
        }
        XCTAssertEqual(cal.cx, 2100, accuracy: 1e-9)
        XCTAssertEqual(cal.rim.count, JoyConMapper.calBins)
        XCTAssertTrue(cal.rim.allSatisfy { $0 > JoyConMapper.calMinRadius })
        XCTAssertEqual(m.calPhase, .idle)
        // an off-centre rest is subtracted before the map
        guard case .axes(let x, let y) = m.ingestRawStick(2100, 1900) else {
            return XCTFail("a calibrated stick must map, not capture")
        }
        XCTAssertEqual(x, 0, accuracy: 1e-9)
        XCTAssertEqual(y, 0, accuracy: 1e-9)

        let partial = JoyConMapper()
        partial.beginCalibration()
        for _ in 0..<30 { _ = partial.ingestRawStick(2000, 2000) }
        for i in 0..<16 {                                  // one quadrant only
            let a = (Double.pi / 2) * Double(i) / 16 - .pi / 4
            _ = partial.ingestRawStick(2000 + 900 * cos(a), 2000 + 900 * sin(a))
        }
        guard case .discarded(let missing) = partial.finishCalibration() else {
            return XCTFail("an unswept rim must be discarded")
        }
        XCTAssertGreaterThan(missing, 0)
        XCTAssertNil(partial.stickCal)
    }

    /// THE POINT of the circle rim: per-axis min/max would send a diagonal to
    /// (±1, ±1) far too early. Mapped circle → square, a deflection at the rim
    /// reads exactly 1 on its larger component in every direction.
    func testCalMapSendsTheRimToTheUnitSquare() {
        let cal = JoyConStickCal(cx: 0, cy: 0,
                                 rim: Array(repeating: 800,
                                            count: JoyConMapper.calBins))
        for deg in stride(from: 0, to: 360, by: 15) {
            let a = Double(deg) * .pi / 180
            let (x, y) = JoyConMapper.calMap(dx: 800 * cos(a),
                                             dy: 800 * sin(a), cal: cal)
            XCTAssertEqual(max(abs(x), abs(y)), 1, accuracy: 1e-9,
                           "rim at \(deg)° must reach full scale")
        }
        let (dx, dy) = JoyConMapper.calMap(dx: 800 * cos(.pi / 4),
                                           dy: 800 * sin(.pi / 4), cal: cal)
        XCTAssertEqual(dx, 1, accuracy: 1e-9)
        XCTAssertEqual(dy, 1, accuracy: 1e-9)
        XCTAssertEqual(JoyConMapper.calMap(dx: 0, dy: 0, cal: cal).0, 0)
        XCTAssertEqual(JoyConMapper.calMap(dx: 2000, dy: 0, cal: cal).0, 1,
                       accuracy: 1e-9, "past the rim must clamp")
    }
}
