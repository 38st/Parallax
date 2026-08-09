import AppKit
import Darwin
import Foundation

struct WorkspaceApplicationBundleIdentity: Equatable, Hashable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String?

    init(bundleURL: URL, bundleIdentifier: String?) {
        self.bundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
    }
}

struct WorkspaceProcessIdentity: Equatable, Hashable, Sendable {
    let process: ProcessStartIdentity
    let application: WorkspaceApplicationBundleIdentity

    var processIdentifier: pid_t {
        process.processIdentifier
    }
}

enum WorkspaceProcessIdentityInspection: Equatable, Sendable {
    case live(WorkspaceProcessIdentity)
    case exited
    case indeterminate
}

enum LaunchProcessProvenanceIndeterminacy: Equatable, Sendable {
    case exitedBeforeVerification
    case unverifiableIdentity
    case processIdentifierMismatch
    case unexpectedApplication
    case bundleIdentityChanged
    case processIdentifierReused
    case processDidNotStartAfterLaunchBoundary
}

enum LaunchRequestTimeBoundaryError: Error, Equatable {
    case unavailable
    case invalidSeconds
    case invalidMicroseconds
}

struct LaunchRequestTimeBoundary: Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    init(seconds: Int64, microseconds: Int64) throws {
        guard seconds >= 0 else {
            throw LaunchRequestTimeBoundaryError.invalidSeconds
        }
        guard (0..<1_000_000).contains(microseconds) else {
            throw LaunchRequestTimeBoundaryError.invalidMicroseconds
        }
        self.seconds = UInt64(seconds)
        self.microseconds = UInt64(microseconds)
    }

    func isStrictlyBefore(_ process: ProcessStartIdentity) -> Bool {
        process.startTimeSeconds > seconds
            || (process.startTimeSeconds == seconds
                && process.startTimeMicroseconds > microseconds)
    }
}

protocol LaunchRequestTimeProviding: Sendable {
    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary
}

struct SystemLaunchRequestTimeProvider: LaunchRequestTimeProviding, Sendable {
    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary {
        var current = timeval()
        guard Darwin.gettimeofday(&current, nil) == 0 else {
            throw LaunchRequestTimeBoundaryError.unavailable
        }
        return try LaunchRequestTimeBoundary(
            seconds: Int64(current.tv_sec),
            microseconds: Int64(current.tv_usec)
        )
    }
}

enum LaunchProcessProvenance: Equatable, Sendable {
    case new(WorkspaceProcessIdentity)
    case preExisting(WorkspaceProcessIdentity)
    case indeterminate(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy
    )
}

enum LaunchProcessProvenanceClassifier {
    static func classify(
        processIdentifier: pid_t,
        inspection: WorkspaceProcessIdentityInspection,
        preopenSnapshot: WorkspaceProcessSnapshot,
        launchBoundary: LaunchRequestTimeBoundary
    ) -> LaunchProcessProvenance {
        switch inspection {
        case .live(let identity):
            guard identity.process.isValidGettimeofdayTuple else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .unverifiableIdentity
                )
            }
            guard identity.processIdentifier == processIdentifier else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processIdentifierMismatch
                )
            }
            guard preopenSnapshot.containsExpectedApplication(identity) else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .unexpectedApplication
                )
            }
            if preopenSnapshot.processes.contains(identity) {
                return .preExisting(identity)
            }
            if preopenSnapshot.processes.contains(where: {
                $0.process == identity.process
                    && $0.application != identity.application
            }) {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .bundleIdentityChanged
                )
            }
            if preopenSnapshot.processes.contains(where: {
                $0.processIdentifier == processIdentifier
                    && $0.process != identity.process
            }) {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processIdentifierReused
                )
            }
            guard launchBoundary.isStrictlyBefore(identity.process) else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processDidNotStartAfterLaunchBoundary
                )
            }
            // A same-user process can still start independently after this
            // boundary while Launch Services is handling the request. The
            // full returned identity check and process-local exact claim are
            // the remaining authority for that irreducible external race.
            // `.new` means the exact expected application identity was
            // verified after a complete pre-open snapshot and no process with
            // this PID existed in that snapshot.
            return .new(identity)
        case .exited:
            return .indeterminate(
                processIdentifier: processIdentifier,
                reason: .exitedBeforeVerification
            )
        case .indeterminate:
            return .indeterminate(
                processIdentifier: processIdentifier,
                reason: .unverifiableIdentity
            )
        }
    }
}

struct WorkspaceProcessSnapshot: Equatable, Sendable {
    let expectedApplication: WorkspaceApplicationBundleIdentity
    let processes: Set<WorkspaceProcessIdentity>

    fileprivate func containsExpectedApplication(
        _ identity: WorkspaceProcessIdentity
    ) -> Bool {
        guard identity.application.bundleURL == expectedApplication.bundleURL
        else {
            return false
        }
        guard
            let expectedIdentifier = expectedApplication.bundleIdentifier
        else {
            return false
        }
        return identity.application.bundleIdentifier == expectedIdentifier
    }
}

struct WorkspaceRunningProcessCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let bundleIdentifier: String?
    let isTerminated: Bool
}

