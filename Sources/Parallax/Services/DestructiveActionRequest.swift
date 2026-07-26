import Foundation

enum DestructiveActionOperation: String, Sendable, Equatable, Hashable {
    case archiveProfileData
    case clearProfileData
    case deleteProfileData
    case duplicateProfileData
    case relocateProfileData
    case removeProfile

    fileprivate var confirmationTitle: String {
        switch self {
        case .archiveProfileData:
            String(localized: "Archive Profile Data")
        case .clearProfileData:
            String(localized: "Clear Profile Data")
        case .deleteProfileData:
            String(localized: "Delete Profile Data")
        case .duplicateProfileData:
            String(localized: "Duplicate Profile Data")
        case .relocateProfileData:
            String(localized: "Move Profile Data")
        case .removeProfile:
            String(localized: "Remove Profile")
        }
    }

    fileprivate func confirmationMessage(
        applicationName: String,
        profileName: String,
        canonicalPath: String
    ) -> String {
        switch self {
        case .archiveProfileData:
            String(
                localized:
                    "Archive the managed data for \(profileName) in \(applicationName) at \(canonicalPath)?"
            )
        case .clearProfileData:
            String(
                localized:
                    "Clear the managed data for \(profileName) in \(applicationName) at \(canonicalPath)?"
            )
        case .deleteProfileData:
            String(
                localized:
                    "Permanently delete the managed data for \(profileName) in \(applicationName) at \(canonicalPath)?"
            )
        case .duplicateProfileData:
            String(
                localized:
                    "Copy the managed data for \(profileName) in \(applicationName) from \(canonicalPath)?"
            )
        case .relocateProfileData:
            String(
                localized:
                    "Move the managed data for \(profileName) in \(applicationName) from \(canonicalPath)?"
            )
        case .removeProfile:
            String(
                localized:
                    "Remove \(profileName) from \(applicationName)? Its managed data target is \(canonicalPath)."
            )
        }
    }
}

struct DestructiveActionPathSnapshot: Sendable, Equatable, Hashable {
    let canonicalURL: URL
    let fileIdentity: FileSystemObjectIdentity?

    init(
        canonicalURL: URL,
        fileIdentity: FileSystemObjectIdentity?
    ) {
        self.canonicalURL = canonicalURL.standardizedFileURL
        self.fileIdentity = fileIdentity
    }

    var canonicalPath: String {
        canonicalURL.path
    }
}

struct DestructiveActionConfirmationPresentation:
    Sendable,
    Equatable
{
    let requestID: UUID
    let sceneID: UUID
    let operation: DestructiveActionOperation
    let title: String
    let message: String
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let applicationName: String
    let profileName: String
    let canonicalPath: String
    let fileIdentity: FileSystemObjectIdentity?
    let configurationRevision: UInt64
    let libraryVersion: LibraryVersionToken
}

struct DestructiveActionCurrentTarget: Sendable, Equatable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let path: DestructiveActionPathSnapshot
    let configurationRevision: UInt64
    let libraryVersion: LibraryVersionToken

    var activityIdentity: ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID,
            profileStorageID: profileStorageID
        )
    }
}

struct DestructiveActionActivitySnapshot: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case inactive
        case active
        case ambiguous
    }

    let identity: ProfileActivityIdentity
    let state: State
}

enum DestructiveActionExpertRiskAcknowledgment:
    String,
    Sendable,
    Equatable,
    Hashable
{
    case profileDataCorruptionAndProcessInstability

    var warningMessage: String {
        switch self {
        case .profileDataCorruptionAndProcessInstability:
            String(
                localized:
                    "The profile may be open in a running application. Continuing can corrupt its data or make the running application unstable."
            )
        }
    }
}

