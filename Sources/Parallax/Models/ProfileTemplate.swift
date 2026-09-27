import Foundation

struct ProfileTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        argumentsText: String = "",
        environmentText: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.notes = notes
    }

    static let defaults: [ProfileTemplate] = [
        ProfileTemplate(
            id: UUID(
                uuid: (
                    0x10, 0, 0, 0, 0, 0, 0x40, 0,
                    0x80, 0, 0, 0, 0, 0, 0, 1
                )
            ),
            name: String(localized: "Personal")
        ),
        ProfileTemplate(
            id: UUID(
                uuid: (
                    0x10, 0, 0, 0, 0, 0, 0x40, 0,
                    0x80, 0, 0, 0, 0, 0, 0, 2
                )
            ),
            name: String(localized: "Work")
        ),
        ProfileTemplate(
            id: UUID(
                uuid: (
                    0x10, 0, 0, 0, 0, 0, 0x40, 0,
                    0x80, 0, 0, 0, 0, 0, 0, 3
                )
            ),
            name: String(localized: "Testing")
        ),
        ProfileTemplate(
            id: UUID(
                uuid: (
                    0x10, 0, 0, 0, 0, 0, 0x40, 0,
                    0x80, 0, 0, 0, 0, 0, 0, 4
                )
            ),
            name: String(localized: "Throwaway"),
            notes: String(
                localized:
                    "A disposable space for temporary sessions."
            )
        )
    ]

    // Only these exact persisted defaults were mistranslated. Stable identity
    // and all other fields must match before repairing a historical name.
    var correctingLegacyDefaultName: ProfileTemplate {
        guard argumentsText.isEmpty, environmentText.isEmpty else { return self }
        let defaultTemplate: ProfileTemplate?
        switch (id.uuidString.lowercased(), name, notes) {
        case ("10000000-0000-4000-8000-000000000002", "Trabajar", ""):
            defaultTemplate = Self.defaults.first { $0.id == id }
        case ("10000000-0000-4000-8000-000000000004", "Tirar a la basura",
              "Un espacio desechable para sesiones temporales."):
            defaultTemplate = Self.defaults.first { $0.id == id }
        default:
            return self
        }
        guard let defaultTemplate else { return self }
        var corrected = self
        corrected.name = defaultTemplate.name
        return corrected
    }

    static let defaultNames = defaults.map(\.name)
}
