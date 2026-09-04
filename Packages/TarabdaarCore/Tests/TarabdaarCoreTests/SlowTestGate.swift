import XCTest

/// The DSP render suites skip under a bare `swift test` and run with
/// `TARABDAAR_SLOW_TESTS=1` — the pre-commit invocation (`tools/test-full.sh`).
/// Gate whole suites, never single tests.
func skipUnlessSlowTestsEnabled(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["TARABDAAR_SLOW_TESTS"] == "1",
        "slow DSP suite — run with TARABDAAR_SLOW_TESTS=1 swift test",
        file: file, line: line)
}
