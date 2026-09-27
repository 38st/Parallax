import Darwin
import Foundation

/// Process-local activity shared by launch lifecycle and managed-data
/// transactions. A request may hold more than one lease, but it cannot silently
/// change identity. Each lease releases at most once, including from `deinit`.
final class ProfileActivityRegistry:
    StorageRelocationActivityProviding,
    @unchecked Sendable
{
    private struct RequestActivity {
        let identity: ProfileActivityIdentity
        let generationID: UUID
        var leaseCount: Int
        var isDataOperation = false
    }

    private struct DurableActivity: Equatable {
        enum Proof: Equatable {
            case running(ProcessStartIdentity)
            case requestOwner(ProcessStartIdentity)
            case ambiguous
        }

        let identity: ProfileActivityIdentity
        let proof: Proof
        var isDataOperation = false
        var isOpeningAmbiguity = false
    }

    private let lock = NSLock()
    private var requests: [UUID: RequestActivity] = [:]
    private var durableActivities: [UUID: DurableActivity] = [:]
    private var hasGlobalDurableAmbiguity = false
    private let durableStore: DurableLaunchActivityStore?
    private let processInspector: any ProcessIdentityInspecting
    private let refreshScheduler: any WorkspaceProcessSupervisionScheduling
    private var refreshTask: (any WorkspaceProcessSupervisionScheduledTask)?
    private var reconciliationGeneration: UInt64 = 0
    private var releasedDataOperations: Set<UUID> = []
    private var completionTasks: [UUID: any WorkspaceProcessSupervisionScheduledTask] = [:]
    private let completionScheduler: any WorkspaceProcessSupervisionScheduling

    var isDurableTrackingAvailable: Bool {
        durableStore != nil
    }

    init(
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) {
        durableStore = nil
        self.processInspector = processInspector
        refreshScheduler = DispatchWorkspaceProcessSupervisionScheduler()
        completionScheduler = DispatchWorkspaceProcessSupervisionScheduler()
    }

    init(
        applicationSupportURL: URL,
        refreshScheduler: any WorkspaceProcessSupervisionScheduling =
            DispatchWorkspaceProcessSupervisionScheduler(),
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector(),
        completionScheduler: any WorkspaceProcessSupervisionScheduling =
            DispatchWorkspaceProcessSupervisionScheduler()
    ) throws {
        durableStore = try DurableLaunchActivityStore(
            applicationSupportURL: applicationSupportURL
        )
        self.processInspector = processInspector
        self.refreshScheduler = refreshScheduler
        self.completionScheduler = completionScheduler
        scheduleRefresh()
    }

    func acquire(
        identity: ProfileActivityIdentity,
        requestID: UUID,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        isDataOperation: Bool = false
    ) throws -> ProfileActivityLease {
        let generationID = try lock.withLock {
            reconciliationGeneration &+= 1
            let sameStorage: (ProfileActivityIdentity) -> Bool = {
                $0.applicationStorageID
                    == identity.applicationStorageID
                    && $0.profileStorageID
                        == identity.profileStorageID
            }
            if requests.contains(where: {
                $0.key != requestID && $0.value.isDataOperation && sameStorage($0.value.identity)
            })
                || durableActivities.contains(where: {
                    $0.key != requestID && $0.value.isDataOperation
                        && sameStorage($0.value.identity)
                })
            {
                throw ProfileActivityRegistryError.storageReservedForDataOperation
            }
            let requestConflict = requests.contains {
                $0.key != requestID && sameStorage($0.value.identity)
            }
            let durableConflict = durableActivities.contains {
                $0.key != requestID && sameStorage($0.value.identity)
            }
            if requestConflict || durableConflict {
                switch concurrentLaunchPolicy {
                case .deny:
                    throw ProfileActivityRegistryError.profileAlreadyActive(
                        applicationStorageID:
                            identity.applicationStorageID,
                        profileStorageID: identity.profileStorageID
                    )
                case .expertOverride(let acknowledgement):
                    guard
                        acknowledgement
                            .acknowledgesProfileDataCorruptionRisk
                    else {
                        throw ProfileActivityRegistryError
                            .expertOverrideRiskNotAcknowledged
                    }
                }
            }
            if var activity = requests[requestID] {
                guard activity.identity == identity else {
                    throw ProfileActivityRegistryError.requestIdentityConflict(
                        requestID: requestID
                    )
                }
                activity.leaseCount += 1
                requests[requestID] = activity
                return activity.generationID
            } else {
                let generationID = UUID()
                requests[requestID] = RequestActivity(
                    identity: identity,
                    generationID: generationID,
                    leaseCount: 1,
                    isDataOperation: isDataOperation
                )
                return generationID
            }
        }

        return ProfileActivityLease { [weak self] in
            self?.release(
                identity: identity,
                requestID: requestID,
                generationID: generationID
            )
        }
    }

    func acquireLaunchLease(
        identity: ProfileActivityIdentity,
        requestID: UUID,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        isDataOperation: Bool = false
    ) throws -> ProfileActivityLease {
        _ = try? reconcileDurableActivity()
        guard let durableStore else {
            return try acquire(
                identity: identity,
                requestID: requestID,
                concurrentLaunchPolicy: concurrentLaunchPolicy,
                isDataOperation: isDataOperation
            )
        }
        let ownerPID = Darwin.getpid()
        guard case .live(let ownerIdentity) =
            processInspector.inspect(processIdentifier: ownerPID)
        else {
            throw ProfileActivityRegistryError.processIdentityAmbiguous(ownerPID)
        }
        try durableStore.createRequest(
            requestID: requestID,
            identity: identity,
            ownerProcess: ownerIdentity,
            allowsConcurrentProfile: {
                if case .expertOverride(let acknowledgement) =
                    concurrentLaunchPolicy
                {
                    return acknowledgement
                        .acknowledgesProfileDataCorruptionRisk
                }
                return false
            }(),
            isDataOperation: isDataOperation
        )
        do {
            let lease = try acquire(
                identity: identity,
                requestID: requestID,
                concurrentLaunchPolicy: concurrentLaunchPolicy,
                isDataOperation: isDataOperation
            )
            lock.withLock {
                reconciliationGeneration &+= 1
                durableActivities[requestID] = DurableActivity(
                    identity: identity,
                    proof: .ambiguous,
                    isDataOperation: isDataOperation
                )
            }
            return lease
        } catch {
            if isDataOperation {
                releaseDataOperation(requestID: requestID, completion: .failed)
            } else {
                try? durableStore.complete(requestID: requestID, completion: .failed)
            }
            throw error
        }
    }

    /// Reserve every affected storage identity before touching data. Keep the
    /// returned lease alive through commit/rollback; release on every exit.
    /// Expert launch overrides cannot bypass these reservations.
    func acquireDataOperationLease(
        identities: Set<ProfileActivityIdentity>,
        activityPolicy: DataOperationActivityPolicy = .requireInactive
    ) throws -> ProfileActivityReservation {
        if case .destructiveExpertOverride(let authorization) = activityPolicy {
            guard let override = authorization.expertOverride,
                authorization.usedExpertOverride,
                override.acknowledgedRisk == .profileDataCorruptionAndProcessInstability,
                identities.contains(override.activityIdentity)
            else { throw DestructiveActionRequestError(.invalidExpertOverride) }
        }
        var acquired: [(UUID, ProfileActivityLease)] = []
        do {
            for identity in identities {
                let requestID = UUID()
                let concurrency: ConcurrentProfileLaunchPolicy
                if case .destructiveExpertOverride(let authorization) = activityPolicy,
                    authorization.expertOverride?.activityIdentity == identity
                {
                    concurrency = .expertOverride(.init(acknowledgesProfileDataCorruptionRisk: true))
                } else {
                    concurrency = .deny
                }
                let lease = try acquireLaunchLease(
                    identity: identity,
                    requestID: requestID,
                    concurrentLaunchPolicy: concurrency,
                    isDataOperation: true
                )
                acquired.append((requestID, lease))
            }
        } catch {
            for (requestID, lease) in acquired {
                lease.release()
                releaseDataOperation(requestID: requestID, completion: .failed)
            }
            throw error
        }
        let reservations = acquired
        let lease = ProfileActivityLease { [self] in
            for (requestID, lease) in reservations {
                lease.release()
                releaseDataOperation(requestID: requestID, completion: .terminated)
            }
        }
        return ProfileActivityReservation(
            identities: identities,
            requestIDs: Set(reservations.map { $0.0 }), registry: self, lease: lease)
    }

    private func releaseDataOperation(requestID: UUID, completion: DurableLaunchCompletion) {
        lock.withLock {
            releasedDataOperations.insert(requestID)
            durableActivities.removeValue(forKey: requestID)
            reconciliationGeneration &+= 1
        }
        finishDataOperation(requestID: requestID, completion: completion, retryDelay: 0.01)
    }

    private func finishDataOperation(
        requestID: UUID, completion: DurableLaunchCompletion, retryDelay: TimeInterval
    ) {
        do {
            try completeDurableLaunch(requestID: requestID, completion: completion)
            lock.withLock {
                releasedDataOperations.remove(requestID)
                completionTasks.removeValue(forKey: requestID)
            }
        } catch {
            // Completion must outlive the caller's lease. Retry off the main
            // thread with capped backoff; reconciliation cannot resurrect it.
            if case DurableLaunchActivityStoreError.activityBusy = error {
                // Contention is expected while another operation owns the journal.
            } else {
                AppLog.persistence.error("Failed to release a profile data reservation: \(error.localizedDescription)")
            }
            lock.withLock {
                guard releasedDataOperations.contains(requestID) else { return }
                completionTasks[requestID] = completionScheduler.schedule(after: retryDelay) { [self] in
                    lock.withLock { _ = completionTasks.removeValue(forKey: requestID) }
                    finishDataOperation(requestID: requestID, completion: completion,
                        retryDelay: min(retryDelay * 2, 30))
                }
            }
        }
    }

    func markLaunchOpening(requestID: UUID) throws {
        try durableStore?.markOpening(requestID: requestID)
    }

    func recordRunningProcess(
        requestID: UUID,
        processIdentifier: pid_t
    ) throws {
        switch processInspector.inspect(processIdentifier: processIdentifier) {
        case .live(let identity):
            try recordRunningProcess(
                requestID: requestID,
                processIdentity: identity
            )
        case .dead:
            throw ProfileActivityRegistryError
                .processExitedBeforeRegistration(processIdentifier)
        case .ambiguous:
            throw ProfileActivityRegistryError
                .processIdentityAmbiguous(processIdentifier)
        }
    }

    func recordRunningProcess(
        requestID: UUID,
        processIdentity: ProcessStartIdentity
    ) throws {
        let processIdentifier = processIdentity.processIdentifier
        switch processInspector.inspect(processIdentifier: processIdentifier) {
        case .live(let current):
            guard current == processIdentity else {
                throw ProfileActivityRegistryError
                    .processIdentityChanged(processIdentifier)
            }
        case .dead:
            throw ProfileActivityRegistryError
                .processExitedBeforeRegistration(processIdentifier)
        case .ambiguous:
            throw ProfileActivityRegistryError
                .processIdentityAmbiguous(processIdentifier)
        }

        guard let durableStore else { return }
        try durableStore.recordProcess(
            requestID: requestID,
            process: processIdentity
        )
        lock.withLock {
            reconciliationGeneration &+= 1
            guard let existing = durableActivities[requestID] else {
                return
            }
            durableActivities[requestID] = DurableActivity(
                identity: existing.identity,
                proof: .running(processIdentity)
            )
        }
    }

    func completeDurableLaunch(
        requestID: UUID,
        completion: DurableLaunchCompletion
    ) throws {
        guard let durableStore else { return }
        do {
            try durableStore.complete(
                requestID: requestID,
                completion: completion
            )
            lock.withLock {
                reconciliationGeneration &+= 1
                durableActivities.removeValue(forKey: requestID)
            }
        } catch {
            // The artifact remains an explicit blocker until reconciliation can
            // prove that its process is dead.
            throw error
        }
    }

    /// Requests of this process whose open had an unknown outcome. When an
    /// expected application is given, a request qualifies only if it opened
    /// that exact bundle: the process check that makes clearing safe looks for
    /// the expected application, so a relinked space must not clear a request
    /// that opened a different bundle.
    private func locallyRecoverableRequests(
        identity: ProfileActivityIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity? = nil
    ) -> Set<UUID> {
        Set(ProcessWideLaunchSupervision.shared.snapshot().compactMap { id, launch in
            let lifecycle = launch.currentLifecycle
            guard lifecycle.identity == identity, !lifecycle.state.isTerminal,
                case .outcomeUnknownAfterError = lifecycle.openingDisposition,
                expectedApplication.map({ launch.requestedApplication == $0 }) ?? true
            else { return nil }
            return id
        })
    }

    func hasCachedStuckLaunchRecord(identity: ProfileActivityIdentity) -> Bool {
        let recoverable = locallyRecoverableRequests(identity: identity)
        return lock.withLock {
            !hasGlobalDurableAmbiguity
                && !requests.contains { $0.value.identity == identity && !recoverable.contains($0.key) }
                && (!recoverable.isEmpty || durableActivities.values.contains {
                    $0.identity == identity && $0.isOpeningAmbiguity && !$0.isDataOperation
                })
        }
    }

    func cachedLaunchBlocker(identity: ProfileActivityIdentity) -> String? {
        lock.withLock {
            if hasGlobalDurableAmbiguity || durableActivities.values.contains(where: {
                $0.identity == identity && $0.proof == .ambiguous && !$0.isDataOperation
            }) {
                return String(localized: "Other launch records could not be verified.")
            }
            let durable = durableActivities.values.filter { $0.identity == identity }
            let local = requests.values.filter { $0.identity == identity }
            if durable.contains(where: \.isDataOperation) || local.contains(where: \.isDataOperation) {
                return ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription
            }
            if !durable.isEmpty || !local.isEmpty {
                return ProfileActivityRegistryError.profileAlreadyActive(
                    applicationStorageID: identity.applicationStorageID,
                    profileStorageID: identity.profileStorageID).localizedDescription
            }
            return nil
        }
    }

    func stuckLaunchRecords(
        identity: ProfileActivityIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity,
        processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting
    ) throws -> [StuckLaunchRecord] {
        let recoverable = locallyRecoverableRequests(
            identity: identity, expectedApplication: expectedApplication)
        return try lock.withLock {
            guard let durableStore, !hasGlobalDurableAmbiguity,
                !requests.contains(where: {
                    $0.value.identity.applicationStorageID == identity.applicationStorageID
                        && $0.value.identity.profileStorageID == identity.profileStorageID
                        && !recoverable.contains($0.key)
                })
            else { return [] }
            return try durableStore.stuckLaunchRecords(identity: identity,
                expectedApplication: expectedApplication, processInspector: processInspector,
                processSnapshotter: processSnapshotter, locallyRecoverableRequestIDs: recoverable)
        }
    }

    func clearStuckLaunchRecords(
        _ records: [StuckLaunchRecord],
        identity: ProfileActivityIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity,
        processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting
    ) throws {
        let recoverable = locallyRecoverableRequests(
            identity: identity, expectedApplication: expectedApplication
        ).intersection(records.map(\.requestID))
        try lock.withLock {
            guard let durableStore, !hasGlobalDurableAmbiguity,
                !requests.contains(where: {
                    $0.value.identity.applicationStorageID == identity.applicationStorageID
                        && $0.value.identity.profileStorageID == identity.profileStorageID
                        && !recoverable.contains($0.key)
                })
            else { throw StuckLaunchRecoveryError.changedOrActive }
            try durableStore.clearStuckLaunchRecords(records, identity: identity,
                expectedApplication: expectedApplication, processInspector: processInspector,
                processSnapshotter: processSnapshotter, locallyRecoverableRequestIDs: recoverable)
            reconciliationGeneration &+= 1
            for record in records {
                durableActivities.removeValue(forKey: record.requestID)
            }
        }
    }

    @discardableResult
    func reconcileDurableActivity() throws -> ProfileActivityReconciliationReport {
        guard let durableStore else {
            return ProfileActivityReconciliationReport()
        }
        let generation = lock.withLock {
            reconciliationGeneration &+= 1
            return reconciliationGeneration
        }
        var report = ProfileActivityReconciliationReport()
        var recovered: [UUID: DurableActivity] = [:]
        var globalAmbiguity = false

        for artifact in try durableStore.reconciliationArtifacts() {
            let retainAsAmbiguous: () -> Void = {
                report.ambiguousCount += 1
                if let requestID = artifact.requestID,
                   let identity = artifact.identity
                {
                    recovered[requestID] = DurableActivity(
                        identity: identity,
                        proof: .ambiguous,
                        isDataOperation: artifact.isDataOperation,
                        isOpeningAmbiguity: {
                            if case .opening = artifact.state { return true }
                            return false
                        }()
                    )
                } else {
                    globalAmbiguity = true
                    report.globalAmbiguousCount += 1
                }
            }
            let removeAsDead: () -> Void = {
                do {
                    guard let requestID = artifact.requestID else {
                        retainAsAmbiguous()
                        return
                    }
                    guard
                        try durableStore.removeProvenDeadArtifact(
                            requestID: requestID,
                            processInspector: self.processInspector
                        )
                    else {
                        retainAsAmbiguous()
                        return
                    }
                    report.removedDeadCount += 1
                } catch {
                    retainAsAmbiguous()
                }
            }

            switch artifact.state {
            case .completed:
                removeAsDead()
            case .corrupt:
                retainAsAmbiguous()
            case .opening:
                retainAsAmbiguous()
            case .requestOnly(let owner):
                switch processInspector.inspect(
                    processIdentifier: owner.processIdentifier
                ) {
                case .live(let current) where current == owner:
                    if let requestID = artifact.requestID,
                       let identity = artifact.identity
                    {
                        recovered[requestID] = DurableActivity(
                            identity: identity,
                            proof: .requestOwner(owner),
                            isDataOperation: artifact.isDataOperation
                        )
                        report.recoveredLiveCount += 1
                    } else {
                        retainAsAmbiguous()
                    }
                case .live, .dead:
                    // No opening marker was persisted, so this owner cannot
                    // have submitted an application open request.
                    removeAsDead()
                case .ambiguous:
                    retainAsAmbiguous()
                }
            case .running(let recorded):
                switch processInspector.inspect(
                    processIdentifier: recorded.processIdentifier
                ) {
                case .live(let current) where current == recorded:
                    if let requestID = artifact.requestID,
                       let identity = artifact.identity
                    {
                        recovered[requestID] = DurableActivity(
                            identity: identity,
                            proof: .running(recorded)
                        )
                        report.recoveredLiveCount += 1
                    } else {
                        retainAsAmbiguous()
                    }
                case .live, .dead:
                    // A start-identity mismatch proves the recorded process is
                    // gone even if its PID has since been reused.
                    removeAsDead()
                case .ambiguous:
                    retainAsAmbiguous()
                }
            }
        }

        lock.withLock {
            guard reconciliationGeneration == generation else { return }
            durableActivities = recovered.filter { !releasedDataOperations.contains($0.key) }
            hasGlobalDurableAmbiguity = globalAmbiguity
        }
        return report
    }

    func isActive(identity: ProfileActivityIdentity) -> Bool {
        return lock.withLock {
            hasGlobalDurableAmbiguity
                || durableActivities.values.contains {
                    $0.identity == identity && !$0.isDataOperation
                }
                || requests.values.contains {
                    $0.identity == identity && !$0.isDataOperation && $0.leaseCount > 0
                }
        }
    }

    func activeLeaseCount(identity: ProfileActivityIdentity) -> Int {
        lock.withLock {
            requests.values
                .filter { $0.identity == identity }
                .reduce(into: 0) { $0 += $1.leaseCount }
        }
    }

    func activeRequestIDs(identity: ProfileActivityIdentity) -> Set<UUID> {
        return lock.withLock {
            let inMemory = Set(
                requests.compactMap { requestID, activity in
                    activity.identity == identity && activity.leaseCount > 0
                        ? requestID
                        : nil
                }
            )
            let durable = Set(
                durableActivities.compactMap { requestID, activity in
                    activity.identity == identity ? requestID : nil
                }
            )
            return inMemory.union(durable)
        }
    }

    func runningProcesses(
        applicationStorageID: UUID
    ) -> [ProfileRunningProcess] {
        return lock.withLock {
            durableActivities.compactMap { requestID, activity in
                guard
                    activity.identity.applicationStorageID
                        == applicationStorageID,
                    case .running(let process) = activity.proof
                else {
                    return nil
                }
                return ProfileRunningProcess(
                    requestID: requestID,
                    identity: activity.identity,
                    process: process
                )
            }
            .sorted {
                if $0.process.startTimeSeconds
                    != $1.process.startTimeSeconds
                {
                    return $0.process.startTimeSeconds
                        < $1.process.startTimeSeconds
                }
                if $0.process.startTimeMicroseconds
                    != $1.process.startTimeMicroseconds
                {
                    return $0.process.startTimeMicroseconds
                        < $1.process.startTimeMicroseconds
                }
                return $0.process.processIdentifier
                    < $1.process.processIdentifier
            }
        }
    }

    func isStorageActive(applicationStorageID: UUID, profileStorageID: UUID) -> Bool {
        isStorageActive(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID, excluding: nil)
    }

    func isStorageActive(
        applicationStorageID: UUID, profileStorageID: UUID,
        excluding reservation: ProfileActivityReservation?
    ) -> Bool {
        !activeProfileStorageIDs(
            applicationStorageID: applicationStorageID,
            profileStorageIDs: [profileStorageID], excluding: reservation
        ).isEmpty
    }

    func isStorageReserved(applicationStorageID: UUID, profileStorageID: UUID) -> Bool {
        lock.withLock {
            durableActivities.values.contains {
                $0.isDataOperation && $0.identity.applicationStorageID == applicationStorageID
                    && $0.identity.profileStorageID == profileStorageID
            }
                || requests.values.contains {
                    $0.isDataOperation && $0.identity.applicationStorageID == applicationStorageID
                        && $0.identity.profileStorageID == profileStorageID
                }
        }
    }

    func refreshForHealthInspection() -> Bool {
        do { _ = try reconcileDurableActivity(); return true } catch { return false }
    }

    func activeProfileStorageIDs(
        applicationStorageID: UUID,
        profileStorageIDs: Set<UUID>
    ) -> Set<UUID> {
        activeProfileStorageIDs(
            applicationStorageID: applicationStorageID,
            profileStorageIDs: profileStorageIDs, excluding: nil)
    }

    func activeProfileStorageIDs(
        applicationStorageID: UUID, profileStorageIDs: Set<UUID>,
        excluding reservation: ProfileActivityReservation?
    ) -> Set<UUID> {
        let excluded = reservation?.requestIDs ?? []
        return lock.withLock {
            if hasGlobalDurableAmbiguity { return profileStorageIDs }
            var identities = durableActivities.compactMap { id, activity in
                excluded.contains(id) && activity.isDataOperation ? nil : activity.identity
            }
            identities += requests.compactMap { id, activity in
                excluded.contains(id) && activity.isDataOperation ? nil : activity.identity
            }
            return Set(
                identities.filter {
                    $0.applicationStorageID == applicationStorageID
                        && profileStorageIDs.contains($0.profileStorageID)
                }.map(\.profileStorageID))
        }
    }

    private func release(
        identity: ProfileActivityIdentity,
        requestID: UUID,
        generationID: UUID
    ) {
        lock.withLock {
            reconciliationGeneration &+= 1
            guard var activity = requests[requestID] else { return }
            guard
                activity.identity == identity,
                activity.generationID == generationID
            else {
                return
            }
            if activity.leaseCount <= 1 {
                requests.removeValue(forKey: requestID)
            } else {
                activity.leaseCount -= 1
                requests[requestID] = activity
            }
        }
    }

    private func scheduleRefresh() {
        let task = refreshScheduler.schedule(after: 1) { [weak self] in
            guard let self else { return }
            _ = try? self.reconcileDurableActivity()
            self.scheduleRefresh()
        }
        let previous = lock.withLock {
            let prior = refreshTask
            refreshTask = task
            return prior
        }
        previous?.cancel()
    }

    deinit { refreshTask?.cancel() }

}

