import XCTest

/// Polls a main-actor test condition against a monotonic deadline.
///
/// Cancellation is deliberately propagated to the caller rather than being
/// converted into either success or a timeout assertion.
@MainActor
@discardableResult
func XCTAssertEventually(
    timeout: Duration,
    pollInterval: Duration,
    description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () -> Bool
) async throws -> Bool {
    guard timeout > .zero else {
        XCTFail(
            "Eventually timeout must be greater than zero: \(description)",
            file: file,
            line: line
        )
        return false
    }
    guard pollInterval > .zero else {
        XCTFail(
            "Eventually poll interval must be greater than zero: \(description)",
            file: file,
            line: line
        )
        return false
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var attempts = 0

    while true {
        try Task.checkCancellation()
        attempts += 1
        if condition() {
            return true
        }

        let now = clock.now
        guard now < deadline else {
            XCTFail(
                "Timed out after \(timeout) waiting for \(description) "
                    + "(\(attempts) checks, poll interval \(pollInterval)).",
                file: file,
                line: line
            )
            return false
        }

        let nextPoll = now.advanced(by: pollInterval)
        try await clock.sleep(until: min(nextPoll, deadline))
    }
}
