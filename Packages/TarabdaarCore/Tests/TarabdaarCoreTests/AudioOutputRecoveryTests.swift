#if os(macOS)
import CoreAudio
import XCTest
@testable import TarabdaarCore

final class AudioOutputRecoveryTests: XCTestCase {
    private final class Driver: AudioOutputRecoveryDriver {
        var availableOutputRoutes = [AudioOutputRoute(id: 1, uid: "built-in"), AudioOutputRoute(id: 2, uid: "interface")]
        var defaultOutputDevice: AudioDeviceID = 1
        var activeOutputDevice: AudioDeviceID = 0
        var running = false
        var validRate = true
        var failures: [AudioDeviceID: Int] = [:]
        var starts: [AudioDeviceID] = []
        var stops = 0
        var selection: AudioDeviceID = 0
        var error: String?
        func outputIsHealthy(on device: AudioDeviceID) -> Bool {
            running && validRate && activeOutputDevice == device
        }
        func startOutput(on device: AudioDeviceID, matchRate: Bool) throws {
            starts.append(device)
            activeOutputDevice = device
            running = false
            if failures[device, default: 0] > 0 {
                failures[device]! -= 1
                throw AudioOutputError.coreAudio("Test device refused startup", -50)
            }
            running = true
            validRate = true
        }
        func stopOutput() { running = false; stops += 1 }
        func outputRecoveryChanged(selection: AudioDeviceID, error: String?) {
            self.selection = selection; self.error = error
        }
    }

    private func drain(_ seconds: Double = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Default routing follows changes, while an explicit selection stays independent of them.
    func testDefaultAndExplicitRouting() {
        let d = Driver()
        let r = AudioOutputRecovery(driver: d)
        defer { r.shutdown() }
        r.start()
        d.defaultOutputDevice = 2
        r.configurationChanged(); drain()
        XCTAssertEqual(d.starts, [1, 2])
        XCTAssertEqual(d.selection, 0)
        XCTAssertTrue(r.select(1))
        r.configurationChanged(); drain()
        XCTAssertEqual(d.starts, [1, 2, 1])
        XCTAssertTrue(r.select(0))
        XCTAssertEqual(d.activeOutputDevice, 2)
    }

    /// Unplugging falls back without losing the UID, and replugging with a new numeric ID restores it.
    func testUnplugAndReplugPreservesDeviceIdentity() {
        let d = Driver()
        let recovery = AudioOutputRecovery(driver: d)
        defer { recovery.shutdown() }
        recovery.start()
        XCTAssertTrue(recovery.select(2))
        d.availableOutputRoutes.removeLast()
        recovery.configurationChanged(); drain()
        XCTAssertEqual(d.activeOutputDevice, 1)
        XCTAssertEqual(d.selection, 2)
        XCTAssertEqual(recovery.preferredUID, "interface")
        d.availableOutputRoutes.append(AudioOutputRoute(id: 22, uid: "interface"))
        recovery.configurationChanged(); drain()
        XCTAssertEqual(d.activeOutputDevice, 22)
        XCTAssertEqual(d.selection, 22)
    }

    /// A failed switch rolls back route intent and playback, retaining the error for the caller.
    func testSwitchFailureRollsBackAndInvalidIDDoesNotStopAudio() {
        let d = Driver()
        let recovery = AudioOutputRecovery(driver: d)
        defer { recovery.shutdown() }
        recovery.start()
        d.failures[2] = 1
        XCTAssertFalse(recovery.select(2))
        XCTAssertEqual(d.starts, [1, 2, 1])
        XCTAssertTrue(d.running)
        XCTAssertEqual(d.selection, 0)
        XCTAssertNil(recovery.preferredUID)
        XCTAssertTrue(d.error?.contains("-50") == true)
        XCTAssertFalse(recovery.select(999))
        XCTAssertEqual(d.starts, [1, 2, 1])
        XCTAssertTrue(d.running)
    }

    /// Sleep suppresses queued recovery and route changes, then wake resumes the latest selection.
    func testSleepWakeAndShutdownCancelPendingRecovery() {
        let d = Driver()
        let r = AudioOutputRecovery(driver: d)
        r.start()
        d.running = false
        r.configurationChanged()
        r.setSleeping(true)
        XCTAssertTrue(r.select(2))
        for _ in 0..<20 { r.configurationChanged() }
        drain()
        XCTAssertEqual(d.starts, [1])
        XCTAssertFalse(d.running)
        r.setSleeping(false); drain()
        XCTAssertEqual(d.starts, [1, 2])
        XCTAssertTrue(d.running)
        d.running = false
        r.configurationChanged()
        r.shutdown(); drain()
        XCTAssertEqual(d.starts, [1, 2])
    }

    /// Notification storms coalesce; an invalid rate and transient startup failure recover once.
    func testRateValidationAndTransientFailureRecovery() {
        let d = Driver()
        let r = AudioOutputRecovery(driver: d, retryDelays: [0.01, 0.02])
        defer { r.shutdown() }
        r.start()
        d.validRate = false
        d.failures[1] = 1
        for _ in 0..<100 { r.configurationChanged() }
        drain(0.3)
        XCTAssertEqual(d.starts, [1, 1, 1])
        XCTAssertTrue(d.running)
        XCTAssertTrue(d.validRate)
        XCTAssertNil(d.error)
        for _ in 0..<100 { r.configurationChanged() }
        drain()
        XCTAssertEqual(d.starts, [1, 1, 1])
    }

    /// Exhausted retries back off, and the latest explicit selection cancels an obsolete retry.
    func testFailedRecoveryBacksOffAndNewSelectionWins() {
        let d = Driver()
        d.failures[1] = 100
        let r = AudioOutputRecovery(driver: d, retryDelays: [0.01, 0.02])
        defer { r.shutdown() }
        r.start(); drain(0.15)
        XCTAssertEqual(d.starts, [1, 1, 1])
        XCTAssertFalse(d.running)
        XCTAssertNotNil(d.error)
        XCTAssertTrue(r.select(2)); drain(0.15)
        XCTAssertEqual(d.starts, [1, 1, 1, 2])
        XCTAssertTrue(d.running)
        XCTAssertNil(d.error)
    }

    /// Losing every output stops truthfully and a later device arrival resumes playback.
    func testNoOutputThenDeviceArrival() {
        let d = Driver()
        let r = AudioOutputRecovery(driver: d, retryDelays: [0.02])
        defer { r.shutdown() }
        r.start()
        d.availableOutputRoutes = []
        r.configurationChanged(); drain(0.15)
        XCTAssertFalse(d.running)
        XCTAssertNotNil(d.error)
        d.availableOutputRoutes = [AudioOutputRoute(id: 1, uid: "built-in")]
        r.configurationChanged(); drain()
        XCTAssertTrue(d.running)
        XCTAssertNil(d.error)
    }
}
#endif
