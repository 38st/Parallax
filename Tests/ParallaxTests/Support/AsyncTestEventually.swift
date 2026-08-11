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

/// Compatibility wrapper for older tests that only need a condition-based wait.
///
/// Unlike the former per-suite polling loops, this shared helper reports a
/// deterministic failure when the deadline expires.
@MainActor
func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await XCTAssertEventually(
            timeout: .seconds(2),
            pollInterval: .milliseconds(5),
            description: "test condition",
            file: file,
            line: line,
            condition: condition
        )
    } catch {
        XCTFail(
            "Cancelled while waiting for test condition: \(error.localizedDescription)",
            file: file,
            line: line
        )
    }
}
