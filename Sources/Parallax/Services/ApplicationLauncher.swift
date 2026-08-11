import AppKit
import Foundation

struct WorkspaceApplicationLauncher: PreparedTrackedApplicationLaunching {
    private let opener: any WorkspaceApplicationOpening
    private let terminationObserver:
        any RunningApplicationTerminationObserving
    private let processProvenanceInspector:
        any WorkspaceLaunchProcessProvenanceInspecting
    private let launchRequestTimeProvider: any LaunchRequestTimeProviding
    private let processSupervisor: WorkspaceProcessSupervisor
    private let launchAuthority: WorkspaceApplicationLaunchAuthority

    init() {
        let inspector = WorkspaceProcessSnapshotter()
        let applicationOpeningDependencies =
            makeNSWorkspaceApplicationOpeningDependencies()
        opener = applicationOpeningDependencies.opener
        terminationObserver =
            applicationOpeningDependencies.terminationObserver
        processProvenanceInspector = inspector
        processSupervisor = WorkspaceProcessSupervisor(inspector: inspector)
        launchRequestTimeProvider = SystemLaunchRequestTimeProvider()
        launchAuthority = .shared
    }

    init(
        opener: any WorkspaceApplicationOpening,
        terminationObserver: any RunningApplicationTerminationObserving,
        processProvenanceInspector:
            any WorkspaceLaunchProcessProvenanceInspecting,
        launchRequestTimeProvider: any LaunchRequestTimeProviding =
            SystemLaunchRequestTimeProvider(),
        processSupervisor: WorkspaceProcessSupervisor? = nil,
        launchAuthority: WorkspaceApplicationLaunchAuthority =
            WorkspaceApplicationLaunchAuthority()
    ) {
        self.opener = opener
        self.terminationObserver = terminationObserver
        self.processProvenanceInspector = processProvenanceInspector
        self.launchRequestTimeProvider = launchRequestTimeProvider
        self.processSupervisor = processSupervisor
            ?? WorkspaceProcessSupervisor(
                inspector: processProvenanceInspector
            )
        self.launchAuthority = launchAuthority
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        throw LaunchError.preparationRequired
    }

    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        throw LaunchError.trackedLaunchRequired
    }

    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void = {
                _ in
            },
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        throw LaunchError.preparationRequired
    }

    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void = {
                _ in
            },
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        let identity = ProfileActivityIdentity(
            applicationID: prepared.applicationID,
            applicationStorageID: prepared.applicationStorageID,
            profileID: prepared.profileID,
            profileStorageID: prepared.profileStorageID
        )
        let lease = try activityRegistry.acquireLaunchLease(
            identity: identity,
            requestID: prepared.requestID,
            concurrentLaunchPolicy: concurrentLaunchPolicy
        )
        let launch = TrackedApplicationLaunch(
            requestID: prepared.requestID,
            identity: identity,
            activityRegistry: activityRegistry,
            activityLease: lease,
            expectedApplication: prepared.applicationIdentity,
            processProvenanceInspector: processProvenanceInspector,
            processSupervisor: processSupervisor,
            launchAuthority: launchAuthority,
            lifecycleHandler: lifecycleHandler,
            eventHandler: eventHandler
        )
        TrackedLaunchSessionDriver.didRequest(launch)
        do {
            try activityRegistry.markLaunchOpening(
                requestID: prepared.requestID
            )
        } catch {
            launch.didFail(error)
            throw error
        }
        TrackedLaunchSessionDriver.didBeginOpening(launch)

        let immediateError = WorkspaceLaunchImmediateErrorBox()
        launchAuthority.enqueueSubmission(
            for: prepared.applicationIdentity,
            requestID: prepared.requestID
        ) { [
            opener,
            processProvenanceInspector,
            launchRequestTimeProvider,
            terminationObserver
        ] submissionSlot in
            let configuration = configuration(for: prepared)
            let preopenSnapshot: WorkspaceProcessSnapshot
            do {
                preopenSnapshot = try processProvenanceInspector.snapshot(
                    expectedApplication: prepared.applicationIdentity
                )
            } catch {
                let provenanceError =
                    LaunchError.launchProcessProvenanceUnavailable
                immediateError.store(provenanceError)
                launch.didFail(provenanceError)
                submissionSlot.complete()
                return
            }

            let launchBoundary: LaunchRequestTimeBoundary
            do {
                // This integer gettimeofday-compatible tuple is captured at
                // the last safe point before handing control to Launch
                // Services. Clock rollback can only cause a safe refusal.
                launchBoundary =
                    try launchRequestTimeProvider.launchRequestBoundary()
            } catch {
                let boundaryError = LaunchError.launchTimeBoundaryUnavailable
                immediateError.store(boundaryError)
                launch.didFail(boundaryError)
                submissionSlot.complete()
                return
            }

            let openerResultGate = WorkspaceApplicationOpenerResultGate()
            opener.openApplication(
                at: prepared.applicationURL,
                configuration: configuration
            ) { result in
                guard openerResultGate.claimResult() else { return }
                switch result {
                case .success(let runningApplication):
                    let inspection =
                        processProvenanceInspector.inspectReturnedProcess(
                            processIdentifier:
                                runningApplication.processIdentifier,
                            expectedApplication: prepared.applicationIdentity
                        )
                    let provenance =
                        LaunchProcessProvenanceClassifier.classify(
                            processIdentifier:
                                runningApplication.processIdentifier,
                            inspection: inspection,
                            preopenSnapshot: preopenSnapshot,
                            launchBoundary: launchBoundary
                        )
                    TrackedLaunchSessionDriver.didOpen(
                        launch,
                        runningApplication,
                        provenance: provenance,
                        observer: terminationObserver
                    )
                    submissionSlot.complete()
                case .failure(let error):
                    TrackedLaunchSessionDriver.didReceiveUnknownOpenOutcome(
                        launch,
                        error,
                        submissionSlot: submissionSlot
                    )
                }
            }
        }
        if let error = immediateError.take() {
            throw error
        }
        return launch
    }

    private func configuration(
        for prepared: PreparedLaunch
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = prepared.arguments
        configuration.environment = prepared.environment
        return configuration
    }
}

private final class WorkspaceLaunchImmediateErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ error: Error) {
        lock.withLock {
            if self.error == nil {
                self.error = error
            }
        }
    }

    func take() -> Error? {
        lock.withLock {
            let error = error
            self.error = nil
            return error
        }
    }
}

private final class WorkspaceApplicationOpenerResultGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var hasClaimedResult = false

    func claimResult() -> Bool {
        lock.withLock {
            guard !hasClaimedResult else { return false }
            hasClaimedResult = true
            return true
        }
    }
}
