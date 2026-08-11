import Foundation
import RelayCore

public enum RelayCodexSessionState: Equatable, Sendable {
    case idle
    case initializing
    case ready
    case startingThread
    case threadReady(threadID: String)
    case startingTurn(threadID: String)
    case turnRunning(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String, status: String)
    case failed
    case closed
}

public enum RelayCodexSessionError: Error, Equatable, Sendable {
    case invalidState
    case unknownResponseID
    case duplicateResponseID
    case malformedResponse
    case serverError(code: Int, message: String)
    case unknownApproval
    case approvalAlreadyResolved
    case malformedApproval
    case approvalContextMismatch
    case approvalOutsideAuthority
    case durableDecisionMismatch
    case durableDecisionAlreadyUsed
    case eventBufferOverflow
    case eventConsumerUnavailable
    case transportFailure
    case closed
}

public enum RelayCodexApprovalKind: String, Codable, Equatable, Sendable {
    case commandExecution
    case fileChange
}

/// Fully parsed, immutable authority request. Its digest covers the raw request
/// plus the exact Relay task, stage, attempt, and workspace identities.
public struct RelayCodexApprovalRequest: Equatable, Sendable {
    public let id: RelayRPCID
    public let kind: RelayCodexApprovalKind
    public let method: String
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let workspacePath: String
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let requestDigest: RelayDigest
    public let durableDecisionScope: String
    public let permitsAcceptance: Bool
    public let params: RelayJSONValue
}

/// The caller must construct this token only after the exact Relay decision has
/// been durably recorded. `resolveApproval` independently verifies every bound
/// field and consumes both the RPC request and decision identifier once.
public struct RelayCodexDurableDecisionToken: Equatable, Sendable {
    public let decision: RelayDecision
    public let requestDigest: RelayDigest

    public init(
        decision: RelayDecision,
        request: RelayCodexApprovalRequest
    ) {
        self.decision = decision
        requestDigest = request.requestDigest
    }
}

public enum RelayCodexSessionEvent: Equatable, Sendable {
    case initialized
    case threadStarted(String)
    case turnStarted(threadID: String, turnID: String)
    case approvalRequested(RelayCodexApprovalRequest)
    case notification(method: String, params: RelayJSONValue?)
    case turnCompleted(threadID: String, turnID: String, status: String)
    case requestFailed(code: Int, message: String)
}

