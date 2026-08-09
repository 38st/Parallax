import AppKit
import Foundation

protocol ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws
}

protocol TrackedApplicationLaunching: ApplicationLaunching {
    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler: @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
}

extension TrackedApplicationLaunching {
    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        eventHandler: @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        try launchTracked(
            application: application,
            profile: profile,
            requestID: requestID,
            activityRegistry: activityRegistry,
            concurrentLaunchPolicy: .deny,
            lifecycleHandler: { _ in },
            eventHandler: eventHandler
        )
    }
}

protocol PreparedApplicationLaunching: ApplicationLaunching {
    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws
}

protocol PreparedTrackedApplicationLaunching:
    PreparedApplicationLaunching,
    TrackedApplicationLaunching
{
    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
}

extension PreparedTrackedApplicationLaunching {
    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        try launchTracked(
            prepared: prepared,
            activityRegistry: activityRegistry,
            concurrentLaunchPolicy: .deny,
            lifecycleHandler: { _ in },
            eventHandler: eventHandler
        )
    }
}

enum TrackedApplicationLaunchEvent: Equatable, Sendable {
    case requested(requestID: UUID)
    case running(requestID: UUID, processIdentifier: pid_t)
    case trackingDegraded(
        requestID: UUID,
        processIdentifier: pid_t,
        message: String
    )
    case terminated(requestID: UUID, processIdentifier: pid_t)
    case failed(requestID: UUID, message: String)
}

enum ProfileLaunchLifecycleState: Equatable, Sendable {
    case requested
    case launching
    case running(processIdentifier: pid_t)
    case runningDegraded(processIdentifier: pid_t, message: String)
    case terminating(processIdentifier: pid_t)
    case terminated(processIdentifier: pid_t)
    case failed(message: String)

    var isTerminal: Bool {
        switch self {
        case .terminated, .failed:
            true
        case .requested, .launching, .running, .runningDegraded, .terminating:
            false
        }
    }
}

enum ManagedProcessTerminationDisposition:
    String,
    Codable,
    Equatable,
    Sendable
{
    case expected
    case unexpected
}

enum ProfileLaunchOpeningDisposition: Equatable, Sendable {
    case pending
    case outcomeUnknownAfterError(message: String)
    case preExistingSingletonRefused(processIdentifier: pid_t)
    case provenanceIndeterminate(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy
    )
}

struct ProfileLaunchLifecycleSnapshot: Equatable, Sendable {
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let state: ProfileLaunchLifecycleState
    let processIdentity: WorkspaceProcessIdentity?
    let openingDisposition: ProfileLaunchOpeningDisposition
    let terminationDisposition:
        ManagedProcessTerminationDisposition?

    init(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        state: ProfileLaunchLifecycleState,
        processIdentity: WorkspaceProcessIdentity? = nil,
        openingDisposition: ProfileLaunchOpeningDisposition = .pending,
        terminationDisposition:
            ManagedProcessTerminationDisposition? = nil
    ) {
        self.requestID = requestID
        self.identity = identity
        self.state = state
        self.processIdentity = processIdentity
        self.openingDisposition = openingDisposition
        self.terminationDisposition = terminationDisposition
    }

    /// Integration boundary used by stores/scenes before presenting a
    /// request-scoped update. A removed or replaced logical/storage identity
    /// cannot match accidentally.
    func matches(
        application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        application.id == identity.applicationID
            && application.storageID == identity.applicationStorageID
            && profile.id == identity.profileID
            && profile.storageID == identity.profileStorageID
            && application.profiles.contains {
                $0.id == identity.profileID
                    && $0.storageID == identity.profileStorageID
            }
    }
}

protocol RunningApplicationInstance: AnyObject, Sendable {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var workspaceApplication: NSRunningApplication? { get }
    func requestActivation(of identity: WorkspaceProcessIdentity)
}

extension RunningApplicationInstance {
    var workspaceApplication: NSRunningApplication? { nil }
    func requestActivation(of identity: WorkspaceProcessIdentity) {}
}

