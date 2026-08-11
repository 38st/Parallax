import AppKit
import Foundation
@testable import Parallax

final class LaunchTestLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func mutate(_ mutation: (inout Value) -> Void) {
        lock.withLock { mutation(&storage) }
    }
}

final class LaunchTestRecorder<Element>: @unchecked Sendable {
    private let storage = LaunchTestLocked<[Element]>([])

    var values: [Element] { storage.value }

    func append(_ element: Element) {
        storage.mutate { $0.append(element) }
    }
}

final class ScriptedWorkspaceApplicationOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completions: [
        @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ] = []
    private var lastCompletion:
        (@Sendable (Result<any RunningApplicationInstance, Error>) -> Void)?
    private var submittedOpenCount = 0
    private var recordedActivates: Bool?
    private var recordedArguments: [String]?
    private var recordedEnvironment: [String: String]?
    private var immediateResult:
        Result<any RunningApplicationInstance, Error>?

    var synchronousResult: Result<any RunningApplicationInstance, Error>? {
        get { lock.withLock { immediateResult } }
        set { lock.withLock { immediateResult = newValue } }
    }

    var openCount: Int { lock.withLock { submittedOpenCount } }
    var pendingCompletionCount: Int { lock.withLock { completions.count } }
    var lastActivates: Bool? { lock.withLock { recordedActivates } }
    var lastArguments: [String]? { lock.withLock { recordedArguments } }
    var lastEnvironment: [String: String]? {
        lock.withLock { recordedEnvironment }
    }

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        let immediate = lock.withLock {
            submittedOpenCount += 1
            recordedActivates = configuration.activates
            recordedArguments = configuration.arguments
            recordedEnvironment = configuration.environment
            lastCompletion = completion
            if immediateResult == nil {
                completions.append(completion)
            }
            return immediateResult
        }
        if let immediate { completion(immediate) }
    }

    func complete(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        completeNext(result)
    }

    func completeNext(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        let completion = lock.withLock {
            completions.isEmpty ? nil : completions.removeFirst()
        }
        completion?(result)
    }

    func replayLast(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        lock.withLock { lastCompletion }?(result)
    }
}

final class ExactRunningApplicationHandle:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var terminated: Bool
    private var activationRequests = 0

    init(processIdentifier: pid_t, isTerminated: Bool = false) {
        self.processIdentifier = processIdentifier
        terminated = isTerminated
    }

    var isTerminated: Bool { lock.withLock { terminated } }
    var activationCount: Int { lock.withLock { activationRequests } }

    func requestActivation(of identity: WorkspaceProcessIdentity) {
        lock.withLock { activationRequests += 1 }
    }

    func markTerminated() {
        lock.withLock { terminated = true }
    }
}

final class TestRunningApplicationTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: (@Sendable () -> Void)? = nil) {
        self.cancellation = cancellation
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let action = lock.withLock {
            guard !cancelled else {
                return Optional<@Sendable () -> Void>.none
            }
            cancelled = true
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}

final class TestRunningApplicationTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private struct Entry {
        let observation: TestRunningApplicationTerminationObservation
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let processState: TestWorkspaceProcessState
    private var entries: [ObjectIdentifier: Entry] = [:]
    var terminateDuringObservation = false
    private(set) var lastObservation:
        TestRunningApplicationTerminationObservation?

    init(processState: TestWorkspaceProcessState) {
        self.processState = processState
    }

    convenience init(state: TestWorkspaceProcessState) {
        self.init(processState: state)
    }

    var observationCount: Int { lock.withLock { entries.count } }

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        let identifier = ObjectIdentifier(application)
        let observation = TestRunningApplicationTerminationObservation {
            [weak self] in
            self?.removeObservation(identifier: identifier)
        }
        lock.withLock {
            entries[identifier] = Entry(
                observation: observation,
                callback: handler
            )
            lastObservation = observation
        }
        if terminateDuringObservation {
            processState.markExited(
                processIdentifier: application.processIdentifier
            )
            handler()
        }
        return observation
    }

    func terminate(_ application: ExactRunningApplicationHandle) {
        application.markTerminated()
        processState.markExited(
            processIdentifier: application.processIdentifier
        )
        let entry = lock.withLock {
            entries[ObjectIdentifier(application)]
        }
        guard entry?.observation.isCancelled == false else { return }
        entry?.callback()
    }

    private func removeObservation(identifier: ObjectIdentifier) {
        _ = lock.withLock { entries.removeValue(forKey: identifier) }
    }
}

