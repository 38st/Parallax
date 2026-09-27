import AppKit
import Foundation

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
    private var submissionWaitingRevision: UInt64 = 0
    private var safetyRetention: TrackedApplicationLaunch?
    private var unknownOutcomeSubmissionSlot:
        WorkspaceApplicationSubmissionSlot?
    private var isInstallingTerminationObservation = false
    private var pendingObservedTermination: pid_t?
    private var terminationWasRequested = false
    private var terminationRequestGeneration: UUID?
    private var terminationCheckID: UUID?
    private var safetyPollGeneration: UUID?
    private var terminationGraceTask: (any WorkspaceProcessSupervisionScheduledTask)?
    private var safetyPollTask: (any WorkspaceProcessSupervisionScheduledTask)?
    private var lifecycleBeforeTerminationRequest:
        ProfileLaunchLifecycleSnapshot?
    private var hasVerifiedLiveProcess = false
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
        ProcessWideLaunchSupervision.shared.register(self, requestID: requestID)
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

    /// The application bundle this request asked Launch Services to open. It
    /// is immutable, so reading it needs no lock.
    var requestedApplication: WorkspaceApplicationBundleIdentity {
        expectedApplication
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
                 .terminated, .failed, .cancelled:
                return nil
            }
        }
        guard let processIdentifier else { return false }
        deliverLifecycle(
            .terminating(processIdentifier: processIdentifier)
        )
        armTerminationGracePeriod()
        return true
    }

    private func armTerminationGracePeriod() {
        guard let process = supervisedProcessIdentity else { return }
        let generation = UUID()
        lock.withLock { terminationRequestGeneration = generation }
        ExpectedProcessTerminationIntent.shared.mark(process, token: generation)
        scheduleTerminationCheck(
            process: process,
            generation: generation,
            after: LaunchHistoryStore.terminationRequestGracePeriod
        )
    }

    private func scheduleTerminationCheck(
        process: WorkspaceProcessIdentity,
        generation: UUID,
        after delay: TimeInterval
    ) {
        let checkID = UUID()
        let active = lock.withLock {
            guard !terminal, terminationRequestGeneration == generation else { return false }
            terminationCheckID = checkID
            return true
        }
        guard active else { return }
        let task = processSupervisor.schedule(after: delay) { [weak self] in
            guard let self,
                self.lock.withLock({
                    !self.terminal && self.terminationRequestGeneration == generation
                        && self.terminationCheckID == checkID
                })
            else { return }
            let inspection = self.processProvenanceInspector.inspectReturnedProcess(
                processIdentifier: process.processIdentifier,
                expectedApplication: process.application
            )
            switch inspection {
            case .live(let current) where current == process:
                self.cancelTerminationRequest()
            case .exited:
                break
            case .live, .indeterminate:
                // A transient inspection failure must not make Quit stay
                // disabled for the rest of an otherwise live process.
                self.scheduleTerminationCheck(process: process, generation: generation, after: 1)
            }
        }
        let discarded = lock.withLock {
            guard !terminal, terminationRequestGeneration == generation,
                terminationCheckID == checkID
            else { return Optional(task) }
            let prior = terminationGraceTask
            terminationGraceTask = task
            return prior
        }
        discarded?.cancel()
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
                if let process = claimedProcessIdentity, let token = terminationRequestGeneration {
                    ExpectedProcessTerminationIntent.shared.cancel(process, token: token)
                }
                terminationRequestGeneration = nil
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
        // Commit exact-live verification under the state lock before any
        // activation or supervisor callback can report an exit. Running may
        // never be published, but a later exit still has exact attribution.
        guard lock.withLock({
            guard !terminal else { return false }
            hasVerifiedLiveProcess = true
            return true
        }) else { return }
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
        scheduleSafetyPoll(for: application)
    }

    private func scheduleSafetyPoll(for application: any RunningApplicationInstance) {
        let generation = UUID()
        let active = lock.withLock {
            guard !terminal else { return false }
            safetyPollGeneration = generation
            return true
        }
        guard active else { return }
        let task = processSupervisor.schedule(after: 1) { [weak self] in
            guard let self,
                self.lock.withLock({
                    !self.terminal && self.safetyPollGeneration == generation
                })
            else { return }
            self.resolveSafetyReceipt(for: application)
            self.scheduleSafetyPoll(for: application)
        }
        let discarded = lock.withLock {
            guard !terminal, safetyPollGeneration == generation else { return Optional(task) }
            let prior = safetyPollTask
            safetyPollTask = task
            return prior
        }
        discarded?.cancel()
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
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else { return Optional<ProfileLaunchLifecycleSnapshot>.none }
                launchProcessProvenance = .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: reason
                )
                suppressesUnexpectedTermination = true
                let snapshot = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .launching,
                    openingDisposition: .provenanceIndeterminate(
                        processIdentifier: processIdentifier,
                        reason: reason
                    )
                )
                latestLifecycle = snapshot
                return snapshot
            }
            if let lifecycle { lifecycleHandler(lifecycle) }
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

    func didWaitForEarlierOpen(outcomeUnknown: Bool, revision: UInt64, blockingRequestID: UUID?) {
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal, latestLifecycle.state == .requested, revision >= submissionWaitingRevision else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                submissionWaitingRevision = revision
                let lifecycle = ProfileLaunchLifecycleSnapshot(requestID: requestID, identity: identity,
                    state: .requested, openingDisposition: .waitingForEarlierOpen(outcomeUnknown: outcomeUnknown, blockingRequestID: blockingRequestID))
                latestLifecycle = lifecycle
                return lifecycle
            }
            if let lifecycle { lifecycleHandler(lifecycle) }
        }
    }

    /// Called only after the confirmed durable record was retired under the
    /// activity lock, including the matching-application process recheck.
    func didClearUnknownOpenRecord(_ record: StuckLaunchRecord) {
        let slot = lock.withLock {
            guard record.requestID == requestID, record.identity == identity,
                openingOutcomeIsUnknown, !terminal
            else { return Optional<WorkspaceApplicationSubmissionSlot>.none }
            return unknownOutcomeSubmissionSlot
        }
        guard let slot else { return }
        finish(with: .cancelled(requestID: requestID), openingDisposition: .pending)
        // The next request writes its opening receipt. Off the main thread it
        // can wait for a peer's short-lived activity lock instead of failing.
        DispatchQueue.global(qos: .userInitiated).async { slot.complete() }
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
        submissionSlot.markOutcomeUnknown()
    }

    private func didTerminate(processIdentifier: pid_t) {
        didFinishObservedProcess(processIdentifier: processIdentifier)
    }

    private func didFinishObservedProcess(processIdentifier: pid_t) {
        guard lock.withLock({ hasVerifiedLiveProcess }) else {
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
                case .cancelled:
                    state = .cancelled
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
                        case .pending, .waitingForEarlierOpen, .outcomeUnknownAfterError:
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
                                || claimedProcessIdentity.map {
                                    ExpectedProcessTerminationIntent.shared.contains($0)
                                } == true
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
        ProcessWideLaunchSupervision.shared.remove(requestID: requestID)
        if let process = resources.claimedIdentity {
            ExpectedProcessTerminationIntent.shared.clear(process)
        }
        let tasks = lock.withLock {
            let tasks = [terminationGraceTask, safetyPollTask]
            terminationGraceTask = nil
            safetyPollTask = nil
            terminationRequestGeneration = nil
            return tasks
        }
        for task in tasks { task?.cancel() }
        let completion: DurableLaunchCompletion
        switch event {
        case .terminated, .cancelled:
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

enum TrackedLaunchSessionDriver {
    static func didRequest(_ launch: TrackedApplicationLaunch) {
        launch.didRequest()
    }

    static func didBeginOpening(_ launch: TrackedApplicationLaunch) {
        launch.didBeginOpening()
    }

    static func didOpen(
        _ launch: TrackedApplicationLaunch,
        _ application: any RunningApplicationInstance,
        provenance: LaunchProcessProvenance,
        observer: any RunningApplicationTerminationObserving
    ) {
        launch.didOpen(
            application,
            provenance: provenance,
            observer: observer
        )
    }

    static func didReceiveUnknownOpenOutcome(
        _ launch: TrackedApplicationLaunch,
        _ error: Error,
        submissionSlot: WorkspaceApplicationSubmissionSlot
    ) {
        launch.didReceiveUnknownOpenOutcome(
            error,
            submissionSlot: submissionSlot
        )
    }
}
