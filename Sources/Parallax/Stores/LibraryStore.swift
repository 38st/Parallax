import AppKit
import Foundation
import Observation

enum LibraryStoreInfrastructureError: LocalizedError {
    case ambiguousDurableActivity(Int)
    case startupRecoveryDidNotConverge

    var errorDescription: String? {
        switch self {
        case let .ambiguousDurableActivity(count):
            String(
                localized: "\(count) durable launch activity record(s) could not be reconciled safely."
            )
        case .startupRecoveryDidNotConverge:
            String(
                localized:
                    "Startup recovery did not reach a stable library state. Parallax stopped retrying to protect the library."
            )
        }
    }
}

enum LibraryImportStoreError: LocalizedError {
    case invalidImportFile
    case replacementUnavailable
    case staleImportSession
    case unresolvedConflict
    case conflictTargetRequired

    var errorDescription: String? {
        switch self {
        case .invalidImportFile:
            String(
                localized:
                    "Choose a regular JSON file within the supported import size limit."
            )
        case .replacementUnavailable:
            String(
                localized:
                    "Recoverable library replacement is unavailable because backup services are not ready."
            )
        case .staleImportSession:
            String(
                localized:
                    "The library changed after this import was reviewed. Start the import again."
            )
        case .unresolvedConflict:
            String(
                localized:
                    "The import still contains an unresolved conflict."
            )
        case .conflictTargetRequired:
            String(
                localized:
                    "Choose the exact existing application or profile for this conflict decision."
            )
        }
    }
}

enum BackgroundStorageRelocationResult: Sendable {
    case succeeded(StorageRelocationOutcome)
    case failed(code: StorageRelocationError.Code?, message: String)
}

struct PendingApplicationRelink {
    let proposal: ApplicationRelinkProposal
    let baselineVersion: LibraryVersionToken
}

enum LibraryExportSensitivePolicy: Equatable, Sendable {
    case omit
    case redact
    case include
}

enum LibraryPortableExportKind: String, Sendable {
    case libraryMetadata
    case settingsAndTemplates
    case portableConfiguration
}

enum LibraryImportConflictChoice: Sendable {
    case keepExisting
    case useImported
    case keepBoth
    case skip
}

struct LibraryImportSummary: Equatable, Sendable {
    let applicationCount: Int
    let profileCount: Int
    let warnings: [String]

    var message: String {
        var lines = [
            String(
                localized:
                    "\(LocalizedCount.applications(applicationCount)), \(LocalizedCount.profiles(profileCount))."
            ),
            String(
                localized:
                    "Import changes library metadata only. Existing profile data is preserved."
            ),
        ]
        lines.append(contentsOf: warnings)
        return lines.joined(separator: "\n")
    }
}

struct LibraryImportConflictTarget: Identifiable, Equatable, Sendable {
    var id: String {
        [
            applicationID.uuidString.lowercased(),
            profileID?.uuidString.lowercased() ?? "",
        ].joined(separator: ":")
    }

    let applicationID: UUID
    let profileID: UUID?
    let label: String
}

struct StagedProfileKeychainSecret: Equatable, Sendable {
    let profile: LaunchProfile
    let reference: EnvironmentSecretReference
}

struct PendingProfileEditingDraft: Equatable, Sendable {
    let applicationID: ManagedApplication.ID
    let draft: LaunchProfile
    let baseline: LaunchProfile
    let baselineVersion: LibraryVersionToken
    let stagedKeychainReferences: Set<EnvironmentSecretReference>
    let pendingKeychainDeletionReferences: Set<EnvironmentSecretReference>
}

@Observable
@MainActor
final class LibraryStore {
    static let defaultProfileTemplateNames = AppSettings.defaultProfileTemplateNames
    static let defaultProfilesRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Parallax/Profiles", isDirectory: true)
        .path

    enum ProfileDataRemoval: Equatable {
        case keep
        case archive
        case delete
    }

    enum LoadState {
        case loading
        case loaded
        case recoveryRequired(originalBytes: Data?, message: String)
        case unsupportedNewerVersion(originalBytes: Data?, message: String)
        case unrecoverable(originalBytes: Data?, message: String)
    }

