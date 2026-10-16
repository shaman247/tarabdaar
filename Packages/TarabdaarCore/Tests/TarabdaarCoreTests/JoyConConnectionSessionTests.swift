import XCTest
@testable import TarabdaarCore

final class JoyConConnectionSessionTests: XCTestCase {
    /// A connection with no completion callback expires once and permits a fresh attempt.
    func testMissingConnectionCallbackRecovers() throws {
        var session = JoyConConnectionSession()
        session.begin(at: 0)
        let old = session.generation
        let deadline = try XCTUnwrap(session.deadline)
        XCTAssertNil(session.expire(at: deadline - 0.01, token: old))
        XCTAssertEqual(session.expire(at: deadline, token: old), .connecting)
        XCTAssertFalse(session.accepts(old))
        XCTAssertNil(session.expire(at: deadline + 1, token: old))

        session.begin(at: deadline + 1)
        let retry = session.generation
        XCTAssertNil(session.expire(at: deadline + 100, token: old))
        XCTAssertTrue(session.accepts(retry))
        session.didConnect(at: deadline + 2)
        session.didReceiveInput()
        XCTAssertNil(session.expire(at: deadline + 100, token: retry))
        XCTAssertTrue(session.accepts(retry))
    }

    /// Link success extends the deadline for setup, but silent setup still expires.
    func testSetupHasItsOwnDeadline() throws {
        var session = JoyConConnectionSession()
        session.begin(at: 0)
        let token = session.generation
        let linkDeadline = try XCTUnwrap(session.deadline)
        session.didConnect(at: linkDeadline - 1)
        XCTAssertNil(session.expire(at: linkDeadline, token: token))
        let setupDeadline = try XCTUnwrap(session.deadline)
        XCTAssertEqual(session.expire(at: setupDeadline, token: token), .settingUp)
        session.didReceiveInput()
        XCTAssertFalse(session.accepts(token), "Late input must not revive an expired session")
    }

    /// Disconnect and Bluetooth resets invalidate queued work even when the same device reconnects.
    func testEndedSessionCannotAffectReconnect() throws {
        var session = JoyConConnectionSession()
        session.begin(at: 0)
        let old = session.generation
        session.didConnect(at: 1)
        session.didReceiveInput()
        session.end()
        XCTAssertFalse(session.accepts(old))
        session.begin(at: 2)
        let current = session.generation
        XCTAssertFalse(session.accepts(old))
        XCTAssertNil(session.expire(at: 100, token: old))
        XCTAssertEqual(session.expire(at: try XCTUnwrap(session.deadline), token: current), .connecting)
    }
}
