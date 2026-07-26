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

struct ApplicationRemovalProfileActivity: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case inactive
        case active
        case ambiguous
    }

    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let state: State
}

struct ApplicationRemovalActivitySnapshot: Equatable, Sendable {
    let profiles: [ApplicationRemovalProfileActivity]

    init(profiles: [ApplicationRemovalProfileActivity]) {
        self.profiles = profiles.sorted {
            if $0.profileStorageID != $1.profileStorageID {
                return $0.profileStorageID.uuidString
                    < $1.profileStorageID.uuidString
            }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
    }
}

enum ApplicationRemovalExpertRiskAcknowledgment:
    String,
    Equatable,
    Sendable
{
    case allManagedProfileDataMayBeCorruptedAndProcessesDestabilized

    var warningMessage: String {
        switch self {
        case .allManagedProfileDataMayBeCorruptedAndProcessesDestabilized:
            String(
                localized:
                    "One or more profiles may be active. Continuing can corrupt any managed profile data being archived or deleted and can destabilize every affected running application process."
            )
        }
    }
}

struct ApplicationRemovalExpertOverrideAuthorization:
    Equatable,
    Sendable
{
    let authorizationID: UUID
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileStorageIDs: [UUID]
    let dataChoice: ApplicationRemovalDataChoice
    let repositoryVersion: LibraryVersionToken
    let acknowledgedRisk: ApplicationRemovalExpertRiskAcknowledgment

    fileprivate init(
        authorizationID: UUID,
        requestID: UUID,
        sceneID: UUID,
        applicationID: UUID,
        applicationStorageID: UUID,
        profileStorageIDs: [UUID],
        dataChoice: ApplicationRemovalDataChoice,
        repositoryVersion: LibraryVersionToken,
        acknowledgedRisk: ApplicationRemovalExpertRiskAcknowledgment
    ) {
        self.authorizationID = authorizationID
        self.requestID = requestID
        self.sceneID = sceneID
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.profileStorageIDs = profileStorageIDs
        self.dataChoice = dataChoice
        self.repositoryVersion = repositoryVersion
        self.acknowledgedRisk = acknowledgedRisk
    }
}

struct ApplicationRemovalPriorBackup: Equatable, Sendable {
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let artifactID: UUID
    let artifactSHA256: String
    let repositoryVersion: LibraryVersionToken

    fileprivate init(
        requestID: UUID,
        sceneID: UUID,
        applicationID: UUID,
        applicationStorageID: UUID,
        artifactID: UUID,
        artifactSHA256: String,
        repositoryVersion: LibraryVersionToken
    ) {
        self.requestID = requestID
        self.sceneID = sceneID
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.repositoryVersion = repositoryVersion
    }
}

enum ApplicationRemovalDataPhaseStatus: Equatable, Sendable {
    case succeeded(transactionID: UUID?)
    case failed
}

struct ApplicationRemovalDataPhaseResult: Equatable, Sendable {
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileStorageIDs: [UUID]
    let dataChoice: ApplicationRemovalDataChoice
    let status: ApplicationRemovalDataPhaseStatus

