import Foundation

enum LibraryImportConflictNormalization {
    static func name(_ value: String) -> String {
        DisplayNameValidator.collisionKey(value)
    }

    static func path(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    static func bundleIdentifier(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    static func validatedRename(_ value: String) throws -> String {
        guard let normalized = DisplayNameValidator.normalized(value) else {
            throw LibraryImportConflictEngineError.emptyRename
        }
        return normalized
    }
}

enum LibraryImportConflictFieldDiffer {
    static func application(
        _ lhs: LibraryImportApplication,
        _ rhs: LibraryImportApplication
    ) -> Set<LibraryImportApplicationField> {
        var result: Set<LibraryImportApplicationField> = []
        if lhs.application.displayName != rhs.application.displayName {
            result.insert(.displayName)
        }
        if lhs.application.bundleIdentifier
            != rhs.application.bundleIdentifier
        {
            result.insert(.bundleIdentifier)
        }
        if LibraryImportConflictNormalization.path(
            lhs.canonicalApplicationPath
        ) != LibraryImportConflictNormalization.path(
            rhs.canonicalApplicationPath
        ) || lhs.application.appPath != rhs.application.appPath {
            result.insert(.applicationPath)
        }
        if lhs.application.preset != rhs.application.preset {
            result.insert(.preset)
        }
        if lhs.application.baseStoragePath
            != rhs.application.baseStoragePath
        {
            result.insert(.baseStoragePath)
        }
        return result
    }

    static func profile(
        _ lhs: LaunchProfile,
        _ rhs: LaunchProfile
    ) -> Set<LibraryImportProfileField> {
        var result: Set<LibraryImportProfileField> = []
        if lhs.name != rhs.name { result.insert(.name) }
        if lhs.argumentsText != rhs.argumentsText {
            result.insert(.arguments)
        }
        if lhs.environmentText != rhs.environmentText {
            result.insert(.environment)
        }
        if lhs.notes != rhs.notes { result.insert(.notes) }
        if lhs.isolationOwnership != rhs.isolationOwnership {
            result.insert(.isolationOwnership)
        }
        if lhs.childEnvironmentPolicy != rhs.childEnvironmentPolicy {
            result.insert(.childEnvironmentPolicy)
        }
        if lhs.sensitiveEnvironmentKeys != rhs.sensitiveEnvironmentKeys {
            result.insert(.sensitiveEnvironmentKeys)
        }
        // Trust and launch history are persistence state, not configuration
        // identity. They are copied by use-imported but never create conflicts.
        return result
    }
}
