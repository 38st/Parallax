import Foundation
import Security

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