final class ProfileActivityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseHandler: (@Sendable () -> Void)?

    fileprivate init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        let handler = lock.withLock {
            let handler = releaseHandler
            releaseHandler = nil
            return handler
        }
        handler?()
    }

    deinit {
        release()
    }
}

/// Keep this handle alive through commit/rollback. Pass it as `excluding:` to
/// destructive rechecks, or inject `reservation.activityProvider` into the
/// operation's coordinator. Never exclude reservations from launch admission.
final class ProfileActivityReservation: StorageRelocationActivityProviding, @unchecked Sendable {
    let identities: Set<ProfileActivityIdentity>
    fileprivate let requestIDs: Set<UUID>
    private let registry: ProfileActivityRegistry
    private let lease: ProfileActivityLease
    var activityProvider: ProfileActivityReservation { self }

    fileprivate init(
        identities: Set<ProfileActivityIdentity>, requestIDs: Set<UUID>,
        registry: ProfileActivityRegistry, lease: ProfileActivityLease
    ) {
        self.identities = identities
        self.requestIDs = requestIDs
        self.registry = registry
        self.lease = lease
    }

    func activeProfileStorageIDs(applicationStorageID: UUID, profileStorageIDs: Set<UUID>) -> Set<
        UUID
    > {
        registry.activeProfileStorageIDs(
            applicationStorageID: applicationStorageID,
            profileStorageIDs: profileStorageIDs, excluding: self)
    }

    func isStorageActive(applicationStorageID: UUID, profileStorageID: UUID) -> Bool {
        registry.isStorageActive(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID, excluding: self)
    }

    func release() { lease.release() }
}
