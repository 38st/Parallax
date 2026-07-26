import Foundation

/// An immutable launch target captured before confirmation. Selection changes
/// cannot alter this value; callers must launch the returned snapshot.
struct ImmutableLaunchRequest: Equatable, Sendable {
    let sceneID: UUID
    let applicationName: String
    let profileName: String
    let configurationSnapshot: LaunchConfigurationSource
    let configurationFingerprint: LaunchConfigurationFingerprint

    var requestID: UUID { configurationSnapshot.requestID }
    var applicationID: UUID { configurationSnapshot.applicationID }
    var profileID: UUID { configurationSnapshot.profileID }
    var configurationRevision: UInt64 {
        configurationSnapshot.configurationRevision
    }
}

enum LaunchPendingConfirmationPolicy: Equatable, Sendable {
    case queue
    case rejectNew
}

enum LaunchRequestSubmissionRejection: Equatable, Sendable {
    case sceneAlreadyHasPendingConfirmation(activeRequestID: UUID)
    case duplicateRequestID(UUID)

    var message: String {
        switch self {
        case .sceneAlreadyHasPendingConfirmation:
            String(
                localized:
                    "This window already has a launch confirmation open. Finish or cancel it before starting another launch."
            )
        case .duplicateRequestID:
            String(
                localized:
                    "This launch request has already been submitted."
            )
        }
    }
}

enum LaunchRequestSubmissionResult: Equatable, Sendable {
    case awaitingConfirmation(UUID)
    case queued(UUID, position: Int)
    case rejected(UUID, reason: LaunchRequestSubmissionRejection)
}

enum LaunchRequestCurrentTarget: Equatable, Sendable {
    case available(
        applicationID: UUID,
        profileID: UUID,
        configurationRevision: UInt64,
        configurationFingerprint: LaunchConfigurationFingerprint
    )
    case applicationRemoved
    case profileRemoved
}

enum LaunchRequestInvalidationReason: Equatable, Sendable {
    case applicationRemoved(
        applicationID: UUID,
        applicationName: String
    )
    case profileRemoved(
        profileID: UUID,
        profileName: String
    )
    case targetChanged(
        expectedApplicationID: UUID,
        expectedProfileID: UUID,
        currentApplicationID: UUID,
        currentProfileID: UUID
    )
    case configurationChanged(
        expectedRevision: UInt64,
        currentRevision: UInt64
    )

    var message: String {
        switch self {
        case .applicationRemoved(_, let applicationName):
            String(
                localized:
                    "“\(applicationName)” was removed before launch confirmation. Choose an application and try again."
            )
        case .profileRemoved(_, let profileName):
            String(
                localized:
                    "The “\(profileName)” profile was removed before launch confirmation. Choose a profile and try again."
            )
        case .targetChanged:
            String(
                localized:
                    "The confirmation target no longer matches the captured application and profile. Start a new launch request."
            )
        case .configurationChanged:
            String(
                localized:
                    "The launch configuration changed after the confirmation opened. Review the updated configuration and try again."
            )
        }
    }
}

enum LaunchRequestConfirmationResolution: Equatable, Sendable {
    case confirmed(ImmutableLaunchRequest)
    case invalidated(UUID, reason: LaunchRequestInvalidationReason)
    case notPending(requestedID: UUID, activeRequestID: UUID?)
}

enum LaunchRequestCancellationResolution: Equatable, Sendable {
    case cancelled(UUID)
    case notPending(requestedID: UUID, activeRequestID: UUID?)
}

enum LaunchRequestStatusState: Equatable, Sendable {
    case queuedForConfirmation
    case awaitingConfirmation
    case confirmed
    case launching
    case running
    case terminated
    case cancelled
    case failed(String)
    case invalidated(LaunchRequestInvalidationReason)
    case rejected(LaunchRequestSubmissionRejection)

    fileprivate var progression: Int {
        switch self {
        case .queuedForConfirmation:
            0
        case .awaitingConfirmation:
            1
        case .confirmed:
            2
        case .launching:
            3
        case .running:
            4
        case .terminated, .cancelled, .failed, .invalidated, .rejected:
            5
        }
    }

