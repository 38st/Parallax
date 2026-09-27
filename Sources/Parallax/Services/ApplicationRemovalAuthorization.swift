import Foundation

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

extension ApplicationRemovalRequest {
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
        let validatedExpertOverride = try validateExecutionTarget(
            currentTarget: currentTarget,
            activity: activity,
            expertOverride: expertOverride
        )
        guard let priorBackup else {
            throw ApplicationRemovalRequestError(.priorBackupRequired)
        }
        guard isExact(priorBackup) else {
            throw ApplicationRemovalRequestError(.invalidPriorBackup)
        }

        return ApplicationRemovalExecutionAuthorization(
            request: self,
            priorBackup: priorBackup,
            expertOverride: validatedExpertOverride
        )
    }

    func validateExecutionTarget(
        currentTarget: ApplicationRemovalCurrentTarget?,
        activity: ApplicationRemovalActivitySnapshot,
        expertOverride: ApplicationRemovalExpertOverrideAuthorization? = nil
    ) throws -> ApplicationRemovalExpertOverrideAuthorization? {
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

        return validatedExpertOverride
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
