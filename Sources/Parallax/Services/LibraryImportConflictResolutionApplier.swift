import Foundation

enum LibraryImportConflictResolutionApplier {
    static func applyApplication(
        _ decision: LibraryImportScopedDecision.Application,
        incoming: LibraryImportApplication,
        matches: [LibraryImportApplicationMatch],
        working: inout [LibraryImportApplication]
    ) throws -> Int? {
        switch decision {
        case .keepExisting(let applicationID):
            guard let target = applicationIndex(
                applicationID,
                matches: matches,
                working: working
            ) else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            return target
        case .useImported(let applicationID):
            guard let target = applicationIndex(
                applicationID,
                matches: matches,
                working: working
            ) else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            working[target] = LibraryImportContentTransformer
                .applicationUsingImportedFields(
                    existing: working[target],
                    imported: incoming
                )
            return target
        case .keepBoth(let rename, let identity):
            try appendFreshApplication(
                incoming,
                renamedTo: rename,
                identity: identity,
                working: &working
            )
            return nil
        case .skip:
            return nil
        }
    }

    static func applyProfile(
        _ decision: LibraryImportScopedDecision.Profile,
        importedProfile: LaunchProfile,
        destinationIndex: Int,
        matches: [LibraryImportProfileMatch],
        working: inout [LibraryImportApplication]
    ) throws {
        switch decision {
        case .keepExisting(let applicationID, let profileID):
            guard profileLocation(
                applicationID: applicationID,
                profileID: profileID,
                matches: matches,
                working: working
            ) != nil else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
        case .useImported(let applicationID, let profileID):
            guard let location = profileLocation(
                applicationID: applicationID,
                profileID: profileID,
                matches: matches,
                working: working
            ) else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            var application = working[location.applicationIndex].application
            application.profiles[location.profileIndex] =
                LibraryImportContentTransformer.profileUsingImportedContent(
                    existing: application.profiles[location.profileIndex],
                    imported: importedProfile
                )
            replaceApplication(
                application,
                at: location.applicationIndex,
                working: &working
            )
        case .keepBoth(let rename, let identity):
            try appendFreshProfile(
                importedProfile,
                renamedTo: rename,
                identity: identity,
                destinationIndex: destinationIndex,
                working: &working
            )
        case .skip:
            break
        }
    }

    static func appendImportedProfile(
        _ profile: LaunchProfile,
        destinationIndex: Int,
        working: inout [LibraryImportApplication]
    ) {
        var application = working[destinationIndex].application
        application.profiles.append(profile)
        replaceApplication(
            application,
            at: destinationIndex,
            working: &working
        )
    }

    private static func appendFreshApplication(
        _ incoming: LibraryImportApplication,
        renamedTo rename: String,
        identity: LibraryImportFreshApplicationIdentity,
        working: inout [LibraryImportApplication]
    ) throws {
        let rename = try LibraryImportConflictNormalization.validatedRename(
            rename
        )
        guard !working.contains(where: {
            LibraryImportConflictNormalization.name(
                $0.application.displayName
            ) == LibraryImportConflictNormalization.name(rename)
        }) else {
            throw LibraryImportConflictEngineError.renameCollision
        }

        let profileIdentities = try LibraryImportIdentityIndex(working)
            .validatedProfileIdentities(
                for: incoming,
                freshApplication: identity
            )
        let profiles = zip(
            incoming.application.profiles,
            profileIdentities
        ).map { profile, freshIdentity in
            LibraryImportContentTransformer.freshProfile(
                from: profile,
                identity: freshIdentity
            )
        }
        working.append(
            LibraryImportContentTransformer.freshApplication(
                from: incoming,
                renamedTo: rename,
                identity: identity,
                profiles: profiles
            )
        )
    }

    private static func appendFreshProfile(
        _ incoming: LaunchProfile,
        renamedTo rename: String,
        identity: LibraryImportFreshProfileIdentity,
        destinationIndex: Int,
        working: inout [LibraryImportApplication]
    ) throws {
        let rename = try LibraryImportConflictNormalization.validatedRename(
            rename
        )
        guard !working[destinationIndex].application.profiles.contains(
            where: {
                LibraryImportConflictNormalization.name($0.name)
                    == LibraryImportConflictNormalization.name(rename)
            }
        ) else {
            throw LibraryImportConflictEngineError.renameCollision
        }
        try LibraryImportIdentityIndex(working).validateFreshProfile(identity)

        var application = working[destinationIndex].application
        application.profiles.append(
            LibraryImportContentTransformer.freshProfile(
                from: incoming,
                renamedTo: rename,
                identity: identity
            )
        )
        replaceApplication(
            application,
            at: destinationIndex,
            working: &working
        )
    }

    private static func applicationIndex(
        _ applicationID: UUID,
        matches: [LibraryImportApplicationMatch],
        working: [LibraryImportApplication]
    ) -> Int? {
        matches.map(\.index).first {
            working[$0].application.id == applicationID
        }
    }

    private static func profileLocation(
        applicationID: UUID,
        profileID: UUID,
        matches: [LibraryImportProfileMatch],
        working: [LibraryImportApplication]
    ) -> LibraryImportProfileLocation? {
        matches.map(\.location).first { location in
            working[location.applicationIndex].application.id
                == applicationID
                && working[location.applicationIndex]
                    .application.profiles[location.profileIndex].id
                    == profileID
        }
    }

    private static func replaceApplication(
        _ application: ManagedApplication,
        at index: Int,
        working: inout [LibraryImportApplication]
    ) {
        working[index] = LibraryImportApplication(
            application: application,
            canonicalApplicationPath: working[index].canonicalApplicationPath
        )
    }
}
