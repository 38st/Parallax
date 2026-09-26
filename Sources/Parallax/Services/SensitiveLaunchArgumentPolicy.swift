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
        "secret-key",
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
            if containsSensitiveValue(value)
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
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = optionAndValue.first, !name.isEmpty else {
                index += 1
                continue
            }
            let option = normalizedOption(String(name))
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
        var sensitive = sensitiveTokenIndexes(in: tokens)
        if omission {
            for index in sensitive where index > 0 {
                let previous = tokens[index - 1].value
                if previous.hasPrefix("-"), previous != "--", previous != "-",
                   !previous.contains("="),
                   isSensitiveOption(
                        normalizedOption(String(previous.drop(while: { $0 == "-" })))
                    )
                {
                    sensitive.insert(index - 1)
                }
            }
        }
        return tokens.enumerated().compactMap { index, token in
            guard sensitive.contains(index) else {
                return token.value
            }
            return omission ? nil : "<redacted>"
        }
    }

    private func normalizedOption(_ value: String) -> String {
        value.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1-$2",
            options: .regularExpression
        ).lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private func isSensitiveOption(_ option: String) -> Bool {
        guard !Self.knownNonSecretOptions.contains(option) else {
            return false
        }
        return Self.sensitiveNameFragments.contains {
            option == $0 || option.hasSuffix("-\($0)")
        }
    }

    func containsSensitiveValue(_ value: String) -> Bool {
        let candidate: String
        if value.hasPrefix("-"), let separator = value.firstIndex(of: "=") {
            candidate = String(value[value.index(after: separator)...])
        } else {
            candidate = value
        }
        return containsCredentialURL(candidate)
            || containsAuthorizationHeader(candidate)
    }

    private func containsAuthorizationHeader(_ value: String) -> Bool {
        value.range(
            of: #"^\s*(?:proxy-)?authorization\s*:\s*(?:bearer|basic)\s+\S+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func containsCredentialURL(_ value: String) -> Bool {
        guard !value.lowercased().hasPrefix("mailto:") else { return false }
        let hasScheme = value.contains("://")
        guard let components = URLComponents(string: hasScheme ? value : "//" + value) else {
            return false
        }
        return components.host?.isEmpty == false && components.password != nil
    }
}
