enum SettingsCurrentMigrationPresence: Equatable, Sendable {
    case unknown
    case absent
    case present
}

struct SettingsCurrentMigrationAssessment: Equatable, Sendable {
    let source: SettingsRepositoryInspection
    let presence: SettingsCurrentMigrationPresence
}

struct SettingsCurrentMigrationAssessor: Sendable {
    let source: SettingsRepositoryInspection

    func assess() -> SettingsCurrentMigrationAssessment {
        let presence: SettingsCurrentMigrationPresence
        switch source {
        case .missing:
            presence = .absent
        case .current, .future, .recoveryRequired:
            presence = .present
        case .unavailable:
            presence = .unknown
        }
        return .init(source: source, presence: presence)
    }
}
