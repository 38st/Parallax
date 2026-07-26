import Darwin
import Foundation

struct ProfileActivityIdentity: Hashable, Sendable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
}

enum ProfileActivityRegistryError: LocalizedError {
    case requestIdentityConflict(requestID: UUID)
    case profileAlreadyActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    )
    case processExitedBeforeRegistration(pid_t)
    case processIdentityAmbiguous(pid_t)

    var errorDescription: String? {
        switch self {
        case .requestIdentityConflict(let requestID):
            String(
                localized:
                    "Launch request \(requestID.uuidString) is already tracking a different profile."
            )
        case .profileAlreadyActive:
            String(
                localized:
                    "This profile is already launching or running."
            )
        case .processExitedBeforeRegistration(let processIdentifier):
            String(localized: "Process \(processIdentifier) exited before launch tracking completed.")
        case .processIdentityAmbiguous(let processIdentifier):
            String(localized: "Process \(processIdentifier) does not have a verifiable start identity.")
        }
    }
}

struct ProfileActivityReconciliationReport: Equatable, Sendable {
    var recoveredLiveCount = 0
    var removedDeadCount = 0
    var ambiguousCount = 0
}

/// Process-local activity shared by launch lifecycle and managed-data
/// transactions. A request may hold more than one lease, but it cannot silently
/// change identity. Each lease releases at most once, including from `deinit`.
final class ProfileActivityRegistry:
    StorageRelocationActivityProviding,
    @unchecked Sendable
{
    private struct RequestActivity {
        let identity: ProfileActivityIdentity
        var leaseCount: Int
    }

    private struct DurableActivity: Equatable {
        enum Proof: Equatable {
            case running(ProcessStartIdentity)
            case requestOwner(ProcessStartIdentity)
            case ambiguous
        }

        let identity: ProfileActivityIdentity
        let proof: Proof
    }

    private let lock = NSLock()
    private var requests: [UUID: RequestActivity] = [:]
    private var durableActivities: [UUID: DurableActivity] = [:]
    private var hasGlobalDurableAmbiguity = false
    private let durableStore: DurableLaunchActivityStore?
    private let processInspector: any ProcessIdentityInspecting

    init(
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) {
        durableStore = nil
        self.processInspector = processInspector
    }

    init(
        applicationSupportURL: URL,
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) throws {
        durableStore = try DurableLaunchActivityStore(
            applicationSupportURL: applicationSupportURL
        )
        self.processInspector = processInspector
    }

    func acquire(
        identity: ProfileActivityIdentity,
        requestID: UUID
    ) throws -> ProfileActivityLease {
        try lock.withLock {
            let sameStorage: (ProfileActivityIdentity) -> Bool = {
                $0.applicationStorageID
                    == identity.applicationStorageID
                    && $0.profileStorageID
                        == identity.profileStorageID
            }
            let requestConflict = requests.contains {
                $0.key != requestID && sameStorage($0.value.identity)
            }
            let durableConflict = durableActivities.contains {
                $0.key != requestID && sameStorage($0.value.identity)
            }
            guard !requestConflict, !durableConflict else {
                throw ProfileActivityRegistryError.profileAlreadyActive(
                    applicationStorageID:
                        identity.applicationStorageID,
                    profileStorageID: identity.profileStorageID
                )
            }
            if var activity = requests[requestID] {
                guard activity.identity == identity else {
                    throw ProfileActivityRegistryError.requestIdentityConflict(
                        requestID: requestID
                    )
                }
                activity.leaseCount += 1
                requests[requestID] = activity
            } else {
                requests[requestID] = RequestActivity(
                    identity: identity,
                    leaseCount: 1
                )
            }
        }

        return ProfileActivityLease { [weak self] in
            self?.release(identity: identity, requestID: requestID)
        }
    }

    func acquireLaunchLease(
        identity: ProfileActivityIdentity,
        requestID: UUID
    ) throws -> ProfileActivityLease {
        guard let durableStore else {
            return try acquire(identity: identity, requestID: requestID)
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
            ownerProcess: ownerIdentity
        )
        do {
            let lease = try acquire(identity: identity, requestID: requestID)
            lock.withLock {
                durableActivities[requestID] = DurableActivity(
                    identity: identity,
                    proof: .ambiguous
                )
            }
            return lease
        } catch {
            try? durableStore.complete(
                requestID: requestID,
                completion: .failed
            )
            throw error
        }
    }

    func markLaunchOpening(requestID: UUID) throws {
        try durableStore?.markOpening(requestID: requestID)
    }

    func recordRunningProcess(
        requestID: UUID,
        processIdentifier: pid_t
    ) throws {
        guard let durableStore else { return }
        switch processInspector.inspect(processIdentifier: processIdentifier) {
        case .live(let identity):
            try durableStore.recordProcess(
                requestID: requestID,
                process: identity
            )
            lock.withLock {
                guard let existing = durableActivities[requestID] else {
                    return
                }
                durableActivities[requestID] = DurableActivity(
                    identity: existing.identity,
                    proof: .running(identity)
                )
            }
        case .dead:
            throw ProfileActivityRegistryError
                .processExitedBeforeRegistration(processIdentifier)
        case .ambiguous:
            throw ProfileActivityRegistryError
                .processIdentityAmbiguous(processIdentifier)
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
            _ = lock.withLock {
                durableActivities.removeValue(forKey: requestID)
            }
        } catch {
            // The artifact remains an explicit blocker until reconciliation can
            // prove that its process is dead.
            throw error
        }
    }

    @discardableResult
    func reconcileDurableActivity() throws -> ProfileActivityReconciliationReport {
        guard let durableStore else {
            return ProfileActivityReconciliationReport()
        }
        var report = ProfileActivityReconciliationReport()
        var recovered: [UUID: DurableActivity] = [:]
        var globalAmbiguity = false

        for artifact in durableStore.artifacts() {
            let retainAsAmbiguous: () -> Void = {
                report.ambiguousCount += 1
                if let requestID = artifact.requestID,
                   let identity = artifact.identity
                {
                    recovered[requestID] = DurableActivity(
                        identity: identity,
                        proof: .ambiguous
                    )
                } else {
                    globalAmbiguity = true
                }
            }
            let removeAsDead: () -> Void = {
                do {
                    guard let requestID = artifact.requestID else {
                        retainAsAmbiguous()
                        return
                    }
                    try durableStore.removeProvenDeadArtifact(
                        requestID: requestID
                    )
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
                            proof: .requestOwner(owner)
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
            durableActivities = recovered
            hasGlobalDurableAmbiguity = globalAmbiguity
        }
        return report
    }

    func isActive(identity: ProfileActivityIdentity) -> Bool {
        refreshRecoveredActivities()
        return lock.withLock {
            hasGlobalDurableAmbiguity
                || durableActivities.values.contains {
                    $0.identity == identity
                }
                || requests.values.contains {
                    $0.identity == identity && $0.leaseCount > 0
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
        refreshRecoveredActivities()
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

    func isStorageActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> Bool {
        refreshRecoveredActivities()
        return lock.withLock {
            hasGlobalDurableAmbiguity
                || durableActivities.values.contains {
                    $0.identity.applicationStorageID == applicationStorageID
                        && $0.identity.profileStorageID == profileStorageID
                }
                || requests.values.contains {
                    $0.identity.applicationStorageID == applicationStorageID
                        && $0.identity.profileStorageID == profileStorageID
                        && $0.leaseCount > 0
                }
        }
    }

    func activeProfileIDs(
        applicationID: UUID,
        profileIDs: Set<UUID>
    ) -> Set<UUID> {
        refreshRecoveredActivities()
        return lock.withLock {
            if hasGlobalDurableAmbiguity {
                return profileIDs
            }
            let durable = Set(
                durableActivities.values.compactMap { identity in
                    identity.identity.applicationID == applicationID
                        && profileIDs.contains(identity.identity.profileID)
                        ? identity.identity.profileID
                        : nil
                }
            )
            let inMemory = Set<UUID>(
                requests.values.compactMap { activity in
                    let identity = activity.identity
                    guard
                        activity.leaseCount > 0,
                        identity.applicationID == applicationID,
                        profileIDs.contains(identity.profileID)
                    else {
                        return nil
                    }
                    return identity.profileID
                }
            )
            return durable.union(inMemory)
        }
    }

    private func release(
        identity: ProfileActivityIdentity,
        requestID: UUID
    ) {
        lock.withLock {
            guard var activity = requests[requestID] else { return }
            guard activity.identity == identity else { return }
            if activity.leaseCount <= 1 {
                requests.removeValue(forKey: requestID)
            } else {
                activity.leaseCount -= 1
                requests[requestID] = activity
            }
        }
    }

    private func refreshRecoveredActivities() {
        guard let durableStore else { return }
        let snapshot = lock.withLock { durableActivities }
        for (requestID, activity) in snapshot {
            let isProvenDead: Bool
            switch activity.proof {
            case .ambiguous:
                continue
            case .running(let recorded):
                switch processInspector.inspect(
                    processIdentifier: recorded.processIdentifier
                ) {
                case .live(let current):
                    isProvenDead = current != recorded
                case .dead:
                    isProvenDead = true
                case .ambiguous:
                    isProvenDead = false
                }
            case .requestOwner(let owner):
                switch processInspector.inspect(
                    processIdentifier: owner.processIdentifier
                ) {
                case .live(let current):
                    isProvenDead = current != owner
                case .dead:
                    isProvenDead = true
                case .ambiguous:
                    isProvenDead = false
                }
            }
            guard isProvenDead else { continue }
            do {
                try durableStore.removeProvenDeadArtifact(
                    requestID: requestID
                )
                lock.withLock {
                    guard durableActivities[requestID] == activity else {
                        return
                    }
                    durableActivities.removeValue(forKey: requestID)
                }
            } catch {
                // Root/identity ambiguity stays active. Never unblock merely
                // because cleanup could not prove it removed the journaled
                // activity.
            }
        }
    }
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