    struct StartOverAuthorization: Equatable {
        let failedPrimarySHA256: String
    }

    struct ProfileRemovalRecovery: Equatable {
        let profileName: String
        let canonicalRemainingDataPath: String
        let applicationID: UUID
        let applicationStorageID: UUID
        let profileID: UUID
        let profileStorageID: UUID
        let expectedVersion: LibraryVersionToken
    }

    var applications: [ManagedApplication] = []
    var selectedApplicationID: ManagedApplication.ID? {
        get { sceneCoordinator.selectedApplicationID }
        set {
            sceneCoordinator.selectApplication(
                newValue,
                in: applications
            )
        }
    }
    var selectedProfileID: LaunchProfile.ID? {
        get { sceneCoordinator.selectedProfileID }
        set {
            sceneCoordinator.selectProfile(
                newValue,
                in: applications
            )
        }
    }
    var errorMessage: String? {
        didSet {
            if errorMessage != nil {
                libraryOperationStatusMessage = nil
            }
        }
    }
    var libraryOperationStatusMessage: String?
    var launchPresentationRevision: UInt = 0

    /// Compatibility spelling for existing callers. Launch attempts use
    /// `launchStatusMessage(for:profile:)`; this value is scene-local library
    /// operation feedback.
    var launchStatusMessage: String? {
        get { libraryOperationStatusMessage }
        set { libraryOperationStatusMessage = newValue }
    }
    var isShowingAppImporter = false
    var isShowingLaunchConfirmation = false
    var isShowingLaunchDiagnosticOverride = false
    var isShowingConcurrentLaunchOverride = false
    var isShowingDestructiveActionConfirmation = false
    var isShowingDestructiveExpertOverride = false
    var isShowingApplicationRelinkConfirmation = false
    var isShowingApplicationRemovalConfirmation = false
    var isShowingImportChoice = false
    var isShowingImportConflictResolution = false
    var isShowingImportedLaunchReview = false
    var loadState: LoadState = .loading
    var migrationRequiredLibrary: LegacyLibrary?
    var pendingProfileRemovalRecovery:
        ProfileRemovalRecovery?
    var pendingImportSummary: LibraryImportSummary?
    var pendingImportConflict: LibraryImportConflict?
    var pendingImportedLaunchReview: ImportedLaunchReview?
    var pendingLibraryImport: PendingLibraryImport?
    var pendingImportResolutions:
        [LibraryImportConflictID: LibraryImportConflictResolution] = [:]
    var lastImportReplacement:
        LibraryImportReplacementResult?
    var pendingImportedLaunch: PendingImportedLaunch?
    var launchRequests = LaunchRequestCoordinator()
    var pendingLaunchDiagnosticRequest:
        PendingLaunchDiagnosticRequest?
    var pendingConcurrentLaunchRequest:
        PendingConcurrentLaunchRequest?
    var pendingDestructiveActionRequest:
        DestructiveActionRequest?
    var pendingApplicationRelink:
        PendingApplicationRelink?
    var pendingApplicationRemoval:
        ApplicationRemovalRequest?
    @ObservationIgnored var pendingProfileEditingDrafts:
        [LaunchProfile.ID: PendingProfileEditingDraft] = [:]

    var pendingDestructiveActionPresentation:
        DestructiveActionConfirmationPresentation?
    {
        pendingDestructiveActionRequest?.confirmationPresentation
    }

    var destructiveExpertOverrideWarning: String {
        DestructiveActionExpertRiskAcknowledgment
            .profileDataCorruptionAndProcessInstability
            .warningMessage
    }

    var pendingLaunchDiagnosticMessage: String? {
        pendingLaunchDiagnosticRequest?.diagnostics
            .map(\.message)
            .joined(separator: "\n")
    }

    var pendingLaunchProfileName: String? {
        launchRequests.pendingConfirmation(in: sceneID)?.profileName
    }

    var pendingLaunchApplicationName: String? {
        launchRequests.pendingConfirmation(in: sceneID)?
            .applicationName
    }

