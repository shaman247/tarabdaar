import XCTest

/// The DSP render suites (parity, realtime, rebuild, zipper, live push) skip
/// under a bare `swift test` and run with `TARABDAAR_SLOW_TESTS=1` — the
/// pre-commit invocation (`tools/test-full.sh`). Gate whole suites.
func skipUnlessSlowTestsEnabled(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["TARABDAAR_SLOW_TESTS"] == "1",
        "slow DSP suite — run with TARABDAAR_SLOW_TESTS=1 swift test",
        file: file, line: line)
}
