import Foundation

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