    var pendingApplicationRelinkMessage: String? {
        guard let proposal = pendingApplicationRelink?.proposal else {
            return nil
        }
        return String(
            localized:
                "Update \(proposal.originalApplication.displayName) from \(proposal.originalApplication.appPath) to \(proposal.canonicalCandidateURL.path)? All profiles and managed storage identities will be preserved."
        )
    }

    var pendingApplicationRemovalPresentation:
        ApplicationRemovalConfirmationPresentation?
    {
        pendingApplicationRemoval?.confirmationPresentation
    }

    let persistence: any LibraryPersisting
    let repository: (any LibraryRepositoryPersisting)?
    let backupStore: LibraryBackupStore?
    let libraryPrimaryURL: URL?
    let profileDataTransactions: ProfileDataTransactionCoordinator?
    let profileDataTransactionInitializationError: Error?
    let storageRelocationCoordinator: StorageRelocationCoordinator?
    let storageRelocationInitializationError: Error?
    let profileActivityRegistry: ProfileActivityRegistry
    let launchHistoryStore: LaunchHistoryStore
    let managedAppWorkaroundStore:
        ManagedAppWorkaroundStore
    let managedAppRecoveryLedger:
        ManagedAppRecoveryLedger
    let applicationRemovalTransactions:
        ApplicationRemovalTransactionCoordinator?
    let applicationRemovalBackupHook:
        ((Data) throws -> LibraryRecoveryArtifact)?
    let profileActivityInitializationError: Error?
    let sceneID: UUID
    let sceneCoordinator: SceneCoordinator
    let libraryChangeBroadcaster: LibraryChangeBroadcaster?
    var libraryVersionToken: LibraryVersionToken?
    let launcher: ApplicationLaunching
    let applicationInstanceController:
        any ApplicationInstanceControlling
    let launchConfigurationCompiler: LaunchConfigurationCompiler
    let launchHealthService: LaunchHealthService
    let secretStore: any SecretStoring
    let importValidator = LibraryImportValidator()
    let importedLaunchTrust = ImportedLaunchTrust()
    let portableConfiguration = PortableConfigurationService()
    let fileSystem: any FileSystem
    let pathResolver: ManagedPathResolver
    var settings: AppSettings
    var storageRelocationPreview: StorageRelocationPreview?
    var storageRelocationProgress: StorageRelocationProgress?
    var storageRelocationCancellation: StorageRelocationCancellation?
    var storageRelocationTask: Task<Void, Never>?
    var isProfileDataOperationRunning = false
    var launchPreparationTasks: [UUID: Task<Void, Never>] = [:]
    var activeTrackedLaunches:
        [UUID: TrackedApplicationLaunch] = [:]
    var importedLaunchAssessmentTasks:
        [UUID: Task<Void, Never>] = [:]
    var healthItemsCache:
        [HealthCacheKey: [(label: String, isHealthy: Bool)]] = [:]
    @ObservationIgnored
    var healthInspectionTasks:
        [HealthCacheKey: Task<Void, Never>] = [:]

    var isStorageRelocationRunning: Bool {
        storageRelocationCancellation != nil
    }