protocol WorkspaceRunningProcessListing: Sendable {
    func runningProcesses() throws -> [WorkspaceRunningProcessCandidate]
    func runningProcess(
        processIdentifier: pid_t
    ) throws -> WorkspaceRunningProcessCandidate?
}

struct SystemWorkspaceRunningProcessList:
    WorkspaceRunningProcessListing,
    Sendable
{
    func runningProcesses() -> [WorkspaceRunningProcessCandidate] {
        NSWorkspace.shared.runningApplications.map(candidate)
    }

    func runningProcess(
        processIdentifier: pid_t
    ) -> WorkspaceRunningProcessCandidate? {
        guard
            let application = NSRunningApplication(
                processIdentifier: processIdentifier
            )
        else {
            return nil
        }
        return candidate(application)
    }

    private func candidate(
        _ application: NSRunningApplication
    ) -> WorkspaceRunningProcessCandidate {
        WorkspaceRunningProcessCandidate(
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            bundleIdentifier: application.bundleIdentifier,
            isTerminated: application.isTerminated
        )
    }
}

enum WorkspaceProcessSnapshotError: Error, Equatable {
    case missingExpectedBundleIdentifier
    case processListUnavailable
    case unverifiableProcess(processIdentifier: pid_t)
}

protocol WorkspaceLaunchProcessProvenanceInspecting: Sendable {
    func snapshot(
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) throws -> WorkspaceProcessSnapshot