    fileprivate init(
        authorization: ApplicationRemovalExecutionAuthorization,
        status: ApplicationRemovalDataPhaseStatus
    ) {
        requestID = authorization.requestID
        sceneID = authorization.sceneID
        applicationID = authorization.applicationID
        applicationStorageID = authorization.applicationStorageID
        profileStorageIDs = authorization.profileStorageIDs
        dataChoice = authorization.dataChoice
        self.status = status
    }
}

struct ApplicationRemovalMetadataCommitAuthorization:
    Equatable,
    Sendable
{
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let repositoryVersion: LibraryVersionToken
    let priorBackupArtifactID: UUID
    let dataTransactionID: UUID?

    fileprivate init(
        execution: ApplicationRemovalExecutionAuthorization,
        dataTransactionID: UUID?
    ) {
        requestID = execution.requestID
        sceneID = execution.sceneID
        applicationID = execution.applicationID
        applicationStorageID = execution.applicationStorageID
        repositoryVersion = execution.repositoryVersion
        priorBackupArtifactID = execution.priorBackupArtifactID
        self.dataTransactionID = dataTransactionID
    }
}

struct ApplicationRemovalExecutionAuthorization:
    Equatable,
    Sendable
{
    let requestID: UUID
    let sceneID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileStorageIDs: [UUID]
    let dataChoice: ApplicationRemovalDataChoice
    let repositoryVersion: LibraryVersionToken
    let priorBackupArtifactID: UUID
    let usedExpertOverride: Bool
    let expertOverrideAuthorizationID: UUID?

    fileprivate init(
        request: ApplicationRemovalRequest,
        priorBackup: ApplicationRemovalPriorBackup,
        expertOverride: ApplicationRemovalExpertOverrideAuthorization?
    ) {
        requestID = request.requestID
        sceneID = request.sceneID
        applicationID = request.applicationID
        applicationStorageID = request.applicationStorageID
        profileStorageIDs = request.profileStorageIDs
        dataChoice = request.dataChoice
        repositoryVersion = request.repositoryVersion
        priorBackupArtifactID = priorBackup.artifactID
        usedExpertOverride = expertOverride != nil
        expertOverrideAuthorizationID = expertOverride?.authorizationID
    }

    func dataPhaseSucceeded(
        transactionID: UUID? = nil
    ) -> ApplicationRemovalDataPhaseResult {
        ApplicationRemovalDataPhaseResult(
            authorization: self,
            status: .succeeded(transactionID: transactionID)
        )
    }

    func dataPhaseFailed() -> ApplicationRemovalDataPhaseResult {
        ApplicationRemovalDataPhaseResult(
            authorization: self,
            status: .failed
        )
    }

    func authorizeMetadataRemoval(
        after dataPhase: ApplicationRemovalDataPhaseResult
    ) throws -> ApplicationRemovalMetadataCommitAuthorization {
        guard
            dataPhase.requestID == requestID,
            dataPhase.sceneID == sceneID,
            dataPhase.applicationID == applicationID,
            dataPhase.applicationStorageID == applicationStorageID,
            dataPhase.profileStorageIDs == profileStorageIDs,
            dataPhase.dataChoice == dataChoice
        else {
            throw ApplicationRemovalRequestError(
                .dataPhaseResultMismatch
            )
        }
        guard
            case .succeeded(let transactionID) = dataPhase.status
        else {
            throw ApplicationRemovalRequestError(
                .managedDataActionFailed
            )
        }
        return ApplicationRemovalMetadataCommitAuthorization(
            execution: self,
            dataTransactionID: transactionID
        )
    }
}

struct ApplicationRemovalRequestError: LocalizedError {
    enum Code: String, Equatable, Sendable {
        case invalidRequest
        case targetRemoved
        case targetRetargeted
        case applicationChanged
        case profileTargetsChanged
        case staleRepositoryVersion
        case activitySnapshotMismatch
        case activeProfileData
        case invalidExpertOverride
        case priorBackupRequired
        case invalidPriorBackup
        case dataPhaseResultMismatch
        case managedDataActionFailed
    }

    let code: Code

    init(_ code: Code) {
        self.code = code
    }

