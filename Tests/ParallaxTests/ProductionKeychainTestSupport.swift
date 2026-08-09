import Foundation
import Security

struct KeychainCharacterizationReplay: Sendable, CustomStringConvertible {
    static let defaultSeed: UInt64 = 0x4B45_592D_5445_5354
    static let seedEnvironmentKey = "PARALLAX_KEYCHAIN_TEST_SEED"
    static let requiredEnvironmentKey =
        "PARALLAX_REQUIRE_PRODUCTION_KEYCHAIN_TESTS"

    let seed: UInt64
    let runID: UUID
    let iterations: Int
    let requiredOnThisHost: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runID: UUID = UUID(),
        iterations: Int = 12
    ) throws {
        if let rawSeed = environment[Self.seedEnvironmentKey] {
            guard let parsed = Self.parseSeed(rawSeed) else {
                throw ProductionKeychainFixtureError.invalidSeed(rawSeed)
            }
            seed = parsed
        } else {
            seed = Self.defaultSeed
        }
        self.runID = runID
        self.iterations = iterations
        requiredOnThisHost = try Self.requiredMode(environment: environment)
    }

    var description: String {
        "KEY-TEST-001 seed=0x\(String(seed, radix: 16, uppercase: true)) "
            + "run=\(runID.uuidString.lowercased()) iterations=\(iterations)"
    }

    static func requiredMode(environment: [String: String]) throws -> Bool {
        guard let rawValue = environment[requiredEnvironmentKey] else {
            return false
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["1", "true", "yes", "required"].contains(value) {
            return true
        }
        if ["0", "false", "no", "optional"].contains(value) {
            return false
        }
        throw ProductionKeychainFixtureError.invalidRequiredMode(rawValue)
    }

    private static func parseSeed(_ raw: String) -> UInt64? {
        if raw.lowercased().hasPrefix("0x") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw, radix: 10)
    }
}

enum KeychainCapabilityDisposition: Equatable {
    case available
    case skip
    case fail
}

enum ProductionKeychainCapabilityPolicy {
    static let unavailableStatuses: Set<OSStatus> = [
        errSecNotAvailable,
        errSecInteractionNotAllowed,
        errSecMissingEntitlement,
        errSecAuthFailed,
    ]

    static func disposition(
        for status: OSStatus,
        required: Bool
    ) -> KeychainCapabilityDisposition {
        if status == errSecSuccess || status == errSecItemNotFound {
            return .available
        }
        if unavailableStatuses.contains(status) {
            return required ? .fail : .skip
        }
        return .fail
    }
}

enum ProductionKeychainFixtureError: Error, CustomStringConvertible {
    case invalidSeed(String)
    case invalidRequiredMode(String)
    case requiredCapabilityUnavailable(status: OSStatus, replay: String)
    case unexpectedStatus(
        operation: String,
        expected: [OSStatus],
        actual: OSStatus,
        replay: String
    )
    case unexpectedResult(operation: String, replay: String)

    var description: String {
        switch self {
        case .invalidSeed(let value):
            "Invalid \(KeychainCharacterizationReplay.seedEnvironmentKey): \(value)"
        case .invalidRequiredMode(let value):
            "Invalid \(KeychainCharacterizationReplay.requiredEnvironmentKey): "
                + "\(value). Use 1/true/yes/required or 0/false/no/optional."
        case .requiredCapabilityUnavailable(let status, let replay):
            "The current production Keychain configuration is required but "
                + "unavailable (status \(status)); \(replay)"
        case let .unexpectedStatus(operation, expected, actual, replay):
            "Keychain \(operation) returned \(actual), expected \(expected); \(replay)"
        case let .unexpectedResult(operation, replay):
            "Keychain \(operation) returned an unexpected result; \(replay)"
        }
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func data(length: Int) -> Data {
        var result = Data()
        result.reserveCapacity(length)
        while result.count < length {
            var word = next().littleEndian
            withUnsafeBytes(of: &word) { bytes in
                result.append(
                    contentsOf: bytes.bindMemory(to: UInt8.self).prefix(
                        min(bytes.count, length - result.count)
                    )
                )
            }
        }
        return result
    }
}

enum ProductionKeychainFixtureMode: Sendable {
    case currentProduction
    case futureDataProtectionProbe