    func inspectReturnedProcess(
        processIdentifier: pid_t,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentityInspection
}

struct WorkspaceProcessSnapshotter:
    WorkspaceLaunchProcessProvenanceInspecting,
    Sendable
{
    private let processList: any WorkspaceRunningProcessListing
    private let processInspector: any ProcessIdentityInspecting

    init(
        processList: any WorkspaceRunningProcessListing =
            SystemWorkspaceRunningProcessList(),
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) {
        self.processList = processList
        self.processInspector = processInspector
    }

    func snapshot(
        applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> WorkspaceProcessSnapshot {
        let expectedApplication = WorkspaceApplicationBundleIdentity(
            bundleURL: applicationURL,
            bundleIdentifier: expectedBundleIdentifier
        )
        return try snapshot(expectedApplication: expectedApplication)
    }

    func snapshot(
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) throws -> WorkspaceProcessSnapshot {
        guard expectedApplication.bundleIdentifier?.isEmpty == false else {
            throw WorkspaceProcessSnapshotError
                .missingExpectedBundleIdentifier
        }
        let processes: [WorkspaceRunningProcessCandidate]
        do {
            processes = try processList.runningProcesses()
        } catch {
            throw WorkspaceProcessSnapshotError.processListUnavailable
        }

        var identities: Set<WorkspaceProcessIdentity> = []
        for process in processes {
            guard !process.isTerminated else {
                continue
            }
            let initialApplication: WorkspaceApplicationBundleIdentity
            switch applicationDisposition(
                for: process,
                expected: expectedApplication
            ) {
            case .unrelated:
                continue
            case .unverifiable:
                throw unverifiable(process.processIdentifier)
            case .matching(let application):
                initialApplication = application
            }
            if let identity = try verifiedIdentity(
                for: process,
                initialApplication: initialApplication,
                expectedApplication: expectedApplication
            ) {
                if identities.contains(where: {
                    $0.process == identity.process
                        && $0.application != identity.application
                }) {
                    throw unverifiable(process.processIdentifier)
                }
                identities.insert(identity)
            }
        }
        return WorkspaceProcessSnapshot(
            expectedApplication: expectedApplication,
            processes: identities
        )
    }

    func inspectReturnedProcess(
        processIdentifier: pid_t,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentityInspection {
        let firstInspection = processInspector.inspect(
            processIdentifier: processIdentifier
        )
        guard case .live(let firstIdentity) = firstInspection else {
            switch firstInspection {
            case .dead:
                return .exited
            case .ambiguous:
                return .indeterminate
            case .live:
                preconditionFailure("Handled by the preceding guard.")
            }
        }
        guard firstIdentity.processIdentifier == processIdentifier,
              firstIdentity.isValidGettimeofdayTuple
        else {
            return .indeterminate
        }

        let refreshedProcess: WorkspaceRunningProcessCandidate?
        do {
            refreshedProcess = try processList.runningProcess(
                processIdentifier: processIdentifier
            )
        } catch {
            return .indeterminate
        }
        guard
            let refreshedProcess,
            !refreshedProcess.isTerminated
        else {
            switch processInspector.inspect(
                processIdentifier: processIdentifier
            ) {
            case .dead:
                return .exited
            case .live, .ambiguous:
                return .indeterminate
            }
        }
        guard
            refreshedProcess.processIdentifier == processIdentifier,
            case .matching(let application) = applicationDisposition(
                for: refreshedProcess,
                expected: expectedApplication
            )
        else {
            return .indeterminate
        }

        let secondRefreshedProcess: WorkspaceRunningProcessCandidate?
        do {
            secondRefreshedProcess = try processList.runningProcess(
                processIdentifier: processIdentifier
            )
        } catch {
            return .indeterminate
        }
        guard
            let secondRefreshedProcess,
            !secondRefreshedProcess.isTerminated
        else {
            switch processInspector.inspect(
                processIdentifier: processIdentifier
            ) {
            case .dead:
                return .exited
            case .live, .ambiguous:
                return .indeterminate
            }
        }
        guard
            secondRefreshedProcess.processIdentifier == processIdentifier,
            case .matching(let secondApplication) = applicationDisposition(
                for: secondRefreshedProcess,
                expected: expectedApplication
            ),
            secondApplication == application
        else {
            return .indeterminate
        }

        switch processInspector.inspect(processIdentifier: processIdentifier) {
        case .live(let secondIdentity):
            guard secondIdentity == firstIdentity,
                  secondIdentity.isValidGettimeofdayTuple
            else {
                return .indeterminate
            }
            return .live(
                WorkspaceProcessIdentity(
                    process: firstIdentity,
                    application: application
                )
            )
        case .dead:
            return .exited
        case .ambiguous:
            return .indeterminate
        }
    }

    private func verifiedIdentity(
        for process: WorkspaceRunningProcessCandidate,
        initialApplication: WorkspaceApplicationBundleIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) throws -> WorkspaceProcessIdentity? {
        let firstInspection = processInspector.inspect(
            processIdentifier: process.processIdentifier
        )
        guard case .live(let firstIdentity) = firstInspection else {
            switch firstInspection {
            case .dead:
                return nil
            case .ambiguous:
                throw unverifiable(process.processIdentifier)
            case .live:
                preconditionFailure("Handled by the preceding guard.")
            }
        }
        guard firstIdentity.processIdentifier == process.processIdentifier,
              firstIdentity.isValidGettimeofdayTuple
        else {
            throw unverifiable(process.processIdentifier)
        }

        let refreshedProcess: WorkspaceRunningProcessCandidate?
        do {
            refreshedProcess = try processList.runningProcess(
                processIdentifier: process.processIdentifier
            )
        } catch {
            throw WorkspaceProcessSnapshotError.processListUnavailable
        }
        guard
            let refreshedProcess,
            !refreshedProcess.isTerminated
        else {
            switch processInspector.inspect(
                processIdentifier: process.processIdentifier
            ) {
            case .dead:
                return nil
            case .live, .ambiguous:
                throw unverifiable(process.processIdentifier)
            }
        }
        guard
            refreshedProcess.processIdentifier == process.processIdentifier,
            case .matching(let refreshedApplication) =
                applicationDisposition(
                    for: refreshedProcess,
                    expected: expectedApplication
                ),
            refreshedApplication == initialApplication
        else {
            throw unverifiable(process.processIdentifier)
        }

        switch processInspector.inspect(
            processIdentifier: process.processIdentifier
        ) {
        case .live(let secondIdentity):
            guard secondIdentity == firstIdentity,
                  secondIdentity.isValidGettimeofdayTuple
            else {
                throw unverifiable(process.processIdentifier)
            }
            return WorkspaceProcessIdentity(
                process: firstIdentity,
                application: initialApplication
            )
        case .dead:
            return nil
        case .ambiguous:
            throw unverifiable(process.processIdentifier)
        }
    }

    private func applicationIdentity(
        for process: WorkspaceRunningProcessCandidate
    ) -> WorkspaceApplicationBundleIdentity? {
        guard let bundleURL = process.bundleURL else { return nil }
        return WorkspaceApplicationBundleIdentity(
            bundleURL: bundleURL,
            bundleIdentifier: process.bundleIdentifier
        )
    }

    private enum ApplicationDisposition {
        case unrelated
        case matching(WorkspaceApplicationBundleIdentity)
        case unverifiable
    }

    private func applicationDisposition(
        for process: WorkspaceRunningProcessCandidate,
        expected: WorkspaceApplicationBundleIdentity
    ) -> ApplicationDisposition {
        let application = applicationIdentity(for: process)
        let pathMatches = application?.bundleURL == expected.bundleURL
        let identifierMatches: Bool
        if let expectedIdentifier = expected.bundleIdentifier {
            identifierMatches =
                process.bundleIdentifier == expectedIdentifier
        } else {
            identifierMatches = false
        }

        if pathMatches {
            guard let application else { return .unverifiable }
            if let expectedIdentifier = expected.bundleIdentifier,
               application.bundleIdentifier != expectedIdentifier
            {
                return .unverifiable
            }
            return .matching(application)
        }
        if identifierMatches {
            // A process claiming the expected bundle identifier without the
            // exact canonical bundle URL is not safe to omit from the target
            // application's pre-open snapshot.
            return .unverifiable
        }
        return .unrelated
    }

    private func unverifiable(
        _ processIdentifier: pid_t
    ) -> WorkspaceProcessSnapshotError {
        .unverifiableProcess(processIdentifier: processIdentifier)
    }
}

private extension ProcessStartIdentity {
    var isValidGettimeofdayTuple: Bool {
        processIdentifier > 0 && startTimeMicroseconds < 1_000_000
    }
}
