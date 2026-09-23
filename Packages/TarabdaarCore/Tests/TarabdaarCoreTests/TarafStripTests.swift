import XCTest
@testable import TarabdaarCore

final class TarafStripTests: XCTestCase {
    /// Fast swipes cross all cells in order, while holds and reversals do not double-trigger.
    func testCrossings() {
        var stroke = TarafStrumGesture()
        XCTAssertEqual(stroke.move(x: 0, count: 34), [0])
        XCTAssertEqual(stroke.move(x: 0.001, count: 34), [])
        XCTAssertEqual(stroke.move(x: 1, count: 34), Array(1..<34))
        XCTAssertEqual(stroke.move(x: 0, count: 34), Array((0..<33).reversed()))
        XCTAssertEqual(stroke.move(x: -0.1, count: 34), [])
        XCTAssertEqual(stroke.move(x: 0.5, count: 34), [17])
        stroke.reset()
        XCTAssertEqual(stroke.move(x: 0.5, count: 34), [17])
        XCTAssertEqual(stroke.move(x: .nan, count: 34), [])
        XCTAssertEqual(stroke.move(x: 0, count: 0), [])
        XCTAssertEqual(stroke.move(x: 0, count: 4), [0])
        XCTAssertEqual(stroke.move(x: 1.2, count: 4), [1, 2, 3])
        XCTAssertEqual(stroke.move(x: 1.3, count: 4), [])
        XCTAssertEqual(stroke.move(x: 1, count: 4), [3])
        XCTAssertEqual(stroke.move(x: -0.2, count: 4), [2, 1, 0])
    }

    /// Pitch sorting preserves kernel identity and stale or malformed banks cannot play a different row.
    func testBankIdentity() {
        let bank = TarafBank(revision: 32, tonic: 220, rows: [
            .init(id: 0, frequency: 440, flags: 1), .init(id: 1, frequency: 220)])
        XCTAssertEqual(bank.orderedRows.map(\.id), [1, 0])
        XCTAssertTrue(bank.contains(revision: 32, row: 0))
        XCTAssertFalse(bank.contains(revision: 31, row: 0))
        XCTAssertFalse(bank.contains(revision: 32, row: 2))
        for rows in [[TarafBank.Row(id: 0, frequency: .nan)],
                     [.init(id: 0, frequency: 220), .init(id: 0, frequency: 440)],
                     [.init(id: 128, frequency: 220)], [.init(id: 0, frequency: 220, flags: 4)]] {
            let bytes = TLPFrame.event(seq: 1, .tarafBank(.init(revision: 1, tonic: 220, rows: rows))).encode()
            XCTAssertNil(TLPFrame.decode(bytes))
        }
    }
}
