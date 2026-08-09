import Foundation

/// An import candidate whose application path has already been canonicalized by
/// structural validation. The conflict engine is pure and never touches disk.
struct LibraryImportApplication: Sendable, Equatable {
    let application: ManagedApplication
    let canonicalApplicationPath: String
}

enum LibraryImportApplicationField: String, Sendable, Hashable, CaseIterable {
    case displayName
    case bundleIdentifier
    case applicationPath
    case preset
    case baseStoragePath
}

enum LibraryImportProfileField: String, Sendable, Hashable, CaseIterable {
    case name
    case arguments
    case environment
    case notes
    case isolationOwnership
    case childEnvironmentPolicy
    case sensitiveEnvironmentKeys
    case launchConfigurationTrust
    case lastLaunchedAt
}

enum LibraryImportConflictReason: Sendable, Hashable {
    case applicationIdentity
    case applicationStorageIdentity
    case canonicalApplicationPath
    case bundleIdentifierRelocation
    case normalizedApplicationName
    case applicationFields(Set<LibraryImportApplicationField>)
    case profileIdentity
    case profileStorageIdentity
    case normalizedProfileName
    case profileFields(Set<LibraryImportProfileField>)
    case ambiguousApplicationMatch
    case ambiguousProfileMatch
}

struct LibraryImportConflictID: Sendable, Hashable {
    let importedApplicationID: UUID
    let importedProfileID: UUID?
    let existingApplicationIDs: [UUID]
    let existingProfileIDs: [UUID]
}

enum LibraryImportConflictScope: Sendable, Equatable {
    case application
    case profile
}

struct LibraryImportConflict: Sendable, Equatable {
    let id: LibraryImportConflictID
    let scope: LibraryImportConflictScope
    let importedApplicationID: UUID
    let importedProfileID: UUID?
    let existingApplicationIDs: [UUID]
    let existingProfileIDs: [UUID]
    let reasons: Set<LibraryImportConflictReason>
}

struct LibraryImportFreshProfileIdentity: Sendable, Equatable, Hashable {
    let id: UUID
    let storageID: UUID
}

struct LibraryImportFreshApplicationIdentity: Sendable, Equatable {
    let id: UUID
    let storageID: UUID
    let profileIdentities: [UUID: LibraryImportFreshProfileIdentity]
}

enum LibraryImportKeepBoth: Sendable, Equatable {
    case application(
        renamedTo: String,
        identity: LibraryImportFreshApplicationIdentity
    )
    case profile(
        renamedTo: String,
        identity: LibraryImportFreshProfileIdentity
    )
}

enum LibraryImportConflictResolution: Sendable, Equatable {
    case keepExisting(
        applicationID: UUID,
        profileID: UUID? = nil
    )
    case useImported(
        applicationID: UUID,
        profileID: UUID? = nil
    )
    case keepBoth(LibraryImportKeepBoth)
    case skip
}

struct LibraryImportResolutionResult: Sendable, Equatable {
    /// Ordered exactly as encountered in the imported batch.
    let conflicts: [LibraryImportConflict]
    let unresolvedConflictIDs: [LibraryImportConflictID]
    /// Nil until every conflict has an explicit decision. This prevents callers
    /// from accidentally persisting a preview's provisional comparison state.
    let applications: [ManagedApplication]?

    var isFullyResolved: Bool {
        unresolvedConflictIDs.isEmpty
    }
}

enum LibraryImportConflictEngineError: Error, Sendable, Equatable {
    case conflictResolutionDoesNotMatch
    case wrongKeepBothScope
    case missingFreshProfileIdentity(UUID)
    case freshIdentityCollision
    case emptyRename
    case renameCollision
}

enum LibraryImportConflictEngine {
    private struct ApplicationMatch {
        let index: Int
        var reasons: Set<LibraryImportConflictReason>
    }

    private struct ProfileLocation: Hashable {
        let applicationIndex: Int
        let profileIndex: Int
    }