struct DestructiveActionExpertOverrideAuthorization:
    Sendable,
    Equatable
{
    let authorizationID: UUID
    let requestID: UUID
    let sceneID: UUID
    let operation: DestructiveActionOperation
    let activityIdentity: ProfileActivityIdentity
    let configurationRevision: UInt64
    let libraryVersion: LibraryVersionToken
    let acknowledgedRisk: DestructiveActionExpertRiskAcknowledgment

    fileprivate init(
        authorizationID: UUID,
        requestID: UUID,
        sceneID: UUID,
        operation: DestructiveActionOperation,
        activityIdentity: ProfileActivityIdentity,
        configurationRevision: UInt64,
        libraryVersion: LibraryVersionToken,
        acknowledgedRisk: DestructiveActionExpertRiskAcknowledgment
    ) {
        self.authorizationID = authorizationID
        self.requestID = requestID
        self.sceneID = sceneID
        self.operation = operation
        self.activityIdentity = activityIdentity
        self.configurationRevision = configurationRevision
        self.libraryVersion = libraryVersion
        self.acknowledgedRisk = acknowledgedRisk
    }
}

struct DestructiveActionExecutionAuthorization:
    Sendable,
    Equatable
{
    let requestID: UUID
    let sceneID: UUID
    let operation: DestructiveActionOperation
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let path: DestructiveActionPathSnapshot
    let configurationRevision: UInt64
    let libraryVersion: LibraryVersionToken
    let usedExpertOverride: Bool
    let expertOverrideAuthorizationID: UUID?
    let acknowledgedRisk: DestructiveActionExpertRiskAcknowledgment?

    fileprivate init(
        request: DestructiveActionRequest,
        expertOverride: DestructiveActionExpertOverrideAuthorization?
    ) {
        requestID = request.requestID
        sceneID = request.sceneID
        operation = request.operation
        applicationID = request.applicationID
        applicationStorageID = request.applicationStorageID
        profileID = request.profileID
        profileStorageID = request.profileStorageID
        path = request.path
        configurationRevision = request.configurationRevision
        libraryVersion = request.libraryVersion
        usedExpertOverride = expertOverride != nil
        expertOverrideAuthorizationID = expertOverride?.authorizationID
        acknowledgedRisk = expertOverride?.acknowledgedRisk
    }
}

struct DestructiveActionRequestError: LocalizedError {
    enum Code: String, Sendable, Equatable {
        case targetRemoved
        case targetRetargeted
        case canonicalPathChanged
        case fileIdentityChanged
        case configurationChanged
        case staleLibraryVersion
        case activitySnapshotMismatch
        case activeProfileData
        case invalidExpertOverride
    }

    let code: Code

    init(_ code: Code) {
        self.code = code
    }

    var errorDescription: String? {
        switch code {
        case .targetRemoved:
            String(
                localized:
                    "The application or profile no longer exists. The action was cancelled."
            )
        case .targetRetargeted:
            String(
                localized:
                    "The destructive action target changed after confirmation was presented."
            )
        case .canonicalPathChanged:
            String(
                localized:
                    "The profile data path changed after confirmation was presented."
            )
        case .fileIdentityChanged:
            String(
                localized:
                    "The item at the confirmed profile data path was replaced."
            )
        case .configurationChanged:
            String(
                localized:
                    "The profile configuration changed after confirmation was presented."
            )
        case .staleLibraryVersion:
            String(
                localized:
                    "The library changed after confirmation was presented. Review the action again."
            )
        case .activitySnapshotMismatch:
            String(
                localized:
                    "Profile activity was checked for a different storage target."
            )
        case .activeProfileData:
            String(
                localized:
                    "This profile may still be in use. Changing its data can corrupt the profile or destabilize the running application."
            )
        case .invalidExpertOverride:
            String(
                localized:
                    "The expert override does not authorize this exact destructive request."
            )
        }
    }
}

/// An immutable, scene-bound snapshot of one destructive profile-data action.
///
/// UI selection and drafts are intentionally absent. Callers must resolve the
/// current model and canonical path again immediately before execution and
/// present them as `DestructiveActionCurrentTarget`.
struct DestructiveActionRequest: Sendable, Equatable {
    let requestID: UUID
    let sceneID: UUID
    let operation: DestructiveActionOperation
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let applicationName: String
    let profileName: String
    let path: DestructiveActionPathSnapshot
    let configurationRevision: UInt64
    let libraryVersion: LibraryVersionToken