final class TestWorkspaceProcessState:
    WorkspaceLaunchProcessProvenanceInspecting,
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    var snapshotError: WorkspaceProcessSnapshotError?
    var preexistingProcesses: Set<WorkspaceProcessIdentity> = []
    var processInspections: [pid_t: ProcessIdentityInspection] = [:]
    var returnedInspections:
        [pid_t: [WorkspaceProcessIdentityInspection]] = [:]
    var onReturnedInspection: ((Int, pid_t) -> Void)?
    var onSnapshot: (() -> Void)?
    private var returnedInspectionCount = 0

    func snapshot(
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) throws -> WorkspaceProcessSnapshot {
        onSnapshot?()
        return try lock.withLock {
            if let snapshotError { throw snapshotError }
            return WorkspaceProcessSnapshot(
                expectedApplication: expectedApplication,
                processes: preexistingProcesses
            )
        }
    }

    func inspectReturnedProcess(
        processIdentifier: pid_t,
        expectedApplication: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentityInspection {
        let countAndInspection = lock.withLock {
            returnedInspectionCount += 1
            let count = returnedInspectionCount
            if var inspections = returnedInspections[processIdentifier],
               !inspections.isEmpty
            {
                let inspection = inspections.removeFirst()
                returnedInspections[processIdentifier] = inspections
                return (count, Optional(inspection))
            }
            return (count, Optional<WorkspaceProcessIdentityInspection>.none)
        }
        onReturnedInspection?(countAndInspection.0, processIdentifier)
        if let inspection = countAndInspection.1 { return inspection }
        switch inspect(processIdentifier: processIdentifier) {
        case .live(let process):
            return .live(
                WorkspaceProcessIdentity(
                    process: process,
                    application: expectedApplication
                )
            )
        case .dead:
            return .exited
        case .ambiguous:
            return .indeterminate
        }
    }

    func inspect(
        processIdentifier: pid_t
    ) -> ProcessIdentityInspection {
        lock.withLock {
            processInspections[processIdentifier]
                ?? .live(processIdentity(processIdentifier: processIdentifier))
        }
    }

    func processIdentity(processIdentifier: pid_t) -> ProcessStartIdentity {
        ProcessStartIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: 10_000 + UInt64(processIdentifier),
            startTimeMicroseconds: UInt64(processIdentifier % 1_000_000)
        )
    }

    func workspaceIdentity(
        processIdentifier: pid_t,
        application: WorkspaceApplicationBundleIdentity
    ) -> WorkspaceProcessIdentity {
        WorkspaceProcessIdentity(
            process: processIdentity(processIdentifier: processIdentifier),
            application: application
        )
    }

    func markExited(processIdentifier: pid_t) {
        lock.withLock {
            processInspections[processIdentifier] = .dead
            returnedInspections[processIdentifier] = [.exited]
        }
    }
}

final class ProvenanceTestTimeProvider:
    LaunchRequestTimeProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var boundary: LaunchRequestTimeBoundary
    var failure: LaunchRequestTimeBoundaryError?
    var onBoundary: (() -> Void)?

    init(seconds: Int64 = 0, microseconds: Int64 = 0) {
        boundary = try! LaunchRequestTimeBoundary(
            seconds: seconds,
            microseconds: microseconds
        )
    }

    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary {
        onBoundary?()
        return try lock.withLock {
            if let failure { throw failure }
            return boundary
        }
    }
}

enum ProvenanceFixtureError: LocalizedError {
    case openFailed

    var errorDescription: String? { "open failed" }
}

extension ProfileLaunchLifecycleState {
    var isRunningForTest: Bool {
        switch self {
        case .running, .runningDegraded:
            true
        case .requested, .launching, .terminating, .terminated, .failed:
            false
        }
    }
}

final class ProvenanceHarness {
    let state = TestWorkspaceProcessState()
    let authority = WorkspaceApplicationLaunchAuthority()
    let opener = ScriptedWorkspaceApplicationOpener()
    let timeProvider: ProvenanceTestTimeProvider

    init(
        timeProvider: ProvenanceTestTimeProvider =
            ProvenanceTestTimeProvider()
    ) {
        self.timeProvider = timeProvider
    }

    lazy var terminationObserver =
        TestRunningApplicationTerminationObserver(state: state)
    lazy var launcher = WorkspaceApplicationLauncher(
        opener: opener,
        terminationObserver: terminationObserver,
        processProvenanceInspector: state,
        launchRequestTimeProvider: timeProvider,
        launchAuthority: authority
    )
    lazy var registry = ProfileActivityRegistry(processInspector: state)
}
