import Foundation

struct LibraryPersistence {
    private let fileManager: FileManager
    private let applicationSupportURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, applicationSupportURL: URL? = nil) {
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> [ManagedApplication] {
        let url = try libraryURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try Self.decodeApplications(from: data, decoder: decoder)
    }

    func save(_ applications: [ManagedApplication]) throws {
        let url = try libraryURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(LibraryDocument(applications: applications))
        try data.write(to: url, options: [.atomic])
    }

    static func decodeApplications(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [ManagedApplication] {
        if let document = try? decoder.decode(LibraryDocument.self, from: data) {
            return document.applications
        }

        return try decoder.decode([ManagedApplication].self, from: data)
    }

    private func libraryURL() throws -> URL {
        let baseURL: URL
        if let applicationSupportURL {
            baseURL = applicationSupportURL
        } else {
            baseURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        return baseURL
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}