    static func resolve(
        existing: [LibraryImportApplication],
        imported: [LibraryImportApplication],
        resolutions: [
            LibraryImportConflictID: LibraryImportConflictResolution
        ] = [:]
    ) throws -> LibraryImportResolutionResult {
        var working = existing
        var conflicts: [LibraryImportConflict] = []
        var unresolved: [LibraryImportConflictID] = []

        for incoming in imported {
            var matches = applicationMatches(
                incoming,
                in: working
            )
            if matches.isEmpty {
                let application = incoming.application
                working.append(
                    LibraryImportApplication(
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
                        canonicalApplicationPath:
                            incoming.canonicalApplicationPath
                    )
                )
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: working.index(before: working.endIndex),
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            let selectedIndex = matches[0].index
            let selected = working[selectedIndex]
            let fieldDifferences = applicationFieldDifferences(
                selected,
                incoming
            )
            if !fieldDifferences.isEmpty {
                matches[0].reasons.insert(
                    .applicationFields(fieldDifferences)
                )
            }
            if matches.count > 1 {
                matches[0].reasons.insert(.ambiguousApplicationMatch)
            }

            let requiresApplicationDecision =
                matches.count > 1
                || !fieldDifferences.isEmpty
                || matches.contains {
                    $0.reasons.contains(.bundleIdentifierRelocation)
                        || $0.reasons.contains(.normalizedApplicationName)
                        || (
                            $0.reasons.contains(.canonicalApplicationPath)
                                && !(
                                    $0.reasons.contains(.applicationIdentity)
                                        && $0.reasons.contains(
                                            .applicationStorageIdentity
                                        )
                                )
                        )
                        || (
                            (
                                $0.reasons.contains(.profileIdentity)
                                    || $0.reasons.contains(
                                        .profileStorageIdentity
                                    )
                            )
                                && !$0.reasons.contains(
                                    .applicationIdentity
                                )
                                && !$0.reasons.contains(
                                    .applicationStorageIdentity
                                )
                        )
                }

            if !requiresApplicationDecision,
               incoming.application.id == selected.application.id,
               incoming.application.storageID
                    == selected.application.storageID
            {
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: selectedIndex,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            let conflict = applicationConflict(
                incoming: incoming,
                matches: matches,
                working: working
            )
            conflicts.append(conflict)
            guard let resolution = resolutions[conflict.id] else {
                unresolved.append(conflict.id)
                // Provisional keep-existing lets preview discover later
                // profile/batch conflicts without publishing a partial result.
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: selectedIndex,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
                continue
            }

            switch resolution {
            case .keepExisting(let applicationID, let profileID):
                guard
                    profileID == nil,
                    let target = matchingApplicationIndex(
                        applicationID,
                        in: matches,
                        working: working
                    )
                else {
                    throw LibraryImportConflictEngineError
                        .conflictResolutionDoesNotMatch
                }
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: target,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
            case .useImported(let applicationID, let profileID):
                guard
                    profileID == nil,
                    let target = matchingApplicationIndex(
                        applicationID,
                        in: matches,
                        working: working
                    )
                else {
                    throw LibraryImportConflictEngineError
                        .conflictResolutionDoesNotMatch
                }
                working[target] = applicationUsingImportedFields(
                    existing: working[target],
                    imported: incoming
                )
                try mergeProfiles(
                    from: incoming,
                    intoApplicationAt: target,
                    working: &working,
                    resolutions: resolutions,
                    conflicts: &conflicts,
                    unresolved: &unresolved
                )
            case .keepBoth(let keepBoth):
                guard
                    case let .application(rename, identity) = keepBoth
                else {
                    throw LibraryImportConflictEngineError.wrongKeepBothScope
                }
                try appendFreshApplication(
                    incoming,
                    renamedTo: rename,
                    identity: identity,
                    to: &working
                )
            case .skip:
                break
            }
        }

        return LibraryImportResolutionResult(
            conflicts: conflicts,
            unresolvedConflictIDs: unresolved,
            applications: unresolved.isEmpty
                ? working.map(\.application)
                : nil
        )
    }

    private static func applicationMatches(
        _ incoming: LibraryImportApplication,
        in working: [LibraryImportApplication]
    ) -> [ApplicationMatch] {
        var matches: [ApplicationMatch] = []
        for (index, current) in working.enumerated() {
            var reasons: Set<LibraryImportConflictReason> = []
            if current.application.id == incoming.application.id {
                reasons.insert(.applicationIdentity)
            }
            if current.application.storageID
                == incoming.application.storageID
            {
                reasons.insert(.applicationStorageIdentity)
            }
            if normalizedPath(current.canonicalApplicationPath)
                == normalizedPath(incoming.canonicalApplicationPath)
            {
                reasons.insert(.canonicalApplicationPath)
            }
            if normalizedBundleIdentifier(
                current.application.bundleIdentifier
            ) == normalizedBundleIdentifier(
                incoming.application.bundleIdentifier
            ),
               normalizedBundleIdentifier(
                   incoming.application.bundleIdentifier
               ) != nil,
               normalizedPath(current.canonicalApplicationPath)
                    != normalizedPath(incoming.canonicalApplicationPath)
            {
                reasons.insert(.bundleIdentifierRelocation)
            }
            if normalizedName(current.application.displayName)
                == normalizedName(incoming.application.displayName),
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
            if !reasons.isEmpty {
                matches.append(
                    ApplicationMatch(index: index, reasons: reasons)
                )
            }
        }
        return matches
    }

    private static func applicationConflict(
        incoming: LibraryImportApplication,
        matches: [ApplicationMatch],
        working: [LibraryImportApplication]
    ) -> LibraryImportConflict {
        let applicationIDs = matches.map {
            working[$0.index].application.id
        }.sorted(by: uuidLess)
        let reasons = matches.reduce(into: Set<LibraryImportConflictReason>()) {
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

    private static func mergeProfiles(
        from incoming: LibraryImportApplication,
        intoApplicationAt destinationIndex: Int,
        working: inout [LibraryImportApplication],
        resolutions: [
            LibraryImportConflictID: LibraryImportConflictResolution
        ],
        conflicts: inout [LibraryImportConflict],
        unresolved: inout [LibraryImportConflictID]
    ) throws {
        for importedProfile in incoming.application.profiles {
            let locations = profileMatches(
                importedProfile,
                destinationIndex: destinationIndex,
                in: working
            )
            guard !locations.isEmpty else {
                var application = working[destinationIndex].application
                application.profiles.append(importedProfile)
                working[destinationIndex] = LibraryImportApplication(
                    application: application,
                    canonicalApplicationPath:
                        working[destinationIndex].canonicalApplicationPath
                )
                continue
            }

            if locations.count == 1 {
                let location = locations[0].location
                let existingProfile = working[location.applicationIndex]
                    .application.profiles[location.profileIndex]
                if profileFieldDifferences(
                    existingProfile,
                    importedProfile
                ).isEmpty {
                    continue
                }
            }

            let conflict = profileConflict(
                importedApplicationID: incoming.application.id,
                importedProfile: importedProfile,
                matches: locations,
                working: working
            )
            conflicts.append(conflict)
            guard let resolution = resolutions[conflict.id] else {
                unresolved.append(conflict.id)
                continue
            }

            switch resolution {
            case .keepExisting(let applicationID, let profileID):
                guard matchingProfileLocation(
                    applicationID: applicationID,
                    profileID: profileID,
                    matches: locations,
                    working: working
                ) != nil else {
                    throw LibraryImportConflictEngineError
                        .conflictResolutionDoesNotMatch
                }
            case .useImported(let applicationID, let profileID):
                guard let location = matchingProfileLocation(
                    applicationID: applicationID,
                    profileID: profileID,
                    matches: locations,
                    working: working
                ) else {
                    throw LibraryImportConflictEngineError
                        .conflictResolutionDoesNotMatch
                }
                var application = working[location.applicationIndex]
                    .application
                let persisted =
                    application.profiles[location.profileIndex]
                application.profiles[location.profileIndex] = LaunchProfile(
                    id: persisted.id,
                    storageID: persisted.storageID,
                    name: importedProfile.name,
                    argumentsText: importedProfile.argumentsText,
                    environmentText: importedProfile.environmentText,
                    notes: importedProfile.notes,
                    isolationOwnership:
                        importedProfile.isolationOwnership,
                    childEnvironmentPolicy:
                        importedProfile.childEnvironmentPolicy,
                    sensitiveEnvironmentKeys:
                        importedProfile.sensitiveEnvironmentKeys,
                    launchConfigurationTrust:
                        importedProfile.launchConfigurationTrust,
                    lastLaunchedAt: importedProfile.lastLaunchedAt
                )
                working[location.applicationIndex] =
                    LibraryImportApplication(
                        application: application,
                        canonicalApplicationPath:
                            working[location.applicationIndex]
                                .canonicalApplicationPath
                    )
            case .keepBoth(let keepBoth):
                guard
                    case let .profile(rename, identity) = keepBoth
                else {
                    throw LibraryImportConflictEngineError.wrongKeepBothScope
                }
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
    }

    private static func profileMatches(
        _ incoming: LaunchProfile,
        destinationIndex: Int,
        in working: [LibraryImportApplication]
    ) -> [(
        location: ProfileLocation,
        reasons: Set<LibraryImportConflictReason>
    )] {
        var result: [(
            location: ProfileLocation,
            reasons: Set<LibraryImportConflictReason>
        )] = []
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
                   normalizedName(profile.name)
                    == normalizedName(incoming.name)
                {
                    reasons.insert(.normalizedProfileName)
                }
                if !reasons.isEmpty {
                    let differences = profileFieldDifferences(
                        profile,
                        incoming
                    )
                    if !differences.isEmpty {
                        reasons.insert(.profileFields(differences))
                    }
                    result.append(
                        (
                            ProfileLocation(
                                applicationIndex: applicationIndex,
                                profileIndex: profileIndex
                            ),
                            reasons
                        )
                    )
                }
            }
        }
        return result
    }

    private static func profileConflict(
        importedApplicationID: UUID,
        importedProfile: LaunchProfile,
        matches: [(
            location: ProfileLocation,
            reasons: Set<LibraryImportConflictReason>
        )],
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
        }).sorted(by: uuidLess)
        let profileIDs = matches.map {
            working[$0.location.applicationIndex]
                .application.profiles[$0.location.profileIndex].id
        }.sorted(by: uuidLess)
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

    private static func applicationUsingImportedFields(
        existing: LibraryImportApplication,
        imported: LibraryImportApplication
    ) -> LibraryImportApplication {
        let current = existing.application
        let incoming = imported.application
        return LibraryImportApplication(
            application: ManagedApplication(
                id: current.id,
                storageID: current.storageID,
                displayName: incoming.displayName,
                bundleIdentifier: incoming.bundleIdentifier,
                appPath: incoming.appPath,
                preset: incoming.preset,
                baseStoragePath: incoming.baseStoragePath,
                profiles: current.profiles
            ),
            canonicalApplicationPath: imported.canonicalApplicationPath
        )
    }

    private static func appendFreshApplication(
        _ incoming: LibraryImportApplication,
        renamedTo rename: String,
        identity: LibraryImportFreshApplicationIdentity,
        to working: inout [LibraryImportApplication]
    ) throws {
        let rename = try validatedRename(rename)
        guard !working.contains(where: {
            normalizedName($0.application.displayName)
                == normalizedName(rename)
        }) else {
            throw LibraryImportConflictEngineError.renameCollision
        }
        let occupiedApplicationIDs = Set(
            working.map(\.application.id)
        )
        let occupiedApplicationStorageIDs = Set(
            working.map(\.application.storageID)
        )
        let occupiedProfileIDs = Set(
            working.flatMap(\.application.profiles).map(\.id)
        )
        let occupiedProfileStorageIDs = Set(
            working.flatMap(\.application.profiles).map(\.storageID)
        )
        guard
            !occupiedApplicationIDs.contains(identity.id),
            !occupiedApplicationStorageIDs.contains(identity.storageID),
            !occupiedProfileIDs.contains(identity.id),
            !occupiedProfileStorageIDs.contains(identity.storageID),
            identity.profileIdentities.count
                == incoming.application.profiles.count,
            Set(identity.profileIdentities.keys)
                == Set(incoming.application.profiles.map(\.id))
        else {
            throw LibraryImportConflictEngineError.freshIdentityCollision
        }

        var freshProfileIDs = Set<UUID>()
        var freshProfileStorageIDs = Set<UUID>()
        let profiles = try incoming.application.profiles.map { profile in
            guard let fresh = identity.profileIdentities[profile.id] else {
                throw LibraryImportConflictEngineError
                    .missingFreshProfileIdentity(profile.id)
            }
            guard
                freshProfileIDs.insert(fresh.id).inserted,
                freshProfileStorageIDs.insert(fresh.storageID).inserted,
                !occupiedProfileIDs.contains(fresh.id),
                !occupiedProfileStorageIDs.contains(fresh.storageID),
                !occupiedApplicationIDs.contains(fresh.id),
                !occupiedApplicationStorageIDs.contains(fresh.storageID),
                fresh.id != identity.id,
                fresh.storageID != identity.storageID
            else {
                throw LibraryImportConflictEngineError.freshIdentityCollision
            }
            return LaunchProfile(
                id: fresh.id,
                storageID: fresh.storageID,
                name: profile.name,
                argumentsText: profile.argumentsText,
                environmentText: profile.environmentText,
                notes: profile.notes,
                isolationOwnership: profile.isolationOwnership,
                childEnvironmentPolicy: profile.childEnvironmentPolicy,
                sensitiveEnvironmentKeys: profile.sensitiveEnvironmentKeys,
                launchConfigurationTrust:
                    profile.launchConfigurationTrust,
                lastLaunchedAt: profile.lastLaunchedAt
            )
        }
        let application = incoming.application
        working.append(
            LibraryImportApplication(
                application: ManagedApplication(
                    id: identity.id,
                    storageID: identity.storageID,
                    displayName: rename,
                    bundleIdentifier: application.bundleIdentifier,
                    appPath: application.appPath,
                    preset: application.preset,
                    baseStoragePath: application.baseStoragePath,
                    profiles: profiles
                ),
                canonicalApplicationPath:
                    incoming.canonicalApplicationPath
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
        let rename = try validatedRename(rename)
        guard !working[destinationIndex].application.profiles.contains(
            where: {
                normalizedName($0.name) == normalizedName(rename)
            }
        ) else {
            throw LibraryImportConflictEngineError.renameCollision
        }
        let occupiedApplicationIDs = Set(
            working.map(\.application.id)
        )
        let occupiedApplicationStorageIDs = Set(
            working.map(\.application.storageID)
        )
        let occupiedProfileIDs = Set(
            working.flatMap(\.application.profiles).map(\.id)
        )
        let occupiedProfileStorageIDs = Set(
            working.flatMap(\.application.profiles).map(\.storageID)
        )
        guard
            !occupiedApplicationIDs.contains(identity.id),
            !occupiedApplicationStorageIDs.contains(identity.storageID),
            !occupiedProfileIDs.contains(identity.id),
            !occupiedProfileStorageIDs.contains(identity.storageID)
        else {
            throw LibraryImportConflictEngineError.freshIdentityCollision
        }
        var application = working[destinationIndex].application
        application.profiles.append(
            LaunchProfile(
                id: identity.id,
                storageID: identity.storageID,
                name: rename,
                argumentsText: incoming.argumentsText,
                environmentText: incoming.environmentText,
                notes: incoming.notes,
                isolationOwnership: incoming.isolationOwnership,
                childEnvironmentPolicy: incoming.childEnvironmentPolicy,
                sensitiveEnvironmentKeys: incoming.sensitiveEnvironmentKeys,
                launchConfigurationTrust:
                    incoming.launchConfigurationTrust,
                lastLaunchedAt: incoming.lastLaunchedAt
            )
        )
        working[destinationIndex] = LibraryImportApplication(
            application: application,
            canonicalApplicationPath:
                working[destinationIndex].canonicalApplicationPath
        )
    }

    private static func matchingApplicationIndex(
        _ applicationID: UUID,
        in matches: [ApplicationMatch],
        working: [LibraryImportApplication]
    ) -> Int? {
        matches.map(\.index).first {
            working[$0].application.id == applicationID
        }
    }

    private static func matchingProfileLocation(
        applicationID: UUID,
        profileID: UUID?,
        matches: [(
            location: ProfileLocation,
            reasons: Set<LibraryImportConflictReason>
        )],
        working: [LibraryImportApplication]
    ) -> ProfileLocation? {
        guard let profileID else { return nil }
        return matches.map(\.location).first { location in
            working[location.applicationIndex].application.id
                == applicationID
                && working[location.applicationIndex]
                    .application.profiles[location.profileIndex].id
                    == profileID
        }
    }

    private static func applicationFieldDifferences(
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
        if normalizedPath(lhs.canonicalApplicationPath)
            != normalizedPath(rhs.canonicalApplicationPath)
            || lhs.application.appPath != rhs.application.appPath
        {
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

    private static func profileFieldDifferences(
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
        return result
    }

    private static func normalizedName(_ value: String) -> String {
        DisplayNameValidator.collisionKey(value)
    }

    private static func normalizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func normalizedBundleIdentifier(
        _ value: String?
    ) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    private static func validatedRename(_ rename: String) throws -> String {
        guard let normalized = DisplayNameValidator.normalized(rename) else {
            throw LibraryImportConflictEngineError.emptyRename
        }
        return normalized
    }

    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