    var activityIdentity: ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID,
            profileStorageID: profileStorageID
        )
    }

    var confirmationPresentation: DestructiveActionConfirmationPresentation {
        DestructiveActionConfirmationPresentation(
            requestID: requestID,
            sceneID: sceneID,
            operation: operation,
            title: operation.confirmationTitle,
            message: operation.confirmationMessage(
                applicationName: applicationName,
                profileName: profileName,
                canonicalPath: path.canonicalPath
            ),
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID,
            profileStorageID: profileStorageID,
            applicationName: applicationName,
            profileName: profileName,
            canonicalPath: path.canonicalPath,
            fileIdentity: path.fileIdentity,
            configurationRevision: configurationRevision,
            libraryVersion: libraryVersion
        )
    }

    func makeExpertOverrideAuthorization(
        acknowledging risk:
            DestructiveActionExpertRiskAcknowledgment,
        authorizationID: UUID = UUID()
    ) -> DestructiveActionExpertOverrideAuthorization {
        DestructiveActionExpertOverrideAuthorization(
            authorizationID: authorizationID,
            requestID: requestID,
            sceneID: sceneID,
            operation: operation,
            activityIdentity: activityIdentity,
            configurationRevision: configurationRevision,
            libraryVersion: libraryVersion,
            acknowledgedRisk: risk
        )
    }

    func authorizeExecution(
        currentTarget: DestructiveActionCurrentTarget?,
        activity: DestructiveActionActivitySnapshot,
        expertOverride:
            DestructiveActionExpertOverrideAuthorization? = nil
    ) throws -> DestructiveActionExecutionAuthorization {
        guard let currentTarget else {
            throw DestructiveActionRequestError(.targetRemoved)
        }
        guard
            currentTarget.applicationID == applicationID,
            currentTarget.applicationStorageID == applicationStorageID,
            currentTarget.profileID == profileID,
            currentTarget.profileStorageID == profileStorageID
        else {
            throw DestructiveActionRequestError(.targetRetargeted)
        }
        guard currentTarget.libraryVersion == libraryVersion else {
            throw DestructiveActionRequestError(.staleLibraryVersion)
        }
        guard
            currentTarget.configurationRevision == configurationRevision
        else {
            throw DestructiveActionRequestError(.configurationChanged)
        }
        guard
            currentTarget.path.canonicalURL.standardizedFileURL
                == path.canonicalURL.standardizedFileURL
        else {
            throw DestructiveActionRequestError(.canonicalPathChanged)
        }
        guard currentTarget.path.fileIdentity == path.fileIdentity else {
            throw DestructiveActionRequestError(.fileIdentityChanged)
        }
        guard activity.identity == activityIdentity else {
            throw DestructiveActionRequestError(.activitySnapshotMismatch)
        }

        let validatedExpertOverride:
            DestructiveActionExpertOverrideAuthorization?
        switch activity.state {
        case .inactive:
            validatedExpertOverride = nil
        case .active, .ambiguous:
            guard let expertOverride else {
                throw DestructiveActionRequestError(.activeProfileData)
            }
            guard
                expertOverride.requestID == requestID,
                expertOverride.sceneID == sceneID,
                expertOverride.operation == operation,
                expertOverride.activityIdentity == activityIdentity,
                expertOverride.configurationRevision
                    == configurationRevision,
                expertOverride.libraryVersion == libraryVersion,
                expertOverride.acknowledgedRisk
                    == .profileDataCorruptionAndProcessInstability
            else {
                throw DestructiveActionRequestError(
                    .invalidExpertOverride
                )
            }
            validatedExpertOverride = expertOverride
        }

        return DestructiveActionExecutionAuthorization(
            request: self,
            expertOverride: validatedExpertOverride
        )
    }
}
