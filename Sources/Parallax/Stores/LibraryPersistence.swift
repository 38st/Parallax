import Foundation

protocol LibraryPersisting {
    func load() throws -> [ManagedApplication]
    func save(_ applications: [ManagedApplication]) throws
}

enum LibraryPersistenceError: LocalizedError {
    case unsupportedVersion(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(found, supported):
            String(localized: "The library was written by a newer version of Parallax (format v\(found)). This build supports up to v\(supported).")
        }
    }
}

struct LibraryPersistence: LibraryPersisting {
    private let fileSystem: any FileSystem
    private let applicationSupportURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        applicationSupportURL: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.applicationSupportURL = applicationSupportURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    init(fileManager: FileManager, applicationSupportURL: URL? = nil) {
        self.init(
            fileSystem: LocalFileSystem(fileManager: fileManager),
            applicationSupportURL: applicationSupportURL
        )
    }

    func load() throws -> [ManagedApplication] {
        let url = try libraryURL()
        guard fileSystem.fileExists(at: url) else { return [] }
        let data = try fileSystem.readData(at: url)
        return try Self.decodeApplications(from: data, decoder: decoder)
    }

    func save(_ applications: [ManagedApplication]) throws {
        let url = try libraryURL()
        let parentURL = url.deletingLastPathComponent()
        try fileSystem.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let data = try encoder.encode(LibraryDocument(applications: applications))

        do {
            try fileSystem.writeData(data, to: temporaryURL)
            try fileSystem.replaceItem(at: url, withItemAt: temporaryURL)
        } catch {
            if fileSystem.fileExists(at: temporaryURL) {
                do {
                    try fileSystem.removeItem(at: temporaryURL)
                } catch {
                    AppLog.persistence.error(
                        "Failed to remove temporary library file: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    static func decodeApplications(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [ManagedApplication] {
        if let document = try? decoder.decode(LibraryDocument.self, from: data) {
            guard document.version <= LibraryDocument.currentVersion else {
                throw LibraryPersistenceError.unsupportedVersion(found: document.version, supported: LibraryDocument.currentVersion)
            }
            return document.applications
        }

        return try decoder.decode([ManagedApplication].self, from: data)
    }

    private func libraryURL() throws -> URL {
        let baseURL: URL
        if let applicationSupportURL {
            baseURL = applicationSupportURL
        } else {
            baseURL = try fileSystem.applicationSupportURL(create: true)
        }

        return baseURL
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}
