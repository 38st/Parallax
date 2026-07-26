import Foundation
import Security

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

struct KeychainSecretStore: SecretStoring, Sendable {
    private static let service =
        "com.parallax.Parallax.launch-environment-secrets"

    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw SecretStoreError.missing(reference)
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(
                operation: .read,
                status: status
            )
        }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw SecretStoreError.invalidStoredValue(reference)
        }
        return SecretValue(value)
    }

    func store(
        _ value: SecretValue,
        for reference: EnvironmentSecretReference
    ) async throws {
        let data = value.withValue { Data($0.utf8) }
        var attributes = baseQuery(for: reference)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(for: reference) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.keychainFailure(
                    operation: .update,
                    status: updateStatus
                )
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.keychainFailure(
                operation: .write,
                status: addStatus
            )
        }
    }

    func remove(_ reference: EnvironmentSecretReference) async throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(
                operation: .delete,
                status: status
            )
        }
    }

    private func baseQuery(
        for reference: EnvironmentSecretReference
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference.id.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false,
        ]
    }
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

enum EnvironmentPreviewDisplayValue: Equatable, Sendable {
    case plain(String)
    case redacted
}

struct EnvironmentPreviewEntry: Equatable, Sendable {
    let key: String
    let displayValue: EnvironmentPreviewDisplayValue
    let isSensitive: Bool
}

enum SensitiveLiteralExportPolicy: Sendable {
    case omit
    case redact
    case includeAfterExplicitConfirmation
}

struct ExportedEnvironmentAssignment: Codable, Equatable, Sendable {
    enum Disposition: String, Codable, Sendable {
        case plain
        case redacted
        case secretReference
    }

    let key: String
    let value: String
    let disposition: Disposition
}

struct EnvironmentDisclosurePolicy: Sendable {
    private let classifier: SensitiveEnvironmentKeyClassifier

    init(explicitSensitiveKeys: Set<String> = []) {
        classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys: explicitSensitiveKeys
        )
    }

    func preview(
        _ assignments: [StoredEnvironmentAssignment],
        revealSensitiveLiterals: Bool = false
    ) -> [EnvironmentPreviewEntry] {
        assignments.map { assignment in
            let classified = classifier.isSensitive(assignment.key)
            switch assignment.value {
            case .secretReference:
                return EnvironmentPreviewEntry(
                    key: assignment.key,
                    displayValue: .redacted,
                    isSensitive: true
                )
            case .literal(let value):
                let shouldRedact = classified && !revealSensitiveLiterals
                return EnvironmentPreviewEntry(
                    key: assignment.key,
                    displayValue: shouldRedact ? .redacted : .plain(value),
                    isSensitive: classified
                )
            }
        }
    }

    func export(
        _ assignments: [StoredEnvironmentAssignment],
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) -> [ExportedEnvironmentAssignment] {
        assignments.compactMap { assignment in
            switch assignment.value {
            case .secretReference(let reference):
                return ExportedEnvironmentAssignment(
                    key: assignment.key,
                    value: reference.token,
                    disposition: .secretReference
                )
            case .literal(let value):
                guard classifier.isSensitive(assignment.key) else {
                    return ExportedEnvironmentAssignment(
                        key: assignment.key,
                        value: value,
                        disposition: .plain
                    )
                }
                switch sensitiveLiteralPolicy {
                case .omit:
                    return nil
                case .redact:
                    return ExportedEnvironmentAssignment(
                        key: assignment.key,
                        value: "<redacted>",
                        disposition: .redacted
                    )
                case .includeAfterExplicitConfirmation:
                    return ExportedEnvironmentAssignment(
                        key: assignment.key,
                        value: value,
                        disposition: .plain
                    )
                }
            }
        }
    }
}