    fileprivate var isTerminal: Bool {
        switch self {
        case .terminated, .cancelled, .failed, .invalidated, .rejected:
            true
        case .queuedForConfirmation,
             .awaitingConfirmation,
             .confirmed,
             .launching,
             .running:
            false
        }
    }
}

struct LaunchRequestStatus: Equatable, Sendable {
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let profileID: UUID
    let attemptSequence: UInt64
    var state: LaunchRequestStatusState
}

/// Value-semantic coordination for window-scoped confirmations and
/// request-scoped status. It performs no launching or model mutation.
struct LaunchRequestCoordinator: Sendable {
    private struct ScenePending: Sendable {
        var activeRequestID: UUID?
        var queuedRequestIDs: [UUID] = []
    }

    private struct StatusContext: Hashable, Sendable {
        let sceneID: UUID
        let profileID: UUID
    }

    private struct Record: Sendable {
        let request: ImmutableLaunchRequest
        var status: LaunchRequestStatus
    }

    private var nextAttemptSequence: UInt64 = 0
    private var records: [UUID: Record] = [:]
    private var pendingByScene: [UUID: ScenePending] = [:]
    private var latestRequestByContext: [StatusContext: UUID] = [:]

    mutating func submit(
        _ request: ImmutableLaunchRequest,
        policy: LaunchPendingConfirmationPolicy
    ) -> LaunchRequestSubmissionResult {
        guard records[request.requestID] == nil else {
            return .rejected(
                request.requestID,
                reason: .duplicateRequestID(request.requestID)
            )
        }

        nextAttemptSequence &+= 1
        let context = StatusContext(
            sceneID: request.sceneID,
            profileID: request.profileID
        )
        var pending = pendingByScene[request.sceneID] ?? ScenePending()
        let initialState: LaunchRequestStatusState
        let result: LaunchRequestSubmissionResult

        if let activeRequestID = pending.activeRequestID {
            switch policy {
            case .queue:
                pending.queuedRequestIDs.append(request.requestID)
                initialState = .queuedForConfirmation
                result = .queued(
                    request.requestID,
                    position: pending.queuedRequestIDs.count
                )
            case .rejectNew:
                let reason =
                    LaunchRequestSubmissionRejection
                        .sceneAlreadyHasPendingConfirmation(
                            activeRequestID: activeRequestID
                        )
                initialState = .rejected(reason)
                result = .rejected(request.requestID, reason: reason)
            }
        } else {
            pending.activeRequestID = request.requestID
            initialState = .awaitingConfirmation
            result = .awaitingConfirmation(request.requestID)
        }

        records[request.requestID] = Record(
            request: request,
            status: LaunchRequestStatus(
                requestID: request.requestID,
                sceneID: request.sceneID,
                applicationID: request.applicationID,
                profileID: request.profileID,
                attemptSequence: nextAttemptSequence,
                state: initialState
            )
        )
        latestRequestByContext[context] = request.requestID
        pendingByScene[request.sceneID] = pending
        return result
    }

    func pendingConfirmation(
        in sceneID: UUID
    ) -> ImmutableLaunchRequest? {
        guard
            let requestID = pendingByScene[sceneID]?.activeRequestID
        else {
            return nil
        }
        return records[requestID]?.request
    }

    func queuedConfirmations(
        in sceneID: UUID
    ) -> [ImmutableLaunchRequest] {
        (pendingByScene[sceneID]?.queuedRequestIDs ?? [])
            .compactMap { records[$0]?.request }
    }

