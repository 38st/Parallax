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
                    "A disposable profile for ephemeral sessions."
            )
        )
    ]

    static let defaultNames = defaults.map(\.name)
}