    var servicePrefix: String {
        switch self {
        case .currentProduction:
            "com.parallax.tests.key-test-001.current."
        case .futureDataProtectionProbe:
            "com.parallax.tests.key-test-001.future-dp."
        }
    }

    var usesDataProtectionKeychain: Bool {
        switch self {
        case .currentProduction:
            false
        case .futureDataProtectionProbe:
            true
        }
    }
}

final class ProductionKeychainQueryAudit {
    static let forbiddenProductionServices: Set<String> = [
        "com.parallax.Parallax.launch-environment-secrets",
    ]

    enum Operation: String {
        case add
        case read
        case update
        case delete
        case namespaceCleanup = "namespace-cleanup"
        case namespaceProbe = "namespace-probe"

        var requiresAccount: Bool {
            switch self {
            case .add, .read, .update, .delete:
                true
            case .namespaceCleanup, .namespaceProbe:
                false
            }
        }
    }

    struct Record {
        let operation: Operation
        let itemClass: String?
        let service: String?
        let account: String?
        let synchronizableIsPresent: Bool
        let synchronizable: Bool?
        let dataProtectionIsPresent: Bool
        let dataProtection: Bool?
        let accessibilityIsPresent: Bool
        let accessibility: String?
    }

    private(set) var records: [Record] = []

    func record(operation: Operation, query: [String: Any]) {
        let synchronizableKey = kSecAttrSynchronizable as String
        let dataProtectionKey = kSecUseDataProtectionKeychain as String
        let accessibilityKey = kSecAttrAccessible as String
        records.append(
            Record(
                operation: operation,
                itemClass: query[kSecClass as String] as? String,
                service: query[kSecAttrService as String] as? String,
                account: query[kSecAttrAccount as String] as? String,
                synchronizableIsPresent: query[synchronizableKey] != nil,
                synchronizable: query[synchronizableKey] as? Bool,
                dataProtectionIsPresent: query[dataProtectionKey] != nil,
                dataProtection: query[dataProtectionKey] as? Bool,
                accessibilityIsPresent: query[accessibilityKey] != nil,
                accessibility: query[accessibilityKey] as? String
            )
        )
    }

    func violations(
        expectedService: String,
        accountPrefix: String,
        expectsDataProtection: Bool
    ) -> [String] {
        guard !records.isEmpty else { return ["No Keychain queries were audited."] }
        var failures: [String] = []
        for (index, record) in records.enumerated() {
            let label = "query[\(index)] \(record.operation.rawValue)"
            if record.itemClass != kSecClassGenericPassword as String {
                failures.append("\(label) did not use generic-password class")
            }
            if record.service != expectedService
                || Self.forbiddenProductionServices.contains(record.service ?? "")
                || !expectedService.hasPrefix("com.parallax.tests.key-test-001.")
            {
                failures.append("\(label) escaped the randomized test service")
            }
            if !record.synchronizableIsPresent || record.synchronizable != false {
                failures.append("\(label) did not explicitly set synchronizable=false")
            }
            if expectsDataProtection {
                if !record.dataProtectionIsPresent || record.dataProtection != true {
                    failures.append("\(label) did not opt into data protection")
                }
            } else if record.dataProtectionIsPresent {
                failures.append(
                    "\(label) diverged from production by setting the data-protection flag"
                )
            }
            if record.operation.requiresAccount {
                if record.account?.hasPrefix(accountPrefix) != true {
                    failures.append("\(label) omitted or escaped the randomized account")
                }
            } else if record.account != nil {
                failures.append("\(label) unexpectedly included an account")
            }
            if record.operation == .add {
                if !record.accessibilityIsPresent
                    || record.accessibility
                        != kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                {
                    failures.append(
                        "\(label) did not use WhenUnlockedThisDeviceOnly accessibility"
                    )
                }
            } else if record.accessibilityIsPresent {
                failures.append("\(label) unexpectedly set accessibility")
            }
        }
        return failures
    }
}

struct ProductionKeychainCanaryResult {
    let account: String
    let expectedData: Data
    let addStatus: OSStatus
    let readStatus: OSStatus
    let readData: Data?
    let deleteStatus: OSStatus
    let postDeleteReadStatus: OSStatus

