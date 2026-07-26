import AppKit
import Foundation
import Observation

private enum LibraryStoreInfrastructureError: LocalizedError {
    case ambiguousDurableActivity(Int)

    var errorDescription: String? {
        switch self {
        case let .ambiguousDurableActivity(count):
            String(
                localized: "\(count) durable launch activity record(s) could not be reconciled safely."
            )
        }
    }
}

private enum LibraryImportStoreError: LocalizedError {
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

private enum BackgroundStorageRelocationResult: Sendable {
    case succeeded(StorageRelocationOutcome)
    case failed(code: StorageRelocationError.Code?, message: String)
}

private struct PendingApplicationRelink {
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
        fileprivate let failedPrimarySHA256: String
    }

    struct ProfileRemovalRecovery: Equatable {
        let profileName: String
        let canonicalRemainingDataPath: String
        fileprivate let applicationID: UUID
        fileprivate let applicationStorageID: UUID
        fileprivate let profileID: UUID
        fileprivate let profileStorageID: UUID
        fileprivate let expectedVersion: LibraryVersionToken
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
    private(set) var libraryOperationStatusMessage: String?

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
    private(set) var loadState: LoadState = .loading
    private(set) var migrationRequiredLibrary: LegacyLibrary?
    private(set) var pendingProfileRemovalRecovery:
        ProfileRemovalRecovery?
    private(set) var pendingImportSummary: LibraryImportSummary?
    private(set) var pendingImportConflict: LibraryImportConflict?
    private(set) var pendingImportedLaunchReview: ImportedLaunchReview?
    private var pendingLibraryImport: PendingLibraryImport?
    private var pendingImportResolutions:
        [LibraryImportConflictID: LibraryImportConflictResolution] = [:]
    private var lastImportReplacement:
        LibraryImportReplacementResult?
    private var pendingImportedLaunch: PendingImportedLaunch?
    private var launchRequests = LaunchRequestCoordinator()
    private var pendingLaunchDiagnosticRequest:
        PendingLaunchDiagnosticRequest?
    private var pendingConcurrentLaunchRequest:
        PendingConcurrentLaunchRequest?
    private var pendingDestructiveActionRequest:
        DestructiveActionRequest?
    private var pendingApplicationRelink:
        PendingApplicationRelink?
    private var pendingApplicationRemoval:
        ApplicationRemovalRequest?

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

