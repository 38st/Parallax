import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class LibraryStore {
    static let defaultProfileTemplateNames = AppSettings.defaultProfileTemplateNames
    static let defaultProfilesRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Parallax/Profiles", isDirectory: true)
        .path

    typealias PendingLibraryImport = PreparedLibraryImport

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
    private(set) var infrastructureFailureMessage: String?
    var libraryOperationStatusMessage: String? {
        didSet {
            if oldValue != nil, libraryOperationStatusMessage == nil,
                isLibraryOperationInProgress, errorMessage == nil
            {
                scheduleLibraryReloadRetry(immediately: true)
            }
        }
    }
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
    var libraryImportFlowState: LibraryImportFlowState = .idle
    var isShowingImportedLaunchReview = false
    var loadState: LoadState = .loading
    var migrationRequiredLibrary: LegacyLibrary?
    var migrationBlockers: [LibraryMigrationBlocker] = []
    var isLibraryOperationInProgress = false
    var pendingRecoveryIdentities: Set<ProfileActivityIdentity>?
    var presentedRelocationNoticeIDs: Set<UUID> = []
    var visibleRelocationNoticeIDs: Set<UUID> = []
    var relocationNoticeMessage: String?
    var libraryReadOnlyWarning: String?
    @ObservationIgnored var libraryReloadRetryCancellation: (@MainActor () -> Void)?
    @ObservationIgnored var libraryReloadActivationObservation: LibraryReloadActivationObservation?
    @ObservationIgnored let libraryReloadRetryScheduler: LibraryReloadRetryScheduler
    var libraryReloadRetryGeneration: UInt = 0
    var libraryReloadRetryDelay: Duration = .milliseconds(100)
    var shouldRetryLibraryMigration = false
    var pendingProfileRemovalRecovery:
        ProfileRemovalRecovery?
    var pendingImportedLaunchReview: ImportedLaunchReview?
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

    let persistence: any LibraryPersisting
    let repository: (any LibraryRepositoryPersisting)?
    let backupStore: LibraryBackupStore?
    let libraryPrimaryURL: URL?
    let sharedHistoryStore: SharedHistoryStore?
    let sharedHistoryInitializationError: Error?
    var sharedHistoryRevision = 0
    var conversationSwitchMessage: String?
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
    let isolationVerification: LaunchIsolationVerification
    @ObservationIgnored var launchConfigurationCompiler: LaunchConfigurationCompiler
    let launchHealthService: LaunchHealthService
    let secretStore: any SecretStoring
    let importValidator = LibraryImportValidator()
    let importedLaunchTrust = ImportedLaunchTrust()
    let portableConfiguration = PortableConfigurationService()
    let fileSystem: any FileSystem
    let pathResolver: ManagedPathResolver
    let settings: AppSettings
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
        isolationVerification: LaunchIsolationVerification = LaunchIsolationVerification(),
        secretStore: (any SecretStoring)? = nil,
        fileSystem: any FileSystem = LocalFileSystem(),
        // Non-persistent default retained for isolated test construction.
        // Production construction always injects its single versioned facade.
        settings: AppSettings = AppSettings(),
        sceneID: UUID = UUID(),
        sceneCoordinator: SceneCoordinator? = nil,
        libraryChangeBroadcaster: LibraryChangeBroadcaster? = nil,
        libraryReloadRetryScheduler: @escaping LibraryReloadRetryScheduler = LibraryReloadRetry.schedule
    ) {
        let resolvedSceneCoordinator =
            sceneCoordinator ?? SceneCoordinator(sceneID: sceneID)
        self.sceneID = resolvedSceneCoordinator.sceneID
        self.sceneCoordinator = resolvedSceneCoordinator
        self.libraryChangeBroadcaster = libraryChangeBroadcaster
        self.libraryReloadRetryScheduler = libraryReloadRetryScheduler
        let resolvedPersistence = persistence
            ?? repository?.persistence
            ?? LibraryPersistence(fileSystem: fileSystem)
        self.persistence = resolvedPersistence
        let applicationSupportURL = persistence == nil
            ? try? (resolvedPersistence as? any LibraryRepositoryPersistence)?
                .resolvedApplicationSupportURL()
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
        if let applicationSupportURL {
            do {
                sharedHistoryStore = try SharedHistoryStore(applicationSupportURL: applicationSupportURL)
                sharedHistoryInitializationError = nil
            } catch {
                sharedHistoryStore = nil
                sharedHistoryInitializationError = error
            }
        } else {
            sharedHistoryStore = nil
            sharedHistoryInitializationError = nil
        }
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
        let resolvedEnrollmentStore = profileDataTransactions?.enrollmentStore
            ?? storageRelocationCoordinator?.enrollmentStore
            ?? applicationSupportURL.flatMap { try? StorageVolumeEnrollmentStore.shared(applicationSupportURL: $0) }
        let resolvedPathResolver = ManagedPathResolver(fileSystem: fileSystem, enrollmentStore: resolvedEnrollmentStore)
        if let profileDataTransactions {
            self.profileDataTransactions = profileDataTransactions
            self.profileDataTransactionInitializationError = nil
        } else if let applicationSupportURL {
            do {
                self.profileDataTransactions = try ProfileDataTransactionCoordinator(
                    applicationSupportURL: applicationSupportURL,
                    fileSystem: fileSystem,
                    enrollmentStore: resolvedEnrollmentStore
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
                    applicationSupportURL: applicationSupportURL,
                    enrollmentStore: resolvedEnrollmentStore
                )
        } else {
            self.applicationRemovalTransactions = nil
        }
        self.applicationRemovalBackupHook =
            applicationRemovalBackupHook
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
            } catch DurableLaunchActivityStoreError.activityBusy {
                // Launch and data admission recheck activity under its lock.
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
                pathResolver: resolvedPathResolver,
                activityProvider: resolvedActivityRegistry
            )
        self.isolationVerification = isolationVerification
        self.launchHealthService = LaunchHealthService(
            fileSystem: fileSystem,
            pathResolver: resolvedPathResolver,
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
        if let infrastructureError =
            profileDataTransactionInitializationError
                ?? storageRelocationInitializationError
                ?? profileActivityInitializationError
        {
            let message = infrastructureError.localizedDescription
            let originalBytes: Data? = if let repository = self.repository {
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
            infrastructureFailureMessage = message
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = nil
            errorMessage = message
            loadState = .recoveryRequired(
                originalBytes: originalBytes,
                message: message
            )
        }
        self.launchConfigurationCompiler.enrollPreparedStorage = { [weak self] source, paths in
            await self?.enrollPreparedStorageIfCurrent(source, paths: paths)
        }
        load()
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
