import Foundation
import RelayCore

public enum RelayStageCapabilityPolicyError: Error, Sendable, Equatable {
    case executionNotPermitted
    case networkDenyRequired
    case credentialsUnsupported
    case externalWritesUnsupported
    case noExecutableAllowed
    case invalidInvocationLimit
    case workspaceTaskMismatch
}

/// Immutable execution authority for one exact stage attempt and workspace
/// revision. It is policy data, not a bearer credential; the opaque handle
/// issued by `RelayStageCapabilityIssuer` is required to exercise it.
public struct RelayStageCapabilityPolicy: Sendable, Equatable {
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let workspaceIdentity: RelayWorkspaceIdentity
    public let workspaceDigest: RelayDigest
    public let authority: RelayAuthority
    public let allowedExecutables: Set<RelayExecutableIdentity>
    public let sandboxRequirements: RelaySandboxRequirements
    public let commandBudget: RelayCommandBudget
    public let expiresAt: RelayInstant?
    public let maximumInvocations: UInt32

    public init(
        taskID: RelayTaskID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        workspaceIdentity: RelayWorkspaceIdentity,
        workspaceDigest: RelayDigest,
        authority: RelayAuthority,
        allowedExecutables: Set<RelayExecutableIdentity>,
        sandboxRequirements: RelaySandboxRequirements = .secureDefault,
        commandBudget: RelayCommandBudget,
        expiresAt: RelayInstant? = nil,
        maximumInvocations: UInt32 = 1
    ) throws {
        guard authority.execution != .none else {
            throw RelayStageCapabilityPolicyError.executionNotPermitted
        }
        guard authority.network != .none
                || sandboxRequirements.requiresNetworkDeny
        else {
            throw RelayStageCapabilityPolicyError.networkDenyRequired
        }
        guard authority.credentials == .none else {
            throw RelayStageCapabilityPolicyError.credentialsUnsupported
        }
        guard authority.externalWrites == .none else {
            throw RelayStageCapabilityPolicyError.externalWritesUnsupported
        }
        guard !allowedExecutables.isEmpty else {
            throw RelayStageCapabilityPolicyError.noExecutableAllowed
        }
        guard maximumInvocations > 0 else {
            throw RelayStageCapabilityPolicyError.invalidInvocationLimit
        }
        guard workspaceIdentity.taskID == taskID else {
            throw RelayStageCapabilityPolicyError.workspaceTaskMismatch
        }

        self.taskID = taskID
        self.stageID = stageID
        self.attemptID = attemptID
        self.workspaceIdentity = workspaceIdentity
        self.workspaceDigest = workspaceDigest
        self.authority = authority
        self.allowedExecutables = allowedExecutables
        self.sandboxRequirements = sandboxRequirements
        self.commandBudget = commandBudget
        self.expiresAt = expiresAt
        self.maximumInvocations = maximumInvocations
    }
}

public struct RelayStageCapabilityHandle: Sendable, Equatable, Hashable {
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum RelayStageCapabilityRejection: Error, Sendable, Equatable {
    case unknown
    case revoked
    case expired
    case exhausted
    case wrongTask
    case wrongStage
    case wrongAttempt
    case staleWorkspace
    case executableNotAllowed
    case executableChanged
    case sandboxPolicyMismatch
}

public struct RelayStageExecutionContext: Sendable, Equatable {
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let workspaceIdentity: RelayWorkspaceIdentity
    public let workspaceDigest: RelayDigest
    public let executable: RelayExecutableIdentity

    public init(
        taskID: RelayTaskID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        workspaceIdentity: RelayWorkspaceIdentity,
        workspaceDigest: RelayDigest,
        executable: RelayExecutableIdentity
    ) {
        self.taskID = taskID
        self.stageID = stageID
        self.attemptID = attemptID
        self.workspaceIdentity = workspaceIdentity
        self.workspaceDigest = workspaceDigest
        self.executable = executable
    }
}

public struct RelayStageExecutionAuthorization: Sendable {
    public let policy: RelayStageCapabilityPolicy
    public let executable: RelayExecutableIdentity
    public let sandbox: RelaySandboxExecutionAuthorization
    let revocation: RelayStageRevocationToken

    fileprivate init(
        policy: RelayStageCapabilityPolicy,
        executable: RelayExecutableIdentity,
        sandbox: RelaySandboxExecutionAuthorization,
        revocation: RelayStageRevocationToken
    ) {
        self.policy = policy
        self.executable = executable
        self.sandbox = sandbox
        self.revocation = revocation
    }
}

final class RelayStageRevocationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isRevoked: Bool {
        lock.withLock { revoked }
    }

    func revoke() {
        lock.withLock { revoked = true }
    }
}

/// Process-local issuer for opaque, revocable stage capabilities.
///
/// All request bindings are rechecked at use time. Revocation also flips the
/// shared token held by an in-flight command so the runner can terminate and
/// reap it instead of merely preventing the next invocation.
public final class RelayStageCapabilityIssuer: @unchecked Sendable {
    private struct Record {
        let policy: RelayStageCapabilityPolicy
        let revocation: RelayStageRevocationToken
        var invocationCount: UInt32
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    public init() {}

    public func issue(
        _ policy: RelayStageCapabilityPolicy
    ) -> RelayStageCapabilityHandle {
        lock.withLock {
            var identifier = UUID()
            while records[identifier] != nil { identifier = UUID() }
            records[identifier] = Record(
                policy: policy,
                revocation: RelayStageRevocationToken(),
                invocationCount: 0
            )
            return RelayStageCapabilityHandle(rawValue: identifier)
        }
    }

    public func authorizeExecution(
        handle: RelayStageCapabilityHandle,
        context: RelayStageExecutionContext,
        sandbox: RelaySandboxExecutionAuthorization,
        now: RelayInstant
    ) -> Result<RelayStageExecutionAuthorization, RelayStageCapabilityRejection> {
        lock.withLock {
            guard var record = records[handle.rawValue] else {
                return .failure(.unknown)
            }
            guard !record.revocation.isRevoked else {
                return .failure(.revoked)
            }
            if let expiresAt = record.policy.expiresAt, now >= expiresAt {
                record.revocation.revoke()
                records[handle.rawValue] = record
                return .failure(.expired)
            }
            guard record.invocationCount < record.policy.maximumInvocations else {
                return .failure(.exhausted)
            }
            guard context.taskID == record.policy.taskID else {
                return .failure(.wrongTask)
            }
            guard context.stageID == record.policy.stageID else {
                return .failure(.wrongStage)
            }
            guard context.attemptID == record.policy.attemptID else {
                return .failure(.wrongAttempt)
            }
            guard context.workspaceIdentity == record.policy.workspaceIdentity else {
                return .failure(.staleWorkspace)
            }
            guard context.workspaceDigest == record.policy.workspaceDigest else {
                return .failure(.staleWorkspace)
            }
            guard record.policy.allowedExecutables.contains(context.executable)
            else {
                return .failure(.executableNotAllowed)
            }
            guard context.executable.matchesCurrentFile() else {
                return .failure(.executableChanged)
            }
            guard sandbox.requirements == record.policy.sandboxRequirements else {
                return .failure(.sandboxPolicyMismatch)
            }

            record.invocationCount += 1
            records[handle.rawValue] = record
            return .success(
                RelayStageExecutionAuthorization(
                    policy: record.policy,
                    executable: context.executable,
                    sandbox: sandbox,
                    revocation: record.revocation
                )
            )
        }
    }

    public func revoke(_ handle: RelayStageCapabilityHandle) {
        lock.withLock {
            records[handle.rawValue]?.revocation.revoke()
        }
    }
}
