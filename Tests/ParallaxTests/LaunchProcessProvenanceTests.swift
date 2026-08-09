import XCTest
@testable import Parallax

final class LaunchProcessProvenanceTests: XCTestCase {
    func testExactPreexistingIdentityIsClassifiedAsPreExisting() {
        let identity = workspaceIdentity(
            processIdentifier: 4_101,
            startTimeSeconds: 10
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: identity.processIdentifier,
                inspection: .live(identity),
                preopenSnapshot: snapshot(processes: [identity]),
                launchBoundary: boundary()
            ),
            .preExisting(identity)
        )
    }

    func testUnseenExactIdentityIsClassifiedAsNew() {
        let identity = workspaceIdentity(
            processIdentifier: 4_102,
            startTimeSeconds: 20
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: identity.processIdentifier,
                inspection: .live(identity),
                preopenSnapshot: snapshot(),
                launchBoundary: boundary()
            ),
            .new(identity)
        )
    }

    func testReusedPIDWithNewStartIdentityIsIndeterminate() {
        let prior = workspaceIdentity(
            processIdentifier: 4_103,
            startTimeSeconds: 30,
            startTimeMicroseconds: 7
        )
        let returned = workspaceIdentity(
            processIdentifier: 4_103,
            startTimeSeconds: 30,
            startTimeMicroseconds: 8
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returned.processIdentifier,
                inspection: .live(returned),
                preopenSnapshot: snapshot(processes: [prior]),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returned.processIdentifier,
                reason: .processIdentifierReused
            )
        )
    }

    func testSameKernelIdentityWithUnexpectedBundleFailsClosed() {
        let prior = workspaceIdentity(
            processIdentifier: 4_104,
            startTimeSeconds: 40
        )
        let returned = workspaceIdentity(
            processIdentifier: 4_104,
            startTimeSeconds: 40,
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.other"
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returned.processIdentifier,
                inspection: .live(returned),
                preopenSnapshot: snapshot(processes: [prior]),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returned.processIdentifier,
                reason: .unexpectedApplication
            )
        )
    }

    func testConflictingSnapshotBundleForSameKernelIdentityFailsClosed() {
        let returned = workspaceIdentity(
            processIdentifier: 4_110,
            startTimeSeconds: 41
        )
        let conflictingSnapshotIdentity = WorkspaceProcessIdentity(
            process: returned.process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                bundleIdentifier: "com.example.other"
            )
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returned.processIdentifier,
                inspection: .live(returned),
                preopenSnapshot: snapshot(
                    processes: [conflictingSnapshotIdentity]
                ),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returned.processIdentifier,
                reason: .bundleIdentityChanged
            )
        )
    }

    func testUnexpectedBundlePathOrIdentifierCannotBeClassifiedAsNew() {
        let wrongPath = workspaceIdentity(
            processIdentifier: 4_107,
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app")
        )
        let missingIdentifier = workspaceIdentity(
            processIdentifier: 4_108,
            bundleIdentifier: nil
        )
        let wrongIdentifier = workspaceIdentity(
            processIdentifier: 4_109,
            bundleIdentifier: "com.example.other"
        )

        for identity in [wrongPath, missingIdentifier, wrongIdentifier] {
            XCTAssertEqual(
                LaunchProcessProvenanceClassifier.classify(
                    processIdentifier: identity.processIdentifier,
                    inspection: .live(identity),
                    preopenSnapshot: snapshot(),
                    launchBoundary: boundary()
                ),
                .indeterminate(
                    processIdentifier: identity.processIdentifier,
                    reason: .unexpectedApplication
                )
            )
        }
    }

    func testMissingExpectedIdentifierCannotBeClassifiedAsNew() {
        let identity = workspaceIdentity(processIdentifier: 4_111)
        let incompleteExpectedIdentity = WorkspaceProcessSnapshot(
            expectedApplication: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(
                    fileURLWithPath: "/Applications/Target.app"
                ),
                bundleIdentifier: nil
            ),
            processes: []
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: identity.processIdentifier,
                inspection: .live(identity),
                preopenSnapshot: incompleteExpectedIdentity,
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: identity.processIdentifier,
                reason: .unexpectedApplication
            )
        )
    }

    func testExitedAmbiguousAndMismatchedResultsAreIndeterminate() {
        let returnedPID: pid_t = 4_105
        let mismatched = workspaceIdentity(processIdentifier: 4_106)

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returnedPID,
                inspection: .exited,
                preopenSnapshot: snapshot(),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returnedPID,
                reason: .exitedBeforeVerification
            )
        )
        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returnedPID,
                inspection: .indeterminate,
                preopenSnapshot: snapshot(),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returnedPID,
                reason: .unverifiableIdentity
            )
        )
        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: returnedPID,
                inspection: .live(mismatched),
                preopenSnapshot: snapshot(),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: returnedPID,
                reason: .processIdentifierMismatch
            )
        )
    }

    func testLaunchBoundaryValidatesIntegerGettimeofdayTuple() throws {
        XCTAssertThrowsError(
            try LaunchRequestTimeBoundary(seconds: -1, microseconds: 0)
        ) { error in
            XCTAssertEqual(
                error as? LaunchRequestTimeBoundaryError,
                .invalidSeconds
            )
        }
        for invalidMicroseconds: Int64 in [-1, 1_000_000] {
            XCTAssertThrowsError(
                try LaunchRequestTimeBoundary(
                    seconds: 1,
                    microseconds: invalidMicroseconds
                )
            ) { error in
                XCTAssertEqual(
                    error as? LaunchRequestTimeBoundaryError,
                    .invalidMicroseconds
                )
            }
        }
    }

    func testLaunchBoundaryRequiresStrictlyLaterProcessTuple() throws {
        let boundary = try LaunchRequestTimeBoundary(
            seconds: 500,
            microseconds: 100
        )
        let before = workspaceIdentity(
            processIdentifier: 4_120,
            startTimeSeconds: 500,
            startTimeMicroseconds: 99
        )
        let equal = workspaceIdentity(
            processIdentifier: 4_121,
            startTimeSeconds: 500,
            startTimeMicroseconds: 100
        )
        let after = workspaceIdentity(
            processIdentifier: 4_122,
            startTimeSeconds: 500,
            startTimeMicroseconds: 101
        )

        for identity in [before, equal] {
            XCTAssertEqual(
                LaunchProcessProvenanceClassifier.classify(
                    processIdentifier: identity.processIdentifier,
                    inspection: .live(identity),
                    preopenSnapshot: snapshot(),
                    launchBoundary: boundary
                ),
                .indeterminate(
                    processIdentifier: identity.processIdentifier,
                    reason: .processDidNotStartAfterLaunchBoundary
                )
            )
        }
        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: after.processIdentifier,
                inspection: .live(after),
                preopenSnapshot: snapshot(),
                launchBoundary: boundary
            ),
            .new(after)
        )
    }

    func testInvalidReturnedProcessTimeTupleIsIndeterminate() {
        let identity = workspaceIdentity(
            processIdentifier: 4_123,
            startTimeSeconds: 501,
            startTimeMicroseconds: 1_000_000
        )

        XCTAssertEqual(
            LaunchProcessProvenanceClassifier.classify(
                processIdentifier: identity.processIdentifier,
                inspection: .live(identity),
                preopenSnapshot: snapshot(),
                launchBoundary: boundary()
            ),
            .indeterminate(
                processIdentifier: identity.processIdentifier,
                reason: .unverifiableIdentity
            )
        )
    }

    private func snapshot(
        processes: Set<WorkspaceProcessIdentity> = []
    ) -> WorkspaceProcessSnapshot {
        WorkspaceProcessSnapshot(
            expectedApplication: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(
                    fileURLWithPath: "/Applications/Target.app"
                ),
                bundleIdentifier: "com.example.target"
            ),
            processes: processes
        )
    }

    private func boundary() -> LaunchRequestTimeBoundary {
        // All ordinary fixtures start strictly after this deterministic tuple.
        try! LaunchRequestTimeBoundary(seconds: 0, microseconds: 0)
    }

    private func workspaceIdentity(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64 = 50,
        startTimeMicroseconds: UInt64 = 7,
        bundleURL: URL = URL(
            fileURLWithPath: "/Applications/Target.app"
        ),
        bundleIdentifier: String? = "com.example.target"
    ) -> WorkspaceProcessIdentity {
        WorkspaceProcessIdentity(
            process: ProcessStartIdentity(
                processIdentifier: processIdentifier,
                startTimeSeconds: startTimeSeconds,
                startTimeMicroseconds: startTimeMicroseconds
            ),
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
            )
        )
    }
}