    private let persistence: any LibraryPersisting
    private let repository: (any LibraryRepositoryPersisting)?
    private let backupStore: LibraryBackupStore?
    private let libraryPrimaryURL: URL?
    private let profileDataTransactions: ProfileDataTransactionCoordinator?
    private let profileDataTransactionInitializationError: Error?
    private let storageRelocationCoordinator: StorageRelocationCoordinator?
    private let storageRelocationInitializationError: Error?
    private let profileActivityRegistry: ProfileActivityRegistry
    private let applicationRemovalTransactions:
        ApplicationRemovalTransactionCoordinator?
    private let applicationRemovalBackupHook:
        ((Data) throws -> LibraryRecoveryArtifact)?
    private let profileActivityInitializationError: Error?
    let sceneID: UUID
    private let sceneCoordinator: SceneCoordinator
    private let libraryChangeBroadcaster: LibraryChangeBroadcaster?
    private var libraryVersionToken: LibraryVersionToken?
    private let launcher: ApplicationLaunching
    private let launchConfigurationCompiler: LaunchConfigurationCompiler
    private let launchHealthService: LaunchHealthService
    private let secretStore: any SecretStoring
    private let importValidator = LibraryImportValidator()
    private let importedLaunchTrust = ImportedLaunchTrust()
    private let portableConfiguration = PortableConfigurationService()
    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    var settings: AppSettings
    private(set) var storageRelocationPreview: StorageRelocationPreview?
    private(set) var storageRelocationProgress: StorageRelocationProgress?
    private var storageRelocationCancellation: StorageRelocationCancellation?
    private var storageRelocationTask: Task<Void, Never>?
    private var launchPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var importedLaunchAssessmentTasks:
        [UUID: Task<Void, Never>] = [:]
    private var healthItemsCache:
        [HealthCacheKey: [(label: String, isHealthy: Bool)]] = [:]
    @ObservationIgnored
    private var healthInspectionTasks:
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
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
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
            activityInitializationError = nil
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
                if report.ambiguousCount > 0 {
                    activityReconciliationError =
                        LibraryStoreInfrastructureError
                            .ambiguousDurableActivity(
                                report.ambiguousCount
                            )
                }
            } catch {
                activityReconciliationError = error
            }
        }
        self.profileActivityRegistry = resolvedActivityRegistry
        self.profileActivityInitializationError =
            activityReconciliationError
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

    @discardableResult
    func applyApplicationEdit(
        draft: ManagedApplication,
        baseline: ManagedApplication,
        baselineVersion: LibraryVersionToken
    ) -> Bool {
        guard
            let latest = applications.first(where: {
                $0.id == baseline.id
            }),
            let currentVersion = libraryVersionToken
        else {
            errorMessage = String(
                localized:
                    "The application no longer exists. Your draft was kept."
            )
            return false
        }
        let session = ManagedApplicationEditSession(
            application: baseline,
            libraryVersion: baselineVersion
        )
        session.draft = ManagedApplicationEditDraft(
            application: draft
        )
        let result = session.apply(
            to: latest,
            libraryVersion: currentVersion
        ) { [self] merged, expectedVersion in
            try persistApplicationEdit(
                merged,
                expectedVersion: expectedVersion
            )
        }
        return handleApplicationEditResult(result)
    }

    func presetChangePreview(
        for application: ManagedApplication,
        targetPreset: AppPreset
    ) -> PresetChangePreview? {
        do {
            let generatedPaths = try application.profiles.map { profile in
                let paths = try managedPaths(
                    for: application,
                    profile: profile
                )
                return PresetGeneratedPaths(
                    profileID: profile.id,
                    profileStorageID: profile.storageID,
                    userDataDirectory: paths.userData.url.path,
                    codexHome: paths.codexHome.url.path
                )
            }
            return try PresetChangePreviewService().preview(
                application: application,
                targetPreset: targetPreset,
                generatedPaths: generatedPaths
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func applyApplicationPresetEdit(
        draft: ManagedApplication,
        baseline: ManagedApplication,
        baselineVersion: LibraryVersionToken,
        preview: PresetChangePreview,
        refreshGeneratedValues: Bool
    ) -> Bool {
        guard
            let latest = applications.first(where: {
                $0.id == baseline.id
            }),
            let currentVersion = libraryVersionToken
        else {
            errorMessage = String(
                localized:
                    "The application no longer exists. Your draft was kept."
            )
            return false
        }
        let session = ManagedApplicationEditSession(
            application: baseline,
            libraryVersion: baselineVersion
        )
        session.draft = ManagedApplicationEditDraft(
            application: draft
        )
        let service = PresetChangePreviewService()
        if refreshGeneratedValues, session.dirtyFields.isEmpty {
            do {
                let authorization = service.authorizeRefresh(
                    preview,
                    acknowledging:
                        .applyListedGeneratedValueChanges
                )
                let final = try service.applyingAuthorizedRefresh(
                    preview,
                    authorization: authorization,
                    to: latest
                )
                _ = try persistApplicationEdit(
                    final,
                    expectedVersion: currentVersion
                )
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        let result = session.apply(
            to: latest,
            libraryVersion: currentVersion
        ) { [self] merged, expectedVersion in
            var source = merged
            source.preset = preview.sourcePreset
            let final: ManagedApplication
            if refreshGeneratedValues {
                let authorization = service.authorizeRefresh(
                    preview,
                    acknowledging:
                        .applyListedGeneratedValueChanges
                )
                final = try service.applyingAuthorizedRefresh(
                    preview,
                    authorization: authorization,
                    to: source
                )
            } else {
                final = try service.applyingPresetMetadata(
                    preview,
                    to: source
                )
            }
            return try persistApplicationEdit(
                final,
                expectedVersion: expectedVersion
            )
        }
        return handleApplicationEditResult(result)
    }

    @discardableResult
    func applyProfileEdit(
        draft: LaunchProfile,
        baseline: LaunchProfile,
        applicationID: UUID,
        baselineVersion: LibraryVersionToken
    ) -> Bool {
        guard
            let application = applications.first(where: {
                $0.id == applicationID
            }),
            let latest = application.profiles.first(where: {
                $0.id == baseline.id
            }),
            let currentVersion = libraryVersionToken
        else {
            errorMessage = String(
                localized:
                    "The profile no longer exists. Your draft was kept."
            )
            return false
        }
        let session = LaunchProfileEditSession(
            applicationID: applicationID,
            profile: baseline,
            libraryVersion: baselineVersion
        )
        session.draft = LaunchProfileEditDraft(profile: draft)
        let result = session.apply(
            to: latest,
            in: applicationID,
            libraryVersion: currentVersion
        ) { [self] merged, expectedVersion in
            try persistProfileEdit(
                merged,
                applicationID: applicationID,
                expectedVersion: expectedVersion
            )
        }
        return handleProfileEditResult(result)
    }

    var pendingImportConflictMessage: String? {
        guard let conflict = pendingImportConflict else { return nil }
        let importedName: String
        if let profileID = conflict.importedProfileID {
            importedName = pendingLibraryImport?.applications
                .flatMap(\.profiles)
                .first { $0.id == profileID }?.name
                ?? String(localized: "Imported profile")
        } else {
            importedName = pendingLibraryImport?.applications
                .first { $0.id == conflict.importedApplicationID }?
                .displayName
                ?? String(localized: "Imported application")
        }
        return String(
            localized:
                "“\(importedName)” conflicts with existing library content. Choose how to resolve this exact item."
        )
    }

    var pendingImportConflictTargets: [LibraryImportConflictTarget] {
        guard let conflict = pendingImportConflict else { return [] }
        if conflict.scope == .application {
            return conflict.existingApplicationIDs.compactMap {
                applicationID in
                guard
                    let application = applications.first(where: {
                        $0.id == applicationID
                    })
                else { return nil }
                return LibraryImportConflictTarget(
                    applicationID: applicationID,
                    profileID: nil,
                    label: application.displayName
                )
            }
        }
        return conflict.existingProfileIDs.compactMap { profileID in
            for application in applications {
                if let profile = application.profiles.first(where: {
                    $0.id == profileID
                }) {
                    return LibraryImportConflictTarget(
                        applicationID: application.id,
                        profileID: profileID,
                        label:
                            "\(application.displayName) / \(profile.name)"
                    )
                }
            }
            return nil
        }
    }

    var canUndoLastImportReplacement: Bool {
        lastImportReplacement != nil
    }

    private var importReplacementCoordinator:
        LibraryImportReplacementCoordinator?
    {
        guard let repository, let backupStore else { return nil }
        return LibraryImportReplacementCoordinator(
            repository: repository,
            backupStore: backupStore,
            validator: importValidator
        )
    }

    var selectedApplication: ManagedApplication? {
        guard let selectedApplicationID else { return nil }
        return applications.first { $0.id == selectedApplicationID }
    }

    var selectedProfile: LaunchProfile? {
        guard
            let application = selectedApplication,
            let selectedProfileID
        else {
            return nil
        }

        return application.profiles.first { $0.id == selectedProfileID }
    }

    func isProfileActive(
        _ application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        profileActivityRegistry.isStorageActive(
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
    }

    private func canMutateProfile(
        _ application: ManagedApplication,
        profile: LaunchProfile,
        allowActiveDataOverride: Bool
    ) -> Bool {
        guard
            allowActiveDataOverride
                || !isProfileActive(application, profile: profile)
        else {
            errorMessage = String(
                localized:
                    "This profile is launching or running. Close it before changing its data, or use the exact expert override and accept the corruption risk."
            )
            return false
        }
        return true
    }

    func requestClearProfileData(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) {
        requestDestructiveAction(
            .clearProfileData,
            application: application,
            profile: profile
        )
    }

    func requestProfileRemoval(
        for application: ManagedApplication,
        profile: LaunchProfile,
        dataRemoval: ProfileDataRemoval
    ) {
        let operation: DestructiveActionOperation = switch dataRemoval {
        case .keep:
            .removeProfile
        case .archive:
            .archiveProfileData
        case .delete:
            .deleteProfileData
        }
        requestDestructiveAction(
            operation,
            application: application,
            profile: profile
        )
    }

    func requestProfileDuplication(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) {
        requestDestructiveAction(
            .duplicateProfileData,
            application: application,
            profile: profile
        )
    }

    func confirmDestructiveAction() {
        authorizeAndExecutePendingDestructiveAction(
            expertOverride: nil
        )
    }

    func confirmDestructiveExpertOverride() {
        guard let request = pendingDestructiveActionRequest else {
            isShowingDestructiveExpertOverride = false
            return
        }
        let override = request.makeExpertOverrideAuthorization(
            acknowledging:
                .profileDataCorruptionAndProcessInstability
        )
        authorizeAndExecutePendingDestructiveAction(
            expertOverride: override
        )
    }

    func cancelDestructiveAction() {
        pendingDestructiveActionRequest = nil
        isShowingDestructiveActionConfirmation = false
        isShowingDestructiveExpertOverride = false
    }

    private func requestDestructiveAction(
        _ operation: DestructiveActionOperation,
        application: ManagedApplication,
        profile: LaunchProfile
    ) {
        guard
            let libraryVersionToken,
            let currentApplication = applications.first(where: {
                $0.id == application.id
                    && $0.storageID == application.storageID
            }),
            let currentProfile =
                currentApplication.profiles.first(where: {
                    $0.id == profile.id
                        && $0.storageID == profile.storageID
                })
        else {
            errorMessage = String(
                localized:
                    "The destructive action target no longer exists."
            )
            return
        }
        do {
            let root = try managedPaths(
                for: currentApplication,
                profile: currentProfile
            ).profileRoot.url
            let canonical = try fileSystem.canonicalURL(for: root)
            let identity = try? fileSystem.attributesOfItem(
                at: canonical
            ).identity
            let request = DestructiveActionRequest(
                requestID: UUID(),
                sceneID: sceneID,
                operation: operation,
                applicationID: currentApplication.id,
                applicationStorageID:
                    currentApplication.storageID,
                profileID: currentProfile.id,
                profileStorageID: currentProfile.storageID,
                applicationName:
                    currentApplication.displayName,
                profileName: currentProfile.name,
                path: DestructiveActionPathSnapshot(
                    canonicalURL: canonical,
                    fileIdentity: identity
                ),
                configurationRevision:
                    libraryVersionToken.revision.rawValue,
                libraryVersion: libraryVersionToken
            )
            pendingDestructiveActionRequest = request
            isShowingDestructiveActionConfirmation = true
            isShowingDestructiveExpertOverride = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authorizeAndExecutePendingDestructiveAction(
        expertOverride:
            DestructiveActionExpertOverrideAuthorization?
    ) {
        guard let request = pendingDestructiveActionRequest else {
            cancelDestructiveAction()
            return
        }
        do {
            let current = try currentDestructiveTarget(for: request)
            let active = profileActivityRegistry.isStorageActive(
                applicationStorageID: request.applicationStorageID,
                profileStorageID: request.profileStorageID
            )
            let authorization = try request.authorizeExecution(
                currentTarget: current,
                activity: DestructiveActionActivitySnapshot(
                    identity: request.activityIdentity,
                    state: active ? .active : .inactive
                ),
                expertOverride: expertOverride
            )
            isShowingDestructiveActionConfirmation = false
            isShowingDestructiveExpertOverride = false
            try executeDestructiveAction(authorization)
            pendingDestructiveActionRequest = nil
        } catch let error as DestructiveActionRequestError
            where error.code == .activeProfileData
                && expertOverride == nil
        {
            isShowingDestructiveActionConfirmation = false
            isShowingDestructiveExpertOverride = true
        } catch {
            cancelDestructiveAction()
            errorMessage = error.localizedDescription
        }
    }

    private func currentDestructiveTarget(
        for request: DestructiveActionRequest
    ) throws -> DestructiveActionCurrentTarget? {
        guard
            let libraryVersionToken,
            let application = applications.first(where: {
                $0.id == request.applicationID
                    && $0.storageID
                        == request.applicationStorageID
            }),
            let profile = application.profiles.first(where: {
                $0.id == request.profileID
                    && $0.storageID == request.profileStorageID
            })
        else {
            return nil
        }
        let root = try managedPaths(
            for: application,
            profile: profile
        ).profileRoot.url
        let canonical = try fileSystem.canonicalURL(for: root)
        let identity = try? fileSystem.attributesOfItem(
            at: canonical
        ).identity
        return DestructiveActionCurrentTarget(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            path: DestructiveActionPathSnapshot(
                canonicalURL: canonical,
                fileIdentity: identity
            ),
            configurationRevision:
                libraryVersionToken.revision.rawValue,
            libraryVersion: libraryVersionToken
        )
    }

    private func executeDestructiveAction(
        _ authorization: DestructiveActionExecutionAuthorization
    ) throws {
        guard
            let application = applications.first(where: {
                $0.id == authorization.applicationID
                    && $0.storageID
                        == authorization.applicationStorageID
            }),
            let profile = application.profiles.first(where: {
                $0.id == authorization.profileID
                    && $0.storageID
                        == authorization.profileStorageID
            })
        else {
            throw DestructiveActionRequestError(.targetRemoved)
        }
        selectedApplicationID = application.id
        selectedProfileID = profile.id
        let allowOverride = authorization.usedExpertOverride
        let succeeded: Bool = switch authorization.operation {
        case .clearProfileData:
            clearProfileData(
                for: application,
                profile: profile,
                allowActiveDataOverride: allowOverride
            )
        case .duplicateProfileData:
            duplicateSelectedProfile(
                allowActiveDataOverride: allowOverride
            )
        case .removeProfile:
            remove(
                profile: profile,
                dataRemoval: .keep,
                allowActiveDataOverride: allowOverride
            )
        case .archiveProfileData:
            remove(
                profile: profile,
                dataRemoval: .archive,
                allowActiveDataOverride: allowOverride
            )
        case .deleteProfileData:
            remove(
                profile: profile,
                dataRemoval: .delete,
                allowActiveDataOverride: allowOverride
            )
        case .relocateProfileData:
            false
        }
        if !succeeded {
            throw LibraryEditPersistenceFailure(
                message: errorMessage
                    ?? String(
                        localized:
                            "The destructive action did not complete."
                    )
            )
        }
    }

    func beginAddingApplication() {
        isShowingAppImporter = true
    }

    func applicationNeedsRelink(
        _ application: ManagedApplication
    ) -> Bool {
        !fileSystem.fileExists(
            at: URL(
                fileURLWithPath: application.appPath,
                isDirectory: true
            )
        )
    }

    func assessApplicationRelink(
        _ application: ManagedApplication,
        candidateURL: URL
    ) {
        guard canMutateLibrary() else { return }
        guard let baselineVersion = libraryVersionToken else {
            errorMessage = String(
                localized:
                    "Application relink is unavailable until the library is loaded."
            )
            return
        }
        let request = ApplicationRelinkRequest(
            targetApplication: application,
            candidateURL: candidateURL,
            otherApplications: applications
        )
        let coordinator = ApplicationRelinkCoordinator(
            fileSystem: fileSystem
        )
        Task { [weak self] in
            let assessment = await coordinator.assess(request)
            guard let self else { return }
            guard
                libraryVersionToken == baselineVersion,
                applications.first(where: {
                    $0.id == application.id
                }) == application
            else {
                errorMessage = String(
                    localized:
                        "The application changed while its new location was being verified. Try again."
                )
                return
            }
            guard let proposal = assessment.proposal else {
                let conflictNames = assessment.conflicts
                    .map(\.applicationName)
                    .joined(separator: ", ")
                errorMessage = conflictNames.isEmpty
                    ? String(
                        localized:
                            "The selected application cannot repair this record because its bundle identity or path did not match."
                    )
                    : String(
                        localized:
                            "The selected application conflicts with existing record(s): \(conflictNames). No application was changed."
                    )
                return
            }
            pendingApplicationRelink = PendingApplicationRelink(
                proposal: proposal,
                baselineVersion: baselineVersion
            )
            isShowingApplicationRelinkConfirmation = true
        }
    }

    func cancelApplicationRelink() {
        pendingApplicationRelink = nil
        isShowingApplicationRelinkConfirmation = false
    }

    func confirmApplicationRelink() {
        guard let pendingApplicationRelink else {
            cancelApplicationRelink()
            return
        }
        let proposal = pendingApplicationRelink.proposal
        guard applyApplicationEdit(
            draft: proposal.application,
            baseline: proposal.originalApplication,
            baselineVersion:
                pendingApplicationRelink.baselineVersion
        ) else {
            isShowingApplicationRelinkConfirmation = false
            self.pendingApplicationRelink = nil
            return
        }
        selectedApplicationID = proposal.application.id
        launchStatusMessage = String(
            localized:
                "Updated the application location for \(proposal.application.displayName)."
        )
        cancelApplicationRelink()
    }

    func storagePath(for application: ManagedApplication) -> String {
        configuredBaseRoot(for: application)
    }

    func prepareStorageRelocation(
        for application: ManagedApplication,
        to destinationBaseRoot: URL
    ) {
        guard canMutateLibrary() else { return }
        guard
            let storageRelocationCoordinator,
            let libraryVersionToken
        else {
            errorMessage = String(
                localized: "Storage relocation is unavailable because its transaction services could not be initialized."
            )
            return
        }

        do {
            storageRelocationPreview = try storageRelocationCoordinator.prepare(
                application: application,
                destinationBaseRoot: destinationBaseRoot.path,
                expectedVersion: libraryVersionToken
            )
            storageRelocationProgress = nil
        } catch {
            storageRelocationPreview = nil
            storageRelocationProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelStorageRelocation(_ preview: StorageRelocationPreview) {
        guard storageRelocationPreview?.requestID == preview.requestID else {
            return
        }
        if let storageRelocationCancellation {
            storageRelocationCancellation.cancel()
            return
        }
        storageRelocationPreview = nil
        storageRelocationProgress = nil
    }

    func beginStorageRelocation(_ preview: StorageRelocationPreview) {
        guard !isStorageRelocationRunning else { return }
        guard canMutateLibrary() else { return }
        guard
            storageRelocationPreview?.requestID == preview.requestID,
            let storageRelocationCoordinator,
            let repository,
            let libraryVersionToken,
            libraryVersionToken == preview.expectedVersion,
            let applicationIndex = applications.firstIndex(where: {
                $0.id == preview.applicationID
            })
        else {
            errorMessage = String(
                localized: "The storage relocation preview is stale. Review the destination again."
            )
            return
        }

        var candidate = applications
        candidate[applicationIndex] = preview.relocatedApplication
        let prepared: PreparedLibraryCommit
        do {
            prepared = try repository.prepare(
                candidate,
                expectedVersion: libraryVersionToken
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let cancellation = StorageRelocationCancellation()
        storageRelocationCancellation = cancellation
        storageRelocationProgress = .preparing
        errorMessage = nil
        storageRelocationTask = Task { [weak self] in
            let result = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    let outcome = try storageRelocationCoordinator.execute(
                        preview,
                        preparedCommit: prepared,
                        repository: repository,
                        cancellation: cancellation
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard
                                self?.storageRelocationPreview?.requestID
                                    == preview.requestID,
                                self?.storageRelocationCancellation
                                    === cancellation
                            else { return }
                            self?.storageRelocationProgress = progress
                        }
                    }
                    return BackgroundStorageRelocationResult
                        .succeeded(outcome)
                } catch {
                    return BackgroundStorageRelocationResult.failed(
                        code: (error as? StorageRelocationError)?.code,
                        message: error.localizedDescription
                    )
                }
            }.value

            guard let self else { return }
            self.storageRelocationTask = nil
            self.storageRelocationCancellation = nil
            switch result {
            case let .succeeded(outcome):
                self.applications = candidate
                self.applications[applicationIndex] = outcome.application
                self.libraryVersionToken = outcome.versionToken
                self.selectedApplicationID = outcome.application.id
                if !outcome.application.profiles.contains(where: {
                    $0.id == self.selectedProfileID
                }) {
                    self.selectedProfileID =
                        outcome.application.profiles.first?.id
                }
                self.storageRelocationPreview = nil
                self.storageRelocationProgress = .completed
                self.publishLibraryChange()
                self.launchStatusMessage = String(
                    localized: "Moved managed storage for \(outcome.application.displayName)."
                )
            case let .failed(code, message):
                self.finishFailedStorageRelocation(
                    preview,
                    code: code,
                    operationMessage: message,
                    coordinator: storageRelocationCoordinator,
                    repository: repository
                )
            }
        }
    }

    @discardableResult
    func confirmStorageRelocation(
        _ preview: StorageRelocationPreview
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard
            storageRelocationPreview?.requestID == preview.requestID,
            let storageRelocationCoordinator,
            let repository,
            let libraryVersionToken,
            libraryVersionToken == preview.expectedVersion,
            let applicationIndex = applications.firstIndex(where: {
                $0.id == preview.applicationID
            })
        else {
            errorMessage = String(
                localized: "The storage relocation preview is stale. Review the destination again."
            )
            return false
        }

        var candidate = applications
        candidate[applicationIndex] = preview.relocatedApplication

        do {
            let prepared = try repository.prepare(
                candidate,
                expectedVersion: libraryVersionToken
            )
            let outcome = try storageRelocationCoordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: repository
            ) { [weak self] progress in
                self?.storageRelocationProgress = progress
            }
            applications = candidate
            applications[applicationIndex] = outcome.application
            self.libraryVersionToken = outcome.versionToken
            selectedApplicationID = outcome.application.id
            if !outcome.application.profiles.contains(where: {
                $0.id == selectedProfileID
            }) {
                selectedProfileID = outcome.application.profiles.first?.id
            }
            storageRelocationPreview = nil
            storageRelocationProgress = .completed
            publishLibraryChange()
            launchStatusMessage = String(
                localized: "Moved managed storage for \(outcome.application.displayName)."
            )
            return true
        } catch {
            let operationError = error
            errorMessage = operationError.localizedDescription
            storageRelocationProgress = nil
            let recoveryOutcomes: [StorageRelocationRecoveryOutcome]
            do {
                recoveryOutcomes =
                    try storageRelocationCoordinator.recoverAll(
                        repository: repository
                    )
                guard
                    try storageRelocationCoordinator
                        .pendingRelocations()
                        .isEmpty
                else {
                    throw StorageRelocationError(.rollbackRequired)
                }
            } catch {
                let recoveryError = error
                let originalBytes: Data? = switch repository.load() {
                case let .loaded(snapshot):
                    snapshot.originalBytes
                case let .recoveryRequired(failure),
                     let .readOnly(failure):
                    failure.originalBytes
                case let .migrationRequired(snapshot):
                    snapshot.originalBytes
                case .missing:
                    nil
                }
                errorMessage = String(
                    localized: "\(operationError.localizedDescription) Recovery could not finish: \(recoveryError.localizedDescription)"
                )
                loadState = .recoveryRequired(
                    originalBytes: originalBytes,
                    message: errorMessage
                        ?? recoveryError.localizedDescription
                )
                return false
            }
            switch repository.load() {
            case let .loaded(snapshot):
                applications = snapshot.applications
                self.libraryVersionToken = snapshot.versionToken
                selectedApplicationID = applications.contains {
                    $0.id == preview.applicationID
                } ? preview.applicationID : applications.first?.id
                selectedProfileID = applications.first(where: {
                    $0.id == selectedApplicationID
                })?.profiles.first?.id
                loadState = .loaded
                if recoveryOutcomes.contains(where: {
                    if case let .committed(outcome) = $0 {
                        outcome.transactionID == preview.requestID
                    } else {
                        false
                    }
                }) {
                    storageRelocationPreview = nil
                    publishLibraryChange()
                    launchStatusMessage = String(
                        localized: "Recovered and completed the storage move."
                    )
                    return true
                }
            case let .recoveryRequired(failure),
                 let .readOnly(failure):
                loadState = .recoveryRequired(
                    originalBytes: failure.originalBytes,
                    message: operationError.localizedDescription
                )
            case .missing, .migrationRequired:
                loadState = .recoveryRequired(
                    originalBytes: nil,
                    message: operationError.localizedDescription
                )
            }
            return false
        }
    }

    private func finishFailedStorageRelocation(
        _ preview: StorageRelocationPreview,
        code: StorageRelocationError.Code?,
        operationMessage: String,
        coordinator: StorageRelocationCoordinator,
        repository: any LibraryRepositoryPersisting
    ) {
        errorMessage = operationMessage
        storageRelocationProgress = nil
        let recoveryOutcomes: [StorageRelocationRecoveryOutcome]
        do {
            recoveryOutcomes = try coordinator.recoverAll(
                repository: repository
            )
            guard try coordinator.pendingRelocations().isEmpty else {
                throw StorageRelocationError(.rollbackRequired)
            }
        } catch {
            let recoveryError = error
            let originalBytes: Data? = switch repository.load() {
            case let .loaded(snapshot):
                snapshot.originalBytes
            case let .recoveryRequired(failure),
                 let .readOnly(failure):
                failure.originalBytes
            case let .migrationRequired(snapshot):
                snapshot.originalBytes
            case .missing:
                nil
            }
            errorMessage = String(
                localized: "\(operationMessage) Recovery could not finish: \(recoveryError.localizedDescription)"
            )
            loadState = .recoveryRequired(
                originalBytes: originalBytes,
                message: errorMessage ?? recoveryError.localizedDescription
            )
            return
        }

        switch repository.load() {
        case let .loaded(snapshot):
            applications = snapshot.applications
            libraryVersionToken = snapshot.versionToken
            selectedApplicationID = applications.contains {
                $0.id == preview.applicationID
            } ? preview.applicationID : applications.first?.id
            selectedProfileID = applications.first(where: {
                $0.id == selectedApplicationID
            })?.profiles.first?.id
            loadState = .loaded
            if recoveryOutcomes.contains(where: {
                if case let .committed(outcome) = $0 {
                    outcome.transactionID == preview.requestID
                } else {
                    false
                }
            }) {
                storageRelocationPreview = nil
                errorMessage = nil
                publishLibraryChange()
                launchStatusMessage = String(
                    localized: "Recovered and completed the storage move."
                )
            } else if code == .cancelled {
                errorMessage = nil
                launchStatusMessage = String(
                    localized: "Storage relocation was cancelled. Managed data remains at its original location."
                )
            }
        case let .recoveryRequired(failure),
             let .readOnly(failure):
            loadState = .recoveryRequired(
                originalBytes: failure.originalBytes,
                message: operationMessage
            )
        case .missing, .migrationRequired:
            loadState = .recoveryRequired(
                originalBytes: nil,
                message: operationMessage
            )
        }
    }

    func addApplication(at url: URL) {
        guard canMutateLibrary() else { return }
        guard url.pathExtension == "app" else {
            errorMessage = String(localized: "The selected item is not an application bundle.")
            return
        }

        guard fileSystem.fileExists(at: url), isDirectory(at: url) else {
            errorMessage = String(localized: "The selected application could not be found.")
            return
        }

        let appURL: URL
        do {
            appURL = try fileSystem.canonicalURL(for: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let bundle = Bundle(url: appURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent

        if let existingIndex = applications.firstIndex(where: {
            normalizedApplicationPath($0.appPath)
                == normalizedApplicationPath(appURL.path)
        }) {
            selectedApplicationID = applications[existingIndex].id
            selectedProfileID = applications[existingIndex].profiles.first?.id
            launchStatusMessage = String(localized: "\(displayName) is already in the library.")
            return
        }

        if let bundleIdentifier = bundle?.bundleIdentifier,
           let existing = applications.first(where: {
               $0.bundleIdentifier == bundleIdentifier
           })
        {
            if applicationNeedsRelink(existing) {
                assessApplicationRelink(
                    existing,
                    candidateURL: appURL
                )
            } else {
                errorMessage = String(
                    localized:
                        "Another stored application uses bundle identifier \(bundleIdentifier) at \(existing.appPath). Parallax did not merge the installations."
                )
            }
            return
        }

        let trimmedDefaultBase = settings.defaultBaseStoragePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBasePath = trimmedDefaultBase.isEmpty ? nil : trimmedDefaultBase
        var app = ManagedApplication(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            appPath: appURL.path,
            preset: .automatic,
            baseStoragePath: resolvedBasePath,
            profiles: []
        )
        do {
            app.profiles = [try defaultProfile(for: app)]
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        var candidate = applications
        candidate.append(app)
        _ = commit(
            candidate,
            selectedApplicationID: app.id,
            selectedProfileID: app.profiles.first?.id
        )
    }

    func removeSelectedApplication() {
        guard let application = selectedApplication else { return }
        beginApplicationRemoval(application)
    }

    func beginApplicationRemoval(
        _ application: ManagedApplication,
        dataChoice: ApplicationRemovalDataChoice = .keep
    ) {
        guard canMutateLibrary() else { return }
        do {
            pendingApplicationRemoval =
                try makeApplicationRemovalRequest(
                    application,
                    dataChoice: dataChoice
                )
            isShowingApplicationRemovalConfirmation = true
        } catch {
            pendingApplicationRemoval = nil
            isShowingApplicationRemovalConfirmation = false
            errorMessage = error.localizedDescription
        }
    }

    func updatePendingApplicationRemovalChoice(
        _ dataChoice: ApplicationRemovalDataChoice
    ) {
        guard
            let pendingApplicationRemoval,
            let application = applications.first(where: {
                $0.id == pendingApplicationRemoval.applicationID
                    && $0.storageID
                        == pendingApplicationRemoval
                            .applicationStorageID
            })
        else {
            cancelApplicationRemoval()
            return
        }
        beginApplicationRemoval(
            application,
            dataChoice: dataChoice
        )
    }

    func cancelApplicationRemoval() {
        pendingApplicationRemoval = nil
        isShowingApplicationRemovalConfirmation = false
    }

    func confirmApplicationRemoval() {
        guard
            let request = pendingApplicationRemoval,
            let repository,
            let backupStore,
            let applicationRemovalTransactions
        else {
            cancelApplicationRemoval()
            errorMessage = String(
                localized:
                    "Application removal is unavailable because its transaction or backup services could not be initialized."
            )
            return
        }

        do {
            let currentTarget = try currentApplicationRemovalTarget(
                for: request
            )
            let activity = ApplicationRemovalActivitySnapshot(
                profiles: request.profiles.map { profile in
                    ApplicationRemovalProfileActivity(
                        applicationID: request.applicationID,
                        applicationStorageID:
                            request.applicationStorageID,
                        profileID: profile.profileID,
                        profileStorageID:
                            profile.profileStorageID,
                        state: profileActivityRegistry
                            .isStorageActive(
                                applicationStorageID:
                                    request
                                        .applicationStorageID,
                                profileStorageID:
                                    profile.profileStorageID
                            ) ? .active : .inactive
                    )
                }
            )
            guard
                case .loaded(let snapshot) = repository.load(),
                snapshot.versionToken == request.repositoryVersion
            else {
                throw ApplicationRemovalRequestError(
                    .staleRepositoryVersion
                )
            }
            let backupArtifact = try applicationRemovalBackupHook?(
                snapshot.originalBytes
            ) ?? backupStore.createBackup(
                of: snapshot.originalBytes,
                reason: .destructiveRewrite
            )
            let priorBackup = try request.acceptPriorBackup(
                backupArtifact
            )
            let execution = try request.authorizeExecution(
                currentTarget: currentTarget,
                activity: activity,
                priorBackup: priorBackup
            )
            let candidate = applications.filter {
                !(
                    $0.id == request.applicationID
                        && $0.storageID
                            == request.applicationStorageID
                )
            }
            let prepared = try repository.prepare(
                candidate,
                expectedVersion: request.repositoryVersion
            )
            let outcome = try applicationRemovalTransactions.execute(
                ApplicationRemovalTransactionRequest(
                    transactionID: UUID(),
                    executionAuthorization: execution,
                    profiles: request.profiles
                ),
                preparedCommit: prepared,
                repository: repository
            )
            guard
                outcome.completion == .committed,
                case .loaded(let updated) = repository.load()
            else {
                throw ApplicationRemovalRequestError(
                    .managedDataActionFailed
                )
            }
            applications = updated.applications
            libraryVersionToken = updated.versionToken
            selectedApplicationID = applications.first?.id
            selectedProfileID =
                applications.first?.profiles.first?.id
            loadState = .loaded
            publishLibraryChange()
            errorMessage = nil
            launchStatusMessage = switch outcome.dataChoice {
            case .keep:
                String(
                    localized:
                        "Removed \(request.applicationName) and kept its managed profile data."
                )
            case .archive:
                String(
                    localized:
                        "Archived managed profile data and removed \(request.applicationName)."
                )
            case .delete:
                String(
                    localized:
                        "Deleted managed profile data and removed \(request.applicationName)."
                )
            }
            cancelApplicationRemoval()
        } catch {
            pendingApplicationRemoval = nil
            isShowingApplicationRemovalConfirmation = false
            errorMessage = error.localizedDescription
        }
    }

    private func makeApplicationRemovalRequest(
        _ application: ManagedApplication,
        dataChoice: ApplicationRemovalDataChoice
    ) throws -> ApplicationRemovalRequest {
        guard
            let libraryVersionToken,
            applications.contains(where: {
                $0.id == application.id
                    && $0.storageID == application.storageID
                    && $0 == application
            })
        else {
            throw ApplicationRemovalRequestError(
                .targetRemoved
            )
        }
        return try ApplicationRemovalRequest(
            requestID: UUID(),
            sceneID: sceneID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            applicationName: application.displayName,
            profiles: try applicationRemovalProfileTargets(
                application
            ),
            dataChoice: dataChoice,
            repositoryVersion: libraryVersionToken
        )
    }

    private func currentApplicationRemovalTarget(
        for request: ApplicationRemovalRequest
    ) throws -> ApplicationRemovalCurrentTarget? {
        guard
            let libraryVersionToken,
            let application = applications.first(where: {
                $0.id == request.applicationID
                    && $0.storageID
                        == request.applicationStorageID
            })
        else {
            return nil
        }
        return ApplicationRemovalCurrentTarget(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            applicationName: application.displayName,
            profiles: try applicationRemovalProfileTargets(
                application
            ),
            repositoryVersion: libraryVersionToken
        )
    }

    private func applicationRemovalProfileTargets(
        _ application: ManagedApplication
    ) throws -> [ApplicationRemovalProfileTarget] {
        try application.profiles.map { profile in
            let paths = try managedPaths(
                for: application,
                profile: profile
            )
            let root = paths.profileRoot.url
            let canonical = fileSystem.fileExists(at: root)
                ? try fileSystem.canonicalURL(for: root)
                : root.standardizedFileURL
            let identity = fileSystem.fileExists(at: canonical)
                ? try fileSystem.attributesOfItem(
                    at: canonical
                ).identity
                : nil
            var externalPaths:
                [ApplicationRemovalExternalPath] = []
            if profile.isolationOwnership.userData
                != .generated,
               let path = userDataPath(
                    for: application,
                    profile: profile
               ),
               path != paths.userData.url.path
            {
                externalPaths.append(
                    ApplicationRemovalExternalPath(
                        role: .userData,
                        declaredPath: path
                    )
                )
            }
            if profile.isolationOwnership.codexHome
                != .generated,
               let path = codexHomePath(
                    for: application,
                    profile: profile
               ),
               path != paths.codexHome.url.path
            {
                externalPaths.append(
                    ApplicationRemovalExternalPath(
                        role: .codexHome,
                        declaredPath: path
                    )
                )
            }
            return ApplicationRemovalProfileTarget(
                profileID: profile.id,
                profileStorageID: profile.storageID,
                profileName: profile.name,
                managedProfileRoot:
                    DestructiveActionPathSnapshot(
                        canonicalURL: canonical,
                        fileIdentity: identity
                    ),
                externalPaths: externalPaths
            )
        }
    }

    func addProfile() {
        addProfile(named: Self.nextProfileName(for: selectedApplication, templates: profileTemplateNames))
    }

    func addProfile(named name: String) {
        guard canMutateLibrary() else { return }
        guard let index = selectedApplicationIndex else { return }
        let template = profileTemplates.first { $0.name == name }
        addProfile(
            named: name,
            template: template,
            applicationIndex: index
        )
    }

    func addProfile(templateID: ProfileTemplate.ID) {
        guard canMutateLibrary() else { return }
        guard
            let index = selectedApplicationIndex,
            let template = profileTemplates.first(where: {
                $0.id == templateID
            })
        else {
            errorMessage = String(
                localized:
                    "The selected profile template no longer exists."
            )
            return
        }
        addProfile(
            named: template.name,
            template: template,
            applicationIndex: index
        )
    }

    private func addProfile(
        named name: String,
        template: ProfileTemplate?,
        applicationIndex index: Int
    ) {
        let profileName = Self.uniqueProfileName(
            basedOn: name,
            existingProfiles: applications[index].profiles
        )
        let profile: LaunchProfile
        do {
            profile = try self.profile(
                named: profileName,
                template: template,
                for: applications[index]
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var candidate = applications
        candidate[index].profiles.append(profile)
        _ = commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: profile.id
        )
    }

    @discardableResult
    func duplicateSelectedProfile() -> Bool {
        duplicateSelectedProfile(allowActiveDataOverride: false)
    }

    @discardableResult
    private func duplicateSelectedProfile(
        allowActiveDataOverride: Bool
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard
            let appIndex = selectedApplicationIndex,
            let profile = selectedProfile
        else { return false }
        guard canMutateProfile(
            applications[appIndex],
            profile: profile,
            allowActiveDataOverride: allowActiveDataOverride
        ) else {
            return false
        }
        let copyName = Self.uniqueProfileName(
            basedOn: String(localized: "\(profile.name) Copy"),
            existingProfiles: applications[appIndex].profiles
        )
        var copy = profile.duplicatedWithFreshIdentity(name: copyName)
        do {
            copy = try applyingRecommendedSettings(
                to: copy,
                for: applications[appIndex],
                replacingExistingIsolation: true
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        var candidate = applications
        candidate[appIndex].profiles.append(copy)
        if profileDataTransactions != nil,
           repository != nil,
           libraryVersionToken != nil {
            guard let outcome = executeProfileDataTransaction(
                operation: .duplicate,
                application: applications[appIndex],
                sourceProfile: profile,
                destinationProfile: copy,
                candidate: candidate,
                selectedProfileID: copy.id,
                externalDataHandling: externalDataHandling(for: profile)
            ) else {
                return false
            }
            let hasExternalConfiguration: Bool
            if case .configurationOnly = outcome.externalDataHandling {
                hasExternalConfiguration = true
            } else {
                hasExternalConfiguration = false
            }
            switch (outcome.dataMutation, hasExternalConfiguration) {
            case (.copiedManagedData, true):
                launchStatusMessage = String(
                    localized: "Copied managed profile data to \(copy.name). Explicit external data locations were not copied."
                )
            case (.copiedManagedData, false):
                launchStatusMessage = String(
                    localized: "Copied managed profile data to \(copy.name)."
                )
            case (.noManagedData, true):
                launchStatusMessage = String(
                    localized: "Duplicated the configuration as \(copy.name). No managed data existed to copy, and explicit external data locations were not copied."
                )
            case (.noManagedData, false):
                launchStatusMessage = String(
                    localized: "Duplicated the configuration as \(copy.name). No managed data existed to copy."
                )
            default:
                launchStatusMessage = String(
                    localized: "Duplicated the profile configuration as \(copy.name)."
                )
            }
            return true
        }

        guard duplicateProfileData(
            from: profile,
            to: copy,
            application: applications[appIndex],
            allowActiveDataOverride: allowActiveDataOverride
        ) else { return false }
        guard commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: copy.id
        ) else {
            if let destinationPaths = try? managedPaths(
                for: applications[appIndex],
                profile: copy
            ), fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
                let persistenceError = errorMessage
                    ?? String(localized: "The library could not be saved.")
                errorMessage = String(
                    localized: "\(persistenceError) Copied data was preserved because its ownership could not be reverified; recovery is required at \(destinationPaths.profileRoot.url.path)."
                )
                loadState = .recoveryRequired(
                    originalBytes: nil,
                    message: errorMessage ?? persistenceError
                )
            }
            launchStatusMessage = nil
            return false
        }
        return true
    }

    @discardableResult
    func removeSelectedProfile(dataRemoval: ProfileDataRemoval = .keep) -> Bool {
        guard
            let selectedProfile = selectedProfile
        else { return false }

        return remove(profile: selectedProfile, dataRemoval: dataRemoval)
    }

    @discardableResult
    func remove(profile: LaunchProfile, dataRemoval: ProfileDataRemoval) -> Bool {
        remove(
            profile: profile,
            dataRemoval: dataRemoval,
            allowActiveDataOverride: false
        )
    }

    @discardableResult
    private func remove(
        profile: LaunchProfile,
        dataRemoval: ProfileDataRemoval,
        allowActiveDataOverride: Bool
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return false }

        let application = applications[appIndex]
        let profileToRemove = applications[appIndex].profiles[profileIndex]
        guard canMutateProfile(
            application,
            profile: profileToRemove,
            allowActiveDataOverride: allowActiveDataOverride
        ) else {
            return false
        }
        pendingProfileRemovalRecovery = nil
        var archivedMove: (
            source: ManagedProfileRootPath,
            destination: ManagedArchiveEntryPath
        )?
        errorMessage = nil
        launchStatusMessage = nil

        var candidate = applications
        candidate[appIndex].profiles.remove(at: profileIndex)
        let candidateSelectedProfileID = candidate[appIndex].profiles.first?.id
        if dataRemoval != .keep,
           profileDataTransactions != nil,
           repository != nil,
           libraryVersionToken != nil {
            let operation: ProfileDataTransactionOperation = switch dataRemoval {
            case .archive:
                .archive
            case .delete:
                .delete
            case .keep:
                preconditionFailure("Metadata-only removal is not a data transaction")
            }
            guard executeProfileDataTransaction(
                operation: operation,
                application: application,
                sourceProfile: profileToRemove,
                destinationProfile: nil,
                candidate: candidate,
                selectedProfileID: candidateSelectedProfileID,
                externalDataHandling: .notConfigured
            ) != nil else {
                recoverProfileDataTransactionsAfterRemovalFailure()
                prepareRemoveEntryAnywayRecovery(
                    application: application,
                    profile: profileToRemove
                )
                return false
            }
            launchStatusMessage = dataRemoval == .archive
                ? String(localized: "Archived data for \(profileToRemove.name)")
                : String(localized: "Deleted data for \(profileToRemove.name)")
            return true
        }

        do {
            switch dataRemoval {
            case .keep:
                break
            case .archive:
                let source = try managedPaths(
                    for: application,
                    profile: profileToRemove
                ).profileRoot
                if let destination = try archiveProfileData(
                    for: application,
                    profile: profileToRemove
                ) {
                    archivedMove = (source, destination)
                }
            case .delete:
                let source = try managedPaths(
                    for: application,
                    profile: profileToRemove
                ).profileRoot
                if let destination = try archiveProfileData(
                    for: application,
                    profile: profileToRemove
                ) {
                    archivedMove = (source, destination)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            prepareRemoveEntryAnywayRecovery(
                application: application,
                profile: profileToRemove
            )
            return false
        }

        guard commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: candidateSelectedProfileID,
            backupReason: dataRemoval == .keep
                ? .destructiveRewrite
                : nil
        ) else {
            if let archivedMove {
                do {
                    try moveManagedItem(
                        at: archivedMove.destination,
                        to: archivedMove.source
                    )
                } catch {
                    let persistenceError = errorMessage ?? String(localized: "The library could not be saved.")
                    errorMessage = String(
                        localized: "\(persistenceError) The archived profile data could not be restored: \(error.localizedDescription)"
                    )
                }
            }
            return false
        }

        switch dataRemoval {
        case .keep:
            break
        case .archive:
            launchStatusMessage = String(localized: "Archived data for \(profileToRemove.name)")
        case .delete:
            if let archivedMove {
                do {
                    try removeManagedItem(at: archivedMove.destination)
                } catch {
                    errorMessage = String(
                        localized: "The profile entry was removed, but its transaction-owned data requires recovery at \(archivedMove.destination.url.path): \(error.localizedDescription)"
                    )
                    loadState = .recoveryRequired(
                        originalBytes: nil,
                        message: errorMessage ?? error.localizedDescription
                    )
                    return false
                }
            }
            launchStatusMessage = String(localized: "Deleted data for \(profileToRemove.name)")
        }
        return true
    }

    func dismissProfileRemovalRecovery() {
        pendingProfileRemovalRecovery = nil
    }

    @discardableResult
    func removeEntryAnyway(
        _ recovery: ProfileRemovalRecovery
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard
            pendingProfileRemovalRecovery == recovery,
            libraryVersionToken == recovery.expectedVersion,
            let appIndex = applications.firstIndex(where: {
                $0.id == recovery.applicationID
                    && $0.storageID == recovery.applicationStorageID
            }),
            let profileIndex = applications[appIndex].profiles
                .firstIndex(where: {
                    $0.id == recovery.profileID
                        && $0.storageID == recovery.profileStorageID
                })
        else {
            pendingProfileRemovalRecovery = nil
            errorMessage = String(
                localized: "The failed profile removal is stale. Review the current profile and data location before trying again."
            )
            return false
        }

        var candidate = applications
        let profile = candidate[appIndex].profiles.remove(
            at: profileIndex
        )
        let nextProfileID = candidate[appIndex].profiles.first?.id
        guard commit(
            candidate,
            selectedApplicationID: recovery.applicationID,
            selectedProfileID: nextProfileID,
            backupReason: .destructiveRewrite
        ) else {
            return false
        }
        pendingProfileRemovalRecovery = nil
        errorMessage = nil
        launchStatusMessage = String(
            localized: "Removed \(profile.name) from the library. Its remaining data was kept at \(recovery.canonicalRemainingDataPath)."
        )
        return true
    }

    private func prepareRemoveEntryAnywayRecovery(
        application: ManagedApplication,
        profile: LaunchProfile
    ) {
        guard
            case .loaded = loadState,
            let libraryVersionToken,
            applications.contains(where: { currentApplication in
                currentApplication.id == application.id
                    && currentApplication.storageID
                        == application.storageID
                    && currentApplication.profiles.contains(where: {
                        $0.id == profile.id
                            && $0.storageID == profile.storageID
                    })
            }),
            let path = try? managedPaths(
                for: application,
                profile: profile
            ).profileRoot.url.path
        else {
            return
        }
        pendingProfileRemovalRecovery = ProfileRemovalRecovery(
            profileName: profile.name,
            canonicalRemainingDataPath: path,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            expectedVersion: libraryVersionToken
        )
    }

    private func recoverProfileDataTransactionsAfterRemovalFailure() {
        guard
            let profileDataTransactions,
            let repository
        else { return }
        let operationMessage = errorMessage
        let priorApplicationID = selectedApplicationID
        let priorProfileID = selectedProfileID
        do {
            for transaction in try profileDataTransactions
                .pendingTransactions() {
                _ = try profileDataTransactions.recover(
                    transactionID: transaction.transactionID,
                    repository: repository
                )
            }
            guard case let .loaded(snapshot) = repository.load() else {
                return
            }
            applications = snapshot.applications
            libraryVersionToken = snapshot.versionToken
            selectedApplicationID = applications.contains {
                $0.id == priorApplicationID
            } ? priorApplicationID : applications.first?.id
            selectedProfileID = applications.first(where: {
                $0.id == selectedApplicationID
            })?.profiles.contains(where: {
                $0.id == priorProfileID
            }) == true
                ? priorProfileID
                : applications.first(where: {
                    $0.id == selectedApplicationID
                })?.profiles.first?.id
            loadState = .loaded
            errorMessage = operationMessage
            publishLibraryChange()
        } catch {
            let recoveryMessage = String(
                localized: "\(operationMessage ?? "Profile removal failed.") Recovery could not finish: \(error.localizedDescription)"
            )
            errorMessage = recoveryMessage
            let originalBytes: Data? = switch repository.load() {
            case let .loaded(snapshot):
                snapshot.originalBytes
            case let .recoveryRequired(failure),
                 let .readOnly(failure):
                failure.originalBytes
            case let .migrationRequired(snapshot):
                snapshot.originalBytes
            case .missing:
                nil
            }
            loadState = .recoveryRequired(
                originalBytes: originalBytes,
                message: recoveryMessage
            )
        }
    }

    func updateApplication(_ application: ManagedApplication) {
        guard canMutateLibrary() else { return }
        guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
        let persisted = applications[index]
        var updated = application.preservingIdentity(of: persisted)
        // Ordinary metadata edits never imply storage relocation.
        updated.baseStoragePath = persisted.baseStoragePath
        let invalidatesImportedApproval =
            updated.appPath != persisted.appPath
            || updated.bundleIdentifier
                != persisted.bundleIdentifier
            || updated.baseStoragePath != persisted.baseStoragePath
        var consumedPersistedProfileIDs = Set<LaunchProfile.ID>()
        updated.profiles = updated.profiles.map { proposed in
            guard
                let persistedProfile = persisted.profiles.first(where: { $0.id == proposed.id }),
                consumedPersistedProfileIDs.insert(persistedProfile.id).inserted
            else {
                return proposed.duplicatedWithFreshIdentity()
            }
            var preserved = proposed.preservingIdentity(
                of: persistedProfile
            )
            if invalidatesImportedApproval,
               preserved.launchConfigurationTrust.isImported
            {
                preserved.markLaunchConfigurationImported()
            }
            return preserved
        }
        var candidate = applications
        candidate[index] = updated
        _ = commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: selectedProfileID
        )
    }

    func updateProfile(_ profile: LaunchProfile) {
        guard canMutateLibrary() else { return }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        let persisted = applications[appIndex].profiles[profileIndex]
        var updated = profile.preservingIdentity(of: persisted)
        if Self.userDataDirectoryConfiguration(
            in: updated.argumentsText
        ) != Self.userDataDirectoryConfiguration(
            in: persisted.argumentsText
        ) {
            updated.isolationOwnership.userData = .explicit
        }
        if Self.environmentConfiguration(
            "CODEX_HOME",
            in: updated.environmentText
        ) != Self.environmentConfiguration(
            "CODEX_HOME",
            in: persisted.environmentText
        ) {
            updated.isolationOwnership.codexHome = .explicit
        }
        var candidate = applications
        candidate[appIndex].profiles[profileIndex] = updated
        _ = commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: selectedProfileID
        )
    }

    func launchSelectedProfile() {
        guard
            let application = selectedApplication,
            let profile = selectedProfile
        else { return }
        launch(profile, application: application)
    }

    func launch(_ profile: LaunchProfile) {
        guard let application = applicationForLaunch(profile) else { return }
        launch(profile, application: application)
    }

    private func launch(_ profile: LaunchProfile, application: ManagedApplication) {
        beginLaunch(
            profile,
            application: application,
            requireGlobalConfirmation: true
        )
    }

    private func beginLaunch(
        _ profile: LaunchProfile,
        application: ManagedApplication,
        requireGlobalConfirmation: Bool
    ) {
        if profile.launchConfigurationTrust.isImported {
            assessImportedLaunch(
                application: application,
                profile: profile,
                requireGlobalConfirmation:
                    requireGlobalConfirmation
            )
            return
        }
        if requireGlobalConfirmation && settings.confirmBeforeLaunch {
            let source = launchConfigurationSource(
                application: application,
                profile: profile,
                requestID: UUID()
            )
            submitLaunchConfirmation(
                application: application,
                profile: profile,
                source: source,
                fingerprint:
                    LaunchConfigurationCompiler
                        .configurationFingerprint(for: source)
            )
            return
        }
        performLaunch(application: application, profile: profile)
    }

    func confirmLaunch() {
        guard
            let request =
                launchRequests.pendingConfirmation(in: sceneID)
        else { return }
        isShowingLaunchConfirmation = false
        let target = currentLaunchTarget(for: request)
        switch launchRequests.confirm(
            sceneID: sceneID,
            requestID: request.requestID,
            currentTarget: target
        ) {
        case .confirmed(let confirmed):
            guard
                let application = applications.first(where: {
                    $0.id == confirmed.applicationID
                }),
                let profile = application.profiles.first(where: {
                    $0.id == confirmed.profileID
                })
            else {
                errorMessage = String(
                    localized:
                        "The confirmed launch target was removed. Choose a profile and try again."
                )
                return
            }
            performLaunch(
                application: application,
                profile: profile,
                preparedSource:
                    confirmed.configurationSnapshot
            )
        case .invalidated(_, let reason):
            errorMessage = reason.message
        case .notPending:
            errorMessage = String(
                localized:
                    "This launch confirmation is no longer pending."
            )
        }
    }

    func cancelLaunch() {
        if let request =
            launchRequests.pendingConfirmation(in: sceneID)
        {
            _ = launchRequests.cancelConfirmation(
                sceneID: sceneID,
                requestID: request.requestID
            )
        }
        isShowingLaunchConfirmation = false
    }

    private func assessImportedLaunch(
        application: ManagedApplication,
        profile: LaunchProfile,
        requireGlobalConfirmation: Bool
    ) {
        let requestID = UUID()
        let source = launchConfigurationSource(
            application: application,
            profile: profile,
            requestID: requestID
        )
        let compiler = launchConfigurationCompiler
        let trust = importedLaunchTrust
        importedLaunchAssessmentTasks[requestID] = Task {
            let analysis = await compiler.analyze(source)
            guard !Task.isCancelled else { return }
            guard
                let currentApplication = applications.first(where: {
                    $0.id == application.id
                        && $0.storageID == application.storageID
                }),
                let currentProfile =
                    currentApplication.profiles.first(where: {
                        $0.id == profile.id
                            && $0.storageID == profile.storageID
                    }),
                currentApplication == application,
                currentProfile == profile
            else {
                errorMessage = String(
                    localized:
                        "The launch configuration changed while it was being inspected. Try again."
                )
                importedLaunchAssessmentTasks[requestID] = nil
                return
            }
            let trustSource = importedLaunchTrustSource(
                application: application,
                profile: profile,
                analysis: analysis
            )
            switch trust.assessment(
                for: profile,
                source: trustSource
            ) {
            case .trustedLocal:
                beginLaunch(
                    profile,
                    application: application,
                    requireGlobalConfirmation:
                        requireGlobalConfirmation
                )
            case .approved:
                if requireGlobalConfirmation
                    && settings.confirmBeforeLaunch
                {
                    submitLaunchConfirmation(
                        application: application,
                        profile: profile,
                        source: source,
                        fingerprint:
                            analysis.configurationFingerprint
                    )
                } else {
                    performLaunch(
                        application: application,
                        profile: profile,
                        preparedSource: source
                    )
                }
            case .reviewRequired(let review):
                pendingImportedLaunch = PendingImportedLaunch(
                    applicationID: application.id,
                    profileID: profile.id,
                    review: review
                )
                pendingImportedLaunchReview = review
                isShowingImportedLaunchReview = true
            }
            importedLaunchAssessmentTasks[requestID] = nil
        }
    }

    func confirmImportedLaunchReview() {
        guard let pending = pendingImportedLaunch else { return }
        guard
            let application = applications.first(where: {
                $0.id == pending.applicationID
            }),
            let profile = application.profiles.first(where: {
                $0.id == pending.profileID
            })
        else {
            cancelImportedLaunchReview()
            return
        }
        let requestID = UUID()
        let source = launchConfigurationSource(
            application: application,
            profile: profile,
            requestID: requestID
        )
        let compiler = launchConfigurationCompiler
        let trust = importedLaunchTrust
        importedLaunchAssessmentTasks[requestID] = Task {
            let analysis = await compiler.analyze(source)
            guard !Task.isCancelled else { return }
            guard
                let currentApplication = applications.first(where: {
                    $0.id == application.id
                }),
                let currentProfile =
                    currentApplication.profiles.first(where: {
                        $0.id == profile.id
                    }),
                currentApplication == application,
                currentProfile == profile,
                pendingImportedLaunch?.review.fingerprint
                    == pending.review.fingerprint
            else {
                errorMessage = String(
                    localized:
                        "The imported launch configuration changed after review. Review it again."
                )
                cancelImportedLaunchReview()
                importedLaunchAssessmentTasks[requestID] = nil
                return
            }
            do {
                let currentTrustSource =
                    importedLaunchTrustSource(
                        application: application,
                        profile: profile,
                        analysis: analysis
                    )
                let approval = try trust.approval(
                    for: pending.review,
                    currentSource: currentTrustSource
                )
                guard
                    let appIndex = applications.firstIndex(where: {
                        $0.id == application.id
                    }),
                    let profileIndex = applications[appIndex]
                        .profiles.firstIndex(where: {
                            $0.id == profile.id
                        })
                else {
                    throw ImportedLaunchTrustError
                        .configurationChangedAfterReview
                }
                var candidate = applications
                candidate[appIndex].profiles[profileIndex]
                    .approveImportedLaunch(using: approval)
                guard commit(
                    candidate,
                    selectedApplicationID: application.id,
                    selectedProfileID: profile.id
                ) else {
                    importedLaunchAssessmentTasks[requestID] = nil
                    return
                }
                let approvedApplication = candidate[appIndex]
                let approvedProfile =
                    approvedApplication.profiles[profileIndex]
                cancelImportedLaunchReview()
                performLaunch(
                    application: approvedApplication,
                    profile: approvedProfile,
                    preparedSource: source
                )
            } catch {
                errorMessage = error.localizedDescription
                cancelImportedLaunchReview()
            }
            importedLaunchAssessmentTasks[requestID] = nil
        }
    }

    func cancelImportedLaunchReview() {
        pendingImportedLaunch = nil
        pendingImportedLaunchReview = nil
        isShowingImportedLaunchReview = false
    }

    private func launchConfigurationSource(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID
    ) -> LaunchConfigurationSource {
        LaunchConfigurationSource(
            requestID: requestID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            configurationRevision:
                libraryVersionToken?.revision.rawValue ?? 0,
            applicationURL: URL(fileURLWithPath: application.appPath),
            expectedBundleIdentifier: application.bundleIdentifier,
            configuredBaseRoot: configuredBaseRoot(for: application),
            argumentsText: profile.argumentsText,
            environmentText: profile.environmentText,
            isolationOwnership: profile.isolationOwnership,
            childEnvironmentPolicy: profile.childEnvironmentPolicy,
            sensitiveEnvironmentKeys: profile.sensitiveEnvironmentKeys,
            peerProfiles: application.profiles.compactMap { peer in
                guard peer.id != profile.id else { return nil }
                return LaunchPeerProfileSource(
                    profileID: peer.id,
                    profileStorageID: peer.storageID,
                    argumentsText: peer.argumentsText,
                    environmentText: peer.environmentText,
                    isolationOwnership: peer.isolationOwnership
                )
            }
        )
    }

    private func importedLaunchTrustSource(
        application: ManagedApplication,
        profile: LaunchProfile,
        analysis: LaunchAnalysis
    ) -> ImportedLaunchTrustSource {
        var isolationPaths: [ImportedLaunchIsolationPath] = []
        if let userData = analysis.isolation.userData {
            isolationPaths.append(
                ImportedLaunchIsolationPath(
                    role: .userData,
                    authority:
                        userData.isManaged ? .managed : .external,
                    canonicalURL: userData.url
                )
            )
        }
        if let codexHome = analysis.isolation.codexHome {
            isolationPaths.append(
                ImportedLaunchIsolationPath(
                    role: .codexHome,
                    authority:
                        codexHome.isManaged ? .managed : .external,
                    canonicalURL: codexHome.url
                )
            )
        }
        return ImportedLaunchTrustSource(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            applicationDisplayName: application.displayName,
            canonicalApplicationURL:
                analysis.applicationHealth.canonicalApplicationURL
                ?? URL(fileURLWithPath: application.appPath)
                    .standardizedFileURL,
            expectedBundleIdentifier: application.bundleIdentifier,
            verifiedBundleIdentifier:
                analysis.applicationHealth.bundleIdentifier,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            profileName: profile.name,
            configuredBaseRoot: configuredBaseRoot(for: application),
            argumentsText: profile.argumentsText,
            environmentText: profile.environmentText,
            isolationOwnership: profile.isolationOwnership,
            childEnvironmentPolicy: profile.childEnvironmentPolicy,
            sensitiveEnvironmentKeys:
                profile.sensitiveEnvironmentKeys,
            isolationPaths: isolationPaths
        )
    }

    private func performLaunch(
        application: ManagedApplication,
        profile: LaunchProfile,
        preparedSource: LaunchConfigurationSource? = nil
    ) {
        let applicationID = application.id
        let profileID = profile.id
        let profileName = profile.name
        let requestID = preparedSource?.requestID ?? UUID()
        let source = preparedSource
            ?? launchConfigurationSource(
                application: application,
                profile: profile,
                requestID: requestID
            )
        guard registerDirectLaunchIfNeeded(
            application: application,
            profile: profile,
            source: source
        ) else { return }
        _ = launchRequests.updateStatus(
            requestID: requestID,
            state: .launching
        )
        selectedApplicationID = applicationID
        selectedProfileID = profile.id
        launchStatusMessage = nil
        AppLog.launch.info("Launching profile \(profileName) for \(application.displayName)")

        if profile.launchConfigurationTrust.isImported,
           !(launcher is any PreparedApplicationLaunching)
        {
            let message = String(
                localized:
                    "Imported launch configurations require validated launch preparation."
            )
            _ = launchRequests.updateStatus(
                requestID: requestID,
                state: .failed(message)
            )
            return
        }

        if launcher is any PreparedApplicationLaunching {
            schedulePreparedLaunch(
                source,
                profileName: profileName,
                override: nil,
                concurrentLaunchPolicy: .deny
            )
            return
        }

        do {
            if let trackedLauncher = launcher as? any TrackedApplicationLaunching {
                _ = try trackedLauncher.launchTracked(
                    application: application,
                    profile: profile,
                    requestID: requestID,
                    activityRegistry: profileActivityRegistry,
                    concurrentLaunchPolicy: .deny,
                    lifecycleHandler: { [weak self] lifecycle in
                        Task { @MainActor in
                            self?.handleLaunchLifecycle(
                                lifecycle,
                                profileName: profileName
                            )
                        }
                    }
                ) { event in
                    switch event {
                    case .requested, .running, .terminated:
                        break
                    case let .failed(_, message):
                        AppLog.launch.error(
                            "Failed to launch \(profileName): \(message)"
                        )
                    }
                }
                return
            }
            try launcher.launch(application: application, profile: profile) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        _ = self?.launchRequests.updateStatus(
                            requestID: requestID,
                            state: .running
                        )
                        self?.recordAcceptedLaunch(
                            applicationID: applicationID,
                            profileID: profileID,
                            profileName: profileName
                        )
                    case .failure(let error):
                        _ = self?.launchRequests.updateStatus(
                            requestID: requestID,
                            state: .failed(error.localizedDescription)
                        )
                        AppLog.launch.error("Failed to launch \(profileName): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            AppLog.launch.error("Launch threw for \(profileName): \(error.localizedDescription)")
            _ = launchRequests.updateStatus(
                requestID: requestID,
                state: .failed(error.localizedDescription)
            )
        }
    }

    func confirmLaunchDiagnosticOverride() {
        guard let pending = pendingLaunchDiagnosticRequest else {
            isShowingLaunchDiagnosticOverride = false
            return
        }
        pendingLaunchDiagnosticRequest = nil
        isShowingLaunchDiagnosticOverride = false
        schedulePreparedLaunch(
            pending.source,
            profileName: pending.profileName,
            override: LaunchDiagnosticOverride(
                requestID: pending.source.requestID,
                configurationFingerprint: pending.fingerprint
            ),
            concurrentLaunchPolicy: .deny
        )
    }

    func cancelLaunchDiagnosticOverride() {
        if let requestID =
            pendingLaunchDiagnosticRequest?.source.requestID
        {
            _ = launchRequests.updateStatus(
                requestID: requestID,
                state: .cancelled
            )
        }
        pendingLaunchDiagnosticRequest = nil
        isShowingLaunchDiagnosticOverride = false
    }

    func confirmConcurrentLaunchOverride() {
        guard let pending = pendingConcurrentLaunchRequest else {
            isShowingConcurrentLaunchOverride = false
            return
        }
        pendingConcurrentLaunchRequest = nil
        isShowingConcurrentLaunchOverride = false
        schedulePreparedLaunch(
            pending.source,
            profileName: pending.profileName,
            override: LaunchDiagnosticOverride(
                requestID: pending.source.requestID,
                configurationFingerprint: pending.fingerprint,
                allowsActiveProfileRisk: true
            ),
            concurrentLaunchPolicy: .expertOverride(
                ConcurrentProfileLaunchRiskAcknowledgement(
                    acknowledgesProfileDataCorruptionRisk: true
                )
            )
        )
    }

    func cancelConcurrentLaunchOverride() {
        if let requestID =
            pendingConcurrentLaunchRequest?.source.requestID
        {
            _ = launchRequests.updateStatus(
                requestID: requestID,
                state: .cancelled
            )
        }
        pendingConcurrentLaunchRequest = nil
        isShowingConcurrentLaunchOverride = false
    }

    private func schedulePreparedLaunch(
        _ source: LaunchConfigurationSource,
        profileName: String,
        override: LaunchDiagnosticOverride?,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy
    ) {
        let compiler = launchConfigurationCompiler
        launchPreparationTasks[source.requestID]?.cancel()
        launchPreparationTasks[source.requestID] = Task { [weak self] in
            do {
                let prepared = try await compiler.prepare(
                    source,
                    override: override
                )
                try Task.checkCancellation()
                guard let self else { return }
                try self.openPreparedLaunch(
                    prepared,
                    profileName: profileName,
                    concurrentLaunchPolicy:
                        concurrentLaunchPolicy
                )
            } catch is CancellationError {
                _ = self?.launchRequests.updateStatus(
                    requestID: source.requestID,
                    state: .cancelled
                )
            } catch let LaunchPreparationError.blocked(diagnostics)
                where override == nil
                    && diagnostics.allSatisfy({
                        $0.code == .profileHealth(.profileActive)
                    })
            {
                let analysis = await compiler.analyze(source)
                guard !Task.isCancelled else { return }
                self?.pendingConcurrentLaunchRequest =
                    PendingConcurrentLaunchRequest(
                        source: source,
                        profileName: profileName,
                        fingerprint:
                            analysis.configurationFingerprint
                    )
                self?.isShowingConcurrentLaunchOverride = true
            } catch let LaunchPreparationError.blocked(diagnostics)
                where override == nil
                    && diagnostics.allSatisfy(\.isOverridable)
            {
                let analysis = await compiler.analyze(source)
                guard !Task.isCancelled else { return }
                self?.pendingLaunchDiagnosticRequest =
                    PendingLaunchDiagnosticRequest(
                        source: source,
                        profileName: profileName,
                        fingerprint:
                            analysis.configurationFingerprint,
                        diagnostics: diagnostics
                    )
                self?.isShowingLaunchDiagnosticOverride = true
            } catch {
                _ = self?.launchRequests.updateStatus(
                    requestID: source.requestID,
                    state: .failed(error.localizedDescription)
                )
                AppLog.launch.error(
                    "Launch preparation failed for \(profileName): \(error.localizedDescription)"
                )
            }
            self?.launchPreparationTasks[source.requestID] = nil
        }
    }

    private func openPreparedLaunch(
        _ prepared: PreparedLaunch,
        profileName: String,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy
    ) throws {
        let applicationID = prepared.applicationID
        let profileID = prepared.profileID
        if let trackedLauncher =
            launcher as? any PreparedTrackedApplicationLaunching
        {
            _ = try trackedLauncher.launchTracked(
                prepared: prepared,
                activityRegistry: profileActivityRegistry,
                concurrentLaunchPolicy: concurrentLaunchPolicy,
                lifecycleHandler: { [weak self] lifecycle in
                    Task { @MainActor in
                        self?.handleLaunchLifecycle(
                            lifecycle,
                            profileName: profileName
                        )
                    }
                }
            ) { event in
                Task { @MainActor in
                    switch event {
                    case .requested, .running, .terminated:
                        break
                    case let .failed(_, message):
                        AppLog.launch.error(
                            "Failed to launch \(profileName): \(message)"
                        )
                    }
                }
            }
            return
        }
        guard
            let preparedLauncher =
                launcher as? any PreparedApplicationLaunching
        else {
            throw LaunchError.preparationRequired
        }
        try preparedLauncher.launch(prepared: prepared) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    _ = self?.launchRequests.updateStatus(
                        requestID: prepared.requestID,
                        state: .running
                    )
                    self?.recordAcceptedLaunch(
                        applicationID: applicationID,
                        profileID: profileID,
                        profileName: profileName
                    )
                case .failure(let error):
                    _ = self?.launchRequests.updateStatus(
                        requestID: prepared.requestID,
                        state: .failed(error.localizedDescription)
                    )
                    AppLog.launch.error(
                        "Failed to launch \(profileName): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func registerDirectLaunchIfNeeded(
        application: ManagedApplication,
        profile: LaunchProfile,
        source: LaunchConfigurationSource
    ) -> Bool {
        if launchRequests.status(for: source.requestID) != nil {
            return true
        }
        let fingerprint =
            LaunchConfigurationCompiler.configurationFingerprint(
                for: source
            )
        let request = ImmutableLaunchRequest(
            sceneID: sceneID,
            applicationName: application.displayName,
            profileName: profile.name,
            configurationSnapshot: source,
            configurationFingerprint: fingerprint
        )
        switch launchRequests.submit(request, policy: .rejectNew) {
        case .awaitingConfirmation:
            let resolution = launchRequests.confirm(
                sceneID: sceneID,
                requestID: request.requestID,
                currentTarget: .available(
                    applicationID: application.id,
                    profileID: profile.id,
                    configurationRevision:
                        source.configurationRevision,
                    configurationFingerprint: fingerprint
                )
            )
            if case .confirmed = resolution {
                return true
            }
            return false
        case .queued:
            return false
        case .rejected:
            return false
        }
    }

    private func handleLaunchLifecycle(
        _ lifecycle: ProfileLaunchLifecycleSnapshot,
        profileName: String
    ) {
        guard
            let application = applications.first(where: {
                $0.id == lifecycle.identity.applicationID
                    && $0.storageID
                        == lifecycle.identity.applicationStorageID
            }),
            let profile = application.profiles.first(where: {
                $0.id == lifecycle.identity.profileID
                    && $0.storageID
                        == lifecycle.identity.profileStorageID
            }),
            lifecycle.matches(
                application: application,
                profile: profile
            )
        else {
            return
        }

        switch lifecycle.state {
        case .requested, .launching:
            _ = launchRequests.updateStatus(
                requestID: lifecycle.requestID,
                state: .launching
            )
        case .running:
            let changed = launchRequests.updateStatus(
                requestID: lifecycle.requestID,
                state: .running
            )
            if changed {
                recordAcceptedLaunch(
                    applicationID: application.id,
                    profileID: profile.id,
                    profileName: profileName
                )
            }
        case .terminating:
            break
        case .terminated:
            _ = launchRequests.updateStatus(
                requestID: lifecycle.requestID,
                state: .terminated
            )
        case .failed(let message):
            _ = launchRequests.updateStatus(
                requestID: lifecycle.requestID,
                state: .failed(message)
            )
        }
    }

    func launchStatusMessage(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> String? {
        guard
            let status = launchRequests.visibleStatus(
                sceneID: sceneID,
                profileID: profile.id
            ),
            status.applicationID == application.id
        else {
            return nil
        }
        switch status.state {
        case .queuedForConfirmation:
            return String(localized: "Launch queued")
        case .awaitingConfirmation:
            return String(localized: "Awaiting launch confirmation")
        case .confirmed, .launching:
            return String(localized: "Launching \(profile.name)…")
        case .running:
            return String(localized: "\(profile.name) is running")
        case .terminated:
            return String(localized: "\(profile.name) exited")
        case .cancelled:
            return String(localized: "Launch cancelled")
        case .failed(let message):
            return String(localized: "Launch failed: \(message)")
        case .invalidated(let reason):
            return reason.message
        case .rejected(let reason):
            return reason.message
        }
    }

    private func recordAcceptedLaunch(
        applicationID: ManagedApplication.ID,
        profileID: LaunchProfile.ID,
        profileName: String
    ) {
        let now = Date()
        if let appIndex = applications.firstIndex(where: {
            $0.id == applicationID
        }),
           let profileIndex = applications[appIndex].profiles.firstIndex(where: {
               $0.id == profileID
           }) {
            var candidate = applications
            candidate[appIndex].profiles[profileIndex].lastLaunchedAt = now
            guard commit(
                candidate,
                selectedApplicationID: selectedApplicationID,
                selectedProfileID: selectedProfileID
            ) else {
                return
            }
        }
        AppLog.launch.info("Successfully launched \(profileName)")
    }

    func dismissLibraryOperationStatus() {
        libraryOperationStatusMessage = nil
    }

    func compatibilityLabel(for application: ManagedApplication) -> String {
        Self.resolvedPreset(for: application).label
    }

    func compatibilityDetail(for application: ManagedApplication) -> String {
        let preset = Self.resolvedPreset(for: application)

        if preset.needsCodexHome {
            return String(localized: "Uses CODEX_HOME and --user-data-dir for separate account state.")
        }

        if preset.supportsUserDataDir {
            return String(localized: "Uses --user-data-dir when the app honors Chromium launch flags.")
        }

        return String(localized: "Profile isolation depends on this app's own launch arguments.")
    }

    func warnings(for application: ManagedApplication, profile: LaunchProfile) -> [String] {
        var warnings: [String] = []
        let preset = Self.resolvedPreset(for: application)

        if preset.needsCodexHome, !hasCodexHomeConfigured(in: profile) {
            warnings.append(String(localized: "Codex profiles need CODEX_HOME to avoid sharing the signed-in account."))
        }

        if preset.supportsUserDataDir,
           !hasUserDataDirectoryConfigured(in: profile) {
            warnings.append(String(localized: "This app may share browser state unless --user-data-dir is set."))
        }

        let parsedArguments = LaunchArgumentParser.parse(
            profile.argumentsText
        )
        let optionDiagnostics = UserDataDirectoryOptionResolver.resolve(
            in: parsedArguments.tokens
        ).diagnostics
        let environmentDiagnostics = LaunchEnvironmentParser.parse(
            profile.environmentText
        ).diagnostics
        warnings.append(
            contentsOf: (
                parsedArguments.diagnostics
                    + optionDiagnostics
                    + environmentDiagnostics
            ).map(\.message)
        )
        if profile.childEnvironmentPolicy == .inheritProcessEnvironment {
            warnings.append(
                String(
                    localized:
                        "Advanced environment inheritance can expose Parallax process variables to the launched application."
                )
            )
        }
        if profile.launchConfigurationTrust == .importedPendingReview {
            warnings.append(
                String(
                    localized:
                        "Review this imported launch configuration before using it."
                )
            )
        }
        return Array(Set(warnings)).sorted()
    }

    func hasCodexHomeConfigured(in profile: LaunchProfile) -> Bool {
        Self.environmentValue("CODEX_HOME", in: profile) != nil
    }

    func hasUserDataDirectoryConfigured(in profile: LaunchProfile) -> Bool {
        Self.userDataDirectoryArgumentValue(in: profile) != nil
    }

    func healthItems(for application: ManagedApplication, profile: LaunchProfile) -> [(label: String, isHealthy: Bool)] {
        let key = HealthCacheKey(
            application: application,
            profileID: profile.id
        )
        if let cached = healthItemsCache[key] {
            return cached
        }
        if healthInspectionTasks[key] == nil {
            let source = healthInspectionSource(
                for: application,
                profile: profile
            )
            let service = launchHealthService
            healthInspectionTasks[key] = Task { [weak self] in
                let items = await Task.detached {
                    Self.inspectHealth(source, service: service)
                }.value
                guard let self else { return }
                self.healthItemsCache = self.healthItemsCache.filter {
                    $0.key.application.id != application.id
                        || $0.key.profileID != profile.id
                }
                self.healthItemsCache[key] = items
                self.healthInspectionTasks[key] = nil
            }
        }
        return [
            (
                String(localized: "Health inspection"),
                false
            )
        ]
    }

    @discardableResult
    func refreshHealthItems(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) async -> [(label: String, isHealthy: Bool)] {
        let key = HealthCacheKey(
            application: application,
            profileID: profile.id
        )
        let source = healthInspectionSource(
            for: application,
            profile: profile
        )
        let service = launchHealthService
        let items = await Task.detached {
            Self.inspectHealth(source, service: service)
        }.value
        healthItemsCache[key] = items
        return items
    }

    nonisolated private static func inspectHealth(
        _ source: HealthInspectionSource,
        service: LaunchHealthService
    ) -> [(label: String, isHealthy: Bool)] {
        let preset = source.preset
        let applicationReport = service.inspectApplication(
            source.applicationInput
        )
        let profileReport = service.inspectProfiles(
            source.profileInputs
        ).first { $0.profileID == source.profile.id }
        var items: [(label: String, isHealthy: Bool)] = [
            (
                String(localized: "Application bundle"),
                applicationReport.isHealthy
            ),
            (
                String(localized: "Profile folder"),
                profileReport?.paths.first {
                    $0.role == .managedProfileRoot
                }.map(Self.isHealthyPath) ?? false
            )
        ]

        if preset.supportsUserDataDir {
            let hasUserDataDir =
                userDataDirectoryArgumentValue(in: source.profile) != nil
            items.append((String(localized: "User data flag"), hasUserDataDir))
            items.append((
                String(localized: "User data folder"),
                hasUserDataDir && (
                    profileReport?.paths.first {
                        $0.role == .managedUserData
                            || $0.role == .externalUserData
                    }.map(Self.isHealthyPath) ?? false
                )
            ))
        }

        if preset.needsCodexHome {
            let hasCodexHome =
                environmentValue("CODEX_HOME", in: source.profile) != nil
            items.append(("CODEX_HOME", hasCodexHome))
            items.append((
                String(localized: "Codex home folder"),
                hasCodexHome && (
                    profileReport?.paths.first {
                        $0.role == .managedCodexHome
                            || $0.role == .externalCodexHome
                    }.map(Self.isHealthyPath) ?? false
                )
            ))
        }
        items.append((
            String(localized: "Storage inactive"),
            profileReport?.isActive == false
        ))
        items.append((
            String(localized: "No storage collisions"),
            profileReport?.issues.contains {
                $0.code == .canonicalPathCollision
                    || $0.code == .fileIdentityCollision
            } == false
        ))

        return items
    }

    func resolvedArguments(for profile: LaunchProfile) -> [String] {
        let parsed = LaunchArgumentParser.parse(profile.argumentsText)
        var arguments = parsed.words
        let resolution = UserDataDirectoryOptionResolver.resolve(
            in: parsed.tokens
        )
        guard let configured = resolution.resolvedValue else {
            return arguments
        }
        let expanded = PathSpecificTildeExpander(
            homeDirectory:
                FileManager.default.homeDirectoryForCurrentUser.path
        ).argumentValue(configured, forOption: "--user-data-dir")
        for index in arguments.indices {
            if arguments[index].hasPrefix("--user-data-dir=") {
                arguments[index] = "--user-data-dir=\(expanded)"
                return arguments
            }
            if arguments[index] == "--user-data-dir",
               arguments.indices.contains(index + 1)
            {
                arguments[index + 1] = expanded
                return arguments
            }
        }
        return arguments
    }

    func resolvedEnvironment(for profile: LaunchProfile) -> [(key: String, value: String)] {
        let entries = LaunchEnvironmentParser.parse(
            profile.environmentText
        ).entries
        var effective: [String: (index: Int, value: String?)] = [:]
        for (index, entry) in entries.enumerated() {
            switch entry.operation {
            case .set(let value):
                effective[entry.name] = (index, value)
            case .unset:
                effective[entry.name] = (index, nil)
            }
        }
        let expander = PathSpecificTildeExpander(
            homeDirectory:
                FileManager.default.homeDirectoryForCurrentUser.path
        )
        return effective
            .compactMap { key, indexed -> (key: String, value: String, index: Int)? in
                guard let value = indexed.value else { return nil }
                return (
                    key,
                    expander.environmentValue(value, forKey: key),
                    indexed.index
                )
            }
            .sorted { $0.index < $1.index }
            .map { (key: $0.key, value: $0.value) }
    }

    func profileFolderPath(for application: ManagedApplication, profile: LaunchProfile) -> String {
        do {
            return try managedPaths(for: application, profile: profile).profileRoot.url.path
        } catch {
            errorMessage = error.localizedDescription
            return ""
        }
    }

    func profileFolderDisplayPath(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> String {
        ManagedPathResolver.profileRootURL(
            baseRootURL: URL(
                fileURLWithPath: configuredBaseRoot(for: application),
                isDirectory: true
            ),
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        ).path
    }

    func shouldShowCodexHomeActions(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        Self.resolvedPreset(for: application).needsCodexHome
            && (
                profile.isolationOwnership.codexHome == .generated
                    || Self.environmentValue(
                        "CODEX_HOME",
                        in: profile
                    ) != nil
            )
    }

    func shouldShowUserDataActions(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        Self.resolvedPreset(for: application).supportsUserDataDir
            && (
                profile.isolationOwnership.userData == .generated
                    || Self.userDataDirectoryArgumentValue(
                        in: profile
                    ) != nil
            )
    }

    func managedPaths(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) throws -> ResolvedProfilePaths {
        try pathResolver.resolve(
            configuredBaseRoot: configuredBaseRoot(for: application),
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
    }

    func codexHomePath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).needsCodexHome else { return nil }
        do {
            if let configured = Self.environmentValue("CODEX_HOME", in: profile) {
                let expanded = PathSpecificTildeExpander(
                    homeDirectory:
                        FileManager.default.homeDirectoryForCurrentUser.path
                ).environmentValue(configured, forKey: "CODEX_HOME")
                return try pathResolver.resolveExternalPath(expanded).url.path
            }
            guard profile.isolationOwnership.codexHome == .generated else {
                return nil
            }
            return try managedPaths(
                for: application,
                profile: profile
            ).codexHome.url.path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func userDataPath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).supportsUserDataDir else { return nil }
        do {
            let resolution = Self.userDataDirectoryResolution(
                in: profile.argumentsText
            )
            if let configured = resolution.resolvedValue {
                let expanded = PathSpecificTildeExpander(
                    homeDirectory:
                        FileManager.default.homeDirectoryForCurrentUser.path
                ).argumentValue(
                    configured,
                    forOption: "--user-data-dir"
                )
                return try pathResolver.resolveExternalPath(expanded).url.path
            }
            if !resolution.occurrences.isEmpty {
                errorMessage = resolution.diagnostics
                    .map(\.message)
                    .joined(separator: "\n")
                return nil
            }
            guard profile.isolationOwnership.userData == .generated else {
                return nil
            }
            return try managedPaths(for: application, profile: profile).userData.url.path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func revealProfileFolder(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        do {
            return revealManagedFolder(
                try managedPaths(for: application, profile: profile).profileRoot
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func revealCodexHome(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        do {
            let paths = try managedPaths(for: application, profile: profile)
            if let configured = Self.environmentValue("CODEX_HOME", in: profile) {
                let expanded = PathSpecificTildeExpander(
                    homeDirectory:
                        FileManager.default.homeDirectoryForCurrentUser.path
                ).environmentValue(configured, forKey: "CODEX_HOME")
                let external = try pathResolver.resolveExternalPath(expanded)
                if external.url.path != paths.codexHome.url.path {
                    return revealExternalFolder(external)
                }
            }
            guard profile.isolationOwnership.codexHome == .generated else {
                return false
            }
            return revealManagedFolder(paths.codexHome)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func revealUserData(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        do {
            let paths = try managedPaths(for: application, profile: profile)
            let resolution = Self.userDataDirectoryResolution(
                in: profile.argumentsText
            )
            if let configured = resolution.resolvedValue {
                let expanded = PathSpecificTildeExpander(
                    homeDirectory:
                        FileManager.default.homeDirectoryForCurrentUser.path
                ).argumentValue(
                    configured,
                    forOption: "--user-data-dir"
                )
                let external = try pathResolver.resolveExternalPath(expanded)
                if external.url.path != paths.userData.url.path {
                    return revealExternalFolder(external)
                }
            }
            if !resolution.occurrences.isEmpty {
                errorMessage = resolution.diagnostics
                    .map(\.message)
                    .joined(separator: "\n")
                return false
            }
            guard profile.isolationOwnership.userData == .generated else {
                return false
            }
            return revealManagedFolder(paths.userData)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearProfileData(for application: ManagedApplication, profile: LaunchProfile) -> Bool {
        clearProfileData(
            for: application,
            profile: profile,
            allowActiveDataOverride: false
        )
    }

    @discardableResult
    private func clearProfileData(
        for application: ManagedApplication,
        profile: LaunchProfile,
        allowActiveDataOverride: Bool
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard canMutateProfile(
            application,
            profile: profile,
            allowActiveDataOverride: allowActiveDataOverride
        ) else {
            return false
        }
        errorMessage = nil
        launchStatusMessage = nil

        do {
            if profileDataTransactions != nil,
               repository != nil,
               libraryVersionToken != nil {
                guard let outcome = executeProfileDataTransaction(
                    operation: .clear,
                    application: application,
                    sourceProfile: profile,
                    destinationProfile: nil,
                    candidate: applications,
                    selectedProfileID: selectedProfileID,
                    externalDataHandling: .notConfigured
                ) else {
                    return false
                }
                launchStatusMessage = outcome.dataMutation == .archivedManagedData
                    ? String(localized: "Archived and cleared data for \(profile.name)")
                    : String(localized: "No data exists to clear for \(profile.name)")
                return true
            }

            let paths = try managedPaths(for: application, profile: profile)
            guard fileSystem.fileExists(at: paths.profileRoot.url) else {
                launchStatusMessage = String(
                    localized: "No data exists to clear for \(profile.name)"
                )
                return true
            }
            _ = try moveToArchive(
                source: paths.profileRoot,
                archiveRoot: paths.archiveRoot
            )
            launchStatusMessage = String(localized: "Archived and cleared data for \(profile.name)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func duplicateProfileData(
        from source: LaunchProfile,
        to destination: LaunchProfile,
        application: ManagedApplication
    ) -> Bool {
        duplicateProfileData(
            from: source,
            to: destination,
            application: application,
            allowActiveDataOverride: false
        )
    }

    @discardableResult
    private func duplicateProfileData(
        from source: LaunchProfile,
        to destination: LaunchProfile,
        application: ManagedApplication,
        allowActiveDataOverride: Bool
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        guard canMutateProfile(
            application,
            profile: source,
            allowActiveDataOverride: allowActiveDataOverride
        ) else {
            return false
        }
        errorMessage = nil
        launchStatusMessage = nil

        do {
            let sourcePaths = try managedPaths(for: application, profile: source)
            let destinationPaths = try managedPaths(for: application, profile: destination)
            guard !fileSystem.fileExists(at: destinationPaths.profileRoot.url) else {
                throw ProfileDataTransactionError(
                    .unexpectedDestination,
                    operation: .duplicate,
                    path: destinationPaths.profileRoot.url.path
                )
            }
            if fileSystem.fileExists(at: sourcePaths.profileRoot.url) {
                try copyManagedItem(
                    at: sourcePaths.profileRoot,
                    to: destinationPaths.profileRoot
                )
            } else {
                let destinationURL = try pathResolver.revalidateForMutation(
                    destinationPaths.profileRoot
                )
                try fileSystem.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
            }
            launchStatusMessage = String(localized: "Copied profile data to \(destination.name)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            if let destinationPaths = try? managedPaths(
                for: application,
                profile: destination
            ), fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
                let copyError = errorMessage
                    ?? String(localized: "The profile data could not be copied.")
                errorMessage = String(
                    localized: "\(copyError) Partial data was preserved because its ownership could not be reverified; recovery is required at \(destinationPaths.profileRoot.url.path)."
                )
                loadState = .recoveryRequired(
                    originalBytes: nil,
                    message: errorMessage ?? copyError
                )
            }
            return false
        }
    }

    func useCodexHome(_ url: URL, for profile: LaunchProfile) {
        guard canMutateLibrary() else { return }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        var updated = applications[appIndex].profiles[profileIndex]
        updated.environmentText = Self.settingEnvironmentValue(
            "CODEX_HOME",
            to: url.path,
            in: updated.environmentText
        )
        updated.isolationOwnership.codexHome = .explicit
        var candidate = applications
        candidate[appIndex].profiles[profileIndex] = updated
        _ = commit(
            candidate,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: updated.id
        )
    }

    func profileDraftUsingCodexHome(
        _ url: URL,
        profile: LaunchProfile
    ) -> LaunchProfile {
        var updated = profile
        updated.environmentText = Self.settingEnvironmentValue(
            "CODEX_HOME",
            to: url.path,
            in: updated.environmentText
        )
        updated.isolationOwnership.codexHome = .explicit
        return updated
    }

    func profileDraftApplyingRecommendedSettings(
        _ profile: LaunchProfile,
        for application: ManagedApplication
    ) -> LaunchProfile? {
        do {
            return try applyingRecommendedSettings(
                to: profile,
                for: application,
                replacingExistingIsolation: false
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func stageKeychainSecret(
        _ secret: String,
        environmentKey: String,
        in profile: LaunchProfile
    ) async -> StagedProfileKeychainSecret? {
        let key = environmentKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let validation = LaunchEnvironmentParser.parse("\(key)=")
        guard
            validation.diagnostics.isEmpty,
            validation.entries.first?.name == key
        else {
            errorMessage = String(
                localized:
                    "Enter a valid environment variable name."
            )
            return nil
        }
        guard !secret.isEmpty else {
            errorMessage = String(
                localized: "The Keychain secret cannot be empty."
            )
            return nil
        }

        let reference = EnvironmentSecretReference()
        do {
            try await secretStore.store(
                SecretValue(secret),
                for: reference
            )
            var updated = profile
            updated.environmentText = Self.settingEnvironmentValue(
                key,
                to: reference.token,
                in: updated.environmentText
            )
            updated.sensitiveEnvironmentKeys = Array(
                Set(
                    updated.sensitiveEnvironmentKeys
                        + [key.uppercased()]
                )
            ).sorted()
            updated.isolationOwnership.codexHome =
                key == "CODEX_HOME"
                ? .explicit
                : updated.isolationOwnership.codexHome
            return StagedProfileKeychainSecret(
                profile: updated,
                reference: reference
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func profileDraftRemovingKeychainSecret(
        environmentKey: String,
        from profile: LaunchProfile
    ) -> (
        profile: LaunchProfile,
        reference: EnvironmentSecretReference
    )? {
        let key = environmentKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let storedText = LaunchEnvironmentParser.parse(
                profile.environmentText
            ).effectiveValues[key],
            case .secretReference(let reference) =
                StoredEnvironmentValue(storedText: storedText)
        else {
            errorMessage = String(
                localized:
                    "This environment value is not a Keychain reference."
            )
            return nil
        }
        var updated = profile
        updated.environmentText = Self.settingEnvironmentValue(
            key,
            to: "",
            in: updated.environmentText
        )
        return (updated, reference)
    }

    @discardableResult
    func discardKeychainSecret(
        _ reference: EnvironmentSecretReference
    ) async -> Bool {
        do {
            try await secretStore.remove(reference)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func applyRecommendedSettings(to profile: LaunchProfile) {
        guard canMutateLibrary() else { return }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        do {
            var candidate = applications
            candidate[appIndex].profiles[profileIndex] = try applyingRecommendedSettings(
                to: profile,
                for: applications[appIndex],
                replacingExistingIsolation: false
            )
            _ = commit(
                candidate,
                selectedApplicationID: selectedApplicationID,
                selectedProfileID: selectedProfileID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func storeKeychainSecret(
        _ secret: String,
        environmentKey: String,
        for profile: LaunchProfile
    ) async -> Bool {
        guard canMutateLibrary() else { return false }
        let key = environmentKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let validation = LaunchEnvironmentParser.parse("\(key)=")
        guard
            validation.diagnostics.isEmpty,
            validation.entries.first?.name == key
        else {
            errorMessage = String(
                localized:
                    "Enter a valid environment variable name."
            )
            return false
        }
        guard !secret.isEmpty else {
            errorMessage = String(
                localized: "The Keychain secret cannot be empty."
            )
            return false
        }
        let reference = EnvironmentSecretReference()
        do {
            try await secretStore.store(
                SecretValue(secret),
                for: reference
            )
            guard
                let appIndex = applications.firstIndex(where: {
                    $0.profiles.contains { $0.id == profile.id }
                }),
                let profileIndex = applications[appIndex].profiles
                    .firstIndex(where: { $0.id == profile.id })
            else {
                try? await secretStore.remove(reference)
                return false
            }
            var candidate = applications
            var updated = candidate[appIndex].profiles[profileIndex]
            updated.environmentText = Self.settingEnvironmentValue(
                key,
                to: reference.token,
                in: updated.environmentText
            )
            updated.sensitiveEnvironmentKeys = Array(
                Set(
                    updated.sensitiveEnvironmentKeys
                        + [key.uppercased()]
                )
            ).sorted()
            updated.isolationOwnership.codexHome =
                key == "CODEX_HOME"
                ? .explicit
                : updated.isolationOwnership.codexHome
            candidate[appIndex].profiles[profileIndex] = updated
            guard commit(
                candidate,
                selectedApplicationID: selectedApplicationID,
                selectedProfileID: selectedProfileID
            ) else {
                try? await secretStore.remove(reference)
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removeKeychainSecret(
        environmentKey: String,
        for profile: LaunchProfile
    ) async -> Bool {
        guard canMutateLibrary() else { return false }
        let key = environmentKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let storedText = LaunchEnvironmentParser.parse(
                profile.environmentText
            ).effectiveValues[key],
            case .secretReference(let reference) =
                StoredEnvironmentValue(storedText: storedText)
        else {
            errorMessage = String(
                localized:
                    "This environment value is not a Keychain reference."
            )
            return false
        }
        do {
            guard
                let appIndex = applications.firstIndex(where: {
                    $0.profiles.contains { $0.id == profile.id }
                }),
                let profileIndex = applications[appIndex].profiles
                    .firstIndex(where: { $0.id == profile.id })
            else {
                return false
            }
            var candidate = applications
            var updated = candidate[appIndex].profiles[profileIndex]
            updated.environmentText = Self.settingEnvironmentValue(
                key,
                to: "",
                in: updated.environmentText
            )
            candidate[appIndex].profiles[profileIndex] = updated
            guard commit(
                candidate,
                selectedApplicationID: selectedApplicationID,
                selectedProfileID: selectedProfileID
            ) else {
                return false
            }
            try await secretStore.remove(reference)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func exportLibrary() {
        exportPortable(.libraryMetadata)
    }

    func exportPortable(_ kind: LibraryPortableExportKind) {
        var sensitivePolicy = SensitiveLiteralExportPolicy.omit
        if portableExportContainsSensitiveLiterals(kind: kind) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized:
                    "Export plaintext sensitive environment values?"
            )
            alert.informativeText = String(
                localized:
                    "This library contains environment values classified as sensitive. Choose whether to omit, redact, or explicitly include those literals. Keychain-backed secrets remain references."
            )
            alert.addButton(
                withTitle: String(localized: "Omit Sensitive Values")
            )
            alert.addButton(
                withTitle: String(localized: "Redact Sensitive Values")
            )
            alert.addButton(
                withTitle: String(localized: "Include Sensitive Values")
            )
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                sensitivePolicy = .omit
            case .alertSecondButtonReturn:
                sensitivePolicy = .redact
            case .alertThirdButtonReturn:
                sensitivePolicy =
                    .includeAfterExplicitConfirmation
            default:
                return
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = switch kind {
        case .libraryMetadata:
            String(localized: "Parallax Library Metadata.json")
        case .settingsAndTemplates:
            String(
                localized:
                    "Parallax Settings and Templates.json"
            )
        case .portableConfiguration:
            String(
                localized:
                    "Parallax Portable Configuration.json"
            )
        }
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try portableExportData(
                kind: kind,
                sensitivePolicy: sensitivePolicy
            )
            try fileSystem.writeDataAtomically(data, to: url)
            launchStatusMessage = switch kind {
            case .libraryMetadata:
                String(localized: "Exported library metadata")
            case .settingsAndTemplates:
                String(localized: "Exported settings and templates")
            case .portableConfiguration:
                String(localized: "Exported portable configuration")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func portableExportData(
        kind: LibraryPortableExportKind,
        sensitivePolicy: SensitiveLiteralExportPolicy
    ) throws -> Data {
        let settingsSnapshot = PortableSettingsSnapshot(
            profileTemplates: settings.profileTemplates,
            defaultBaseStoragePath:
                settings.defaultBaseStoragePath,
            confirmBeforeLaunch:
                settings.confirmBeforeLaunch,
            appearance: settings.appearance
        )
        let library = LibraryDocument(
            applications: applications
        )
        return switch kind {
        case .libraryMetadata:
            try portableConfiguration.encode(
                portableConfiguration.makeLibraryMetadataExport(
                    library: library,
                    sensitiveLiteralPolicy: sensitivePolicy
                )
            )
        case .settingsAndTemplates:
            try portableConfiguration.encode(
                portableConfiguration
                    .makeSettingsAndTemplatesExport(
                        settings: settingsSnapshot,
                        sensitiveLiteralPolicy:
                            sensitivePolicy
                    )
            )
        case .portableConfiguration:
            try portableConfiguration.encode(
                portableConfiguration
                    .makePortableConfigurationExport(
                        library: library,
                        settings: settingsSnapshot,
                        sensitiveLiteralPolicy:
                            sensitivePolicy
                    )
            )
        }
    }

    private func portableExportContainsSensitiveLiterals(
        kind: LibraryPortableExportKind
    ) -> Bool {
        let includesLibrary = kind != .settingsAndTemplates
        let includesSettings = kind != .libraryMetadata
        return (
            includesLibrary
                && libraryExportContainsSensitiveLiterals()
        ) || (
            includesSettings
                && settings.profileTemplates.contains {
                    Self.environmentContainsSensitiveLiterals(
                        $0.environmentText,
                        explicitSensitiveKeys: []
                    )
                }
        )
    }

    func libraryExportContainsSensitiveLiterals() -> Bool {
        applications.contains { application in
            application.profiles.contains { profile in
                Self.environmentContainsSensitiveLiterals(
                    profile.environmentText,
                    explicitSensitiveKeys:
                        Set(profile.sensitiveEnvironmentKeys)
                )
            }
        }
    }

    private static func environmentContainsSensitiveLiterals(
        _ environmentText: String,
        explicitSensitiveKeys: Set<String>
    ) -> Bool {
        let classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys: explicitSensitiveKeys
        )
        return LaunchEnvironmentParser.parse(
            environmentText
        ).entries.contains { entry in
            guard
                case .set(let storedText) = entry.operation,
                classifier.isSensitive(entry.name),
                case .literal =
                    StoredEnvironmentValue(storedText: storedText)
            else {
                return false
            }
            return true
        }
    }

    func libraryDocumentForExport(
        sensitivePolicy: LibraryExportSensitivePolicy
    ) -> LibraryDocument {
        guard sensitivePolicy != .include else {
            return LibraryDocument(applications: applications)
        }
        let exportedApplications = applications.map { application in
            var exported = application
            exported.profiles = application.profiles.map { profile in
                var exportedProfile = profile
                exportedProfile.environmentText =
                    Self.exportEnvironmentText(
                        profile,
                        sensitivePolicy: sensitivePolicy
                    )
                return exportedProfile
            }
            return exported
        }
        return LibraryDocument(applications: exportedApplications)
    }

    private static func exportEnvironmentText(
        _ profile: LaunchProfile,
        sensitivePolicy: LibraryExportSensitivePolicy
    ) -> String {
        let classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys:
                Set(profile.sensitiveEnvironmentKeys)
        )
        let replacements: [(range: NSRange, text: String)] =
            LaunchEnvironmentParser.parse(
                profile.environmentText
            ).entries.compactMap { entry in
                guard
                    case .set(let storedText) = entry.operation,
                    classifier.isSensitive(entry.name),
                    case .literal =
                        StoredEnvironmentValue(storedText: storedText)
                else {
                    return nil
                }
                switch sensitivePolicy {
                case .include:
                    return nil
                case .redact:
                    guard let valueRange = entry.valueRange else {
                        return nil
                    }
                    return (
                        NSRange(
                            location: valueRange.start.utf16Offset,
                            length:
                                valueRange.end.utf16Offset
                                - valueRange.start.utf16Offset
                        ),
                        "<redacted>"
                    )
                case .omit:
                    return (
                        NSRange(
                            location: entry.range.start.utf16Offset,
                            length:
                                entry.range.end.utf16Offset
                                - entry.range.start.utf16Offset
                        ),
                        "# Omitted sensitive value: \(entry.name)"
                    )
                }
            }
        let result = NSMutableString(string: profile.environmentText)
        for replacement in replacements.sorted(by: {
            $0.range.location > $1.range.location
        }) {
            result.replaceCharacters(
                in: replacement.range,
                with: replacement.text
            )
        }
        return result as String
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        _ = prepareImport(at: url)
    }

    @discardableResult
    func prepareImport(at url: URL) -> Bool {
        do {
            let attributes = try fileSystem.attributesOfItem(at: url)
            guard
                attributes.kind == .regularFile,
                let size = attributes.size,
                size <= UInt64(
                    LibraryImportLimits().maximumBytes
                )
            else {
                throw LibraryImportStoreError.invalidImportFile
            }
            let data = try fileSystem.readData(at: url)
            return prepareImport(data: data)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func prepareImport(data: Data) -> Bool {
        guard canMutateLibrary() else { return false }
        var report = importValidator.validate(data)
        var portableWarning: String?
        if !report.isValid,
           let portable = try? portableConfiguration
            .decodeLibraryMetadataExport(from: data),
           let innerData = try? encodedImportDocument(
               portable.library
           )
        {
            report = importValidator.validate(innerData)
            portableWarning = String(
                localized:
                    "This metadata export excludes settings, profile data, application binaries, external data, and Keychain secret values."
            )
        } else if !report.isValid,
                  let portable = try? portableConfiguration
                    .decodePortableConfigurationExport(
                        from: data
                    ),
                  let innerData = try? encodedImportDocument(
                      portable.library
                  )
        {
            report = importValidator.validate(innerData)
            portableWarning = String(
                localized:
                    "This import applies library metadata only. Review and import settings separately; profile data and Keychain secret values are not included."
            )
        }
        guard
            report.isValid,
            let document = report.document
        else {
            errorMessage = report.issues
                .map { "\($0.path): \($0.message)" }
                .joined(separator: "\n")
            return false
        }
        var importedApplications = document.applications
        for applicationIndex in importedApplications.indices {
            for profileIndex in importedApplications[
                applicationIndex
            ].profiles.indices {
                importedApplications[applicationIndex]
                    .profiles[profileIndex]
                    .markLaunchConfigurationImported()
                importedApplications[applicationIndex]
                    .profiles[profileIndex].lastLaunchedAt = nil
            }
        }
        var warningMessages = report.issues
            .filter { $0.severity == .warning }
            .map { "\($0.path): \($0.message)" }
        if let portableWarning {
            warningMessages.append(portableWarning)
        }
        pendingLibraryImport = PendingLibraryImport(
            sourceSHA256: LibraryPersistence.sha256(data),
            expectedVersion: libraryVersionToken,
            applications: importedApplications,
            canonicalApplications: importedApplications.map {
                LibraryImportApplication(
                    application: $0,
                    canonicalApplicationPath: URL(
                        fileURLWithPath: $0.appPath
                    ).standardizedFileURL.path
                )
            },
            warnings: warningMessages
        )
        pendingImportResolutions = [:]
        pendingImportConflict = nil
        pendingImportSummary = LibraryImportSummary(
            applicationCount: importedApplications.count,
            profileCount: importedApplications.reduce(into: 0) {
                $0 += $1.profiles.count
            },
            warnings: warningMessages
        )
        isShowingImportConflictResolution = false
        isShowingImportChoice = true
        errorMessage = nil
        return true
    }

    func confirmImport(replacing: Bool) {
        guard canMutateLibrary() else { return }
        guard let pending = pendingLibraryImport else { return }
        isShowingImportChoice = false

        do {
            try validatePendingImportVersion(pending)
            if replacing {
                guard
                    let coordinator = importReplacementCoordinator
                else {
                    throw LibraryImportStoreError
                        .replacementUnavailable
                }
                let data = try encodedImportApplications(
                    pending.applications
                )
                let preview = try coordinator.preview(
                    importData: data,
                    expectedVersion: pending.expectedVersion
                )
                let result = try coordinator.replace(using: preview)
                applications = result.snapshot.applications
                libraryVersionToken = result.snapshot.versionToken
                selectedApplicationID = applications.first?.id
                selectedProfileID =
                    applications.first?.profiles.first?.id
                loadState = .loaded
                lastImportReplacement = result
                publishLibraryChange()
                finishImport()
                launchStatusMessage = String(
                    localized:
                        "Replaced library metadata. Existing profile data was preserved."
                )
            } else {
                try continueMergeImport()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelImport() {
        finishImport()
    }

    func resolvePendingImportConflict(
        _ choice: LibraryImportConflictChoice,
        target: LibraryImportConflictTarget? = nil
    ) {
        guard
            let pending = pendingLibraryImport,
            let conflict = pendingImportConflict
        else { return }
        do {
            try validatePendingImportVersion(pending)
            let resolution: LibraryImportConflictResolution
            switch choice {
            case .keepExisting:
                guard let target else {
                    throw LibraryImportStoreError
                        .conflictTargetRequired
                }
                resolution = .keepExisting(
                    applicationID: target.applicationID,
                    profileID: target.profileID
                )
            case .useImported:
                guard let target else {
                    throw LibraryImportStoreError
                        .conflictTargetRequired
                }
                resolution = .useImported(
                    applicationID: target.applicationID,
                    profileID: target.profileID
                )
            case .keepBoth:
                resolution = try keepBothResolution(
                    for: conflict,
                    pending: pending
                )
            case .skip:
                resolution = .skip
            }
            pendingImportResolutions[conflict.id] = resolution
            pendingImportConflict = nil
            isShowingImportConflictResolution = false
            try continueMergeImport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func undoLastImportReplacement() -> Bool {
        guard
            let replacement = lastImportReplacement,
            let coordinator = importReplacementCoordinator
        else {
            errorMessage = String(
                localized:
                    "No import replacement is available to undo."
            )
            return false
        }
        do {
            let result = try coordinator.undo(
                replacement: replacement
            )
            applications = result.snapshot.applications
            libraryVersionToken = result.snapshot.versionToken
            selectedApplicationID = applications.first?.id
            selectedProfileID = applications.first?.profiles.first?.id
            lastImportReplacement = nil
            publishLibraryChange()
            launchStatusMessage = String(
                localized:
                    "Undid the library metadata replacement. Profile data was unchanged."
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startOverAuthorization() -> StartOverAuthorization? {
        guard let bytes = failedPrimaryBytes else { return nil }
        return StartOverAuthorization(
            failedPrimarySHA256: LibraryPersistence.sha256(bytes)
        )
    }

    @discardableResult
    func restoreLatestVerifiedBackup() -> Bool {
        guard
            let backupStore,
            let libraryPrimaryURL,
            let expectedBytes = failedPrimaryBytes
        else {
            errorMessage = String(localized: "No failed library is available to restore.")
            return false
        }

        do {
            let restore = try backupStore.prepareLatestBackupRestore()
            _ = try backupStore.preparePrimaryRestore(
                from: restore.artifact,
                replacing: libraryPrimaryURL
            )
            try replaceFailedPrimary(
                expectedBytes: expectedBytes,
                targetBytes: restore.bytes
            )
            load()
            if case .loaded = loadState {
                publishLibraryChange()
                return true
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func exportRecoveryCopy() {
        guard
            let backupStore,
            failedPrimaryBytes != nil
        else {
            errorMessage = String(
                localized: "No failed library is available to export."
            )
            return
        }

        do {
            let artifact = try recoveryArtifactForCurrentFailure()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = String(
                localized: "Parallax Recovery Library.json"
            )
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let destination = panel.url else {
                return
            }
            try backupStore.export(artifact, to: destination)
            launchStatusMessage = String(
                localized: "Exported a verified recovery copy."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealRecoveryArtifacts() {
        guard
            backupStore != nil,
            failedPrimaryBytes != nil
        else {
            errorMessage = String(
                localized: "No failed library is available to inspect."
            )
            return
        }

        do {
            let artifact = try recoveryArtifactForCurrentFailure()
            NSWorkspace.shared.activateFileViewerSelecting([
                artifact.libraryURL
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recoveryArtifactForCurrentFailure() throws
        -> LibraryRecoveryArtifact
    {
        guard
            let backupStore,
            let originalBytes = failedPrimaryBytes
        else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let expectedSHA256 = LibraryPersistence.sha256(originalBytes)
        if let exactQuarantine = try backupStore.inspectArtifacts(
            kind: .quarantine
        ).first(where: {
            $0.isVerified
                && $0.artifact.sha256 == expectedSHA256
                && $0.artifact.byteCount == originalBytes.count
        }) {
            return exactQuarantine.artifact
        }
        return try backupStore.quarantine(originalBytes)
    }

    @discardableResult
    func confirmStartOver(_ authorization: StartOverAuthorization) -> Bool {
        guard
            let backupStore,
            let libraryPrimaryURL,
            let expectedBytes = failedPrimaryBytes,
            LibraryPersistence.sha256(expectedBytes)
                == authorization.failedPrimarySHA256
        else {
            errorMessage = String(
                localized: "The failed library changed before start-over confirmation."
            )
            return false
        }

        do {
            let preparation = try backupStore.prepareQuarantineAndStartOver(
                primaryAt: libraryPrimaryURL
            )
            guard
                preparation.originalSHA256
                    == authorization.failedPrimarySHA256
            else {
                throw LibraryRepositoryError.staleWriter(
                    expected: LibraryVersionToken(
                        revision: .initial,
                        primarySHA256: authorization.failedPrimarySHA256
                    ),
                    actual: LibraryVersionToken(
                        revision: .initial,
                        primarySHA256: preparation.originalSHA256
                    )
                )
            }
            try replaceFailedPrimary(
                expectedBytes: expectedBytes,
                targetBytes: preparation.emptyLibraryBytes
            )
            load()
            if case .loaded = loadState {
                publishLibraryChange()
                return true
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var selectedApplicationIndex: Int? {
        guard let selectedApplicationID else { return nil }
        return applications.firstIndex { $0.id == selectedApplicationID }
    }

    private var failedPrimaryBytes: Data? {
        switch loadState {
        case .recoveryRequired(let bytes, _),
             .unsupportedNewerVersion(let bytes, _),
             .unrecoverable(let bytes, _):
            bytes
        case .loading, .loaded:
            nil
        }
    }

    private func replaceFailedPrimary(
        expectedBytes: Data,
        targetBytes: Data
    ) throws {
        guard let libraryPrimaryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try LibraryPersistence.decodeCurrentDocument(from: targetBytes)
        let parent = libraryPrimaryURL.deletingLastPathComponent()
        let lock = LibraryAdvisoryLock(
            url: parent.appendingPathComponent(
                ".library.lock",
                isDirectory: false
            )
        )
        try lock.withExclusiveLock {
            guard try fileSystem.readData(at: libraryPrimaryURL) == expectedBytes else {
                throw LibraryRepositoryError.staleWriter(
                    expected: LibraryVersionToken(
                        revision: .initial,
                        primarySHA256: LibraryPersistence.sha256(expectedBytes)
                    ),
                    actual: LibraryVersionToken(
                        revision: .initial,
                        primarySHA256: try? LibraryPersistence.sha256(
                            fileSystem.readData(at: libraryPrimaryURL)
                        )
                    )
                )
            }
            let temporary = parent.appendingPathComponent(
                ".library.recovery-\(UUID().uuidString.lowercased()).tmp",
                isDirectory: false
            )
            do {
                try fileSystem.writeData(targetBytes, to: temporary)
                try fileSystem.setPOSIXPermissions(0o600, at: temporary)
                try fileSystem.synchronize(at: temporary)
                try fileSystem.replaceItem(
                    at: libraryPrimaryURL,
                    withItemAt: temporary
                )
                try fileSystem.synchronize(at: libraryPrimaryURL)
                try fileSystem.synchronize(at: parent)
            } catch {
                if fileSystem.fileExists(at: temporary) {
                    try? fileSystem.removeItem(at: temporary)
                }
                throw error
            }
            guard try fileSystem.readData(at: libraryPrimaryURL) == targetBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func isDirectory(at url: URL) -> Bool {
        guard let attributes = try? fileSystem.attributesOfItem(at: url) else {
            return false
        }
        return attributes.kind == .directory
    }

    private func applicationForLaunch(_ profile: LaunchProfile) -> ManagedApplication? {
        if let selectedApplication,
           selectedApplication.profiles.contains(where: { $0.id == profile.id }) {
            return selectedApplication
        }

        return applications.first { application in
            application.profiles.contains { $0.id == profile.id }
        }
    }

    private func submitLaunchConfirmation(
        application: ManagedApplication,
        profile: LaunchProfile,
        source: LaunchConfigurationSource,
        fingerprint: LaunchConfigurationFingerprint
    ) {
        let request = ImmutableLaunchRequest(
            sceneID: sceneID,
            applicationName: application.displayName,
            profileName: profile.name,
            configurationSnapshot: source,
            configurationFingerprint: fingerprint
        )
        switch launchRequests.submit(request, policy: .rejectNew) {
        case .awaitingConfirmation:
            isShowingLaunchConfirmation = true
        case .queued:
            isShowingLaunchConfirmation = true
        case .rejected(_, let reason):
            errorMessage = reason.message
        }
    }

    private func currentLaunchTarget(
        for request: ImmutableLaunchRequest
    ) -> LaunchRequestCurrentTarget {
        guard
            let application = applications.first(where: {
                $0.id == request.applicationID
            })
        else {
            return .applicationRemoved
        }
        guard
            let profile = application.profiles.first(where: {
                $0.id == request.profileID
            })
        else {
            return .profileRemoved
        }
        let source = launchConfigurationSource(
            application: application,
            profile: profile,
            requestID: request.requestID
        )
        return .available(
            applicationID: application.id,
            profileID: profile.id,
            configurationRevision: source.configurationRevision,
            configurationFingerprint:
                LaunchConfigurationCompiler
                    .configurationFingerprint(for: source)
        )
    }

    private func load() {
        loadState = .loading
        if let repository {
            load(from: repository)
            return
        }

        do {
            switch try persistence.loadResult() {
            case let .current(loaded):
                try LibraryPersistence.validateCurrentApplications(loaded)
                migrationRequiredLibrary = nil
                applications = loaded
                selectedApplicationID = applications.first?.id
                selectedProfileID = applications.first?.profiles.first?.id
                loadState = .loaded
            case let .migrationRequired(legacy):
                migrationRequiredLibrary = legacy
                applications = []
                selectedApplicationID = nil
                selectedProfileID = nil
                errorMessage = LibraryPersistenceError
                    .migrationRequired(format: legacy.format)
                    .localizedDescription
                loadState = .recoveryRequired(
                    originalBytes: nil,
                    message: errorMessage ?? String(localized: "Library migration is required.")
                )
            }
        } catch {
            AppLog.persistence.error("Failed to load library: \(error.localizedDescription)")
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            errorMessage = error.localizedDescription
            if case let LibraryPersistenceError.unsupportedVersion(found, supported) = error {
                loadState = .unsupportedNewerVersion(
                    originalBytes: nil,
                    message: String(
                        localized: "The library uses format v\(found), but this build supports v\(supported)."
                    )
                )
            } else {
                loadState = .unrecoverable(
                    originalBytes: nil,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func load(from repository: any LibraryRepositoryPersisting) {
        switch repository.load() {
        case .missing:
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = .missing
            migrationRequiredLibrary = nil
            loadState = .loaded
        case let .loaded(snapshot):
            if let storageRelocationCoordinator {
                do {
                    let pending =
                        try storageRelocationCoordinator.pendingRelocations()
                    if !pending.isEmpty {
                        _ = try storageRelocationCoordinator.recoverAll(
                            repository: repository
                        )
                        load(from: repository)
                        return
                    }
                } catch {
                    applications = []
                    selectedApplicationID = nil
                    selectedProfileID = nil
                    libraryVersionToken = nil
                    errorMessage = error.localizedDescription
                    loadState = .recoveryRequired(
                        originalBytes: snapshot.originalBytes,
                        message: error.localizedDescription
                    )
                    return
                }
            }
            if let profileDataTransactions {
                do {
                    let pending = try profileDataTransactions.pendingTransactions()
                    if !pending.isEmpty {
                        for transaction in pending {
                            _ = try profileDataTransactions.recover(
                                transactionID: transaction.transactionID,
                                repository: repository
                            )
                        }
                        load(from: repository)
                        return
                    }
                } catch {
                    applications = []
                    selectedApplicationID = nil
                    selectedProfileID = nil
                    libraryVersionToken = nil
                    errorMessage = error.localizedDescription
                    loadState = .recoveryRequired(
                        originalBytes: snapshot.originalBytes,
                        message: error.localizedDescription
                    )
                    return
                }
            }
            if let applicationRemovalTransactions {
                do {
                    let pending =
                        try applicationRemovalTransactions
                            .pendingTransactions()
                    if !pending.isEmpty {
                        for transactionID in pending {
                            _ = try applicationRemovalTransactions
                                .recover(
                                    transactionID: transactionID,
                                    repository: repository
                                )
                        }
                        load(from: repository)
                        return
                    }
                } catch {
                    applications = []
                    selectedApplicationID = nil
                    selectedProfileID = nil
                    libraryVersionToken = nil
                    errorMessage = error.localizedDescription
                    loadState = .recoveryRequired(
                        originalBytes: snapshot.originalBytes,
                        message: error.localizedDescription
                    )
                    return
                }
            }
            applications = snapshot.applications
            selectedApplicationID = applications.first?.id
            selectedProfileID = applications.first?.profiles.first?.id
            libraryVersionToken = snapshot.versionToken
            migrationRequiredLibrary = nil
            loadState = .loaded
        case let .migrationRequired(snapshot):
            do {
                _ = try persistence.loadResult()
                load(from: repository)
            } catch {
                migrationRequiredLibrary = snapshot.library
                applications = []
                selectedApplicationID = nil
                selectedProfileID = nil
                errorMessage = error.localizedDescription
                loadState = .recoveryRequired(
                    originalBytes: snapshot.originalBytes,
                    message: error.localizedDescription
                )
            }
        case let .recoveryRequired(failure):
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = nil
            errorMessage = failure.error.localizedDescription
            loadState = .recoveryRequired(
                originalBytes: failure.originalBytes,
                message: failure.error.localizedDescription
            )
        case let .readOnly(failure):
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = nil
            errorMessage = failure.error.localizedDescription
            loadState = .unsupportedNewerVersion(
                originalBytes: failure.originalBytes,
                message: failure.error.localizedDescription
            )
        }
    }

    /// Refreshes a peer scene after another window commits to the shared
    /// repository. Window-local selection and presentation state are retained
    /// when their immutable targets still exist.
    func reloadFromSharedRepository() {
        guard let repository else { return }
        let applicationID = selectedApplicationID
        let profileID = selectedProfileID
        switch repository.load() {
        case let .loaded(snapshot):
            applications = snapshot.applications
            libraryVersionToken = snapshot.versionToken
            selectedApplicationID = applications.contains {
                $0.id == applicationID
            } ? applicationID : nil
            if let selectedApplication = applications.first(where: {
                $0.id == selectedApplicationID
            }), selectedApplication.profiles.contains(where: {
                $0.id == profileID
            }) {
                selectedProfileID = profileID
            } else {
                selectedProfileID = nil
            }
            loadState = .loaded
        case .missing:
            applications = []
            selectedApplicationID = nil
            selectedProfileID = nil
            libraryVersionToken = .missing
            loadState = .loaded
        case .migrationRequired, .recoveryRequired, .readOnly:
            // The full load path owns migration and recovery presentation.
            load()
        }
    }

    private func publishLibraryChange() {
        libraryChangeBroadcaster?.publish(sourceSceneID: sceneID)
    }

    private func persistApplicationEdit(
        _ application: ManagedApplication,
        expectedVersion: LibraryVersionToken
    ) throws -> (
        persisted: ManagedApplication,
        version: LibraryVersionToken
    ) {
        guard
            let repository,
            let index = applications.firstIndex(where: {
                $0.id == application.id
                    && $0.storageID == application.storageID
            })
        else {
            throw LibraryEditPersistenceFailure(
                message: String(
                    localized:
                        "Application edit persistence is unavailable."
                )
            )
        }
        var candidate = applications
        candidate[index] = application
        let snapshot = try repository.save(
            candidate,
            expectedVersion: expectedVersion
        )
        applications = snapshot.applications
        libraryVersionToken = snapshot.versionToken
        sceneCoordinator.synchronize(with: applications)
        loadState = .loaded
        publishLibraryChange()
        return (
            applications[index],
            snapshot.versionToken
        )
    }

    private func persistProfileEdit(
        _ profile: LaunchProfile,
        applicationID: UUID,
        expectedVersion: LibraryVersionToken
    ) throws -> (
        persisted: LaunchProfile,
        version: LibraryVersionToken
    ) {
        guard
            let repository,
            let applicationIndex = applications.firstIndex(where: {
                $0.id == applicationID
            }),
            let profileIndex = applications[applicationIndex]
                .profiles.firstIndex(where: {
                    $0.id == profile.id
                        && $0.storageID == profile.storageID
                })
        else {
            throw LibraryEditPersistenceFailure(
                message: String(
                    localized:
                        "Profile edit persistence is unavailable."
                )
            )
        }
        var candidate = applications
        candidate[applicationIndex].profiles[profileIndex] = profile
        let snapshot = try repository.save(
            candidate,
            expectedVersion: expectedVersion
        )
        applications = snapshot.applications
        libraryVersionToken = snapshot.versionToken
        sceneCoordinator.synchronize(with: applications)
        loadState = .loaded
        publishLibraryChange()
        return (
            applications[applicationIndex].profiles[profileIndex],
            snapshot.versionToken
        )
    }

    private func handleApplicationEditResult(
        _ result:
            LibraryEditApplyResult<ManagedApplicationEditField>
    ) -> Bool {
        switch result {
        case .applied, .noChanges:
            errorMessage = nil
            return true
        case .targetChanged:
            errorMessage = String(
                localized:
                    "The application changed identity. Your draft was kept."
            )
        case .conflicts(let fields):
            errorMessage = String(
                localized:
                    "Another window changed the same application fields: \(Self.editFieldList(fields.map(\.rawValue))). Your draft was kept."
            )
        case .persistenceFailed(let failure):
            errorMessage = failure.localizedDescription
        }
        return false
    }

    private func handleProfileEditResult(
        _ result: LibraryEditApplyResult<LaunchProfileEditField>
    ) -> Bool {
        switch result {
        case .applied, .noChanges:
            errorMessage = nil
            return true
        case .targetChanged:
            errorMessage = String(
                localized:
                    "The profile changed identity. Your draft was kept."
            )
        case .conflicts(let fields):
            errorMessage = String(
                localized:
                    "Another window changed the same profile fields: \(Self.editFieldList(fields.map(\.rawValue))). Your draft was kept."
            )
        case .persistenceFailed(let failure):
            errorMessage = failure.localizedDescription
        }
        return false
    }

    private static func editFieldList(_ fields: [String]) -> String {
        fields.sorted().joined(separator: ", ")
    }

    @discardableResult
    private func save() -> Bool {
        commit(
            applications,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: selectedProfileID
        )
    }

    @discardableResult
    private func commit(
        _ candidate: [ManagedApplication],
        selectedApplicationID candidateApplicationID: ManagedApplication.ID?,
        selectedProfileID candidateProfileID: LaunchProfile.ID?,
        backupReason: LibraryBackupReason? = nil
    ) -> Bool {
        guard canMutateLibrary() else { return false }
        do {
            if let repository {
                guard let libraryVersionToken else {
                    throw LibraryRepositoryError.libraryUnavailable(
                        LibraryPersistenceFailure(
                            originalBytes: nil,
                            error: CocoaError(.fileReadCorruptFile)
                        )
                    )
                }
                let snapshot = try repository.save(
                    candidate,
                    expectedVersion: libraryVersionToken,
                    backupReason: backupReason
                )
                self.libraryVersionToken = snapshot.versionToken
            } else {
                try persistence.save(candidate)
            }
            applications = candidate
            selectedApplicationID = candidateApplicationID
            selectedProfileID = candidateProfileID
            loadState = .loaded
            publishLibraryChange()
            return true
        } catch {
            AppLog.persistence.error("Failed to save library: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            if case let LibraryRepositoryError.commitFailed(state, failure) = error,
               state != .prior {
                loadState = .recoveryRequired(
                    originalBytes: failure.originalBytes,
                    message: error.localizedDescription
                )
            }
            return false
        }
    }

    private func executeProfileDataTransaction(
        operation: ProfileDataTransactionOperation,
        application: ManagedApplication,
        sourceProfile: LaunchProfile,
        destinationProfile: LaunchProfile?,
        candidate: [ManagedApplication],
        selectedProfileID candidateProfileID: LaunchProfile.ID?,
        externalDataHandling: ProfileExternalDataHandling
    ) -> ProfileDataTransactionOutcome? {
        guard
            let profileDataTransactions,
            let repository,
            let libraryVersionToken
        else {
            return nil
        }
        let priorVersionToken = libraryVersionToken

        do {
            let source = try managedPaths(
                for: application,
                profile: sourceProfile
            )
            let destination = try destinationProfile.map {
                try managedPaths(for: application, profile: $0)
            }
            let prepared = try repository.prepare(
                candidate,
                expectedVersion: libraryVersionToken
            )
            let request = ProfileDataTransactionRequest(
                transactionID: UUID(),
                identity: ProfileDataTransactionIdentity(
                    applicationID: application.id,
                    applicationStorageID: application.storageID,
                    sourceProfileID: sourceProfile.id,
                    sourceProfileStorageID: sourceProfile.storageID,
                    destinationProfileID: destinationProfile?.id,
                    destinationProfileStorageID: destinationProfile?.storageID
                ),
                operation: operation,
                source: source,
                destination: destination,
                externalDataHandling: externalDataHandling
            )
            let outcome = try profileDataTransactions.execute(
                request,
                preparedCommit: prepared,
                repository: repository
            )
            applications = candidate
            selectedApplicationID = application.id
            selectedProfileID = candidateProfileID
            self.libraryVersionToken = prepared.targetVersion
            loadState = .loaded
            publishLibraryChange()
            return outcome
        } catch {
            AppLog.profiles.error(
                "Profile data transaction failed: \(error.localizedDescription)"
            )
            errorMessage = error.localizedDescription
            switch repository.load() {
            case let .loaded(snapshot):
                let previousApplicationID = selectedApplicationID
                let previousProfileID = selectedProfileID
                applications = snapshot.applications
                self.libraryVersionToken = snapshot.versionToken
                selectedApplicationID = applications.contains {
                    $0.id == previousApplicationID
                } ? previousApplicationID : applications.first?.id
                if let selectedApplication = applications.first(where: {
                    $0.id == selectedApplicationID
                }) {
                    selectedProfileID = selectedApplication.profiles.contains {
                        $0.id == previousProfileID
                    } ? previousProfileID : selectedApplication.profiles.first?.id
                } else {
                    selectedProfileID = nil
                }
                if snapshot.versionToken == priorVersionToken {
                    loadState = .loaded
                } else {
                    loadState = .recoveryRequired(
                        originalBytes: nil,
                        message: error.localizedDescription
                    )
                }
            case let .recoveryRequired(failure),
                 let .readOnly(failure):
                loadState = .recoveryRequired(
                    originalBytes: failure.originalBytes,
                    message: error.localizedDescription
                )
            case .missing, .migrationRequired:
                loadState = .recoveryRequired(
                    originalBytes: nil,
                    message: error.localizedDescription
                )
            }
            if (try? profileDataTransactions.pendingTransactions().isEmpty) == false {
                loadState = .recoveryRequired(
                    originalBytes: failedPrimaryBytes,
                    message: error.localizedDescription
                )
            }
            return nil
        }
    }

    private func externalDataHandling(
        for profile: LaunchProfile
    ) -> ProfileExternalDataHandling {
        var configuredKinds: [String] = []
        if profile.isolationOwnership.userData != .generated,
           hasUserDataDirectoryConfigured(in: profile) {
            configuredKinds.append("user-data-dir")
        }
        if profile.isolationOwnership.codexHome != .generated,
           hasCodexHomeConfigured(in: profile) {
            configuredKinds.append("CODEX_HOME")
        }
        return configuredKinds.isEmpty
            ? .notConfigured
            : .configurationOnly(configuredPaths: configuredKinds)
    }

    private func canMutateLibrary() -> Bool {
        guard case .loaded = loadState else {
            errorMessage = String(
                localized: "The library is read-only until its load or recovery problem is resolved."
            )
            return false
        }
        guard migrationRequiredLibrary == nil else {
            errorMessage = String(
                localized: "This legacy library is read-only until its profile data is migrated."
            )
            return false
        }
        return true
    }

    private func revealManagedFolder(_ path: any ManagedMutationPath) -> Bool {
        do {
            let target = path.url.standardizedFileURL
            let revealURL: URL
            if fileSystem.fileExists(at: target) {
                let attributes = try fileSystem.attributesOfItem(at: target)
                guard attributes.kind == .directory else {
                    throw ManagedPathError(.targetNotDirectory, path: target.path)
                }
                revealURL = target
            } else {
                var parent = target.deletingLastPathComponent()
                while
                    !fileSystem.fileExists(at: parent),
                    parent.path != "/"
                {
                    parent.deleteLastPathComponent()
                }
                guard fileSystem.fileExists(at: parent) else {
                    throw ManagedPathError(.baseRootUnavailable, path: target.path)
                }
                revealURL = parent
                launchStatusMessage = String(
                    localized: "The managed folder does not exist. Revealed its nearest existing parent."
                )
            }
            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func revealExternalFolder(_ path: ExternalIsolationPath) -> Bool {
        guard isDirectory(at: path.url) else {
            errorMessage = String(localized: "The external isolation folder does not exist.")
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([path.url])
        return true
    }

    private func archiveProfileData(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) throws -> ManagedArchiveEntryPath? {
        let paths = try managedPaths(for: application, profile: profile)
        guard fileSystem.fileExists(at: paths.profileRoot.url) else { return nil }
        return try moveToArchive(
            source: paths.profileRoot,
            archiveRoot: paths.archiveRoot
        )
    }

    private func deleteProfileData(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) throws {
        let profileRoot = try managedPaths(
            for: application,
            profile: profile
        ).profileRoot
        guard fileSystem.fileExists(at: profileRoot.url) else { return }
        try removeManagedItem(at: profileRoot)
    }

    private func defaultProfile(for application: ManagedApplication) throws -> LaunchProfile {
        let preset = Self.resolvedPreset(for: application)

        if preset.supportsUserDataDir {
            var profile = LaunchProfile(
                name: String(localized: "Personal"),
                notes: preset.needsCodexHome
                    ? String(localized: "Codex stores account state in CODEX_HOME, so Parallax sets a separate Codex home in addition to --user-data-dir.")
                    : String(localized: "Apps built on Chromium or Electron often support isolated profiles with --user-data-dir.")
            )
            let paths = try managedPaths(for: application, profile: profile)
            profile.argumentsText = ShellWordsParser.quote(
                "--user-data-dir=\(paths.userData.url.path)"
            )
            profile.environmentText = preset.needsCodexHome
                ? "CODEX_HOME=\(paths.codexHome.url.path)"
                : ""
            profile.isolationOwnership.userData = .generated
            if preset.needsCodexHome {
                profile.isolationOwnership.codexHome = .generated
            }
            return profile
        }

        return LaunchProfile(
            name: "Default",
            notes: String(localized: "This app may reuse its normal macOS container, Keychain items, or account store unless it supports profile-specific launch arguments.")
        )
    }

    private func continueMergeImport() throws {
        guard let pending = pendingLibraryImport else { return }
        try validatePendingImportVersion(pending)
        let existing = applications.map {
            LibraryImportApplication(
                application: $0,
                canonicalApplicationPath: URL(
                    fileURLWithPath: $0.appPath
                ).standardizedFileURL.path
            )
        }
        let result = try LibraryImportConflictEngine.resolve(
            existing: existing,
            imported: pending.canonicalApplications,
            resolutions: pendingImportResolutions
        )
        if let conflict = result.conflicts.first(where: {
            result.unresolvedConflictIDs.contains($0.id)
        }) {
            pendingImportConflict = conflict
            isShowingImportConflictResolution = true
            return
        }
        guard let candidate = result.applications else {
            throw LibraryImportStoreError.unresolvedConflict
        }
        let selectedApplication = candidate.first?.id
        let selectedProfile = candidate.first?.profiles.first?.id
        guard commit(
            candidate,
            selectedApplicationID: selectedApplication,
            selectedProfileID: selectedProfile
        ) else {
            return
        }
        finishImport()
        launchStatusMessage = String(localized: "Imported library metadata")
    }

    private func validatePendingImportVersion(
        _ pending: PendingLibraryImport
    ) throws {
        guard pending.expectedVersion == libraryVersionToken else {
            finishImport()
            throw LibraryImportStoreError.staleImportSession
        }
    }

    private func finishImport() {
        pendingLibraryImport = nil
        pendingImportResolutions = [:]
        pendingImportConflict = nil
        pendingImportSummary = nil
        isShowingImportChoice = false
        isShowingImportConflictResolution = false
    }

    private func encodedImportApplications(
        _ applications: [ManagedApplication]
    ) throws -> Data {
        try encodedImportDocument(
            LibraryDocument(applications: applications)
        )
    }

    private func encodedImportDocument(
        _ document: LibraryDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func keepBothResolution(
        for conflict: LibraryImportConflict,
        pending: PendingLibraryImport
    ) throws -> LibraryImportConflictResolution {
        if conflict.scope == .application {
            guard
                let application = pending.applications.first(where: {
                    $0.id == conflict.importedApplicationID
                })
            else {
                throw LibraryImportStoreError.unresolvedConflict
            }
            let occupiedNames = Set(
                applications.map {
                    Self.normalizedImportName($0.displayName)
                }
            ).union(
                pendingImportResolutions.values.compactMap {
                    guard
                        case let .keepBoth(.application(name, _)) = $0
                    else { return nil }
                    return Self.normalizedImportName(name)
                }
            )
            let rename = Self.uniqueImportedName(
                application.displayName,
                occupied: occupiedNames
            )
            let identities = Dictionary(
                uniqueKeysWithValues: application.profiles.map {
                    (
                        $0.id,
                        LibraryImportFreshProfileIdentity(
                            id: UUID(),
                            storageID: UUID()
                        )
                    )
                }
            )
            return .keepBoth(
                .application(
                    renamedTo: rename,
                    identity: LibraryImportFreshApplicationIdentity(
                        id: UUID(),
                        storageID: UUID(),
                        profileIdentities: identities
                    )
                )
            )
        }
        guard
            let importedProfileID = conflict.importedProfileID,
            let profile = pending.applications
                .flatMap(\.profiles)
                .first(where: { $0.id == importedProfileID })
        else {
            throw LibraryImportStoreError.unresolvedConflict
        }
        let occupiedNames = Set(
            applications.flatMap(\.profiles).map {
                Self.normalizedImportName($0.name)
            }
        ).union(
            pendingImportResolutions.values.compactMap {
                guard
                    case let .keepBoth(.profile(name, _)) = $0
                else { return nil }
                return Self.normalizedImportName(name)
            }
        )
        return .keepBoth(
            .profile(
                renamedTo: Self.uniqueImportedName(
                    profile.name,
                    occupied: occupiedNames
                ),
                identity: LibraryImportFreshProfileIdentity(
                    id: UUID(),
                    storageID: UUID()
                )
            )
        )
    }

    private static func uniqueImportedName(
        _ base: String,
        occupied: Set<String>
    ) -> String {
        var suffix = 1
        var candidate = String(localized: "\(base) Imported")
        while occupied.contains(normalizedImportName(candidate)) {
            suffix += 1
            candidate = String(
                localized: "\(base) Imported \(suffix)"
            )
        }
        return candidate
    }

    private static func normalizedImportName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvedPreset(for application: ManagedApplication) -> AppPreset {
        application.preset == .automatic
            ? AppPreset.detected(displayName: application.displayName, bundleIdentifier: application.bundleIdentifier)
            : application.preset
    }

    private func configuredBaseRoot(for application: ManagedApplication) -> String {
        let trimmed = application.baseStoragePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultProfilesRootPath : application.baseStoragePath ?? ""
    }

    private func profile(
        named name: String,
        template: ProfileTemplate?,
        for application: ManagedApplication
    ) throws -> LaunchProfile {
        var profile = LaunchProfile(
            name: name,
            argumentsText: template?.argumentsText ?? "",
            environmentText: template?.environmentText ?? "",
            notes: template?.notes ?? ""
        )
        profile = try applyingRecommendedSettings(
            to: profile,
            for: application
        )
        return profile
    }

    private func applyingRecommendedSettings(
        to profile: LaunchProfile,
        for application: ManagedApplication,
        replacingExistingIsolation: Bool = false
    ) throws -> LaunchProfile {
        var migratedProfile = profile

        let preset = Self.resolvedPreset(for: application)
        let paths = try managedPaths(for: application, profile: migratedProfile)

        if preset.needsCodexHome, replacingExistingIsolation || Self.environmentValue("CODEX_HOME", in: profile) == nil {
            migratedProfile.environmentText = Self.settingEnvironmentValue(
                "CODEX_HOME",
                to: paths.codexHome.url.path,
                in: migratedProfile.environmentText
            )
            migratedProfile.isolationOwnership.codexHome = .generated
        }

        if preset.supportsUserDataDir,
           replacingExistingIsolation || Self.userDataDirectoryArgumentValue(in: profile) == nil {
            migratedProfile.argumentsText = Self.settingArgument(
                named: "--user-data-dir",
                to: paths.userData.url.path,
                in: migratedProfile.argumentsText
            )
            migratedProfile.isolationOwnership.userData = .generated
        }

        if preset.needsCodexHome, profile.notes.isEmpty || profile.notes.contains("Chromium-family apps") {
            migratedProfile.notes = String(localized: "Codex stores account state in CODEX_HOME, so Parallax sets a separate Codex home in addition to --user-data-dir.")
        }

        return migratedProfile
    }

    private static func nextProfileName(for application: ManagedApplication?, templates: [String]) -> String {
        guard let application else {
            return String(localized: "New Profile")
        }
        let existingNames = Set(application.profiles.map(\.name))

        if let templateName = templates.first(where: { !existingNames.contains($0) }) {
            return templateName
        }

        var index = 2
        while existingNames.contains(
            String(localized: "Profile \(index)")
        ) {
            index += 1
        }
        return String(localized: "Profile \(index)")
    }

    private static func uniqueProfileName(basedOn name: String, existingProfiles: [LaunchProfile]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? String(localized: "Profile") : trimmed
        let existingNames = Set(existingProfiles.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return String(localized: "\(baseName) \(index)")
    }

    private func matchesApplication(
        _ application: ManagedApplication,
        appPath: String,
        bundleIdentifier: String?
    ) -> Bool {
        if let bundleIdentifier,
           !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           application.bundleIdentifier == bundleIdentifier {
            return true
        }

        return normalizedApplicationPath(application.appPath) == normalizedApplicationPath(appPath)
    }

    private func normalizedApplicationPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return (try? fileSystem.canonicalURL(for: url))?.path
            ?? url.standardizedFileURL.path
    }

    private static func appendingEnvironmentLine(_ line: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : "\(trimmed)\n\(line)"
    }

    private static func appendingArgument(_ argument: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? argument : "\(trimmed) \(argument)"
    }

    private static func settingEnvironmentValue(_ key: String, to value: String, in text: String) -> String {
        var didReplace = false
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            let string = String(line)
            guard environmentKey(in: string) == key else { return string }
            didReplace = true
            return "\(key)=\(value)"
        }
        let updated = lines.joined(separator: "\n")
        return didReplace ? updated : appendingEnvironmentLine("\(key)=\(value)", to: text)
    }

    private static func settingArgument(named name: String, to value: String, in text: String) -> String {
        let replacement = "\(name)=\(value)"
        var didReplace = false
        let arguments = ShellWordsParser.parse(text).map { argument -> String in
            guard argument.hasPrefix("\(name)=") else { return argument }
            didReplace = true
            return replacement
        }

        if didReplace {
            return arguments.map(ShellWordsParser.quote).joined(separator: " ")
        }

        return appendingArgument(ShellWordsParser.quote(replacement), to: text)
    }

    private static func environmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }

        let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    nonisolated private static func environmentValue(
        _ key: String,
        in profile: LaunchProfile
    ) -> String? {
        guard
            let value = LaunchEnvironmentParser.parse(
                profile.environmentText
            ).effectiveValues[key],
            !value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else { return nil }
        return value
    }

    nonisolated private static func userDataDirectoryArgumentValue(
        in profile: LaunchProfile
    ) -> String? {
        userDataDirectoryResolution(
            in: profile.argumentsText
        ).resolvedValue
    }

    nonisolated private static func userDataDirectoryResolution(
        in text: String
    ) -> UserDataDirectoryResolution {
        let parsed = LaunchArgumentParser.parse(text)
        let resolution = UserDataDirectoryOptionResolver.resolve(
            in: parsed.tokens
        )
        return UserDataDirectoryResolution(
            occurrences: resolution.occurrences,
            diagnostics:
                parsed.diagnostics + resolution.diagnostics
        )
    }

    private static func userDataDirectoryConfiguration(
        in text: String
    ) -> IsolationOptionConfiguration {
        let parsed = LaunchArgumentParser.parse(text)
        let resolution = UserDataDirectoryOptionResolver.resolve(
            in: parsed.tokens
        )
        return IsolationOptionConfiguration(
            occurrences: resolution.occurrences.map {
                "\($0.form.rawValue):\($0.value)"
            },
            diagnosticCodes: resolution.diagnostics.map(\.code)
        )
    }

    private static func environmentConfiguration(
        _ key: String,
        in text: String
    ) -> LaunchEnvironmentOperation? {
        LaunchEnvironmentParser.parse(text).effectiveOperations[key]
    }

    private func profileHealthInput(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> ProfileHealthInput {
        let expander = PathSpecificTildeExpander(
            homeDirectory:
                FileManager.default.homeDirectoryForCurrentUser.path
        )
        var isolationPaths: [ProfileIsolationHealthInput] = []
        switch profile.isolationOwnership.userData {
        case .generated:
            isolationPaths.append(
                ProfileIsolationHealthInput(
                    role: .managedUserData,
                    source: .managedUserData
                )
            )
        case .explicit, .legacyUnknown:
            if let configured = Self
                .userDataDirectoryArgumentValue(in: profile)
            {
                isolationPaths.append(
                    ProfileIsolationHealthInput(
                        role: .externalUserData,
                        source: .external(
                            expander.argumentValue(
                                configured,
                                forOption: "--user-data-dir"
                            )
                        )
                    )
                )
            }
        }
        switch profile.isolationOwnership.codexHome {
        case .generated:
            isolationPaths.append(
                ProfileIsolationHealthInput(
                    role: .managedCodexHome,
                    source: .managedCodexHome
                )
            )
        case .explicit, .legacyUnknown:
            if let configured = Self.environmentValue(
                "CODEX_HOME",
                in: profile
            ) {
                isolationPaths.append(
                    ProfileIsolationHealthInput(
                        role: .externalCodexHome,
                        source: .external(
                            expander.environmentValue(
                                configured,
                                forKey: "CODEX_HOME"
                            )
                        )
                    )
                )
            }
        }
        return ProfileHealthInput(
            applicationID: application.id,
            profileID: profile.id,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID,
            configuredBaseRoot: configuredBaseRoot(for: application),
            isolationPaths: isolationPaths
        )
    }

    private func healthInspectionSource(
        for application: ManagedApplication,
        profile: LaunchProfile
    ) -> HealthInspectionSource {
        HealthInspectionSource(
            application: application,
            profile: profile,
            preset: Self.resolvedPreset(for: application),
            applicationInput: ApplicationHealthInput(
                applicationID: application.id,
                applicationURL: URL(fileURLWithPath: application.appPath),
                expectedBundleIdentifier: application.bundleIdentifier
            ),
            profileInputs: application.profiles.map {
                profileHealthInput(for: application, profile: $0)
            }
        )
    }

    nonisolated private static func isHealthyPath(
        _ path: ProfileHealthPathReport
    ) -> Bool {
        path.state == .existingDirectory
            || path.state == .missingCreatable
    }

    private func moveToArchive(
        source: ManagedProfileRootPath,
        archiveRoot: ManagedArchiveRootPath
    ) throws -> ManagedArchiveEntryPath {
        var destination = archiveRoot.entry()
        while fileSystem.fileExists(at: destination.url) {
            destination = archiveRoot.entry()
        }
        let archiveDirectoryURL = try pathResolver.revalidateForMutation(archiveRoot)
        try fileSystem.createDirectory(
            at: archiveDirectoryURL,
            withIntermediateDirectories: true
        )
        try moveManagedItem(at: source, to: destination)
        return destination
    }

    private func removeManagedItem(at path: any ManagedMutationPath) throws {
        let url = try pathResolver.revalidateForMutation(path)
        try fileSystem.removeItem(at: url)
    }

    private func copyManagedItem(
        at source: any ManagedMutationPath,
        to destination: any ManagedMutationPath
    ) throws {
        let sourceURL = try pathResolver.revalidateForMutation(source)
        let destinationURL = try pathResolver.revalidateForMutation(destination)
        try fileSystem.copyItem(at: sourceURL, to: destinationURL)
    }

    private func moveManagedItem(
        at source: any ManagedMutationPath,
        to destination: any ManagedMutationPath
    ) throws {
        let sourceURL = try pathResolver.revalidateForMutation(source)
        let destinationURL = try pathResolver.revalidateForMutation(destination)
        try fileSystem.moveItem(at: sourceURL, to: destinationURL)
    }

    private static let launchTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private struct PendingLibraryImport {
        let sourceSHA256: String
        let expectedVersion: LibraryVersionToken?
        let applications: [ManagedApplication]
        let canonicalApplications: [LibraryImportApplication]
        let warnings: [String]
    }

    private struct PendingImportedLaunch {
        let applicationID: UUID
        let profileID: UUID
        let review: ImportedLaunchReview
    }

    private struct PendingLaunchDiagnosticRequest {
        let source: LaunchConfigurationSource
        let profileName: String
        let fingerprint: LaunchConfigurationFingerprint
        let diagnostics: [LaunchCompilerDiagnostic]
    }

    private struct PendingConcurrentLaunchRequest {
        let source: LaunchConfigurationSource
        let profileName: String
        let fingerprint: LaunchConfigurationFingerprint
    }

    private struct IsolationOptionConfiguration: Equatable {
        let occurrences: [String]
        let diagnosticCodes: [LaunchParsingDiagnosticCode]
    }

    private struct HealthCacheKey: Hashable {
        let application: ManagedApplication
        let profileID: UUID
    }

    private struct HealthInspectionSource: Sendable {
        let application: ManagedApplication
        let profile: LaunchProfile
        let preset: AppPreset
        let applicationInput: ApplicationHealthInput
        let profileInputs: [ProfileHealthInput]
    }
}
