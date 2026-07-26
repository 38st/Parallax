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

private enum BackgroundStorageRelocationResult: Sendable {
    case succeeded(StorageRelocationOutcome)
    case failed(code: StorageRelocationError.Code?, message: String)
}

enum LibraryExportSensitivePolicy: Equatable, Sendable {
    case omit
    case redact
    case include
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
    var selectedApplicationID: ManagedApplication.ID?
    var selectedProfileID: LaunchProfile.ID?
    var errorMessage: String?
    var launchStatusMessage: String?
    var isShowingAppImporter = false
    var isShowingLaunchConfirmation = false
    var isShowingLaunchDiagnosticOverride = false
    var isShowingImportChoice = false
    private(set) var loadState: LoadState = .loading
    private(set) var migrationRequiredLibrary: LegacyLibrary?
    private(set) var pendingProfileRemovalRecovery:
        ProfileRemovalRecovery?
    private var pendingImportedApplications: [ManagedApplication]?
    private var pendingLaunchRequest: LaunchRequest?
    private var pendingLaunchDiagnosticRequest:
        PendingLaunchDiagnosticRequest?

    var pendingLaunchDiagnosticMessage: String? {
        pendingLaunchDiagnosticRequest?.diagnostics
            .map(\.message)
            .joined(separator: "\n")
    }

    var pendingLaunchProfileName: String? {
        guard let request = pendingLaunchRequest else { return nil }
        return launchTarget(for: request)?.profile.name ?? request.profileName
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
    private let profileActivityInitializationError: Error?
    private var libraryVersionToken: LibraryVersionToken?
    private let launcher: ApplicationLaunching
    private let launchConfigurationCompiler: LaunchConfigurationCompiler
    private let launchHealthService: LaunchHealthService
    private let secretStore: any SecretStoring
    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    var settings: AppSettings
    private(set) var storageRelocationPreview: StorageRelocationPreview?
    private(set) var storageRelocationProgress: StorageRelocationProgress?
    private var storageRelocationCancellation: StorageRelocationCancellation?
    private var storageRelocationTask: Task<Void, Never>?
    private var launchPreparationTasks: [UUID: Task<Void, Never>] = [:]
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
        storageRelocationCoordinator: StorageRelocationCoordinator? = nil,
        profileActivityRegistry: ProfileActivityRegistry? = nil,
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        launchConfigurationCompiler: LaunchConfigurationCompiler? = nil,
        secretStore: (any SecretStoring)? = nil,
        fileSystem: any FileSystem = LocalFileSystem(),
        settings: AppSettings = AppSettings()
    ) {
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
        settings.profileTemplateNames.isEmpty ? Self.defaultProfileTemplateNames : settings.profileTemplateNames
    }

    var profileTemplates: [ProfileTemplate] {
        settings.profileTemplates.isEmpty ? ProfileTemplate.defaults : settings.profileTemplates
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

    func beginAddingApplication() {
        isShowingAppImporter = true
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
            matchesApplication($0, appPath: appURL.path, bundleIdentifier: bundle?.bundleIdentifier)
        }) {
            selectedApplicationID = applications[existingIndex].id
            selectedProfileID = applications[existingIndex].profiles.first?.id
            launchStatusMessage = String(localized: "\(displayName) is already in the library.")
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
        guard canMutateLibrary() else { return }
        guard let selectedApplicationID else { return }
        var candidate = applications
        candidate.removeAll { $0.id == selectedApplicationID }
        _ = commit(
            candidate,
            selectedApplicationID: candidate.first?.id,
            selectedProfileID: candidate.first?.profiles.first?.id,
            backupReason: .destructiveRewrite
        )
    }

    func addProfile() {
        addProfile(named: Self.nextProfileName(for: selectedApplication, templates: profileTemplateNames))
    }

    func addProfile(named name: String) {
        guard canMutateLibrary() else { return }
        guard let index = selectedApplicationIndex else { return }
        let template = profileTemplates.first { $0.name == name }
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
        guard canMutateLibrary() else { return false }
        guard
            let appIndex = selectedApplicationIndex,
            let profile = selectedProfile
        else { return false }
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
            application: applications[appIndex]
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
        guard canMutateLibrary() else { return false }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return false }

        let application = applications[appIndex]
        let profileToRemove = applications[appIndex].profiles[profileIndex]
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
        var consumedPersistedProfileIDs = Set<LaunchProfile.ID>()
        updated.profiles = updated.profiles.map { proposed in
            guard
                let persistedProfile = persisted.profiles.first(where: { $0.id == proposed.id }),
                consumedPersistedProfileIDs.insert(persistedProfile.id).inserted
            else {
                return proposed.duplicatedWithFreshIdentity()
            }
            return proposed.preservingIdentity(of: persistedProfile)
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
        if settings.confirmBeforeLaunch {
            pendingLaunchRequest = LaunchRequest(
                applicationID: application.id,
                profileID: profile.id,
                profileName: profile.name
            )
            isShowingLaunchConfirmation = true
            return
        }
        performLaunch(application: application, profile: profile)
    }

