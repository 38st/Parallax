import XCTest
@testable import Parallax

final class WorkspaceProcessSnapshotterTests: XCTestCase {
    func testSnapshotCapturesOnlyLiveExactBundleIdentities() throws {
        let targetURL = URL(fileURLWithPath: "/Applications/Target.app")
        let target = candidate(processIdentifier: 5_101, bundleURL: targetURL)
        let secondTarget = candidate(
            processIdentifier: 5_102,
            bundleURL: targetURL
        )
        let wrongIdentifier = candidate(
            processIdentifier: 5_103,
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.wrong"
        )
        let other = candidate(
            processIdentifier: 5_104,
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "com.example.other"
        )
        let terminated = candidate(
            processIdentifier: 5_105,
            bundleURL: targetURL,
            isTerminated: true
        )
        let firstIdentity = processIdentity(
            processIdentifier: target.processIdentifier
        )
        let secondIdentity = processIdentity(
            processIdentifier: secondTarget.processIdentifier
        )
        let snapshotter = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [
                    target,
                    secondTarget,
                    wrongIdentifier,
                    other,
                    terminated,
                ]
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    target.processIdentifier: [
                        .live(firstIdentity),
                        .live(firstIdentity),
                    ],
                    secondTarget.processIdentifier: [
                        .live(secondIdentity),
                        .live(secondIdentity),
                    ],
                ]
            )
        )

        XCTAssertEqual(
            try snapshotter.snapshot(
                applicationURL: targetURL,
                expectedBundleIdentifier: "com.example.target"
            ).processes,
            [
                workspaceIdentity(process: firstIdentity, candidate: target),
                workspaceIdentity(
                    process: secondIdentity,
                    candidate: secondTarget
                ),
            ]
        )
    }

    func testSnapshotAcceptsCanonicalSymlinkEquivalentBundle() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let targetURL = temporaryRoot.appendingPathComponent("Target.app")
        let aliasURL = temporaryRoot.appendingPathComponent("Alias.app")
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: temporaryRoot.path)
            )
        }
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: targetURL
        )
        let process = candidate(
            processIdentifier: 5_106,
            bundleURL: aliasURL
        )
        let identity = processIdentity(
            processIdentifier: process.processIdentifier
        )
        let snapshotter = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(processes: [process]),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    process.processIdentifier: [
                        .live(identity),
                        .live(identity),
                    ]
                ]
            )
        )

        XCTAssertEqual(
            try snapshotter.snapshot(
                applicationURL: targetURL,
                expectedBundleIdentifier: "com.example.target"
            ).processes,
            [workspaceIdentity(process: identity, candidate: process)]
        )
    }

    func testDeadMatchingProcessIsAnIgnorableExitRace() throws {
        let process = candidate(processIdentifier: 5_107)
        let snapshotter = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(processes: [process]),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [process.processIdentifier: [.dead]]
            )
        )

        XCTAssertEqual(
            try snapshotter.snapshot(
                applicationURL: process.bundleURL!,
                expectedBundleIdentifier: process.bundleIdentifier!
            ).processes,
            []
        )
    }

    func testMatchingPathWithMissingOrConflictingIdentifierFailsClosed() {
        let missingIdentifier = candidate(
            processIdentifier: 5_114,
            bundleIdentifier: nil
        )
        let conflictingIdentifier = candidate(
            processIdentifier: 5_115,
            bundleIdentifier: "com.example.other"
        )

        for process in [missingIdentifier, conflictingIdentifier] {
            let snapshotter = WorkspaceProcessSnapshotter(
                processList: SnapshotProcessList(processes: [process]),
                processInspector: SequencedSnapshotProcessInspector(
                    inspections: [:]
                )
            )
            assertUnverifiable(snapshotter, process: process)
        }
    }

    func testMatchingIdentifierWithMissingOrChangedPathFailsClosed() {
        let missingPath = candidate(
            processIdentifier: 5_116,
            bundleURL: nil
        )
        let changedPath = candidate(
            processIdentifier: 5_117,
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app")
        )

        for process in [missingPath, changedPath] {
            let snapshotter = WorkspaceProcessSnapshotter(
                processList: SnapshotProcessList(processes: [process]),
                processInspector: SequencedSnapshotProcessInspector(
                    inspections: [:]
                )
            )
            XCTAssertThrowsError(
                try snapshotter.snapshot(
                    applicationURL: URL(
                        fileURLWithPath: "/Applications/Target.app"
                    ),
                    expectedBundleIdentifier: "com.example.target"
                )
            ) {
                XCTAssertEqual(
                    $0 as? WorkspaceProcessSnapshotError,
                    .unverifiableProcess(
                        processIdentifier: process.processIdentifier
                    )
                )
            }
        }
    }

    func testAmbiguousOrMismatchedMatchingProcessFailsClosed() {
        let process = candidate(processIdentifier: 5_108)
        let ambiguous = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(processes: [process]),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [process.processIdentifier: [.ambiguous]]
            )
        )
        let mismatched = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(processes: [process]),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    process.processIdentifier: [
                        .live(processIdentity(processIdentifier: 5_109))
                    ]
                ]
            )
        )

        assertUnverifiable(ambiguous, process: process)
        assertUnverifiable(mismatched, process: process)
    }

    func testPIDReuseDuringSnapshotFailsClosed() {
        let process = candidate(processIdentifier: 5_110)
        let first = processIdentity(
            processIdentifier: process.processIdentifier,
            startTimeSeconds: 50,
            startTimeMicroseconds: 9
        )
        let reused = processIdentity(
            processIdentifier: process.processIdentifier,
            startTimeSeconds: 50,
            startTimeMicroseconds: 10
        )
        let snapshotter = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(processes: [process]),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    process.processIdentifier: [.live(first), .live(reused)]
                ]
            )
        )

        assertUnverifiable(snapshotter, process: process)
    }

    func testPIDReboundToDifferentBundleOrIdentifierFailsClosed() {
        let process = candidate(processIdentifier: 5_111)
        let identity = processIdentity(
            processIdentifier: process.processIdentifier
        )
        let reboundURL = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                refreshedProcesses: [
                    candidate(
                        processIdentifier: process.processIdentifier,
                        bundleURL: URL(
                            fileURLWithPath: "/Applications/Other.app"
                        )
                    )
                ]
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [process.processIdentifier: [.live(identity)]]
            )
        )
        let reboundIdentifier = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                refreshedProcesses: [
                    candidate(
                        processIdentifier: process.processIdentifier,
                        bundleIdentifier: "com.example.rebound"
                    )
                ]
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [process.processIdentifier: [.live(identity)]]
            )
        )

        assertUnverifiable(reboundURL, process: process)
        assertUnverifiable(reboundIdentifier, process: process)
    }

    func testProcessExitDuringRefreshIsAnIgnorableRace() throws {
        let process = candidate(processIdentifier: 5_112)
        let identity = processIdentity(
            processIdentifier: process.processIdentifier
        )
        let snapshotter = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                refreshedProcesses: []
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    process.processIdentifier: [.live(identity), .dead]
                ]
            )
        )

        XCTAssertEqual(
            try snapshotter.snapshot(
                applicationURL: process.bundleURL!,
                expectedBundleIdentifier: process.bundleIdentifier!
            ).processes,
            []
        )
    }

    func testMissingLiveRefreshAndProcessListFailuresFailClosed() {
        let process = candidate(processIdentifier: 5_113)
        let identity = processIdentity(
            processIdentifier: process.processIdentifier
        )
        let missingButLive = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                refreshedProcesses: []
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [
                    process.processIdentifier: [
                        .live(identity),
                        .live(identity),
                    ]
                ]
            )
        )
        let initialFailure = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                failsInitialList: true
            ),
            processInspector: SequencedSnapshotProcessInspector(inspections: [:])
        )
        let refreshFailure = WorkspaceProcessSnapshotter(
            processList: SnapshotProcessList(
                processes: [process],
                failsRefresh: true
            ),
            processInspector: SequencedSnapshotProcessInspector(
                inspections: [process.processIdentifier: [.live(identity)]]
            )
        )

        assertUnverifiable(missingButLive, process: process)
        XCTAssertThrowsError(
            try initialFailure.snapshot(
                applicationURL: process.bundleURL!,
                expectedBundleIdentifier: process.bundleIdentifier!
            )
        ) {
            XCTAssertEqual(
                $0 as? WorkspaceProcessSnapshotError,
                .processListUnavailable
            )
        }
        XCTAssertThrowsError(
            try refreshFailure.snapshot(
                applicationURL: process.bundleURL!,
                expectedBundleIdentifier: process.bundleIdentifier!
            )
        ) {
            XCTAssertEqual(
                $0 as? WorkspaceProcessSnapshotError,
                .processListUnavailable
            )
        }
    }

    private func assertUnverifiable(
        _ snapshotter: WorkspaceProcessSnapshotter,
        process: WorkspaceRunningProcessCandidate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try snapshotter.snapshot(
                applicationURL: URL(
                    fileURLWithPath: "/Applications/Target.app"
                ),
                expectedBundleIdentifier: "com.example.target"
            ),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? WorkspaceProcessSnapshotError,
                .unverifiableProcess(
                    processIdentifier: process.processIdentifier
                ),
                file: file,
                line: line
            )
        }
    }

    private func candidate(
        processIdentifier: pid_t,
        bundleURL: URL? = URL(
            fileURLWithPath: "/Applications/Target.app"
        ),
        bundleIdentifier: String? = "com.example.target",
        isTerminated: Bool = false
    ) -> WorkspaceRunningProcessCandidate {
        WorkspaceRunningProcessCandidate(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            isTerminated: isTerminated
        )
    }

    private func processIdentity(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64 = 50,
        startTimeMicroseconds: UInt64 = 9
    ) -> ProcessStartIdentity {
        ProcessStartIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: startTimeMicroseconds
        )
    }

    private func workspaceIdentity(
        process: ProcessStartIdentity,
        candidate: WorkspaceRunningProcessCandidate
    ) -> WorkspaceProcessIdentity {
        WorkspaceProcessIdentity(
            process: process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: candidate.bundleURL!,
                bundleIdentifier: candidate.bundleIdentifier
            )
        )
    }
}

