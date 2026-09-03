import XCTest
@testable import TarabdaarCore

/// The pure half of the Joy-Con path: button edges out of per-bearer
/// snapshots, and the stick's deadband / circle-rim calibration laws.
/// No hardware, no frameworks — exactly why the mapper was lifted out of
/// the Mac transports.
final class JoyConMapperTests: XCTestCase {

    // MARK: - Button edges

    /// A snapshot bearer sends the WHOLE held set every report; the
    /// mapper turns that into edges and nothing else: a repeat is silent,
    /// a press and a release each fire exactly once.
    func testSnapshotDiffingFiresOneEdgePerChange() {
        let m = JoyConMapper()
        var edges = m.edges(.snapshot([.l]), from: .hid)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].0, .l)
        XCTAssertTrue(edges[0].1)
        XCTAssertEqual(m.buttonsDown, [.l])

        // The same held set again — the wire repeats at 60 Hz and must
        // not retrigger.
        XCTAssertTrue(m.edges(.snapshot([.l]), from: .hid).isEmpty)

        // One added, one removed, in the same report.
        edges = m.edges(.snapshot([.zl]), from: .hid)
        XCTAssertEqual(Set(edges.map(\.0)), [.l, .zl])
        XCTAssertEqual(edges.first { $0.0 == .zl }?.1, true)
        XCTAssertEqual(edges.first { $0.0 == .l }?.1, false)
        XCTAssertEqual(m.buttonsDown, [.zl])
    }

    /// Two bearers can be live at once (a classic Joy-Con is seen by the
    /// GameController profile AND the raw HID side-channel). Each keeps
    /// its own snapshot, so one going quiet cannot release the other's
    /// presses.
    func testBearerSnapshotsAreIndependent() {
        let m = JoyConMapper()
        _ = m.edges(.snapshot([.l]), from: .hid)
        _ = m.edges(.snapshot([.zl]), from: .ble)
        XCTAssertEqual(m.buttonsDown, [.l, .zl])

        // A BLE report with no buttons releases only ZL.
        let edges = m.edges(.snapshot([]), from: .ble)
        XCTAssertEqual(edges.map(\.0), [.zl])
        XCTAssertEqual(m.buttonsDown, [.l])

        // The HID bearer going away releases what IT held.
        XCTAssertEqual(m.release(source: .hid).map(\.0), [.l])
        XCTAssertTrue(m.buttonsDown.isEmpty)
    }

    /// The GameController profile delivers per-button callbacks, so its
    /// updates arrive as edges — passed through, and still tracked so a
    /// detach can release them.
    func testEdgeUpdatesPassThroughAndStayTracked() {
        let m = JoyConMapper()
        let down = m.edges(.edge(.dpadUp, true), from: .gameController)
        XCTAssertEqual(down.count, 1)
        XCTAssertEqual(m.buttonsDown, [.dpadUp])
        XCTAssertEqual(m.release(source: .gameController).map(\.0), [.dpadUp])
        XCTAssertTrue(m.buttonsDown.isEmpty)
    }

    /// A device reattach (new generation) drops the stale snapshot, so a
    /// button the OS reported as held before the unplug cannot leave a
    /// phantom release behind.
    func testGenerationChangeDropsTheStaleSnapshot() {
        let m = JoyConMapper()
        _ = m.edges(.snapshot([.l]), from: .hid, generation: 1)
        // Same held set, new generation: the snapshot resets, so L reads
        // as a fresh press rather than a silent repeat.
        let edges = m.edges(.snapshot([.l]), from: .hid, generation: 2)
        XCTAssertEqual(edges.map(\.0), [.l])
        XCTAssertEqual(edges.map(\.1), [true])
    }

    /// HID full-mode handover: the GC bindings stand down, and everything
    /// currently SHOWN as down must be released or a press sticks.
    func testReleaseAllClearsTheHeldView() {
        let m = JoyConMapper()
        _ = m.edges(.edge(.l, true), from: .gameController)
        _ = m.edges(.edge(.sl, true), from: .gameController)
        let released = m.releaseAll()
        XCTAssertEqual(Set(released.map(\.0)), [.l, .sl])
        XCTAssertTrue(released.allSatisfy { !$0.1 })
        XCTAssertTrue(m.buttonsDown.isEmpty)
    }

    // MARK: - The stick's deadband + change gate

    /// The deadzone pins a drifting neutral to exact centre and rescales
    /// what is left, so the axis is continuous across the gate: 0.1 → 0,
    /// 1 → 1, and the midpoint of the live range → 0.5.
    func testDeadzoneGateIsContinuous() {
        XCTAssertEqual(JoyConMapper.gate(0.05), 0)
        XCTAssertEqual(JoyConMapper.gate(-0.099), 0)
        XCTAssertEqual(JoyConMapper.gate(0.1), 0, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(1), 1, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(-1), -1, accuracy: 1e-12)
        XCTAssertEqual(JoyConMapper.gate(0.55), 0.5, accuracy: 1e-12)
    }

    /// A held or centred stick is SILENT: the quantized value has to
    /// change before an axis update goes out. `active` still reports the
    /// deadzone state on every sample.
    func testStickChangeGateAndActivity() {
        let m = JoyConMapper()
        let first = m.gateStick(x: 0.55, y: 0)
        XCTAssertEqual(first.axes?.x ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(first.active)

        // Held: same quantized value, nothing sent.
        XCTAssertNil(m.gateStick(x: 0.55, y: 0).axes)
        // A sub-quantum wiggle (1/256 ≈ 0.0039 in gated units) is silent.
        XCTAssertNil(m.gateStick(x: 0.5501, y: 0).axes)

        // Back inside the deadzone: one update to centre, then silence.
        let rest = m.gateStick(x: 0.02, y: -0.02)
        XCTAssertEqual(rest.axes, SIMD2(0, 0))
        XCTAssertFalse(rest.active)
        XCTAssertNil(m.gateStick(x: 0.0, y: 0.0).axes)

        // A device removal parks the axes: the next value always sends.
        m.resetStickSend()
        XCTAssertEqual(m.gateStick(x: 0.0, y: 0.0).axes, SIMD2(0, 0))
    }

    // MARK: - The circle-rim stick calibration

    private func sweepRim(_ m: JoyConMapper, center: (Double, Double),
                          radius: Double, bins: Int = 64) {
        for i in 0..<bins {
            let a = 2 * Double.pi * Double(i) / Double(bins)
            _ = m.ingestRawStick(center.0 + radius * cos(a),
                                 center.1 + radius * sin(a))
        }
    }

    /// The two-phase capture: 30 samples establish the in-grip rest, the
    /// sweep grows a radius per angle bin, and a FULL circle is accepted.
    func testCalibrationCapturesRestThenRim() {
        let m = JoyConMapper()
        m.beginCalibration()
        XCTAssertEqual(m.calPhase, .rest)
        for _ in 0..<29 {
            XCTAssertEqual(m.ingestRawStick(2100, 1900), .capturingRest)
        }
        // The 30th completes the rest average and opens the sweep.
        XCTAssertEqual(m.ingestRawStick(2100, 1900), .capturingRest)
        XCTAssertEqual(m.calPhase, .range)

        sweepRim(m, center: (2100, 1900), radius: 900)
        guard case .accepted(let cal) = m.finishCalibration() else {
            return XCTFail("a full sweep must be accepted")
        }
        XCTAssertEqual(cal.cx, 2100, accuracy: 1e-9)
        XCTAssertEqual(cal.cy, 1900, accuracy: 1e-9)
        XCTAssertEqual(cal.rim.count, JoyConMapper.calBins)
        XCTAssertTrue(cal.rim.allSatisfy { $0 > JoyConMapper.calMinRadius })
        XCTAssertEqual(m.calPhase, .idle)
    }

    /// An unswept bin would divide by ~zero at runtime — the whole
    /// calibration is discarded rather than shipped with a hole in it.
    func testPartialSweepIsDiscarded() {
        let m = JoyConMapper()
        m.beginCalibration()
        for _ in 0..<30 { _ = m.ingestRawStick(2000, 2000) }
        // Only the right-hand quadrant.
        for i in 0..<16 {
            let a = (Double.pi / 2) * Double(i) / 16 - .pi / 4
            _ = m.ingestRawStick(2000 + 900 * cos(a), 2000 + 900 * sin(a))
        }
        guard case .discarded(let missing) = m.finishCalibration() else {
            return XCTFail("an unswept rim must be discarded")
        }
        XCTAssertGreaterThan(missing, 0)
        XCTAssertNil(m.stickCal)
        XCTAssertEqual(m.calPhase, .idle)
    }

    /// THE POINT of the circle rim: per-axis min/max would send a
    /// diagonal to (±1, ±1) far too early. Mapped circle → square, a
    /// deflection AT the rim reads exactly 1 on its larger component, in
    /// every direction — and the diagonal reaches (1, 1) only there.
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
        // Rest is exact centre, and past the rim stays clamped.
        XCTAssertEqual(JoyConMapper.calMap(dx: 0, dy: 0, cal: cal).0, 0)
        let (ox, _) = JoyConMapper.calMap(dx: 2000, dy: 0, cal: cal)
        XCTAssertEqual(ox, 1, accuracy: 1e-9)
    }

    /// An off-centre rest is subtracted before the map — the neutral
    /// drifts, and a calibrated stick must still read 0 at ITS rest.
    func testCalibratedRestReadsCentre() {
        let m = JoyConMapper()
        m.beginCalibration()
        for _ in 0..<30 { _ = m.ingestRawStick(2100, 1900) }
        sweepRim(m, center: (2100, 1900), radius: 900)
        _ = m.finishCalibration()
        guard case .axes(let x, let y) = m.ingestRawStick(2100, 1900) else {
            return XCTFail("a calibrated stick must map, not capture")
        }
        XCTAssertEqual(x, 0, accuracy: 1e-9)
        XCTAssertEqual(y, 0, accuracy: 1e-9)
    }

    /// Uncalibrated fallback: the first 23 samples establish a rest and
    /// produce nothing; the 24th completes the average and maps in the
    /// same call, then a fixed span carries the axes.
    func testUncalibratedFallbackLearnsItsCentre() {
        let m = JoyConMapper()
        for _ in 0..<23 {
            XCTAssertEqual(m.ingestRawStick(2000, 2000), .pending)
        }
        guard case .axes(let x, let y) = m.ingestRawStick(2000, 2000) else {
            return XCTFail("the centre is established on the 24th sample")
        }
        XCTAssertEqual(x, 0, accuracy: 1e-12)
        XCTAssertEqual(y, 0, accuracy: 1e-12)
        // Full span, and clamped past it.
        guard case .axes(let fx, _) =
                m.ingestRawStick(2000 + JoyConMapper.stickSpan, 2000) else {
            return XCTFail("expected axes")
        }
        XCTAssertEqual(fx, 1, accuracy: 1e-12)
        guard case .axes(let cx, _) = m.ingestRawStick(9999, 2000) else {
            return XCTFail("expected axes")
        }
        XCTAssertEqual(cx, 1, accuracy: 1e-12)
    }
}
