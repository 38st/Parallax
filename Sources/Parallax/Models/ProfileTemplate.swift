import Foundation

struct ProfileTemplate: Identifiable, Codable, Hashable {
    var id: UUID
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
        ProfileTemplate(name: "Personal"),
        ProfileTemplate(name: "Work"),
        ProfileTemplate(name: "Testing"),
        ProfileTemplate(name: "Throwaway", notes: "A disposable profile for ephemeral sessions.")
    ]

    static let defaultNames = defaults.map(\.name)
}