/// Correlates the stable app-server JSON-RPC protocol independently from the
/// child-process implementation. It rejects duplicate and unknown responses,
/// exposes server approvals as durable host decisions, and never grants
/// session-wide approval.
public actor RelayCodexSession {
    public nonisolated let events: AsyncStream<RelayCodexSessionEvent>

    private enum PendingRequest: Equatable {
        case initialize
        case startThread
        case startTurn(threadID: String)
        case interrupt(threadID: String, turnID: String)
    }

    private struct ApprovalState {
        let request: RelayCodexApprovalRequest
        var resolved: Bool
    }

    private let context: RelayCodexControlContext
    private let sendBytes: @Sendable (Data) async throws -> Void
    private let continuation: AsyncStream<RelayCodexSessionEvent>.Continuation
    private var decoder = RelayJSONLDecoder()
    private var nextRequestID: Int64 = 1
    private var pending: [RelayRPCID: PendingRequest] = [:]
    private var completedResponseIDs: Set<RelayRPCID> = []
    private var approvals: [RelayRPCID: ApprovalState] = [:]
    private var seenApprovalIDs: Set<RelayRPCID> = []
    private var usedDecisionIDs: Set<RelayDecisionID> = []
    private var internalState: RelayCodexSessionState = .idle

    public init(
        context: RelayCodexControlContext,
        eventBufferCapacity: Int = 256,
        sendBytes: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.context = context
        self.sendBytes = sendBytes
        let stream = AsyncStream.makeStream(
            of: RelayCodexSessionEvent.self,
            bufferingPolicy: .bufferingOldest(max(1, eventBufferCapacity))
        )
        events = stream.stream
        continuation = stream.continuation
    }

    deinit {
        continuation.finish()
    }

    public var state: RelayCodexSessionState { internalState }

    public func initialize() async throws {
        guard internalState == .idle else {
            throw RelayCodexSessionError.invalidState
        }
        internalState = .initializing
        try await send(
            RelayCodexMessages.initialize(id: 0),
            id: .integer(0),
            kind: .initialize
        )
    }

    public func startThread(
        model: String? = nil
    ) async throws {
        guard internalState == .ready else {
            throw RelayCodexSessionError.invalidState
        }
        let id = allocateID()
        internalState = .startingThread
        try await send(
            RelayCodexMessages.startThread(
                id: id,
                workspace: context.workspace,
                model: model
            ),
            id: .integer(id),
            kind: .startThread
        )
    }

    public func startTurn(
        prompt: String,
        outputSchema: RelayJSONValue
    ) async throws {
        guard case let .threadReady(threadID) = internalState else {
            throw RelayCodexSessionError.invalidState
        }
        let id = allocateID()
        internalState = .startingTurn(threadID: threadID)
        try await send(
            RelayCodexMessages.startTurn(
                id: id,
                threadID: threadID,
                prompt: prompt,
                context: context,
                outputSchema: outputSchema
            ),
            id: .integer(id),
            kind: .startTurn(threadID: threadID)
        )
    }

    public func interrupt() async throws {
        guard case let .turnRunning(threadID, turnID) = internalState else {
            throw RelayCodexSessionError.invalidState
        }
        invalidateApprovals()
        let id = allocateID()
        try await send(
            RelayCodexMessages.interruptTurn(
                id: id,
                threadID: threadID,
                turnID: turnID
            ),
            id: .integer(id),
            kind: .interrupt(threadID: threadID, turnID: turnID)
        )
    }

    public func resolveApproval(
        request: RelayCodexApprovalRequest,
        token: RelayCodexDurableDecisionToken
    ) async throws {
        guard var approval = approvals[request.id] else {
            throw RelayCodexSessionError.unknownApproval
        }
        guard !approval.resolved else {
            throw RelayCodexSessionError.approvalAlreadyResolved
        }
        guard approval.request == request,
              token.requestDigest == request.requestDigest,
              token.decision.taskID == context.taskID,
              token.decision.kind == .executeRepositoryCode,
              token.decision.scope == request.durableDecisionScope,
              token.decision.decidedAt != nil,
              token.decision.rationale?.isEmpty == false
        else {
            throw RelayCodexSessionError.durableDecisionMismatch
        }
        guard !usedDecisionIDs.contains(token.decision.id) else {
            throw RelayCodexSessionError.durableDecisionAlreadyUsed
        }
        let accepted: Bool
        switch token.decision.status {
        case .granted:
            guard request.permitsAcceptance else {
                throw RelayCodexSessionError.approvalOutsideAuthority
            }
            accepted = true
        case .denied:
            accepted = false
        case .requested:
            throw RelayCodexSessionError.durableDecisionMismatch
        }
        approval.resolved = true
        approvals[request.id] = approval
        usedDecisionIDs.insert(token.decision.id)
        do {
            try await sendBytes(
                RelayCodexMessages.encode(
                    RelayCodexMessages.approvalResponse(
                        id: request.id,
                        accepted: accepted
                    )
                )
            )
        } catch {
            transitionToFailed()
            throw error
        }
    }

    public func receive(_ bytes: Data) async throws {
        guard internalState != .closed else {
            throw RelayCodexSessionError.closed
        }
        guard internalState != .failed else {
            throw RelayCodexSessionError.transportFailure
        }
        do {
            for message in try decoder.append(bytes) {
                try await handle(message)
            }
        } catch {
            transitionToFailed()
            throw error
        }
    }

    public func close() throws {
        guard internalState != .closed else { return }
        guard internalState != .failed else { return }
        do {
            try decoder.finish()
            invalidateApprovals()
            internalState = .closed
            continuation.finish()
        } catch {
            transitionToFailed()
            throw error
        }
    }

    public func cancelAndClose() {
        guard internalState != .closed, internalState != .failed else { return }
        invalidateApprovals()
        internalState = .closed
        continuation.finish()
    }

    public func failTransport() {
        transitionToFailed()
    }

    private func send(
        _ message: RelayRPCMessage,
        id: RelayRPCID,
        kind: PendingRequest
    ) async throws {
        pending[id] = kind
        do {
            try await sendBytes(RelayCodexMessages.encode(message))
        } catch {
            pending.removeValue(forKey: id)
            transitionToFailed()
            throw error
        }
    }

    private func allocateID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func handle(_ message: RelayRPCMessage) async throws {
        if message.isResponse {
            try await handleResponse(message)
        } else if message.isServerRequest {
            try handleServerRequest(message)
        } else if message.isNotification {
            try handleNotification(message)
        } else {
            throw RelayCodexProtocolError.invalidMessageShape
        }
    }

    private func handleResponse(_ message: RelayRPCMessage) async throws {
        guard let id = message.id else {
            throw RelayCodexSessionError.malformedResponse
        }
        if completedResponseIDs.contains(id) {
            internalState = .failed
            throw RelayCodexSessionError.duplicateResponseID
        }
        guard let request = pending.removeValue(forKey: id) else {
            internalState = .failed
            throw RelayCodexSessionError.unknownResponseID
        }
        completedResponseIDs.insert(id)
        if let error = message.error {
            internalState = .failed
            try publish(.requestFailed(
                code: error.code,
                message: error.message
            ))
            throw RelayCodexSessionError.serverError(
                code: error.code,
                message: error.message
            )
        }
        guard let result = message.result else {
            internalState = .failed
            throw RelayCodexSessionError.malformedResponse
        }

        switch request {
        case .initialize:
            try await sendBytes(
                RelayCodexMessages.encode(RelayCodexMessages.initialized)
            )
            internalState = .ready
            try publish(.initialized)

        case .startThread:
            guard let threadID = result["thread"]?["id"]?.stringValue,
                  !threadID.isEmpty
            else {
                internalState = .failed
                throw RelayCodexSessionError.malformedResponse
            }
            internalState = .threadReady(threadID: threadID)
            try publish(.threadStarted(threadID))

        case let .startTurn(threadID):
            guard let turnID = result["turn"]?["id"]?.stringValue,
                  !turnID.isEmpty
            else {
                internalState = .failed
                throw RelayCodexSessionError.malformedResponse
            }
            internalState = .turnRunning(
                threadID: threadID,
                turnID: turnID
            )
            try publish(.turnStarted(
                threadID: threadID,
                turnID: turnID
            ))

        case .interrupt:
            guard case .object = result else {
                internalState = .failed
                throw RelayCodexSessionError.malformedResponse
            }
        }
    }

    private func handleServerRequest(_ message: RelayRPCMessage) throws {
        guard let id = message.id, let method = message.method else {
            throw RelayCodexSessionError.malformedResponse
        }
        guard !seenApprovalIDs.contains(id) else {
            throw RelayCodexSessionError.duplicateResponseID
        }
        let request = try approvalRequest(
            id: id,
            method: method,
            params: message.params
        )
        seenApprovalIDs.insert(id)
        approvals[id] = ApprovalState(request: request, resolved: false)
        try publish(.approvalRequested(request))
    }

    private func handleNotification(_ message: RelayRPCMessage) throws {
        guard let method = message.method else { return }
        if method == "serverRequest/resolved" {
            try handleServerRequestResolved(message.params)
            return
        }
        if method == "turn/completed",
           let turn = message.params?["turn"],
           let turnID = turn["id"]?.stringValue,
           let status = turn["status"]?.stringValue,
           case let .turnRunning(threadID, expectedTurnID) = internalState,
           expectedTurnID == turnID
        {
            invalidateApprovals()
            internalState = .turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: status
            )
            try publish(.turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: status
            ))
        } else {
            try publish(.notification(
                method: method,
                params: message.params
            ))
        }
    }

    private func approvalRequest(
        id: RelayRPCID,
        method: String,
        params optionalParams: RelayJSONValue?
    ) throws -> RelayCodexApprovalRequest {
        guard case let .turnRunning(expectedThreadID, expectedTurnID) = internalState,
              let params = optionalParams,
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let itemID = params["itemId"]?.stringValue,
              !itemID.isEmpty
        else {
            throw RelayCodexSessionError.malformedApproval
        }
        guard threadID == expectedThreadID, turnID == expectedTurnID else {
            throw RelayCodexSessionError.approvalContextMismatch
        }
        let workspacePath = try context.workspace.validatedPath()
        let kind: RelayCodexApprovalKind
        switch method {
        case "item/commandExecution/requestApproval":
            guard context.authority.execution != .none,
                  params["cwd"]?.stringValue == workspacePath,
                  hasNonNullValue(params["command"]),
                  params["networkApprovalContext"] == nil,
                  params["additionalPermissions"] == nil,
                  params["proposedExecpolicyAmendment"] == nil
            else {
                throw RelayCodexSessionError.approvalOutsideAuthority
            }
            kind = .commandExecution

        case "item/fileChange/requestApproval":
            guard context.authority.fileSystem == .workspaceWrite,
                  params["grantRoot"]?.stringValue == workspacePath
            else {
                throw RelayCodexSessionError.approvalOutsideAuthority
            }
            kind = .fileChange

        default:
            throw RelayCodexSessionError.approvalOutsideAuthority
        }

        let permitsAcceptance = try permitsAcceptDecision(params)
        let digest = try RelayCanonicalEncoding.digest(
            ApprovalDigestInput(
                method: method,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                taskID: context.taskID,
                stageID: context.stageID,
                attemptID: context.attemptID,
                workspaceDigest: context.workspace.identity.workspaceDigest,
                params: params
            )
        )
        return RelayCodexApprovalRequest(
            id: id,
            kind: kind,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            workspacePath: workspacePath,
            stageID: context.stageID,
            attemptID: context.attemptID,
            requestDigest: digest,
            durableDecisionScope: "relay-codex-approval:\(digest.rawValue)",
            permitsAcceptance: permitsAcceptance,
            params: params
        )
    }

    private func permitsAcceptDecision(
        _ params: RelayJSONValue
    ) throws -> Bool {
        guard let available = params["availableDecisions"] else { return true }
        guard case let .array(values) = available,
              values.allSatisfy({ $0.stringValue != nil })
        else {
            throw RelayCodexSessionError.malformedApproval
        }
        return values.contains(.string("accept"))
    }

    private func hasNonNullValue(_ value: RelayJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    private func handleServerRequestResolved(
        _ optionalParams: RelayJSONValue?
    ) throws {
        guard let params = optionalParams,
              let threadID = params["threadId"]?.stringValue,
              threadID == currentThreadID(),
              let requestIDValue = params["requestId"],
              let requestID = rpcID(requestIDValue),
              seenApprovalIDs.contains(requestID)
        else {
            throw RelayCodexSessionError.approvalContextMismatch
        }
        approvals.removeValue(forKey: requestID)
    }

    private func currentThreadID() -> String? {
        switch internalState {
        case .threadReady(let threadID), .startingTurn(let threadID),
             .turnRunning(let threadID, _), .turnCompleted(let threadID, _, _):
            threadID
        case .idle, .initializing, .ready, .startingThread, .failed, .closed:
            nil
        }
    }

    private func rpcID(_ value: RelayJSONValue) -> RelayRPCID? {
        switch value {
        case .integer(let id): .integer(id)
        case .string(let id): .string(id)
        default: nil
        }
    }

    private func publish(_ event: RelayCodexSessionEvent) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            transitionToFailed()
            throw RelayCodexSessionError.eventBufferOverflow
        case .terminated:
            transitionToFailed()
            throw RelayCodexSessionError.eventConsumerUnavailable
        @unknown default:
            transitionToFailed()
            throw RelayCodexSessionError.eventBufferOverflow
        }
    }

    private func invalidateApprovals() {
        approvals.removeAll(keepingCapacity: false)
    }

    private func transitionToFailed() {
        guard internalState != .closed else { return }
        invalidateApprovals()
        pending.removeAll(keepingCapacity: false)
        internalState = .failed
        continuation.finish()
    }

    private struct ApprovalDigestInput: Codable {
        let method: String
        let threadID: String
        let turnID: String
        let itemID: String
        let taskID: RelayTaskID
        let stageID: RelayStageID
        let attemptID: RelayAttemptID
        let workspaceDigest: RelayDigest
        let params: RelayJSONValue
    }
}
