import Foundation

enum ApplicationRemovalDataChoice:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Sendable
{
    case keep
    case archive
    case delete

    var transactionStep: ApplicationRemovalTransactionStep {
        return switch self {
        case .keep:
            .preserveManagedData
        case .archive:
            .archiveManagedData
        case .delete:
            .deleteManagedData
        }
    }

    fileprivate func confirmationMessage(
        applicationName: String,
        profileCount: Int
    ) -> String {
        let profiles = LocalizedCount.profiles(profileCount)
        let configurations =
            LocalizedCount.profileConfigurations(profileCount)
        return switch self {
        case .keep:
            String(
                localized:
                    "Remove \(applicationName) and its \(configurations), but keep all managed profile data?"
            )
        case .archive:
            String(
                localized:
                    "Archive the managed data for \(profiles), then remove \(applicationName) and its \(configurations)?"
            )
        case .delete:
            String(
                localized:
                    "Permanently delete the managed data for \(profiles), then remove \(applicationName) and its \(configurations)?"
            )
        }
    }
}

enum ApplicationRemovalTransactionStep: String, Equatable, Sendable {
    case verifyPriorBackup
    case preserveManagedData
    case archiveManagedData
    case deleteManagedData
    case commitMetadataRemoval
}

enum ApplicationRemovalExternalPathRole:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case userData
    case codexHome
}

struct ApplicationRemovalExternalPath: Equatable, Hashable, Sendable {
    let role: ApplicationRemovalExternalPathRole
    let declaredPath: String
}

struct ApplicationRemovalProfileTarget: Equatable, Sendable {
    let profileID: UUID
    let profileStorageID: UUID
    let profileName: String
    let managedProfileRoot: DestructiveActionPathSnapshot
    let externalPaths: [ApplicationRemovalExternalPath]

    init(
        profileID: UUID,
        profileStorageID: UUID,
        profileName: String,
        managedProfileRoot: DestructiveActionPathSnapshot,
        externalPaths: [ApplicationRemovalExternalPath]
    ) {
        self.profileID = profileID
        self.profileStorageID = profileStorageID
        self.profileName = profileName
        self.managedProfileRoot = managedProfileRoot
        self.externalPaths = externalPaths.sorted {
            if $0.role != $1.role {
                return $0.role.rawValue < $1.role.rawValue
            }
            return $0.declaredPath < $1.declaredPath
        }
    }
}

struct ApplicationRemovalConfirmationPresentation: Equatable, Sendable {
    let requestID: UUID
    let sceneID: UUID
    let title: String
    let message: String
    let isDestructive: Bool
    let requiresPriorBackup: Bool
    let applicationID: UUID
    let applicationStorageID: UUID
    let applicationName: String
    let profileCount: Int
    let dataChoice: ApplicationRemovalDataChoice
    let managedDataPaths: [String]
    let externalDataPaths: [String]
    let externalDataCaveat: String
    let repositoryVersion: LibraryVersionToken
}

struct ApplicationRemovalCurrentTarget: Equatable, Sendable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let applicationName: String
    let profiles: [ApplicationRemovalProfileTarget]
    let repositoryVersion: LibraryVersionToken

    init(
        applicationID: UUID,
        applicationStorageID: UUID,
        applicationName: String,
        profiles: [ApplicationRemovalProfileTarget],
        repositoryVersion: LibraryVersionToken
    ) {
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.applicationName = applicationName
        self.profiles = Self.canonicalProfiles(profiles)
        self.repositoryVersion = repositoryVersion
    }

    fileprivate static func canonicalProfiles(
        _ profiles: [ApplicationRemovalProfileTarget]
    ) -> [ApplicationRemovalProfileTarget] {
        profiles.sorted {
            if $0.profileStorageID != $1.profileStorageID {
                return $0.profileStorageID.uuidString
                    < $1.profileStorageID.uuidString
            }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
    }
}

/// An immutable, scene-bound snapshot of one complete application removal.
///
/// This type never performs I/O. It requires exact backup evidence before it
/// authorizes the managed-data phase, and it issues metadata authority only
/// after the caller reports successful completion of that phase.
struct ApplicationRemovalRequest: Equatable, Sendable {
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let applicationName: String
    let profiles: [ApplicationRemovalProfileTarget]
    let dataChoice: ApplicationRemovalDataChoice
    let repositoryVersion: LibraryVersionToken

    init(
        requestID: UUID,
        sceneID: UUID,
        applicationID: UUID,
        applicationStorageID: UUID,
        applicationName: String,
        profiles: [ApplicationRemovalProfileTarget],
        dataChoice: ApplicationRemovalDataChoice,
        repositoryVersion: LibraryVersionToken
    ) throws {
        let logicalIDs = Set(profiles.map(\.profileID))
        let storageIDs = Set(profiles.map(\.profileStorageID))
        guard
            logicalIDs.count == profiles.count,
            storageIDs.count == profiles.count
        else {
            throw ApplicationRemovalRequestError(.invalidRequest)
        }
        self.requestID = requestID
        self.sceneID = sceneID
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.applicationName = applicationName
        self.profiles =
            ApplicationRemovalCurrentTarget.canonicalProfiles(profiles)
        self.dataChoice = dataChoice
        self.repositoryVersion = repositoryVersion
    }

    var profileStorageIDs: [UUID] {
        profiles.map(\.profileStorageID)
    }

    var requiredTransactionSteps: [ApplicationRemovalTransactionStep] {
        [
            .verifyPriorBackup,
            dataChoice.transactionStep,
            .commitMetadataRemoval,
        ]
    }

    var confirmationPresentation:
        ApplicationRemovalConfirmationPresentation
    {
        let externalDataCaveat = String(
            localized:
                "External user-data and CODEX_HOME folders are not managed by Parallax. They remain in place and will not be archived, deleted, or otherwise modified by this action."
        )
        return ApplicationRemovalConfirmationPresentation(
            requestID: requestID,
            sceneID: sceneID,
            title: String(localized: "Remove Application"),
            message: dataChoice.confirmationMessage(
                applicationName: applicationName,
                profileCount: profiles.count
            ),
            isDestructive: true,
            requiresPriorBackup: true,
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            applicationName: applicationName,
            profileCount: profiles.count,
            dataChoice: dataChoice,
            managedDataPaths: profiles.map {
                $0.managedProfileRoot.canonicalPath
            },
            externalDataPaths: profiles.flatMap(\.externalPaths)
                .map(\.declaredPath),
            externalDataCaveat: externalDataCaveat,
            repositoryVersion: repositoryVersion
        )
    }

}
