import Foundation

struct EnvironmentSecretReference: Codable, Hashable, Sendable {
    private static let prefix = "{{keychain:"
    private static let suffix = "}}"

    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }

    init?(token: String) {
        guard
            token.hasPrefix(Self.prefix),
            token.hasSuffix(Self.suffix)
        else {
            return nil
        }
        let start = token.index(token.startIndex, offsetBy: Self.prefix.count)
        let end = token.index(token.endIndex, offsetBy: -Self.suffix.count)
        let rawID = String(token[start..<end])
        guard
            rawID.count == 36,
            let id = UUID(uuidString: rawID),
            token == Self.prefix + id.uuidString.lowercased() + Self.suffix
        else {
            return nil
        }
        self.id = id
    }

    var token: String {
        Self.prefix + id.uuidString.lowercased() + Self.suffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let reference = Self(token: token) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Keychain secret reference."
            )
        }
        self = reference
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }

    func withValue<Result>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try body(value)
    }
}

enum SecretStoreError: LocalizedError, Sendable {
    enum Operation: String, Sendable {
        case read
        case write
        case update
        case delete
    }

    case missing(EnvironmentSecretReference)
    case invalidStoredValue(EnvironmentSecretReference)
    case keychainFailure(operation: Operation, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missing(let reference):
            String(
                localized: "The Keychain secret \(reference.id.uuidString.lowercased()) is unavailable."
            )
        case .invalidStoredValue(let reference):
            String(
                localized: "The Keychain secret \(reference.id.uuidString.lowercased()) is not valid text."
            )
        case .keychainFailure(let operation, let status):
            String(
                localized: "Keychain \(operation.rawValue) failed with status \(status)."
            )
        }
    }
}

protocol SecretResolving: Sendable {
    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue
}

protocol SecretStoring: SecretResolving {
    func store(
        _ value: SecretValue,
        for reference: EnvironmentSecretReference
    ) async throws

    func remove(_ reference: EnvironmentSecretReference) async throws
}

enum StoredEnvironmentValue: Codable, Hashable, Sendable {
    case literal(String)
    case secretReference(EnvironmentSecretReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case reference
    }

    private enum Kind: String, Codable {
        case literal
        case secretReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .literal:
            self = .literal(
                try container.decode(String.self, forKey: .value)
            )
        case .secretReference:
            self = .secretReference(
                try container.decode(
                    EnvironmentSecretReference.self,
                    forKey: .reference
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value):
            try container.encode(Kind.literal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .secretReference(let reference):
            try container.encode(Kind.secretReference, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        }
    }

    init(storedText: String) {
        if let reference = EnvironmentSecretReference(token: storedText) {
            self = .secretReference(reference)
        } else {
            self = .literal(storedText)
        }
    }

    var storedText: String {
        switch self {
        case .literal(let value):
            value
        case .secretReference(let reference):
            reference.token
        }
    }
}

struct StoredEnvironmentAssignment: Codable, Hashable, Sendable {
    let key: String
    let value: StoredEnvironmentValue
}

struct SensitiveEnvironmentKeyClassifier: Sendable {
    private static let exactSensitiveKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AZURE_CLIENT_SECRET",
        "DATABASE_URL",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "NPM_TOKEN",
        "OPENAI_API_KEY",
        "SLACK_TOKEN",
    ]
    private static let sensitiveSuffixes = [
        "_ACCESS_KEY",
        "_API_KEY",
        "_CREDENTIAL",
        "_CREDENTIALS",
        "_PASSWORD",
        "_PASSWD",
        "_PRIVATE_KEY",
        "_SECRET",
        "_TOKEN",
    ]

    private let explicitSensitiveKeys: Set<String>

    init(explicitSensitiveKeys: Set<String> = []) {
        self.explicitSensitiveKeys = Set(
            explicitSensitiveKeys.map { $0.uppercased() }
        )
    }

    func isSensitive(_ key: String) -> Bool {
        let normalized = key.uppercased()
        if explicitSensitiveKeys.contains(normalized)
            || Self.exactSensitiveKeys.contains(normalized) {
            return true
        }
        // Public-key material is ordinarily safe to display and export.
        if normalized.hasSuffix("_PUBLIC_KEY") || normalized == "PUBLIC_KEY" {
            return false
        }
        return Self.sensitiveSuffixes.contains {
            normalized.hasSuffix($0)
        }
    }
}
