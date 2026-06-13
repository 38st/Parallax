import Foundation

struct LaunchProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String
    var storageName: String?
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        argumentsText: String = "",
        environmentText: String = "",
        notes: String = "",
        storageName: String? = nil,
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.notes = notes
        self.storageName = storageName
        self.lastLaunchedAt = lastLaunchedAt
    }

    var arguments: [String] {
        ShellWordsParser.parse(argumentsText)
    }

    var environment: [String: String] {
        environmentText
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
                guard let separator = trimmed.firstIndex(of: "=") else { return }

                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                let valueStart = trimmed.index(after: separator)
                let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    result[key] = value
                }
            }
    }
}