private enum SnapshotFixtureError: Error {
    case unavailable
}

private struct SnapshotProcessList:
    WorkspaceRunningProcessListing,
    Sendable
{
    let processes: [WorkspaceRunningProcessCandidate]
    let refreshedProcesses: [WorkspaceRunningProcessCandidate]?
    let failsInitialList: Bool
    let failsRefresh: Bool

    init(
        processes: [WorkspaceRunningProcessCandidate],
        refreshedProcesses: [WorkspaceRunningProcessCandidate]? = nil,
        failsInitialList: Bool = false,
        failsRefresh: Bool = false
    ) {
        self.processes = processes
        self.refreshedProcesses = refreshedProcesses
        self.failsInitialList = failsInitialList
        self.failsRefresh = failsRefresh
    }

    func runningProcesses() throws -> [WorkspaceRunningProcessCandidate] {
        if failsInitialList { throw SnapshotFixtureError.unavailable }
        return processes
    }

    func runningProcess(
        processIdentifier: pid_t
    ) throws -> WorkspaceRunningProcessCandidate? {
        if failsRefresh { throw SnapshotFixtureError.unavailable }
        return (refreshedProcesses ?? processes).first {
            $0.processIdentifier == processIdentifier
        }
    }
}

private final class SequencedSnapshotProcessInspector:
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var inspections: [pid_t: [ProcessIdentityInspection]]

    init(inspections: [pid_t: [ProcessIdentityInspection]]) {
        self.inspections = inspections
    }

    func inspect(
        processIdentifier: pid_t
    ) -> ProcessIdentityInspection {
        lock.withLock {
            guard
                var processInspections = inspections[processIdentifier],
                !processInspections.isEmpty
            else {
                return .ambiguous
            }
            let result = processInspections.removeFirst()
            inspections[processIdentifier] = processInspections
            return result
        }
    }
}