    init(
        persistence: (any LibraryPersisting)? = nil,
        repository: (any LibraryRepositoryPersisting)? = nil,
        backupStore: LibraryBackupStore? = nil,
        profileDataTransactions: ProfileDataTransactionCoordinator? = nil,
        applicationRemovalTransactions:
            ApplicationRemovalTransactionCoordinator? = nil,
        applicationRemovalBackupHook:
            ((Data) throws -> LibraryRecoveryArtifact)? = nil,
        storageRelocationCoordinator: StorageRelocationCoordinator? = nil,
        profileActivityRegistry: ProfileActivityRegistry? = nil,
        profileActivityBootstrapError: Error? = nil,
        launchHistoryStore: LaunchHistoryStore? = nil,
        managedAppWorkaroundStore:
            ManagedAppWorkaroundStore? = nil,
        managedAppRecoveryLedger:
            ManagedAppRecoveryLedger? = nil,
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        applicationInstanceController:
            (any ApplicationInstanceControlling)? = nil,
        launchConfigurationCompiler: LaunchConfigurationCompiler? = nil,
        secretStore: (any SecretStoring)? = nil,
        fileSystem: any FileSystem = LocalFileSystem(),
        settings: AppSettings = AppSettings(),
        sceneID: UUID = UUID(),
        sceneCoordinator: SceneCoordinator? = nil,
        libraryChangeBroadcaster: LibraryChangeBroadcaster? = nil
    ) {
        let resolvedSceneCoordinator =
            sceneCoordinator ?? SceneCoordinator(sceneID: sceneID)
        self.sceneID = resolvedSceneCoordinator.sceneID
        self.sceneCoordinator = resolvedSceneCoordinator
        self.libraryChangeBroadcaster = libraryChangeBroadcaster
        self.persistence = persistence ?? LibraryPersistence(fileSystem: fileSystem)
        let applicationSupportURL = persistence == nil
            ? try? fileSystem.applicationSupportURL(create: true)
            : nil
        if let launchHistoryStore {
            self.launchHistoryStore = launchHistoryStore
        } else if let applicationSupportURL {
            self.launchHistoryStore =
                (try? LaunchHistoryStore(
                    applicationSupportURL: applicationSupportURL
                ))
                ?? LaunchHistoryStore()
        } else {
            self.launchHistoryStore = LaunchHistoryStore()
        }
        if let managedAppWorkaroundStore {
            self.managedAppWorkaroundStore =
                managedAppWorkaroundStore
        } else if let applicationSupportURL {
            self.managedAppWorkaroundStore =
                (try? ManagedAppWorkaroundStore(
                    applicationSupportURL: applicationSupportURL
                ))
                ?? ManagedAppWorkaroundStore()
        } else {
            self.managedAppWorkaroundStore =
                ManagedAppWorkaroundStore()
        }
        if let managedAppRecoveryLedger {
            self.managedAppRecoveryLedger =
                managedAppRecoveryLedger
        } else if let applicationSupportURL {
            self.managedAppRecoveryLedger =
                (try? ManagedAppRecoveryLedger(
                    applicationSupportURL: applicationSupportURL
                ))
                ?? ManagedAppRecoveryLedger(
                    persistenceErrorMessage:
                        "Application Support is unavailable."
                )
        } else {
            self.managedAppRecoveryLedger =
                ManagedAppRecoveryLedger()
        }
        let resolvedBackupStore: LibraryBackupStore? = if let backupStore {
            backupStore
        } else if let applicationSupportURL {
            LibraryBackupStore(
                fileSystem: fileSystem,
                recoveryRoot: applicationSupportURL
                    .appendingPathComponent("Parallax", isDirectory: true)
                    .appendingPathComponent("Recovery", isDirectory: true)
            )
        } else {
            nil
        }
        self.backupStore = resolvedBackupStore
        self.libraryPrimaryURL = applicationSupportURL?
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        if let repository {
            self.repository = repository
        } else if let applicationSupportURL {
            self.repository = LibraryRepository(
                fileSystem: fileSystem,
                applicationSupportURL: applicationSupportURL,
                backupHook: { bytes, reason in
                    guard let resolvedBackupStore else {
                        throw LibraryRepositoryError.backupUnavailable
                    }
                    _ = try resolvedBackupStore.createBackup(
                        of: bytes,
                        reason: reason
                    )
                }
            )
        } else {
            self.repository = nil
        }
        if let profileDataTransactions {
            self.profileDataTransactions = profileDataTransactions
            self.profileDataTransactionInitializationError = nil
        } else if let applicationSupportURL {
            do {
                self.profileDataTransactions = try ProfileDataTransactionCoordinator(
                    applicationSupportURL: applicationSupportURL,
                    fileSystem: fileSystem
                )
                self.profileDataTransactionInitializationError = nil
            } catch {
                self.profileDataTransactions = nil
                self.profileDataTransactionInitializationError = error
            }
        } else {
            self.profileDataTransactions = nil
            self.profileDataTransactionInitializationError = nil
        }
        if let applicationRemovalTransactions {
            self.applicationRemovalTransactions =
                applicationRemovalTransactions
        } else if let applicationSupportURL {
            self.applicationRemovalTransactions = try?
                ApplicationRemovalTransactionCoordinator(
                    applicationSupportURL: applicationSupportURL
                )
        } else {
            self.applicationRemovalTransactions = nil
        }
        self.applicationRemovalBackupHook =
            applicationRemovalBackupHook
        let resolvedPathResolver = ManagedPathResolver(fileSystem: fileSystem)
        let resolvedActivityRegistry: ProfileActivityRegistry
        let activityInitializationError: Error?
        if let profileActivityRegistry {
            resolvedActivityRegistry = profileActivityRegistry
            activityInitializationError = profileActivityBootstrapError
        } else if let applicationSupportURL {
            do {
                resolvedActivityRegistry = try ProfileActivityRegistry(
                    applicationSupportURL: applicationSupportURL
                )
                activityInitializationError = nil
            } catch {
                resolvedActivityRegistry = ProfileActivityRegistry()
                activityInitializationError = error
            }
        } else {
            resolvedActivityRegistry = ProfileActivityRegistry()
            activityInitializationError = nil
        }
        var activityReconciliationError = activityInitializationError
        if activityReconciliationError == nil {
            do {
                let report =
                    try resolvedActivityRegistry.reconcileDurableActivity()
                if report.globalAmbiguousCount > 0 {
                    activityReconciliationError =
                        LibraryStoreInfrastructureError
                            .ambiguousDurableActivity(
                                report.globalAmbiguousCount
                            )
                }
            } catch {
                activityReconciliationError = error
            }
        }
        self.profileActivityRegistry = resolvedActivityRegistry
        self.profileActivityInitializationError =
            activityReconciliationError
        self.applicationInstanceController =
            applicationInstanceController
            ?? ApplicationInstanceController()
        self.launchConfigurationCompiler =
            launchConfigurationCompiler
            ?? LaunchConfigurationCompiler(
                fileSystem: fileSystem,
                activityProvider: resolvedActivityRegistry
            )
        self.launchHealthService = LaunchHealthService(
            fileSystem: fileSystem,
            activityProvider: resolvedActivityRegistry
        )
        self.secretStore = secretStore ?? KeychainSecretStore()
        if let storageRelocationCoordinator {
            self.storageRelocationCoordinator = storageRelocationCoordinator
            self.storageRelocationInitializationError = nil
        } else if let applicationSupportURL {
            do {
                self.storageRelocationCoordinator = try StorageRelocationCoordinator(
                    applicationSupportURL: applicationSupportURL,
                    fileSystem: fileSystem,
                    pathResolver: resolvedPathResolver,
                    activityProvider: resolvedActivityRegistry
                )
                self.storageRelocationInitializationError = nil
            } catch {
                self.storageRelocationCoordinator = nil
                self.storageRelocationInitializationError = error
            }
        } else {
            self.storageRelocationCoordinator = nil
            self.storageRelocationInitializationError = nil
        }
        self.launcher = launcher
        self.fileSystem = fileSystem
        self.pathResolver = resolvedPathResolver
        self.settings = settings
        load()
        if let infrastructureError =
            profileDataTransactionInitializationError
                ?? storageRelocationInitializationError
                ?? profileActivityInitializationError
        {
            let originalBytes: Data? = if let repository {
                switch repository.load() {
                case let .loaded(snapshot):
                    snapshot.originalBytes
                case let .migrationRequired(snapshot):
                    snapshot.originalBytes
                case let .recoveryRequired(failure),
                     let .readOnly(failure):
                    failure.originalBytes
                case .missing:
                    nil
                }
            } else {
                nil
            }
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = nil
            errorMessage = infrastructureError.localizedDescription
            loadState = .recoveryRequired(
                originalBytes: originalBytes,
                message: infrastructureError.localizedDescription
            )
        }
    }

    var profileTemplateNames: [String] {
        settings.profileTemplateNames
    }

    var profileTemplates: [ProfileTemplate] {
        settings.profileTemplates
    }

    var currentLibraryVersion: LibraryVersionToken? {
        libraryVersionToken
    }

}
