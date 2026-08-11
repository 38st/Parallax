import Foundation

enum LibraryImportConflictMatcher {
    static func applications(
        matching incoming: LibraryImportApplication,
        in working: [LibraryImportApplication]
    ) -> [LibraryImportApplicationMatch] {
        working.enumerated().compactMap { index, current in
            var reasons: Set<LibraryImportConflictReason> = []
            if current.application.id == incoming.application.id {
                reasons.insert(.applicationIdentity)
            }
            if current.application.storageID
                == incoming.application.storageID
            {
                reasons.insert(.applicationStorageIdentity)
            }

            let currentPath = LibraryImportConflictNormalization.path(
                current.canonicalApplicationPath
            )
            let incomingPath = LibraryImportConflictNormalization.path(
                incoming.canonicalApplicationPath
            )
            if currentPath == incomingPath {
                reasons.insert(.canonicalApplicationPath)
            }

            let currentBundle = LibraryImportConflictNormalization
                .bundleIdentifier(current.application.bundleIdentifier)
            let incomingBundle = LibraryImportConflictNormalization
                .bundleIdentifier(incoming.application.bundleIdentifier)
            if currentBundle == incomingBundle,
               incomingBundle != nil,
               currentPath != incomingPath
            {
                reasons.insert(.bundleIdentifierRelocation)
            }

            if LibraryImportConflictNormalization.name(
                current.application.displayName
            ) == LibraryImportConflictNormalization.name(
                incoming.application.displayName
            ),
               !(
                   current.application.id == incoming.application.id
                       && current.application.storageID
                        == incoming.application.storageID
               )
            {
                reasons.insert(.normalizedApplicationName)
            }

            let currentIDs = Set(current.application.profiles.map(\.id))
            let incomingIDs = Set(incoming.application.profiles.map(\.id))
            if !currentIDs.isDisjoint(with: incomingIDs) {
                reasons.insert(.profileIdentity)
            }
            let currentStorageIDs = Set(
                current.application.profiles.map(\.storageID)
            )
            let incomingStorageIDs = Set(
                incoming.application.profiles.map(\.storageID)
            )
            if !currentStorageIDs.isDisjoint(with: incomingStorageIDs) {
                reasons.insert(.profileStorageIdentity)
            }
            return reasons.isEmpty
                ? nil
                : LibraryImportApplicationMatch(
                    index: index,
                    reasons: reasons
                )
        }
    }

    static func requiresApplicationDecision(
        matches: [LibraryImportApplicationMatch],
        fieldDifferences: Set<LibraryImportApplicationField>
    ) -> Bool {
        matches.count > 1
            || !fieldDifferences.isEmpty
            || matches.contains { match in
                match.reasons.contains(.bundleIdentifierRelocation)
                    || match.reasons.contains(.normalizedApplicationName)
                    || (
                        match.reasons.contains(.canonicalApplicationPath)
                            && !(
                                match.reasons.contains(.applicationIdentity)
                                    && match.reasons.contains(
                                        .applicationStorageIdentity
                                    )
                            )
                    )
                    || (
                        (
                            match.reasons.contains(.profileIdentity)
                                || match.reasons.contains(
                                    .profileStorageIdentity
                                )
                        )
                            && !match.reasons.contains(.applicationIdentity)
                            && !match.reasons.contains(
                                .applicationStorageIdentity
                            )
                    )
            }
    }

    static func profiles(
        matching incoming: LaunchProfile,
        destinationIndex: Int,
        in working: [LibraryImportApplication]
    ) -> [LibraryImportProfileMatch] {
        var result: [LibraryImportProfileMatch] = []
        for (applicationIndex, candidate) in working.enumerated() {
            for (profileIndex, profile) in candidate.application.profiles
                .enumerated()
            {
                var reasons: Set<LibraryImportConflictReason> = []
                if profile.id == incoming.id {
                    reasons.insert(.profileIdentity)
                }
                if profile.storageID == incoming.storageID {
                    reasons.insert(.profileStorageIdentity)
                }
                if applicationIndex == destinationIndex,
                   LibraryImportConflictNormalization.name(profile.name)
                    == LibraryImportConflictNormalization.name(incoming.name)
                {
                    reasons.insert(.normalizedProfileName)
                }
                guard !reasons.isEmpty else { continue }

                let differences = LibraryImportConflictFieldDiffer.profile(
                    profile,
                    incoming
                )
                if !differences.isEmpty {
                    reasons.insert(.profileFields(differences))
                }
                result.append(
                    LibraryImportProfileMatch(
                        location: LibraryImportProfileLocation(
                            applicationIndex: applicationIndex,
                            profileIndex: profileIndex
                        ),
                        reasons: reasons
                    )
                )
            }
        }
        return result
    }

    static func applicationConflict(
        incoming: LibraryImportApplication,
        matches: [LibraryImportApplicationMatch],
        working: [LibraryImportApplication]
    ) -> LibraryImportConflict {
        let applicationIDs = matches.map {
            working[$0.index].application.id
        }.sorted(by: LibraryImportConflictNormalization.uuidLess)
        let reasons = matches.reduce(
            into: Set<LibraryImportConflictReason>()
        ) {
            $0.formUnion($1.reasons)
        }
        let id = LibraryImportConflictID(
            importedApplicationID: incoming.application.id,
            importedProfileID: nil,
            existingApplicationIDs: applicationIDs,
            existingProfileIDs: []
        )
        return LibraryImportConflict(
            id: id,
            scope: .application,
            importedApplicationID: incoming.application.id,
            importedProfileID: nil,
            existingApplicationIDs: applicationIDs,
            existingProfileIDs: [],
            reasons: reasons
        )
    }

    static func profileConflict(
        importedApplicationID: UUID,
        importedProfile: LaunchProfile,
        matches: [LibraryImportProfileMatch],
        working: [LibraryImportApplication]
    ) -> LibraryImportConflict {
        var reasons = matches.reduce(
            into: Set<LibraryImportConflictReason>()
        ) {
            $0.formUnion($1.reasons)
        }
        if matches.count > 1 {
            reasons.insert(.ambiguousProfileMatch)
        }
        let applicationIDs = Set(matches.map {
            working[$0.location.applicationIndex].application.id
        }).sorted(by: LibraryImportConflictNormalization.uuidLess)
        let profileIDs = matches.map {
            working[$0.location.applicationIndex]
                .application.profiles[$0.location.profileIndex].id
        }.sorted(by: LibraryImportConflictNormalization.uuidLess)
        let id = LibraryImportConflictID(
            importedApplicationID: importedApplicationID,
            importedProfileID: importedProfile.id,
            existingApplicationIDs: applicationIDs,
            existingProfileIDs: profileIDs
        )
        return LibraryImportConflict(
            id: id,
            scope: .profile,
            importedApplicationID: importedApplicationID,
            importedProfileID: importedProfile.id,
            existingApplicationIDs: applicationIDs,
            existingProfileIDs: profileIDs,
            reasons: reasons
        )
    }
}
