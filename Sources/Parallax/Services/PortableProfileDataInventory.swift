import Foundation

enum PortableProfileDataKind: String, Codable, Equatable, Sendable {
    case profileRoot
    case userData
    case codexHome
}

enum PortableProfileDataSource: String, Codable, Equatable, Sendable {
    case managed
    case external
}

enum PortableProfileDataDisposition: String, Codable, Equatable, Sendable {
    case includedPayload
    case excludedExternal
}

struct PortableProfileDataInventoryEntry:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let applicationStorageID: UUID
    let profileStorageID: UUID
    let kind: PortableProfileDataKind
    let declaredPath: String
    let source: PortableProfileDataSource
    let disposition: PortableProfileDataDisposition
    let archiveRelativePath: String?

    static func managed(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        kind: PortableProfileDataKind,
        declaredPath: String,
        archiveRelativePath: String
    ) -> PortableProfileDataInventoryEntry {
        PortableProfileDataInventoryEntry(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            kind: kind,
            declaredPath: declaredPath,
            source: .managed,
            disposition: .includedPayload,
            archiveRelativePath: archiveRelativePath
        )
    }

    static func external(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        kind: PortableProfileDataKind,
        declaredPath: String
    ) -> PortableProfileDataInventoryEntry {
        PortableProfileDataInventoryEntry(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            kind: kind,
            declaredPath: declaredPath,
            source: .external,
            disposition: .excludedExternal,
            archiveRelativePath: nil
        )
    }
}

enum PortableProfileDataInventoryValidator {
    static func validate(
        _ inventory: [PortableProfileDataInventoryEntry]
    ) throws {
        var archivePaths: Set<String> = []
        var entries: Set<PortableProfileDataInventoryEntry> = []
        for entry in inventory {
            guard
                isSafeAbsoluteDeclaredPath(entry.declaredPath),
                entries.insert(entry).inserted
            else {
                throw PortableConfigurationError.invalidProfileDataInventory
            }
            switch (entry.source, entry.disposition) {
            case (.managed, .includedPayload):
                guard
                    let archivePath = entry.archiveRelativePath,
                    isSafeArchiveRelativePath(archivePath),
                    archivePaths.insert(archivePath).inserted
                else {
                    throw PortableConfigurationError
                        .invalidProfileDataInventory
                }
            case (.external, .excludedExternal):
                guard entry.archiveRelativePath == nil else {
                    throw PortableConfigurationError
                        .invalidProfileDataInventory
                }
            default:
                throw PortableConfigurationError.invalidProfileDataInventory
            }
        }
    }

    private static func isSafeAbsoluteDeclaredPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !containsControlCharacter(path) else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.contains { $0 == "." || $0 == ".." }
    }

    private static func isSafeArchiveRelativePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasSuffix("/"),
            !path.contains("\\"),
            !containsControlCharacter(path)
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":")
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}