    var errorDescription: String? {
        switch code {
        case .invalidRequest:
            String(
                localized:
                    "The application removal request contains duplicate or ambiguous profile identities."
            )
        case .targetRemoved:
            String(
                localized:
                    "The application no longer exists. Removal was cancelled."
            )
        case .targetRetargeted:
            String(
                localized:
                    "The application removal target changed after confirmation was presented."
            )
        case .applicationChanged:
            String(
                localized:
                    "The application changed after confirmation was presented."
            )
        case .profileTargetsChanged:
            String(
                localized:
                    "The application’s profiles or storage targets changed after confirmation was presented."
            )
        case .staleRepositoryVersion:
            String(
                localized:
                    "The library changed after application removal was confirmed. Review the removal again."
            )
        case .activitySnapshotMismatch:
            String(
                localized:
                    "Profile activity was not checked for every exact application removal target."
            )
        case .activeProfileData:
            String(
                localized:
                    "One or more profiles may still be active. Application removal stopped to protect their data."
            )
        case .invalidExpertOverride:
            String(
                localized:
                    "The expert override does not authorize this exact application removal request."
            )
        case .priorBackupRequired:
            String(
                localized:
                    "A verified backup of the current library is required before application removal."
            )
        case .invalidPriorBackup:
            String(
                localized:
                    "The selected backup does not preserve the exact library version being removed."
            )
        case .dataPhaseResultMismatch:
            String(
                localized:
                    "The managed-data result belongs to a different application removal request."
            )
        case .managedDataActionFailed:
            String(
                localized:
                    "Managed profile data could not be handled. The application record must remain unchanged."
            )
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

    func acceptPriorBackup(
        _ artifact: LibraryRecoveryArtifact
    ) throws -> ApplicationRemovalPriorBackup {
        guard
            artifact.kind == .backup,
            artifact.reason == .destructiveRewrite,
            artifact.content == .currentLibrary,
            let expectedSHA256 = repositoryVersion.primarySHA256,
            artifact.sha256 == expectedSHA256
        else {
            throw ApplicationRemovalRequestError(.invalidPriorBackup)
        }
        return ApplicationRemovalPriorBackup(
            requestID: requestID,
            sceneID: sceneID,
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            artifactID: artifact.id,
            artifactSHA256: artifact.sha256,
            repositoryVersion: repositoryVersion
        )
    }

    func makeExpertOverrideAuthorization(
        acknowledging risk: ApplicationRemovalExpertRiskAcknowledgment,
        authorizationID: UUID = UUID()
    ) -> ApplicationRemovalExpertOverrideAuthorization {
        ApplicationRemovalExpertOverrideAuthorization(
            authorizationID: authorizationID,
            requestID: requestID,
            sceneID: sceneID,
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileStorageIDs: profileStorageIDs,
            dataChoice: dataChoice,
            repositoryVersion: repositoryVersion,
            acknowledgedRisk: risk
        )
    }

    func authorizeExecution(
        currentTarget: ApplicationRemovalCurrentTarget?,
        activity: ApplicationRemovalActivitySnapshot,
        priorBackup: ApplicationRemovalPriorBackup?,
        expertOverride: ApplicationRemovalExpertOverrideAuthorization? = nil
    ) throws -> ApplicationRemovalExecutionAuthorization {
        guard let currentTarget else {
            throw ApplicationRemovalRequestError(.targetRemoved)
        }
        guard
            currentTarget.applicationID == applicationID,
            currentTarget.applicationStorageID == applicationStorageID
        else {
            throw ApplicationRemovalRequestError(.targetRetargeted)
        }
        guard currentTarget.repositoryVersion == repositoryVersion else {
            throw ApplicationRemovalRequestError(
                .staleRepositoryVersion
            )
        }
        guard currentTarget.applicationName == applicationName else {
            throw ApplicationRemovalRequestError(.applicationChanged)
        }
        guard currentTarget.profiles == profiles else {
            throw ApplicationRemovalRequestError(.profileTargetsChanged)
        }
        guard let priorBackup else {
            throw ApplicationRemovalRequestError(.priorBackupRequired)
        }
        guard isExact(priorBackup) else {
            throw ApplicationRemovalRequestError(.invalidPriorBackup)
        }

        let active = try validatedActivity(activity)
        let validatedExpertOverride:
            ApplicationRemovalExpertOverrideAuthorization?
        if active {
            guard let expertOverride else {
                throw ApplicationRemovalRequestError(
                    .activeProfileData
                )
            }
            guard isExact(expertOverride) else {
                throw ApplicationRemovalRequestError(
                    .invalidExpertOverride
                )
            }
            validatedExpertOverride = expertOverride
        } else {
            validatedExpertOverride = nil
        }

        return ApplicationRemovalExecutionAuthorization(
            request: self,
            priorBackup: priorBackup,
            expertOverride: validatedExpertOverride
        )
    }

    private func validatedActivity(
        _ snapshot: ApplicationRemovalActivitySnapshot
    ) throws -> Bool {
        guard snapshot.profiles.count == profiles.count else {
            throw ApplicationRemovalRequestError(
                .activitySnapshotMismatch
            )
        }
        var seenStorageIDs: Set<UUID> = []
        var hasActiveOrAmbiguous = false
        let targets = Dictionary(
            uniqueKeysWithValues: profiles.map {
                ($0.profileStorageID, $0)
            }
        )
        for activity in snapshot.profiles {
            guard
                seenStorageIDs.insert(activity.profileStorageID).inserted,
                let target = targets[activity.profileStorageID],
                activity.applicationID == applicationID,
                activity.applicationStorageID == applicationStorageID,
                activity.profileID == target.profileID
            else {
                throw ApplicationRemovalRequestError(
                    .activitySnapshotMismatch
                )
            }
            switch activity.state {
            case .inactive:
                break
            case .active, .ambiguous:
                hasActiveOrAmbiguous = true
            }
        }
        guard seenStorageIDs == Set(profileStorageIDs) else {
            throw ApplicationRemovalRequestError(
                .activitySnapshotMismatch
            )
        }
        return hasActiveOrAmbiguous
    }

    private func isExact(
        _ backup: ApplicationRemovalPriorBackup
    ) -> Bool {
        backup.requestID == requestID
            && backup.sceneID == sceneID
            && backup.applicationID == applicationID
            && backup.applicationStorageID == applicationStorageID
            && backup.repositoryVersion == repositoryVersion
            && backup.artifactSHA256
                == repositoryVersion.primarySHA256
    }

    private func isExact(
        _ authorization: ApplicationRemovalExpertOverrideAuthorization
    ) -> Bool {
        authorization.requestID == requestID
            && authorization.sceneID == sceneID
            && authorization.applicationID == applicationID
            && authorization.applicationStorageID
                == applicationStorageID
            && authorization.profileStorageIDs == profileStorageIDs
            && authorization.dataChoice == dataChoice
            && authorization.repositoryVersion == repositoryVersion
            && authorization.acknowledgedRisk
                == .allManagedProfileDataMayBeCorruptedAndProcessesDestabilized
    }
}
