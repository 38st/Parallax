import Foundation

struct SensitiveLaunchArgumentPolicy: Sendable {
    private static let sensitiveNameFragments = [
        "access-key",
        "api-key",
        "auth-token",
        "client-secret",
        "credential",
        "password",
        "passwd",
        "private-key",
        "secret",
        "token",
    ]
    private static let knownNonSecretOptions: Set<String> = [
        "password-store",
        "password-store-metrics-reporting",
        "use-mock-keychain",
    ]

    func sensitiveTokenIndexes(
        in tokens: [LaunchArgumentToken]
    ) -> Set<Int> {
        var indexes: Set<Int> = []
        var index = 0
        while index < tokens.count {
            let value = tokens[index].value
            if containsCredentialURL(value)
                || EnvironmentSecretReference(token: value) != nil
            {
                indexes.insert(index)
                index += 1
                continue
            }

            guard value.hasPrefix("-") else {
                index += 1
                continue
            }
            let optionAndValue = value
                .drop(while: { $0 == "-" })
                .split(separator: "=", maxSplits: 1)
            let option = normalizedOption(String(optionAndValue[0]))
            guard isSensitiveOption(option) else {
                index += 1
                continue
            }
            if optionAndValue.count == 2 {
                indexes.insert(index)
            } else if index + 1 < tokens.count {
                indexes.insert(index + 1)
            } else {
                indexes.insert(index)
            }
            index += 1
        }
        return indexes
    }

    func redactedWords(
        in tokens: [LaunchArgumentToken],
        omission: Bool = false
    ) -> [String] {
        let sensitive = sensitiveTokenIndexes(in: tokens)
        return tokens.enumerated().compactMap { index, token in
            guard sensitive.contains(index) else {
                return token.value
            }
            return omission ? nil : "<redacted>"
        }
    }

    private func normalizedOption(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private func isSensitiveOption(_ option: String) -> Bool {
        guard !Self.knownNonSecretOptions.contains(option) else {
            return false
        }
        return Self.sensitiveNameFragments.contains {
            option == $0 || option.hasSuffix("-\($0)")
        }
    }

    private func containsCredentialURL(_ value: String) -> Bool {
        guard
            value.contains("://"),
            let components = URLComponents(string: value)
        else {
            return false
        }
        return components.user?.isEmpty == false
            || components.password != nil
    }
}