    func confirmLaunch() {
        guard let request = pendingLaunchRequest else { return }
        pendingLaunchRequest = nil
        isShowingLaunchConfirmation = false
        guard let target = launchTarget(for: request) else { return }
        performLaunch(application: target.application, profile: target.profile)
    }

    func cancelLaunch() {
        pendingLaunchRequest = nil
        isShowingLaunchConfirmation = false
    }

    private func performLaunch(application: ManagedApplication, profile: LaunchProfile) {
        let applicationID = application.id
        let profileID = profile.id
        let profileName = profile.name
        let requestID = UUID()
        selectedApplicationID = applicationID
        selectedProfileID = profile.id
        launchStatusMessage = nil
        AppLog.launch.info("Launching profile \(profileName) for \(application.displayName)")

        if launcher is any PreparedApplicationLaunching {
            let source = LaunchConfigurationSource(
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
            schedulePreparedLaunch(
                source,
                profileName: profileName,
                override: nil
            )
            return
        }

        do {
            if let trackedLauncher = launcher as? any TrackedApplicationLaunching {
                _ = try trackedLauncher.launchTracked(
                    application: application,
                    profile: profile,
                    requestID: requestID,
                    activityRegistry: profileActivityRegistry
                ) { [weak self] event in
                    Task { @MainActor in
                        switch event {
                        case .requested:
                            break
                        case .running:
                            self?.recordAcceptedLaunch(
                                applicationID: applicationID,
                                profileID: profileID,
                                profileName: profileName
                            )
                        case .terminated:
                            guard let self else { return }
                            self.launchStatusMessage = String(
                                localized: "\(profileName) exited."
                            )
                        case let .failed(_, message):
                            AppLog.launch.error(
                                "Failed to launch \(profileName): \(message)"
                            )
                            self?.errorMessage = message
                        }
                    }
                }
                return
            }
            try launcher.launch(application: application, profile: profile) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        self?.recordAcceptedLaunch(
                            applicationID: applicationID,
                            profileID: profileID,
                            profileName: profileName
                        )
                    case .failure(let error):
                        AppLog.launch.error("Failed to launch \(profileName): \(error.localizedDescription)")
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            AppLog.launch.error("Launch threw for \(profileName): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
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
            )
        )
    }

    func cancelLaunchDiagnosticOverride() {
        pendingLaunchDiagnosticRequest = nil
        isShowingLaunchDiagnosticOverride = false
    }

    private func schedulePreparedLaunch(
        _ source: LaunchConfigurationSource,
        profileName: String,
        override: LaunchDiagnosticOverride?
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
                    profileName: profileName
                )
            } catch is CancellationError {
                // A cancelled request has not reached the opener and does not
                // represent an application launch failure.
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
                AppLog.launch.error(
                    "Launch preparation failed for \(profileName): \(error.localizedDescription)"
                )
                self?.errorMessage = error.localizedDescription
            }
            self?.launchPreparationTasks[source.requestID] = nil
        }
    }

    private func openPreparedLaunch(
        _ prepared: PreparedLaunch,
        profileName: String
    ) throws {
        let applicationID = prepared.applicationID
        let profileID = prepared.profileID
        if let trackedLauncher =
            launcher as? any PreparedTrackedApplicationLaunching
        {
            _ = try trackedLauncher.launchTracked(
                prepared: prepared,
                activityRegistry: profileActivityRegistry
            ) { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .requested:
                        break
                    case .running:
                        self?.recordAcceptedLaunch(
                            applicationID: applicationID,
                            profileID: profileID,
                            profileName: profileName
                        )
                    case .terminated:
                        self?.launchStatusMessage = String(
                            localized: "\(profileName) exited."
                        )
                    case let .failed(_, message):
                        AppLog.launch.error(
                            "Failed to launch \(profileName): \(message)"
                        )
                        self?.errorMessage = message
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
                    self?.recordAcceptedLaunch(
                        applicationID: applicationID,
                        profileID: profileID,
                        profileName: profileName
                    )
                case .failure(let error):
                    AppLog.launch.error(
                        "Failed to launch \(profileName): \(error.localizedDescription)"
                    )
                    self?.errorMessage = error.localizedDescription
                }
            }
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
        launchStatusMessage = String(
            localized: "Launched \(profileName) at \(Self.launchTimeFormatter.string(from: now))"
        )
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
        guard canMutateLibrary() else { return false }
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
        guard canMutateLibrary() else { return false }
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
        var sensitivePolicy = LibraryExportSensitivePolicy.include
        if libraryExportContainsSensitiveLiterals() {
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
                sensitivePolicy = .include
            default:
                return
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parallax Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                libraryDocumentForExport(
                    sensitivePolicy: sensitivePolicy
                )
            )
            try fileSystem.writeDataAtomically(data, to: url)
            launchStatusMessage = String(localized: "Exported library")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func libraryExportContainsSensitiveLiterals() -> Bool {
        applications.contains { application in
            application.profiles.contains { profile in
                let classifier = SensitiveEnvironmentKeyClassifier(
                    explicitSensitiveKeys:
                        Set(profile.sensitiveEnvironmentKeys)
                )
                return LaunchEnvironmentParser.parse(
                    profile.environmentText
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

        do {
            let data = try fileSystem.readData(at: url)
            let imported = try LibraryPersistence.decodeApplications(from: data)
            pendingImportedApplications = imported
            isShowingImportChoice = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmImport(replacing: Bool) {
        guard canMutateLibrary() else { return }
        guard let imported = pendingImportedApplications else { return }
        pendingImportedApplications = nil
        isShowingImportChoice = false

        do {
            let candidate = if replacing {
                imported
            } else {
                try mergingApplications(into: applications, from: imported)
            }
            let candidateApplicationID = candidate.first?.id
            let candidateProfileID = candidate.first?.profiles.first?.id
            if commit(
                candidate,
                selectedApplicationID: candidateApplicationID,
                selectedProfileID: candidateProfileID,
                backupReason: replacing ? .importReplacement : nil
            ) {
                launchStatusMessage = String(localized: "Imported library")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelImport() {
        pendingImportedApplications = nil
        isShowingImportChoice = false
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
            return if case .loaded = loadState { true } else { false }
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
            panel.nameFieldStringValue = "Parallax Recovery Library.json"
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
            return if case .loaded = loadState { true } else { false }
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

    private func launchTarget(for request: LaunchRequest) -> (application: ManagedApplication, profile: LaunchProfile)? {
        guard
            let application = applications.first(where: { $0.id == request.applicationID }),
            let profile = application.profiles.first(where: { $0.id == request.profileID })
        else { return nil }
        return (application, profile)
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

    private func mergingApplications(
        into existing: [ManagedApplication],
        from imported: [ManagedApplication]
    ) throws -> [ManagedApplication] {
        var result = existing
        for importedApp in imported {
            if let existingIndex = result.firstIndex(where: {
                matchesApplication($0, appPath: importedApp.appPath, bundleIdentifier: importedApp.bundleIdentifier)
            }) {
                var mergedApp = result[existingIndex]
                let existingProfileNames = Set(mergedApp.profiles.map(\.name))
                for importedProfile in importedApp.profiles where !existingProfileNames.contains(importedProfile.name) {
                    var profile = importedProfile.duplicatedWithFreshIdentity()
                    profile = try applyingRecommendedSettings(
                        to: profile,
                        for: mergedApp,
                        replacingExistingIsolation: true
                    )
                    mergedApp.profiles.append(profile)
                }
                result[existingIndex] = mergedApp
            } else {
                let existingApplicationIDs = Set(result.map(\.id))
                let existingApplicationStorageIDs = Set(result.map(\.storageID))
                let existingProfileIDs = Set(result.flatMap(\.profiles).map(\.id))
                let existingProfileStorageIDs = Set(result.flatMap(\.profiles).map(\.storageID))
                let importedProfileIDs = Set(importedApp.profiles.map(\.id))
                let importedProfileStorageIDs = Set(importedApp.profiles.map(\.storageID))
                let conflicts = result.contains { existingApplication in
                    existingApplication.id == importedApp.id
                        || existingApplication.storageID == importedApp.storageID
                        || !Set(existingApplication.profiles.map(\.id))
                            .isDisjoint(with: Set(importedApp.profiles.map(\.id)))
                        || !Set(existingApplication.profiles.map(\.storageID))
                            .isDisjoint(with: Set(importedApp.profiles.map(\.storageID)))
                }
                    || existingApplicationIDs.contains(importedApp.id)
                    || existingApplicationStorageIDs.contains(importedApp.storageID)
                    || existingProfileStorageIDs.contains(importedApp.storageID)
                    || !existingProfileIDs.isDisjoint(with: importedProfileIDs)
                    || !existingProfileStorageIDs.isDisjoint(with: importedProfileStorageIDs)
                    || !existingApplicationStorageIDs.isDisjoint(with: importedProfileStorageIDs)
                result.append(
                    conflicts
                        ? importedApp.duplicatedWithFreshIdentity()
                        : importedApp
                )
            }
        }
        return result
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
        guard let application else { return "New Profile" }
        let existingNames = Set(application.profiles.map(\.name))

        if let templateName = templates.first(where: { !existingNames.contains($0) }) {
            return templateName
        }

        var index = 2
        while existingNames.contains("Profile \(index)") {
            index += 1
        }
        return "Profile \(index)"
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
        return "\(baseName) \(index)"
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

    private struct LaunchRequest {
        var applicationID: ManagedApplication.ID
        var profileID: LaunchProfile.ID
        var profileName: String
    }

    private struct PendingLaunchDiagnosticRequest {
        let source: LaunchConfigurationSource
        let profileName: String
        let fingerprint: LaunchConfigurationFingerprint
        let diagnostics: [LaunchCompilerDiagnostic]
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
