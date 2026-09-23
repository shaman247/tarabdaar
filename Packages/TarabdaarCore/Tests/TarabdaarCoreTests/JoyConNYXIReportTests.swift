import XCTest
@testable import TarabdaarCore

final class JoyConNYXIReportTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// A nearby right controller cannot win discovery over the left controller, even with no advertised name.
    func testLeftControllerDiscovery() {
        let left = bytes("53 05 01 00 03 7e 05 67 20 00 01 00")
        let right = bytes("53 05 01 00 03 7e 05 66 20 00 01 00")
        XCTAssertTrue(JoyConBLEDiscovery.accepts(manufacturerData: left, name: ""))
        XCTAssertFalse(JoyConBLEDiscovery.accepts(manufacturerData: right, name: ""))
        XCTAssertFalse(JoyConBLEDiscovery.accepts(manufacturerData: right, name: "NYXI NJ22Ultra-R"))
        XCTAssertFalse(JoyConBLEDiscovery.accepts(manufacturerData: nil, name: "NYXI NJ22Ultra-R"))
        XCTAssertTrue(JoyConBLEDiscovery.accepts(manufacturerData: nil, name: "NYXI NJ22Ultra-L"))
        XCTAssertTrue(JoyConBLEDiscovery.accepts(manufacturerData: nil, name: "Joy-Con (L)"))
        XCTAssertFalse(JoyConBLEDiscovery.accepts(manufacturerData: nil, name: "Joy-Con (R)"))
        XCTAssertFalse(JoyConBLEDiscovery.accepts(manufacturerData: bytes("53"), name: "Mouse"))
    }

    /// Captured NYXI button packets decode into distinct controls and release through the shared mapper.
    func testCapturedButtons() throws {
        let captures: [(String, JoyConControl)] = [
            ("08 00 00 00 00 00 04", .dpadUp),
            ("04 00 00 00 00 00 01", .dpadDown),
            ("02 00 00 00 00 00 08", .dpadLeft),
            ("01 00 00 00 00 00 02", .dpadRight),
            ("80 00 00 00 00 00 80", .l),
            ("40 00 00 00 00 00 40", .zl),
            ("20 00 00 00 00 00 20", .minus),
            ("10 00 00 00 00 00 10", .stickClick),
            ("00 04 00 00 00 00 00", .capture),
            ("00 01 00 00 00 00 00", .sl),
            ("00 02 00 00 00 00 00", .sr),
            ("00 08 00 00 00 00 00", .rearZ),
        ]
        let header = "ea 01 00 8b 00 78 00 00 0c "
        let mapper = JoyConMapper()
        for (payload, control) in captures {
            let report = try XCTUnwrap(JoyConNYXIReport.decode(bytes(header + payload),
                                                              timestamp: 1, generation: 3))
            XCTAssertEqual(report.source, .bleAlt)
            XCTAssertEqual(report.generation, 3)
            let update = try XCTUnwrap(report.buttons)
            let edges = mapper.edges(update, from: report.source, generation: report.generation)
            XCTAssertEqual(edges.map(\.0), [control])
            XCTAssertEqual(edges.map(\.1), [true])
            XCTAssertTrue(mapper.edges(update, from: report.source, generation: 3).isEmpty)
            let rest = try XCTUnwrap(JoyConNYXIReport.decode(
                bytes(header + "00 00 00 00 00 00 00"), timestamp: 2, generation: 3))
            let release = mapper.edges(try XCTUnwrap(rest.buttons), from: rest.source, generation: 3)
            XCTAssertEqual(release.map(\.0), [control])
            XCTAssertEqual(release.map(\.1), [false])
        }
    }

    /// Vendor framing separates input from acks, and signed stick values retain both halves of their range.
    func testFramingAndStick() throws {
        let packet = bytes("ea 01 00 8b 00 78 00 00 0c 88 04 00 80 ff 7f 84")
        let report = try XCTUnwrap(JoyConNYXIReport.decode(packet, timestamp: 1))
        guard case .snapshot(let down) = report.buttons,
              case .raw(let x, let y) = report.stick else { return XCTFail("missing input") }
        XCTAssertEqual(down, [.dpadUp, .l, .capture])
        XCTAssertEqual(x, 0)
        XCTAssertEqual(y, 4095.9375)
        XCTAssertTrue(report.imu.isEmpty)
        XCTAssertFalse(report.fuseIMU)
        for count in 0..<16 {
            XCTAssertNil(JoyConNYXIReport.decode(packet.prefix(count), timestamp: 1))
        }
        XCTAssertNil(JoyConNYXIReport.decode(
            bytes("02 01 01 04 10 78 00 00 40 00 00 00 00 30 01 00"), timestamp: 1))
        for offset in [0, 1, 2, 3, 4, 5, 6, 7, 8] {
            var other = packet
            other[offset] ^= 1
            XCTAssertNil(JoyConNYXIReport.decode(other, timestamp: 1))
        }
    }

    /// The console-session stream preserves buttons while supplying signed motion samples to fusion.
    func testCapturedStandardMotion() throws {
        let packet = bytes("7a 20 00 00 40 00 40 00 00 00 00 08 80 00 08 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 20 00 00 00 00 00 00 00 01 aa 47 01 00 00 00 26 08 0b 02 41 0f c9 00 5f 00 47 ff 00 00 00")
        let rear = bytes("e7 20 00 00 00 00 00 03 00 00 00 08 80 00 08 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 20 00 00 00 00 00 00 00 01 ca 55 01 00 00 00 29 09 9a 06 f5 0b c8 00 2c 00 d8 ff 00 00 00")
        let decoder = JoyCon2ReportDecoder()
        let report = try XCTUnwrap(decoder.decode(packet, timestamp: 10, isNYXI: true))
        guard case .snapshot(let down) = report.buttons else { return XCTFail("missing buttons") }
        XCTAssertEqual(down, [.l])
        XCTAssertEqual(report.source, .bleAlt)
        XCTAssertTrue(report.fuseIMU)
        let sample = try XCTUnwrap(report.imu.first)
        XCTAssertGreaterThan(sample.accelG.z, sample.accelG.x)
        XCTAssertGreaterThan(sample.gyroDps.x, 0)
        XCTAssertLessThan(sample.gyroDps.z, 0)
        XCTAssertNil(sample.mag)
        XCTAssertNotNil(JoyConFusion().ingest(accelG: sample.accelG,
                                             gyroRadPerSec: sample.gyroRadPerSec, at: sample.t))
        let rearReport = try XCTUnwrap(decoder.decode(rear, timestamp: 11, isNYXI: true))
        guard case .snapshot(let rearDown) = rearReport.buttons else { return XCTFail("missing rear button") }
        XCTAssertEqual(rearDown, [.rearZ])
        for count in 13..<60 {
            let short = try XCTUnwrap(decoder.decode(packet.prefix(count), timestamp: 12, isNYXI: true))
            XCTAssertTrue(short.imu.isEmpty)
            XCTAssertFalse(short.fuseIMU)
        }
    }

    /// Batched delivery, clock wrap, duplicate samples and reconnects cannot distort the NYXI sensor interval.
    func testSensorClock() throws {
        var packet = Data(repeating: 0, count: 63)
        packet[53] = 0x10
        func stamped(_ tick: UInt32) -> Data {
            var d = packet
            for i in 0..<4 { d[42 + i] = UInt8(truncatingIfNeeded: tick >> (i * 8)) }
            return d
        }
        let decoder = JoyCon2ReportDecoder()
        let first = try XCTUnwrap(decoder.decode(stamped(UInt32.max - 2), timestamp: 10, isNYXI: true)?.imu.first)
        let next = try XCTUnwrap(decoder.decode(stamped(2), timestamp: 10.0001, isNYXI: true)?.imu.first)
        XCTAssertEqual(next.t - first.t, 0.005, accuracy: 0.000001)
        XCTAssertTrue(try XCTUnwrap(decoder.decode(stamped(2), timestamp: 10.0002, isNYXI: true)).imu.isEmpty)
        let dropped = try XCTUnwrap(decoder.decode(stamped(22), timestamp: 10.0003, isNYXI: true)?.imu.first)
        XCTAssertEqual(dropped.t - next.t, 0.020, accuracy: 0.000001)
        let reconnect = try XCTUnwrap(decoder.decode(stamped(1), timestamp: 20, generation: 1, isNYXI: true)?.imu.first)
        XCTAssertEqual(reconnect.t, 20)
        let gap = try XCTUnwrap(decoder.decode(stamped(6), timestamp: 21, generation: 1, isNYXI: true)?.imu.first)
        XCTAssertEqual(gap.t, 21)
        let standard = try XCTUnwrap(decoder.decode(stamped(7), timestamp: 21.01)?.imu.first)
        XCTAssertEqual(standard.t, 21.01)
    }
}
