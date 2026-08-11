import Foundation

enum LibraryImportContentTransformer {
    static func applicationShell(
        from incoming: LibraryImportApplication
    ) -> LibraryImportApplication {
        let application = incoming.application
        return LibraryImportApplication(
            application: ManagedApplication(
                id: application.id,
                storageID: application.storageID,
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier,
                appPath: application.appPath,
                preset: application.preset,
                baseStoragePath: application.baseStoragePath,
                profiles: []
            ),
            canonicalApplicationPath: incoming.canonicalApplicationPath
        )
    }

    static func applicationUsingImportedFields(
        existing: LibraryImportApplication,
        imported: LibraryImportApplication
    ) -> LibraryImportApplication {
        let persisted = existing.application
        let incoming = imported.application
        return LibraryImportApplication(
            application: ManagedApplication(
                id: persisted.id,
                storageID: persisted.storageID,
                displayName: incoming.displayName,
                bundleIdentifier: incoming.bundleIdentifier,
                appPath: incoming.appPath,
                preset: incoming.preset,
                baseStoragePath: incoming.baseStoragePath,
                profiles: persisted.profiles
            ),
            canonicalApplicationPath: imported.canonicalApplicationPath
        )
    }

    static func freshApplication(
        from incoming: LibraryImportApplication,
        renamedTo name: String,
        identity: LibraryImportFreshApplicationIdentity,
        profiles: [LaunchProfile]
    ) -> LibraryImportApplication {
        let application = incoming.application
        return LibraryImportApplication(
            application: ManagedApplication(
                id: identity.id,
                storageID: identity.storageID,
                displayName: name,
                bundleIdentifier: application.bundleIdentifier,
                appPath: application.appPath,
                preset: application.preset,
                baseStoragePath: application.baseStoragePath,
                profiles: profiles
            ),
            canonicalApplicationPath: incoming.canonicalApplicationPath
        )
    }

    static func profileUsingImportedContent(
        existing: LaunchProfile,
        imported: LaunchProfile
    ) -> LaunchProfile {
        profile(
            imported,
            id: existing.id,
            storageID: existing.storageID,
            name: imported.name
        )
    }

    static func freshProfile(
        from imported: LaunchProfile,
        renamedTo name: String? = nil,
        identity: LibraryImportFreshProfileIdentity
    ) -> LaunchProfile {
        profile(
            imported,
            id: identity.id,
            storageID: identity.storageID,
            name: name ?? imported.name
        )
    }

    private static func profile(
        _ source: LaunchProfile,
        id: UUID,
        storageID: UUID,
        name: String
    ) -> LaunchProfile {
        LaunchProfile(
            id: id,
            storageID: storageID,
            name: name,
            argumentsText: source.argumentsText,
            environmentText: source.environmentText,
            notes: source.notes,
            isolationOwnership: source.isolationOwnership,
            childEnvironmentPolicy: source.childEnvironmentPolicy,
            sensitiveEnvironmentKeys: source.sensitiveEnvironmentKeys,
            launchConfigurationTrust: source.launchConfigurationTrust,
            lastLaunchedAt: source.lastLaunchedAt
        )
    }
}