struct WorkspaceVerifiedActivationRequester: Sendable {
    private let operation:
        @MainActor @Sendable (WorkspaceProcessIdentity) -> Void
    private let schedule:
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    init(
        operation:
            @escaping @MainActor @Sendable (WorkspaceProcessIdentity) -> Void = {
                identity in
                _ = NSWorkspaceApplicationProcessProvider()
                    .requestActivation(of: identity)
            },
        schedule:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { operation in
                Task { @MainActor in operation() }
            }
    ) {
        self.operation = operation
        self.schedule = schedule
    }

    func requestActivation(of identity: WorkspaceProcessIdentity) {
        schedule {
            operation(identity)
        }
    }
}

protocol WorkspaceApplicationOpening: Sendable {
    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    )
}

protocol RunningApplicationTerminationObservation: AnyObject, Sendable {
    func cancel()
}

protocol RunningApplicationTerminationObserving: Sendable {
    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation
}

enum LaunchError: LocalizedError {
    case missingApplication(String)
    case applicationDidNotOpen(String)
    case preparationRequired
    case trackedLaunchRequired
    case launchProcessProvenanceUnavailable
    case launchTimeBoundaryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingApplication(let path):
            String(localized: "The application could not be found at \(path).")
        case .applicationDidNotOpen(let path):
            String(localized: "The application at \(path) did not open.")
        case .preparationRequired:
            String(
                localized:
                    "The launch configuration must be validated before opening the application."
            )
        case .trackedLaunchRequired:
            String(
                localized:
                    "The launch configuration must be validated before opening the application."
            )
        case .launchProcessProvenanceUnavailable,
             .launchTimeBoundaryUnavailable:
            String(
                localized:
                    "The selected application is not healthy enough to launch."
            )
        }
    }
}

