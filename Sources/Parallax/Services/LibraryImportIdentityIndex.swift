import Foundation

struct LibraryImportIdentityIndex {
    private let applicationIDs: Set<UUID>
    private let applicationStorageIDs: Set<UUID>
    private let profileIDs: Set<UUID>
    private let profileStorageIDs: Set<UUID>

    init(_ working: [LibraryImportApplication]) {
        applicationIDs = Set(working.map(\.application.id))
        applicationStorageIDs = Set(working.map(\.application.storageID))
        profileIDs = Set(working.flatMap(\.application.profiles).map(\.id))
        profileStorageIDs = Set(
            working.flatMap(\.application.profiles).map(\.storageID)
        )
    }

    func validatedProfileIdentities(
        for incoming: LibraryImportApplication,
        freshApplication: LibraryImportFreshApplicationIdentity
    ) throws -> [LibraryImportFreshProfileIdentity] {
        guard
            !applicationIDs.contains(freshApplication.id),
            !applicationStorageIDs.contains(freshApplication.storageID),
            !profileIDs.contains(freshApplication.id),
            !profileStorageIDs.contains(freshApplication.storageID)
        else {
            throw LibraryImportConflictEngineError.freshIdentityCollision
        }

        let importedProfiles = incoming.application.profiles
        let importedProfileIDs = Set(importedProfiles.map(\.id))
        guard freshApplication.profileIdentities.count
            == importedProfiles.count,
            Set(freshApplication.profileIdentities.keys) == importedProfileIDs
        else {
            throw LibraryImportConflictEngineError.freshIdentityCollision
        }

        var freshProfileIDs = Set<UUID>()
        var freshProfileStorageIDs = Set<UUID>()
        return try importedProfiles.map { profile in
            guard let fresh = freshApplication.profileIdentities[profile.id]
            else {
                throw LibraryImportConflictEngineError
                    .missingFreshProfileIdentity(profile.id)
            }
            guard
                freshProfileIDs.insert(fresh.id).inserted,
                freshProfileStorageIDs.insert(fresh.storageID).inserted,
                !profileIDs.contains(fresh.id),
                !profileStorageIDs.contains(fresh.storageID),
                !applicationIDs.contains(fresh.id),
                !applicationStorageIDs.contains(fresh.storageID),
                fresh.id != freshApplication.id,
                fresh.storageID != freshApplication.storageID
            else {
                throw LibraryImportConflictEngineError.freshIdentityCollision
            }
            return fresh
        }
    }

    func validateFreshProfile(
        _ identity: LibraryImportFreshProfileIdentity
    ) throws {
        guard
            !applicationIDs.contains(identity.id),
            !applicationStorageIDs.contains(identity.storageID),
            !profileIDs.contains(identity.id),
            !profileStorageIDs.contains(identity.storageID)
        else {
            throw LibraryImportConflictEngineError.freshIdentityCollision
        }
    }
}
