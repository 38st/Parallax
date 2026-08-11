import Darwin
import Foundation
import RelayCore

public enum RelayJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([RelayJSONValue])
    case object([String: RelayJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "non-finite JSON number"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RelayJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(
                [String: RelayJSONValue].self
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .boolean(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "non-finite JSON number"
                    )
                )
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public subscript(key: String) -> RelayJSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

public enum RelayRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public struct RelayRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: RelayJSONValue?

    public init(code: Int, message: String, data: RelayJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct RelayRPCMessage: Codable, Equatable, Sendable {
    public let id: RelayRPCID?
    public let method: String?
    public let params: RelayJSONValue?
    public let result: RelayJSONValue?
    public let error: RelayRPCErrorObject?

    public init(
        id: RelayRPCID? = nil,
        method: String? = nil,
        params: RelayJSONValue? = nil,
        result: RelayJSONValue? = nil,
        error: RelayRPCErrorObject? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var isServerRequest: Bool { id != nil && method != nil }
    public var isNotification: Bool { id == nil && method != nil }
    public var isResponse: Bool {
        id != nil && method == nil && (result != nil || error != nil)
    }
}

public enum RelayCodexProtocolError: Error, Equatable, Sendable {
    case bufferedInputTooLarge
    case lineTooLarge
    case malformedMessage
    case invalidMessageShape
    case invalidWorkspacePath
    case workspaceIdentityChanged
    case stageAuthorityMismatch
}

/// Bounded newline-delimited JSON decoder for the stable stdio app-server
/// transport. Malformed input is terminal to the owning attempt; it is never
/// silently skipped because doing so could lose an approval or completion.
public struct RelayJSONLDecoder: Sendable {
    public static let maximumLineBytes = 1 * 1_024 * 1_024
    public static let maximumBufferedBytes = maximumLineBytes * 2

    private var buffer = Data()
    private let decoder = JSONDecoder()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RelayRPCMessage] {
        buffer.append(bytes)
        guard buffer.count <= Self.maximumBufferedBytes else {
            throw RelayCodexProtocolError.bufferedInputTooLarge
        }
        var messages: [RelayRPCMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumLineBytes else {
                throw RelayCodexProtocolError.lineTooLarge
            }
            let message: RelayRPCMessage
            do {
                message = try decoder.decode(RelayRPCMessage.self, from: line)
            } catch {
                throw RelayCodexProtocolError.malformedMessage
            }
            guard message.isResponse
                    || message.isNotification
                    || message.isServerRequest
            else {
                throw RelayCodexProtocolError.invalidMessageShape
            }
            messages.append(message)
        }
        return messages
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else {
            throw RelayCodexProtocolError.malformedMessage
        }
    }
}

public enum RelayCodexStagePolicy: String, Codable, Sendable {
    case scout
    case implement
    case verify
    case review

    public var isReadOnly: Bool {
        self == .scout || self == .review
    }
}

/// Immutable, identity-pinned workspace authority for one Codex connection.
/// A path string alone is not authority because an ancestor or leaf can be
/// replaced between workspace admission and a later turn.
public struct RelayCodexWorkspaceBinding: Equatable, Sendable {
    public let identity: RelayWorkspaceIdentity

    public init(identity: RelayWorkspaceIdentity) throws {
        self.identity = identity
        _ = try validatedPath()
    }

    public func validatedPath() throws -> String {
        let declared = URL(
            fileURLWithPath: identity.repositoryRootPath,
            isDirectory: true
        ).standardizedFileURL
        guard declared.isFileURL, declared.path.hasPrefix("/") else {
            throw RelayCodexProtocolError.invalidWorkspacePath
        }

        var facts = stat()
        guard lstat(declared.path, &facts) == 0,
              facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_mode & S_IFMT != S_IFLNK
        else {
            throw RelayCodexProtocolError.workspaceIdentityChanged
        }
        let canonical = declared.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == declared.path,
              UInt64(facts.st_dev) == identity.repositoryFileIdentity.deviceID,
              UInt64(facts.st_ino) == identity.repositoryFileIdentity.fileID
        else {
            throw RelayCodexProtocolError.workspaceIdentityChanged
        }
        return canonical.path
    }
}

/// Exact immutable authority attached to one app-server process. The stage and
/// Relay authority must agree before any protocol message can be constructed.
public struct RelayCodexControlContext: Equatable, Sendable {
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let workspace: RelayCodexWorkspaceBinding
    public let stage: RelayCodexStagePolicy
    public let authority: RelayAuthority

    public init(
        taskID: RelayTaskID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        workspace: RelayCodexWorkspaceBinding,
        stage: RelayCodexStagePolicy,
        authority: RelayAuthority
    ) throws {
        let expectsReadOnly = stage == .scout || stage == .review
        let matchingFileSystem =
            (expectsReadOnly && authority.fileSystem == .readOnly)
            || (!expectsReadOnly && authority.fileSystem == .workspaceWrite)
        guard taskID == workspace.identity.taskID,
              matchingFileSystem,
              authority.network == .none,
              authority.externalWrites == .none
        else {
            throw RelayCodexProtocolError.stageAuthorityMismatch
        }
        self.taskID = taskID
        self.stageID = stageID
        self.attemptID = attemptID
        self.workspace = workspace
        self.stage = stage
        self.authority = authority
    }
}

public enum RelayCodexMessages {
    public static func initialize(id: Int64) -> RelayRPCMessage {
        RelayRPCMessage(
            id: .integer(id),
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("parallax_relay"),
                    "title": .string("Parallax Relay"),
                    "version": .string("0.1.0"),
                ]),
            ])
        )
    }

    public static let initialized = RelayRPCMessage(
        method: "initialized",
        params: .object([:])
    )

    public static func startThread(
        id: Int64,
        workspace: RelayCodexWorkspaceBinding,
        model: String? = nil
    ) throws -> RelayRPCMessage {
        let path = try workspace.validatedPath()
        var parameters: [String: RelayJSONValue] = [
            "cwd": .string(path),
            "approvalPolicy": .string("onRequest"),
            "serviceName": .string("parallax_relay"),
        ]
        if let model { parameters["model"] = .string(model) }
        return RelayRPCMessage(
            id: .integer(id),
            method: "thread/start",
            params: .object(parameters)
        )
    }

    public static func startTurn(
        id: Int64,
        threadID: String,
        prompt: String,
        context: RelayCodexControlContext,
        outputSchema: RelayJSONValue
    ) throws -> RelayRPCMessage {
        let path = try context.workspace.validatedPath()
        let sandbox: RelayJSONValue
        if context.stage.isReadOnly {
            sandbox = .object([
                "type": .string("readOnly"),
                "access": restrictedReadAccess(path: path),
            ])
        } else {
            sandbox = .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(path)]),
                "readOnlyAccess": restrictedReadAccess(path: path),
                "networkAccess": .boolean(false),
            ])
        }
        return RelayRPCMessage(
            id: .integer(id),
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(prompt),
                    ]),
                ]),
                "cwd": .string(path),
                "approvalPolicy": .string("onRequest"),
                "sandboxPolicy": sandbox,
                "outputSchema": outputSchema,
            ])
        )
    }

    public static func interruptTurn(
        id: Int64,
        threadID: String,
        turnID: String
    ) -> RelayRPCMessage {
        RelayRPCMessage(
            id: .integer(id),
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    public static func approvalResponse(
        id: RelayRPCID,
        accepted: Bool
    ) -> RelayRPCMessage {
        RelayRPCMessage(
            id: id,
            result: .object([
                "decision": .string(accepted ? "accept" : "decline"),
            ])
        )
    }

    public static func encode(_ message: RelayRPCMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(message)
        bytes.append(0x0A)
        return bytes
    }

    private static func restrictedReadAccess(path: String) -> RelayJSONValue {
        .object([
            "type": .string("restricted"),
            "includePlatformDefaults": .boolean(false),
            "readableRoots": .array([.string(path)]),
        ])
    }
}