    var firstMutatingUnavailableStatus: OSStatus? {
        [addStatus, deleteStatus].first {
            ProductionKeychainCapabilityPolicy.unavailableStatuses.contains($0)
        }
    }

    var statusDescription: String {
        "add=\(addStatus) read=\(readStatus) delete=\(deleteStatus) "
            + "postDeleteRead=\(postDeleteReadStatus)"
    }
}

struct ProductionKeychainCleanupReport {
    let requiredVerification: Bool
    let possibleAccountsBeforeCleanup: [String]
    let deleteStatus: OSStatus
    let residualStatus: OSStatus

    var succeeded: Bool {
        (deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound)
            && residualStatus == errSecItemNotFound
    }

    var description: String {
        "required=\(requiredVerification) possibleAccounts="
            + "\(possibleAccountsBeforeCleanup) delete=\(deleteStatus) "
            + "residual=\(residualStatus)"
    }
}

final class ProductionKeychainFixture {
    let replay: KeychainCharacterizationReplay
    let mode: ProductionKeychainFixtureMode
    let service: String
    let accountPrefix: String
    let audit = ProductionKeychainQueryAudit()

    private(set) var establishedWriteCapability = false
    private(set) var possibleAccounts = Set<String>()

    init(
        replay: KeychainCharacterizationReplay,
        mode: ProductionKeychainFixtureMode = .currentProduction
    ) {
        self.replay = replay
        self.mode = mode
        let scope = replay.runID.uuidString.lowercased()
        service = mode.servicePrefix + scope
        accountPrefix = "key-test-001.\(scope)."
        precondition(
            !ProductionKeychainQueryAudit.forbiddenProductionServices
                .contains(service)
        )
    }

    func account(iteration: Int) -> String {
        accountPrefix + String(format: "%04d", iteration)
    }

    func runDisposableCanary(data: Data) -> ProductionKeychainCanaryResult {
        let canaryAccount = accountPrefix + "capability-canary"
        let addStatus = add(data, account: canaryAccount)
        let readResult = read(account: canaryAccount)
        let deleteStatus = delete(account: canaryAccount)
        let postDeleteReadStatus = read(account: canaryAccount).0
        return ProductionKeychainCanaryResult(
            account: canaryAccount,
            expectedData: data,
            addStatus: addStatus,
            readStatus: readResult.0,
            readData: readResult.1,
            deleteStatus: deleteStatus,
            postDeleteReadStatus: postDeleteReadStatus
        )
    }

    func add(_ data: Data, account: String) -> OSStatus {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        audit.record(operation: .add, query: attributes)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            establishedWriteCapability = true
            possibleAccounts.insert(account)
        }
        return status
    }

    func read(account: String) -> (OSStatus, Data?) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        audit.record(operation: .read, query: query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ data: Data, account: String) -> OSStatus {
        let query = baseQuery(account: account)
        audit.record(operation: .update, query: query)
        return SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func delete(account: String) -> OSStatus {
        let query = baseQuery(account: account)
        audit.record(operation: .delete, query: query)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            possibleAccounts.remove(account)
        }
        return status
    }

    @discardableResult
    func deleteAll() -> OSStatus {
        let query = serviceQuery()
        audit.record(operation: .namespaceCleanup, query: query)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            possibleAccounts.removeAll()
        }
        return status
    }

    func anyItemStatus() -> OSStatus {
        var query = serviceQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        audit.record(operation: .namespaceProbe, query: query)
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    func cleanupAndInspect() -> ProductionKeychainCleanupReport {
        let possibleBeforeCleanup = possibleAccounts.sorted()
        let deleteStatus = deleteAll()
        let residualStatus = anyItemStatus()
        return ProductionKeychainCleanupReport(
            requiredVerification:
                establishedWriteCapability || !possibleBeforeCleanup.isEmpty,
            possibleAccountsBeforeCleanup: possibleBeforeCleanup,
            deleteStatus: deleteStatus,
            residualStatus: residualStatus
        )
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if mode.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