    mutating func confirm(
        sceneID: UUID,
        requestID: UUID,
        currentTarget: LaunchRequestCurrentTarget
    ) -> LaunchRequestConfirmationResolution {
        let activeRequestID =
            pendingByScene[sceneID]?.activeRequestID
        guard activeRequestID == requestID,
              let record = records[requestID]
        else {
            return .notPending(
                requestedID: requestID,
                activeRequestID: activeRequestID
            )
        }

        let invalidation = invalidationReason(
            for: record.request,
            currentTarget: currentTarget
        )
        if let invalidation {
            records[requestID]?.status.state =
                .invalidated(invalidation)
            advanceConfirmationQueue(in: sceneID)
            return .invalidated(requestID, reason: invalidation)
        }

        records[requestID]?.status.state = .confirmed
        advanceConfirmationQueue(in: sceneID)
        return .confirmed(record.request)
    }

    mutating func cancelConfirmation(
        sceneID: UUID,
        requestID: UUID
    ) -> LaunchRequestCancellationResolution {
        guard var pending = pendingByScene[sceneID] else {
            return .notPending(
                requestedID: requestID,
                activeRequestID: nil
            )
        }
        if pending.activeRequestID == requestID {
            records[requestID]?.status.state = .cancelled
            advanceConfirmationQueue(in: sceneID)
            return .cancelled(requestID)
        }
        guard
            let queuedIndex = pending.queuedRequestIDs.firstIndex(
                of: requestID
            )
        else {
            return .notPending(
                requestedID: requestID,
                activeRequestID: pending.activeRequestID
            )
        }
        pending.queuedRequestIDs.remove(at: queuedIndex)
        pendingByScene[sceneID] = pending
        records[requestID]?.status.state = .cancelled
        return .cancelled(requestID)
    }

    @discardableResult
    mutating func updateStatus(
        requestID: UUID,
        state: LaunchRequestStatusState
    ) -> Bool {
        guard var record = records[requestID] else { return false }
        let current = record.status.state
        guard !current.isTerminal,
              state.progression >= current.progression
        else {
            return false
        }
        record.status.state = state
        records[requestID] = record
        return true
    }

    func status(for requestID: UUID) -> LaunchRequestStatus? {
        records[requestID]?.status
    }

    func visibleStatus(
        sceneID: UUID,
        profileID: UUID
    ) -> LaunchRequestStatus? {
        let context = StatusContext(
            sceneID: sceneID,
            profileID: profileID
        )
        guard let requestID = latestRequestByContext[context] else {
            return nil
        }
        return records[requestID]?.status
    }

    private func invalidationReason(
        for request: ImmutableLaunchRequest,
        currentTarget: LaunchRequestCurrentTarget
    ) -> LaunchRequestInvalidationReason? {
        switch currentTarget {
        case .applicationRemoved:
            return .applicationRemoved(
                applicationID: request.applicationID,
                applicationName: request.applicationName
            )
        case .profileRemoved:
            return .profileRemoved(
                profileID: request.profileID,
                profileName: request.profileName
            )
        case let .available(
            applicationID,
            profileID,
            configurationRevision,
            configurationFingerprint
        ):
            guard
                applicationID == request.applicationID,
                profileID == request.profileID
            else {
                return .targetChanged(
                    expectedApplicationID: request.applicationID,
                    expectedProfileID: request.profileID,
                    currentApplicationID: applicationID,
                    currentProfileID: profileID
                )
            }
            guard
                configurationRevision
                    == request.configurationRevision,
                configurationFingerprint
                    == request.configurationFingerprint
            else {
                return .configurationChanged(
                    expectedRevision: request.configurationRevision,
                    currentRevision: configurationRevision
                )
            }
            return nil
        }
    }

    private mutating func advanceConfirmationQueue(in sceneID: UUID) {
        guard var pending = pendingByScene[sceneID] else { return }
        pending.activeRequestID = nil
        while !pending.queuedRequestIDs.isEmpty {
            let nextRequestID = pending.queuedRequestIDs.removeFirst()
            guard records[nextRequestID] != nil else { continue }
            pending.activeRequestID = nextRequestID
            records[nextRequestID]?.status.state =
                .awaitingConfirmation
            break
        }
        if pending.activeRequestID == nil
            && pending.queuedRequestIDs.isEmpty {
            pendingByScene.removeValue(forKey: sceneID)
        } else {
            pendingByScene[sceneID] = pending
        }
    }
}
