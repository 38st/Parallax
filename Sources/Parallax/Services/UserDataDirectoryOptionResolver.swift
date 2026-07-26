import Foundation

enum UserDataDirectoryOccurrenceForm: String, Sendable, Equatable {
    case equals
    case split
}

struct UserDataDirectoryOccurrence: Sendable, Equatable {
    let value: String
    let form: UserDataDirectoryOccurrenceForm
    let optionRange: LaunchSourceRange
    let valueRange: LaunchSourceRange?
}

struct UserDataDirectoryResolution: Sendable, Equatable {
    let occurrences: [UserDataDirectoryOccurrence]
    let diagnostics: [LaunchParsingDiagnostic]

    var resolvedValue: String? {
        guard
            occurrences.count == 1,
            diagnostics.allSatisfy({ $0.severity != .error }),
            let value = occurrences.first?.value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }
}

enum UserDataDirectoryOptionResolver {
    private static let option = "--user-data-dir"
    private static let equalsPrefix = "\(option)="

    static func resolve(
        in tokens: [LaunchArgumentToken]
    ) -> UserDataDirectoryResolution {
        var occurrences: [UserDataDirectoryOccurrence] = []
        var diagnostics: [LaunchParsingDiagnostic] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token.value.hasPrefix(equalsPrefix) {
                let value = String(token.value.dropFirst(equalsPrefix.count))
                let occurrence = UserDataDirectoryOccurrence(
                    value: value,
                    form: .equals,
                    optionRange: token.range,
                    valueRange: token.range
                )
                occurrences.append(occurrence)
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diagnostics.append(
                        LaunchParsingDiagnostic(
                            code: .blankUserDataDirectory,
                            source: .arguments,
                            range: token.range
                        )
                    )
                }
                index += 1
                continue
            }

            guard token.value == option else {
                index += 1
                continue
            }

            let followingToken = tokens.indices.contains(index + 1)
                ? tokens[index + 1]
                : nil
            let hasUsableFollowingToken = followingToken.map {
                !$0.value.hasPrefix("--")
            } ?? false

            guard hasUsableFollowingToken, let followingToken else {
                occurrences.append(
                    UserDataDirectoryOccurrence(
                        value: "",
                        form: .split,
                        optionRange: token.range,
                        valueRange: nil
                    )
                )
                diagnostics.append(
                    LaunchParsingDiagnostic(
                        code: .missingUserDataDirectory,
                        source: .arguments,
                        range: token.range
                    )
                )
                index += 1
                continue
            }

            occurrences.append(
                UserDataDirectoryOccurrence(
                    value: followingToken.value,
                    form: .split,
                    optionRange: token.range,
                    valueRange: followingToken.range
                )
            )
            if followingToken.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            {
                diagnostics.append(
                    LaunchParsingDiagnostic(
                        code: .blankUserDataDirectory,
                        source: .arguments,
                        range: followingToken.range
                    )
                )
            }
            index += 2
        }

        if let first = occurrences.first, occurrences.count > 1 {
            for duplicate in occurrences.dropFirst() {
                diagnostics.append(
                    LaunchParsingDiagnostic(
                        code: .duplicateUserDataDirectory,
                        source: .arguments,
                        range: duplicate.optionRange,
                        relatedRange: first.optionRange
                    )
                )
            }
        }

        return UserDataDirectoryResolution(
            occurrences: occurrences,
            diagnostics: diagnostics
        )
    }
}
