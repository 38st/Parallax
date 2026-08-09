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
                preopenSnapshot: snapshot(processes: [identity])
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
                preopenSnapshot: snapshot()
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
                preopenSnapshot: snapshot(processes: [prior])
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
                preopenSnapshot: snapshot(processes: [prior])
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
                )
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
                    preopenSnapshot: snapshot()
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
                preopenSnapshot: incompleteExpectedIdentity
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
                preopenSnapshot: snapshot()
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
                preopenSnapshot: snapshot()
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
                preopenSnapshot: snapshot()
            ),
            .indeterminate(
                processIdentifier: returnedPID,
                reason: .processIdentifierMismatch
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
