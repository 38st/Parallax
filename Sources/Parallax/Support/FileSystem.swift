import Foundation

struct FileSystemItemAttributes: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    var kind: Kind
    var size: UInt64?
    var modificationDate: Date?
    var posixPermissions: Int?
}

/// The filesystem operations Parallax uses for library persistence and profile data.
///
/// Keeping this interface URL-based makes failure behavior independently testable and
/// gives later path-containment and transaction work one boundary to harden.
protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes
    func canonicalURL(for url: URL) throws -> URL
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws
    func applicationSupportURL(create: Bool) throws -> URL
}

struct LocalFileSystem: FileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let kind: FileSystemItemAttributes.Kind
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            kind = .directory
        case .typeRegular:
            kind = .regularFile
        case .typeSymbolicLink:
            kind = .symbolicLink
        default:
            kind = .other
        }
        return FileSystemItemAttributes(
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    func canonicalURL(for url: URL) throws -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.withoutOverwriting])
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        if fileExists(at: destinationURL) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: sourceURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
    }
}