/// Retains the running-process observation and activity lease until a terminal
/// event. The observer callback also retains this handle, so callers do not
/// have to keep it alive merely to avoid prematurely clearing active state.
final class TrackedApplicationLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryLock = NSLock()
    private let requestID: UUID
    private let identity: ProfileActivityIdentity
    private let activityRegistry: ProfileActivityRegistry
    private let expectedApplication: WorkspaceApplicationBundleIdentity
    private let processProvenanceInspector:
        any WorkspaceLaunchProcessProvenanceInspecting
    private let processSupervisor: WorkspaceProcessSupervisor
    private let launchAuthority: WorkspaceApplicationLaunchAuthority
    private let eventHandler:
        @Sendable (TrackedApplicationLaunchEvent) -> Void
    private let lifecycleHandler:
        @Sendable (ProfileLaunchLifecycleSnapshot) -> Void
    private var activityLease: ProfileActivityLease?
    private var terminationObservation:
        (any RunningApplicationTerminationObservation)?
    private var runningInstance: (any RunningApplicationInstance)?
    private var launchProcessProvenance: LaunchProcessProvenance?
    private var claimedProcessIdentity: WorkspaceProcessIdentity?
    private var suppressesUnexpectedTermination = false
    private var openingOutcomeIsUnknown = false
    private var safetyRetention: TrackedApplicationLaunch?
    private var unknownOutcomeSubmissionSlot:
        WorkspaceApplicationSubmissionSlot?
    private var isInstallingTerminationObservation = false
    private var pendingObservedTermination: pid_t?
    private var terminationWasRequested = false
    private var lifecycleBeforeTerminationRequest:
        ProfileLaunchLifecycleSnapshot?
    private var hasPublishedRunning = false
    private var terminal = false
    private var latestEvent: TrackedApplicationLaunchEvent
    private var latestLifecycle: ProfileLaunchLifecycleSnapshot

    init(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        activityRegistry: ProfileActivityRegistry,
        activityLease: ProfileActivityLease,
        expectedApplication: WorkspaceApplicationBundleIdentity,
        processProvenanceInspector:
            any WorkspaceLaunchProcessProvenanceInspecting,
        processSupervisor: WorkspaceProcessSupervisor,
        launchAuthority: WorkspaceApplicationLaunchAuthority,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) {
        self.requestID = requestID
        self.identity = identity
        self.activityRegistry = activityRegistry
        self.activityLease = activityLease
        self.expectedApplication = expectedApplication
        self.processProvenanceInspector = processProvenanceInspector
        self.processSupervisor = processSupervisor
        self.launchAuthority = launchAuthority
        self.lifecycleHandler = lifecycleHandler
        self.eventHandler = eventHandler
        latestEvent = .requested(requestID: requestID)
        latestLifecycle = ProfileLaunchLifecycleSnapshot(
            requestID: requestID,
            identity: identity,
            state: .requested
        )
    }

    var currentEvent: TrackedApplicationLaunchEvent {
        lock.withLock { latestEvent }
    }

    var currentLifecycle: ProfileLaunchLifecycleSnapshot {
        lock.withLock { latestLifecycle }
    }

    var processProvenance: LaunchProcessProvenance? {
        lock.withLock { launchProcessProvenance }
    }

    var supervisedProcessIdentity: WorkspaceProcessIdentity? {
        lock.withLock {
            switch launchProcessProvenance {
            case .new(let identity):
                return identity
            case .preExisting, .indeterminate, nil:
                return claimedProcessIdentity
            }
        }
    }

    func isSupervising(_ processIdentity: WorkspaceProcessIdentity) -> Bool {
        supervisedProcessIdentity == processIdentity
    }

    /// The production handle returned by `NSWorkspace`, retained until the
    /// process reaches a terminal state.
    var runningApplication: NSRunningApplication? {
        lock.withLock { runningInstance?.workspaceApplication }
    }

    fileprivate func didRequest() {
        deliveryLock.withLock {
            eventHandler(.requested(requestID: requestID))
            lifecycleHandler(currentLifecycle)
        }
    }

    fileprivate func didBeginOpening() {
        deliverLifecycle(.launching)
    }

    /// Records that a caller requested process termination. It does not itself
    /// terminate the process; the retained process handle and observer remain
    /// authoritative until the termination notification arrives.
    @discardableResult
    func noteTerminationRequested() -> Bool {
        let processIdentifier = lock.withLock {
            guard
                !terminal,
                let runningInstance
            else {
                return Optional<pid_t>.none
            }
            switch latestLifecycle.state {
            case .running, .runningDegraded:
                lifecycleBeforeTerminationRequest = latestLifecycle
                terminationWasRequested = true
                return runningInstance.processIdentifier
            case .requested, .launching, .terminating,
                 .terminated, .failed:
                return nil
            }
        }
        guard let processIdentifier else { return false }
        deliverLifecycle(
            .terminating(processIdentifier: processIdentifier)
        )
        return true
    }

    /// Marks the quit as intentional before invoking the operation that can
    /// synchronously deliver a termination notification. If the operation is
    /// rejected, the prior running lifecycle is restored.
    func performTerminationRequest(
        _ request: () throws -> Void
    ) throws {
        let marked = noteTerminationRequested()
        do {
            try request()
        } catch {
            if marked {
                cancelTerminationRequest()
            }
            throw error
        }
    }

    private func cancelTerminationRequest() {
        deliveryLock.withLock {
            let restored = lock.withLock {
                guard
                    !terminal,
                    terminationWasRequested,
                    let prior = lifecycleBeforeTerminationRequest,
                    case .terminating = latestLifecycle.state
                else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                terminationWasRequested = false
                lifecycleBeforeTerminationRequest = nil
                latestLifecycle = prior
                return prior
            }
            if let restored {
                lifecycleHandler(restored)
            }
        }
    }

    fileprivate func didOpen(
        _ application: any RunningApplicationInstance,
        provenance: LaunchProcessProvenance,
        observer: any RunningApplicationTerminationObserving
    ) {
        guard lock.withLock({ !terminal && !openingOutcomeIsUnknown }) else {
            return
        }
        switch provenance {
        case .new(let processIdentity):
            guard
                launchAuthority.claim(
                    processIdentity,
                    requestID: requestID
                )
            else {
                didRefusePreExistingSingleton(
                    processIdentifier: application.processIdentifier,
                    processIdentity: processIdentity
                )
                return
            }
            didOpenClaimedNew(
                application,
                processIdentity: processIdentity,
                observer: observer
            )
        case .preExisting(let processIdentity):
            didRefusePreExistingSingleton(
                processIdentifier: application.processIdentifier,
                processIdentity: processIdentity
            )
        case .indeterminate:
            didOpenBlocked(
                application,
                provenance: provenance,
                observer: observer
            )
        }
    }

    private func didOpenClaimedNew(
        _ application: any RunningApplicationInstance,
        processIdentity: WorkspaceProcessIdentity,
        observer: any RunningApplicationTerminationObserving
    ) {
        let retained = lock.withLock {
            guard !terminal else { return false }
            runningInstance = application
            launchProcessProvenance = .new(processIdentity)
            claimedProcessIdentity = processIdentity
            return true
        }
        guard retained else {
            launchAuthority.release(
                processIdentity,
                requestID: requestID
            )
            return
        }
        let supervision = prepareSupervision(
            of: application,
            identity: processIdentity,
            observer: observer
        )
        defer { supervision.start() }
        if application.isTerminated {
            failUnverifiedOpen(
                processIdentifier: application.processIdentifier,
                reason: .exitedBeforeVerification
            )
            return
        }

        let verification = processProvenanceInspector.inspectReturnedProcess(
            processIdentifier: application.processIdentifier,
            expectedApplication: expectedApplication
        )
        guard case .live(let verifiedIdentity) = verification,
              verifiedIdentity == processIdentity
        else {
            handleAdmissionVerificationFailure(
                verification,
                expectedIdentity: processIdentity,
                application: application
            )
            return
        }
        var durableTrackingError: Error?
        do {
            try activityRegistry.recordRunningProcess(
                requestID: requestID,
                processIdentity: processIdentity.process
            )
        } catch ProfileActivityRegistryError.processExitedBeforeRegistration {
            failUnverifiedOpen(
                processIdentifier: application.processIdentifier,
                reason: .exitedBeforeVerification
            )
            return
        } catch ProfileActivityRegistryError.processIdentityChanged {
            blockClaimedProcessAsIndeterminate(
                processIdentifier: application.processIdentifier,
                reason: .processIdentifierReused
            )
            return
        } catch ProfileActivityRegistryError.processIdentityAmbiguous {
            blockClaimedProcessAsIndeterminate(
                processIdentifier: application.processIdentifier
            )
            return
        } catch let error as DurableLaunchActivityStoreError {
            if case .processAlreadyTracked = error {
                blockClaimedProcessAsIndeterminate(
                    processIdentifier: application.processIdentifier
                )
                return
            } else {
                durableTrackingError = error
            }
        } catch {
            durableTrackingError = error
        }

        let finalVerification =
            processProvenanceInspector.inspectReturnedProcess(
                processIdentifier: application.processIdentifier,
                expectedApplication: expectedApplication
            )
        guard case .live(let finalIdentity) = finalVerification,
              finalIdentity == processIdentity
        else {
            handleAdmissionVerificationFailure(
                finalVerification,
                expectedIdentity: processIdentity,
                application: application
            )
            return
        }
        // Launch Services is asked not to activate before provenance is known.
        // Only an exact-new process owned by this request may now be brought
        // forward; pre-existing or indeterminate processes are never activated
        // by Parallax.
        application.requestActivation(of: processIdentity)
        supervision.start()
        guard lock.withLock({ !terminal }) else { return }
        if let durableTrackingError {
            didEnterDegradedTracking(
                processIdentifier: application.processIdentifier,
                error: durableTrackingError
            )
            return
        }

        let runningEvent = TrackedApplicationLaunchEvent.running(
            requestID: requestID,
            processIdentifier: application.processIdentifier
        )
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                latestEvent = runningEvent
                hasPublishedRunning = true
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .running(
                        processIdentifier: application.processIdentifier
                    ),
                    processIdentity: processIdentity
                )
                latestLifecycle = lifecycle
                return lifecycle
            }
            guard let lifecycle else { return }
            lifecycleHandler(lifecycle)
            eventHandler(runningEvent)
        }
    }

    private func didRefusePreExistingSingleton(
        processIdentifier: pid_t,
        processIdentity: WorkspaceProcessIdentity
    ) {
        lock.withLock {
            guard !terminal else { return }
            launchProcessProvenance = .preExisting(processIdentity)
            suppressesUnexpectedTermination = true
        }
        finish(
            with: .failed(
                requestID: requestID,
                message: String(
                    localized:
                        "The app reused a pre-existing process, so Parallax refused to claim a new isolated instance."
                )
            ),
            openingDisposition: .preExistingSingletonRefused(
                processIdentifier: processIdentifier
            )
        )
    }

    private func failUnverifiedOpen(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy
    ) {
        lock.withLock {
            guard !terminal else { return }
            launchProcessProvenance = .indeterminate(
                processIdentifier: processIdentifier,
                reason: reason
            )
            suppressesUnexpectedTermination = true
        }
        finish(
            with: .failed(
                requestID: requestID,
                message: String(
                    localized:
                        "Parallax could not verify the opened process before it exited. The space was not marked as open."
                )
            ),
            openingDisposition: .provenanceIndeterminate(
                processIdentifier: processIdentifier,
                reason: reason
            )
        )
    }

    private func didOpenBlocked(
        _ application: any RunningApplicationInstance,
        provenance: LaunchProcessProvenance,
        observer: any RunningApplicationTerminationObserving
    ) {
        let retained = lock.withLock {
            guard !terminal else { return false }
            runningInstance = application
            launchProcessProvenance = provenance
            suppressesUnexpectedTermination = true
            return true
        }
        guard retained else { return }
        switch provenance {
        case .indeterminate(let processIdentifier, let reason):
            if reason != .exitedBeforeVerification {
                deliveryLock.withLock {
                    let lifecycle = lock.withLock {
                        guard !terminal else {
                            return Optional<ProfileLaunchLifecycleSnapshot>.none
                        }
                        let lifecycle = ProfileLaunchLifecycleSnapshot(
                            requestID: requestID,
                            identity: identity,
                            state: .launching,
                            openingDisposition: .provenanceIndeterminate(
                                processIdentifier: processIdentifier,
                                reason: reason
                            )
                        )
                        latestLifecycle = lifecycle
                        return lifecycle
                    }
                    if let lifecycle {
                        lifecycleHandler(lifecycle)
                    }
                }
            }
            _ = observeTermination(of: application, observer: observer)
        case .new, .preExisting:
            preconditionFailure(
                "Only indeterminate provenance may retain a blocked open."
            )
        }
        resolveSafetyReceipt(for: application)
    }

    private func handleAdmissionVerificationFailure(
        _ inspection: WorkspaceProcessIdentityInspection,
        expectedIdentity: WorkspaceProcessIdentity,
        application: any RunningApplicationInstance
    ) {
        switch inspection {
        case .exited:
            didFinishObservedProcess(
                processIdentifier: application.processIdentifier
            )
        case .live, .indeterminate:
            // A final-window PID rebind or metadata change proves this exact
            // admission is unsafe, but it does not prove the opener had no
            // other side effect. Retain the request-scoped gate for later
            // exact reconciliation.
            blockClaimedProcessAsIndeterminate(
                processIdentifier: application.processIdentifier
            )
        }
    }

    private func blockClaimedProcessAsIndeterminate(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy = .unverifiableIdentity
    ) {
        lock.withLock {
            guard !terminal else { return }
            launchProcessProvenance = .indeterminate(
                processIdentifier: processIdentifier,
                reason: reason
            )
            suppressesUnexpectedTermination = true
        }
    }

    private func resolveSafetyReceipt(
        for application: any RunningApplicationInstance
    ) {
        let exactIdentity = lock.withLock {
            claimedProcessIdentity ?? {
                switch launchProcessProvenance {
                case .new(let identity), .preExisting(let identity):
                    return identity
                case .indeterminate, nil:
                    return nil
                }
            }()
        }
        let inspection = processProvenanceInspector.inspectReturnedProcess(
            processIdentifier: application.processIdentifier,
            expectedApplication: expectedApplication
        )
        switch inspection {
        case .exited:
            didTerminate(processIdentifier: application.processIdentifier)
        case .live(let current):
            if let exactIdentity,
               current.process != exactIdentity.process
            {
                didFinishObservedProcess(
                    processIdentifier: application.processIdentifier
                )
            }
        case .indeterminate:
            break
        }
    }

    private func didEnterDegradedTracking(
        processIdentifier: pid_t,
        error: Error
    ) {
        let processIdentity = supervisedProcessIdentity
        let message = String(
            localized:
                "The application opened, but durable process tracking is unavailable: \(error.localizedDescription)"
        )
        let event = TrackedApplicationLaunchEvent.trackingDegraded(
            requestID: requestID,
            processIdentifier: processIdentifier,
            message: message
        )
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                latestEvent = event
                hasPublishedRunning = true
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .runningDegraded(
                        processIdentifier: processIdentifier,
                        message: message
                    ),
                    processIdentity: processIdentity
                )
                latestLifecycle = lifecycle
                return lifecycle
            }
            guard let lifecycle else { return }
            lifecycleHandler(lifecycle)
            eventHandler(event)
        }
    }

    private func observeTermination(
        of application: any RunningApplicationInstance,
        observer: any RunningApplicationTerminationObserving
    ) -> Bool {
        lock.withLock {
            guard !terminal else { return }
            isInstallingTerminationObservation = true
            pendingObservedTermination = nil
        }
        let observation = observer.observeTermination(of: application) {
            [self] in
            let deferred = lock.withLock {
                guard isInstallingTerminationObservation else {
                    return false
                }
                pendingObservedTermination = application.processIdentifier
                return true
            }
            guard !deferred else { return }
            resolveSafetyReceipt(for: application)
        }
        install(observation)
        return lock.withLock {
            isInstallingTerminationObservation = false
            let observed = pendingObservedTermination != nil
            pendingObservedTermination = nil
            return observed
        }
    }

    private func supervise(
        of application: any RunningApplicationInstance,
        identity: WorkspaceProcessIdentity,
        observer: any RunningApplicationTerminationObserving
    ) {
        let supervision = prepareSupervision(
            of: application,
            identity: identity,
            observer: observer
        )
        supervision.start()
    }

    private func prepareSupervision(
        of application: any RunningApplicationInstance,
        identity: WorkspaceProcessIdentity,
        observer: any RunningApplicationTerminationObserving
    ) -> WorkspaceProcessSupervisionObservation {
        let supervision = processSupervisor.makeObservation(
            identity: identity
        ) { [self] in
            didTerminate(processIdentifier: identity.processIdentifier)
        }
        let notification = observer.observeTermination(of: application) {
            supervision.receiveTerminationHint(
                processIdentifier: application.processIdentifier
            )
        }
        supervision.installNotificationObservation(notification)
        install(supervision)
        return supervision
    }

    func didFail(_ error: Error) {
        finish(
            with: .failed(
                requestID: requestID,
                message: error.localizedDescription
            )
        )
    }

    fileprivate func didReceiveUnknownOpenOutcome(
        _ error: Error,
        submissionSlot: WorkspaceApplicationSubmissionSlot
    ) {
        let message = error.localizedDescription
        let event = TrackedApplicationLaunchEvent.failed(
            requestID: requestID,
            message: message
        )
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal, !openingOutcomeIsUnknown else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                openingOutcomeIsUnknown = true
                safetyRetention = self
                unknownOutcomeSubmissionSlot = submissionSlot
                // No snapshot or timeout sequence can prove causal exhaustion
                // after Launch Services reports an error. Retain both the
                // durable receipt and per-application FIFO slot until a future
                // explicit authoritative or user-directed recovery policy.
                latestEvent = event
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .launching,
                    openingDisposition: .outcomeUnknownAfterError(
                        message: message
                    )
                )
                latestLifecycle = lifecycle
                return lifecycle
            }
            guard let lifecycle else { return }
            lifecycleHandler(lifecycle)
            eventHandler(event)
        }
    }

    private func didTerminate(processIdentifier: pid_t) {
        didFinishObservedProcess(processIdentifier: processIdentifier)
    }

    private func didFinishObservedProcess(processIdentifier: pid_t) {
        guard lock.withLock({ hasPublishedRunning }) else {
            failUnverifiedOpen(
                processIdentifier: processIdentifier,
                reason: .exitedBeforeVerification
            )
            return
        }
        finish(
            with: .terminated(
                requestID: requestID,
                processIdentifier: processIdentifier
            )
        )
    }

    func install(
        _ observation: any RunningApplicationTerminationObservation
    ) {
        let shouldCancel = lock.withLock {
            if terminal {
                return true
            }
            terminationObservation = observation
            return false
        }
        if shouldCancel {
            observation.cancel()
        }
    }

    private func finish(
        with event: TrackedApplicationLaunchEvent,
        openingDisposition: ProfileLaunchOpeningDisposition? = nil
    ) {
        let resources = deliveryLock.withLock {
            lock.withLock {
                guard !terminal else {
                    return (
                        lifecycle:
                            Optional<ProfileLaunchLifecycleSnapshot>.none,
                        lease: Optional<ProfileActivityLease>.none,
                        observation:
                            Optional<
                                any RunningApplicationTerminationObservation
                            >.none,
                        claimedIdentity:
                            Optional<WorkspaceProcessIdentity>.none
                    )
                }
                terminal = true
                lifecycleBeforeTerminationRequest = nil
                latestEvent = event
                let state: ProfileLaunchLifecycleState
                switch event {
                case .terminated(_, let processIdentifier):
                    state = .terminated(
                        processIdentifier: processIdentifier
                    )
                case .failed(_, let message):
                    state = .failed(message: message)
                case .requested, .running, .trackingDegraded:
                    state = .failed(
                        message: String(
                            localized:
                                "Launch tracking ended without a terminal process result."
                        )
                    )
                }
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: state,
                    processIdentity: {
                        let disposition = openingDisposition
                            ?? latestLifecycle.openingDisposition
                        switch disposition {
                        case .preExistingSingletonRefused,
                             .provenanceIndeterminate:
                            return nil
                        case .pending, .outcomeUnknownAfterError:
                            break
                        }
                        if let claimedProcessIdentity {
                            return claimedProcessIdentity
                        }
                        switch launchProcessProvenance {
                        case .new(let identity):
                            return identity
                        case .preExisting, .indeterminate, nil:
                            return nil
                        }
                    }(),
                    openingDisposition:
                        openingDisposition
                        ?? latestLifecycle.openingDisposition,
                    terminationDisposition: {
                        if case .terminated = state {
                            return terminationWasRequested
                                || suppressesUnexpectedTermination
                                ? .expected
                                : .unexpected
                        }
                        return nil
                    }()
                )
                latestLifecycle = lifecycle
                let lease = activityLease
                activityLease = nil
                let observation = terminationObservation
                terminationObservation = nil
                let claimedIdentity = claimedProcessIdentity
                claimedProcessIdentity = nil
                runningInstance = nil
                safetyRetention = nil
                unknownOutcomeSubmissionSlot = nil
                return (
                    lifecycle: Optional(lifecycle),
                    lease: lease,
                    observation: observation,
                    claimedIdentity: claimedIdentity
                )
            }
        }

        guard let lifecycle = resources.lifecycle else { return }
        let completion: DurableLaunchCompletion
        switch event {
        case .terminated:
            completion = .terminated
        case .failed:
            completion = .failed
        case .requested, .running, .trackingDegraded:
            completion = .failed
        }
        try? activityRegistry.completeDurableLaunch(
            requestID: requestID,
            completion: completion
        )
        // Strong observation cancellation may wait for an in-flight callback.
        // The terminal bit already prevents any later state delivery, so never
        // hold deliveryLock across this or the other external cleanup calls.
        resources.observation?.cancel()
        if let claimedIdentity = resources.claimedIdentity {
            launchAuthority.release(
                claimedIdentity,
                requestID: requestID
            )
        }
        resources.lease?.release()
        deliveryLock.withLock {
            lifecycleHandler(lifecycle)
            eventHandler(event)
        }
    }

    private func deliverLifecycle(
        _ state: ProfileLaunchLifecycleState
    ) {
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                let snapshot = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: state,
                    processIdentity: {
                        if let claimedProcessIdentity {
                            return claimedProcessIdentity
                        }
                        switch launchProcessProvenance {
                        case .new(let identity),
                             .preExisting(let identity):
                            return identity
                        case .indeterminate, nil:
                            return nil
                        }
                    }()
                )
                latestLifecycle = snapshot
                return snapshot
            }
            if let lifecycle {
                lifecycleHandler(lifecycle)
            }
        }
    }
}

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
        opener = NSWorkspaceApplicationOpener()
        terminationObserver = NSWorkspaceTerminationObserver()
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
        launch.didRequest()
        do {
            try activityRegistry.markLaunchOpening(
                requestID: prepared.requestID
            )
        } catch {
            launch.didFail(error)
            throw error
        }
        launch.didBeginOpening()

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
                    launch.didOpen(
                        runningApplication,
                        provenance: provenance,
                        observer: terminationObserver
                    )
                    submissionSlot.complete()
                case .failure(let error):
                    launch.didReceiveUnknownOpenOutcome(
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

private final class WorkspaceRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let application: NSRunningApplication
    private let activationRequester: WorkspaceVerifiedActivationRequester

    init(
        application: NSRunningApplication,
        activationRequester: WorkspaceVerifiedActivationRequester =
            WorkspaceVerifiedActivationRequester()
    ) {
        self.application = application
        self.activationRequester = activationRequester
    }

    var processIdentifier: pid_t {
        application.processIdentifier
    }

    var isTerminated: Bool {
        application.isTerminated
    }

    var workspaceApplication: NSRunningApplication? {
        application
    }

    func requestActivation(of identity: WorkspaceProcessIdentity) {
        activationRequester.requestActivation(of: identity)
    }
}

private struct NSWorkspaceApplicationOpener:
    WorkspaceApplicationOpening,
    Sendable
{
    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ) {
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { application, error in
            if let error {
                completion(.failure(error))
            } else if let application {
                completion(
                    .success(
                        WorkspaceRunningApplication(application: application)
                    )
                )
            } else {
                completion(.failure(LaunchError.applicationDidNotOpen(url.path)))
            }
        }
    }
}

private struct NSWorkspaceTerminationObserver:
    RunningApplicationTerminationObserving,
    Sendable
{
    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        let center = NSWorkspace.shared.notificationCenter
        let processIdentifier = application.processIdentifier
        let token = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard
                let terminatedApplication =
                    notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication,
                terminatedApplication.processIdentifier == processIdentifier
            else {
                return
            }
            handler()
        }
        return NSWorkspaceTerminationObservation(
            notificationCenter: center,
            token: token
        )
    }
}

private final class NSWorkspaceTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter,
        token: NSObjectProtocol
    ) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    func cancel() {
        let token = lock.withLock {
            let token = self.token
            self.token = nil
            return token
        }
        if let token {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}
