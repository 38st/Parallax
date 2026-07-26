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

    enum ProfileDataRemoval {
        case keep
        case archive
        case delete
    }

    var applications: [ManagedApplication] = []
    var selectedApplicationID: ManagedApplication.ID?
    var selectedProfileID: LaunchProfile.ID?
    var errorMessage: String?
    var launchStatusMessage: String?
    var isShowingAppImporter = false
    var isShowingLaunchConfirmation = false
    var isShowingImportChoice = false
    private(set) var migrationRequiredLibrary: LegacyLibrary?
    private var pendingImportedApplications: [ManagedApplication]?
    private var pendingLaunchRequest: LaunchRequest?

    var pendingLaunchProfileName: String? {
        guard let request = pendingLaunchRequest else { return nil }
        return launchTarget(for: request)?.profile.name ?? request.profileName
    }

    private let persistence: any LibraryPersisting
    private let launcher: ApplicationLaunching
    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    var settings: AppSettings

    init(
        persistence: (any LibraryPersisting)? = nil,
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        fileSystem: any FileSystem = LocalFileSystem(),
        settings: AppSettings = AppSettings()
    ) {
        self.persistence = persistence ?? LibraryPersistence(fileSystem: fileSystem)
        self.launcher = launcher
        self.fileSystem = fileSystem
        self.pathResolver = ManagedPathResolver(fileSystem: fileSystem)
        self.settings = settings
        load()
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

        applications.append(app)
        selectedApplicationID = app.id
        selectedProfileID = app.profiles.first?.id
        _ = save()
    }

    func removeSelectedApplication() {
        guard canMutateLibrary() else { return }
        guard let selectedApplicationID else { return }
        applications.removeAll { $0.id == selectedApplicationID }
        self.selectedApplicationID = applications.first?.id
        selectedProfileID = applications.first?.profiles.first?.id
        _ = save()
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
        applications[index].profiles.append(profile)
        selectedProfileID = profile.id
        _ = save()
    }

    @discardableResult
    func duplicateSelectedProfile() -> Bool {
        guard canMutateLibrary() else { return false }
        guard
            let appIndex = selectedApplicationIndex,
            let profile = selectedProfile
        else { return false }
        let applicationsBeforeMutation = applications
        let selectedProfileIDBeforeMutation = selectedProfileID

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
        applications[appIndex].profiles.append(copy)
        selectedProfileID = copy.id
        guard save() else {
            applications = applicationsBeforeMutation
            selectedProfileID = selectedProfileIDBeforeMutation
            return false
        }
        guard duplicateProfileData(
            from: profile,
            to: copy,
            application: applications[appIndex]
        ) else {
            let copyError = errorMessage
            applications = applicationsBeforeMutation
            selectedProfileID = selectedProfileIDBeforeMutation
            if save() {
                errorMessage = copyError
            } else if let copyError {
                errorMessage = String(
                    localized: "\(copyError) The duplicate profile record could not be rolled back."
                )
            }
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
        let applicationsBeforeMutation = applications
        let selectedProfileIDBeforeMutation = selectedProfileID
        var archivedMove: (
            source: ManagedProfileRootPath,
            destination: ManagedArchiveEntryPath
        )?
        errorMessage = nil
        launchStatusMessage = nil

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
                try deleteProfileData(for: application, profile: profileToRemove)
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        applications[appIndex].profiles.remove(at: profileIndex)
        self.selectedProfileID = applications[appIndex].profiles.first?.id
        guard save() else {
            applications = applicationsBeforeMutation
            selectedProfileID = selectedProfileIDBeforeMutation
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
            launchStatusMessage = String(localized: "Deleted data for \(profileToRemove.name)")
        }
        return true
    }

    func updateApplication(_ application: ManagedApplication) {
        guard canMutateLibrary() else { return }
        guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
        let persisted = applications[index]
        var updated = application.preservingIdentity(of: persisted)
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
        do {
            updated.profiles = try updated.profiles.map {
                try applyingRecommendedSettings(
                    to: $0,
                    for: updated,
                    replacingExistingIsolation: true
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        applications[index] = updated
        _ = save()
    }

    func updateProfile(_ profile: LaunchProfile) {
        guard canMutateLibrary() else { return }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        let persisted = applications[appIndex].profiles[profileIndex]
        applications[appIndex].profiles[profileIndex] = profile.preservingIdentity(of: persisted)
        _ = save()
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
        selectedApplicationID = applicationID
        selectedProfileID = profile.id
        AppLog.launch.info("Launching profile \(profileName) for \(application.displayName)")

        do {
            try launcher.launch(application: application, profile: profile) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        guard let self else { return }
                        let now = Date()
                        if let appIndex = self.applications.firstIndex(where: { $0.id == applicationID }),
                           let profileIndex = self.applications[appIndex].profiles.firstIndex(where: { $0.id == profileID }) {
                            self.applications[appIndex].profiles[profileIndex].lastLaunchedAt = now
                            guard self.save() else { return }
                        }
                        AppLog.launch.info("Successfully launched \(profileName)")
                        self.launchStatusMessage = String(localized: "Launched \(profileName) at \(Self.launchTimeFormatter.string(from: now))")
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

        return warnings
    }

    func hasCodexHomeConfigured(in profile: LaunchProfile) -> Bool {
        Self.environmentValue("CODEX_HOME", in: profile) != nil
    }

    func hasUserDataDirectoryConfigured(in profile: LaunchProfile) -> Bool {
        Self.userDataDirectoryArgumentValue(in: profile) != nil
    }

    func healthItems(for application: ManagedApplication, profile: LaunchProfile) -> [(label: String, isHealthy: Bool)] {
        let preset = Self.resolvedPreset(for: application)
        let paths = try? managedPaths(for: application, profile: profile)
        var items: [(label: String, isHealthy: Bool)] = [
            (
                String(localized: "Profile folder"),
                paths.map { isDirectory(at: $0.profileRoot.url) } ?? false
            )
        ]

        if preset.supportsUserDataDir {
            let hasUserDataDir = hasUserDataDirectoryConfigured(in: profile)
            items.append((String(localized: "User data flag"), hasUserDataDir))
            items.append((
                String(localized: "User data folder"),
                hasUserDataDir && (
                    userDataPath(for: application, profile: profile)
                        .map { isDirectory(at: URL(fileURLWithPath: $0)) } ?? false
                )
            ))
        }

        if preset.needsCodexHome {
            let hasCodexHome = hasCodexHomeConfigured(in: profile)
            items.append(("CODEX_HOME", hasCodexHome))
            items.append((
                String(localized: "Codex home folder"),
                hasCodexHome && (
                    codexHomePath(for: application, profile: profile)
                        .map { isDirectory(at: URL(fileURLWithPath: $0)) } ?? false
                )
            ))
        }

        return items
    }

    func resolvedArguments(for profile: LaunchProfile) -> [String] {
        profile.arguments.map(WorkspaceApplicationLauncher.expandingTildeInArgument)
    }

    func resolvedEnvironment(for profile: LaunchProfile) -> [(key: String, value: String)] {
        profile.environment
            .map { key, value in
                (key: key, value: NSString(string: value).expandingTildeInPath)
            }
            .sorted { $0.key < $1.key }
    }

    func profileFolderPath(for application: ManagedApplication, profile: LaunchProfile) -> String {
        do {
            return try managedPaths(for: application, profile: profile).profileRoot.url.path
        } catch {
            errorMessage = error.localizedDescription
            return ""
        }
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
                return try pathResolver.resolveExternalPath(configured).url.path
            }
            return try managedPaths(for: application, profile: profile).codexHome.url.path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func userDataPath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).supportsUserDataDir else { return nil }
        do {
            if let configured = Self.userDataDirectoryArgumentValue(in: profile) {
                return try pathResolver.resolveExternalPath(configured).url.path
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
                let external = try pathResolver.resolveExternalPath(configured)
                if external.url.path != paths.codexHome.url.path {
                    return revealExternalFolder(external)
                }
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
            if let configured = Self.userDataDirectoryArgumentValue(in: profile) {
                let external = try pathResolver.resolveExternalPath(configured)
                if external.url.path != paths.userData.url.path {
                    return revealExternalFolder(external)
                }
            }
            return revealManagedFolder(paths.userData)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearProfileData(for application: ManagedApplication, profile: LaunchProfile) -> Bool {
        errorMessage = nil
        launchStatusMessage = nil

        do {
            let paths = try managedPaths(for: application, profile: profile)
            if fileSystem.fileExists(at: paths.profileRoot.url) {
                _ = try moveToArchive(
                    source: paths.profileRoot,
                    archiveRoot: paths.archiveRoot
                )
            }
            let url = try pathResolver.revalidateForMutation(paths.profileRoot)
            try fileSystem.createDirectory(
                at: url,
                withIntermediateDirectories: true
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
        errorMessage = nil
        launchStatusMessage = nil

        do {
            let sourcePaths = try managedPaths(for: application, profile: source)
            let destinationPaths = try managedPaths(for: application, profile: destination)
            if fileSystem.fileExists(at: sourcePaths.profileRoot.url) {
                if fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
                    try removeManagedItem(at: destinationPaths.profileRoot)
                }
                try copyManagedItem(
                    at: sourcePaths.profileRoot,
                    to: destinationPaths.profileRoot
                )
            } else {
                if fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
                    try removeManagedItem(at: destinationPaths.profileRoot)
                }
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
            if let destinationPaths = try? managedPaths(
                for: application,
                profile: destination
            ), fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
                do {
                    try removeManagedItem(at: destinationPaths.profileRoot)
                } catch {
                    AppLog.profiles.error(
                        "Failed to clean partial duplicate at \(destinationPaths.profileRoot.url.path): \(error.localizedDescription)"
                    )
                }
            }
            errorMessage = error.localizedDescription
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
        applications[appIndex].profiles[profileIndex] = updated
        selectedProfileID = updated.id
        _ = save()
    }

    func applyRecommendedSettings(to profile: LaunchProfile) {
        guard canMutateLibrary() else { return }
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        do {
            applications[appIndex].profiles[profileIndex] = try applyingRecommendedSettings(
                to: profile,
                for: applications[appIndex],
                replacingExistingIsolation: false
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        _ = save()
    }

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parallax Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LibraryDocument(applications: applications))
            try fileSystem.writeDataAtomically(data, to: url)
            launchStatusMessage = String(localized: "Exported library")
        } catch {
            errorMessage = error.localizedDescription
        }
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
            if replacing {
                applications = imported
            } else {
                applications = try mergingApplications(into: applications, from: imported)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        selectedApplicationID = applications.first?.id
        selectedProfileID = applications.first?.profiles.first?.id
        if save() {
            launchStatusMessage = String(localized: "Imported library")
        }
    }

    func cancelImport() {
        pendingImportedApplications = nil
        isShowingImportChoice = false
    }

    private var selectedApplicationIndex: Int? {
        guard let selectedApplicationID else { return nil }
        return applications.firstIndex { $0.id == selectedApplicationID }
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
        do {
            switch try persistence.loadResult() {
            case let .current(loaded):
                try LibraryPersistence.validateCurrentApplications(loaded)
                migrationRequiredLibrary = nil
                applications = loaded
                selectedApplicationID = applications.first?.id
                selectedProfileID = applications.first?.profiles.first?.id
            case let .migrationRequired(legacy):
                migrationRequiredLibrary = legacy
                applications = []
                selectedApplicationID = nil
                selectedProfileID = nil
                errorMessage = LibraryPersistenceError
                    .migrationRequired(format: legacy.format)
                    .localizedDescription
            }
        } catch {
            AppLog.persistence.error("Failed to load library: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard canMutateLibrary() else { return false }
        do {
            try persistence.save(applications)
            return true
        } catch {
            AppLog.persistence.error("Failed to save library: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func canMutateLibrary() -> Bool {
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
            let url = try pathResolver.revalidateForMutation(path)
            try fileSystem.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
        }

        if preset.supportsUserDataDir,
           replacingExistingIsolation || Self.userDataDirectoryArgumentValue(in: profile) == nil {
            migratedProfile.argumentsText = Self.settingArgument(
                named: "--user-data-dir",
                to: paths.userData.url.path,
                in: migratedProfile.argumentsText
            )
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

    private static func environmentValue(_ key: String, in profile: LaunchProfile) -> String? {
        guard let value = profile.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func userDataDirectoryArgumentValue(in profile: LaunchProfile) -> String? {
        for argument in profile.arguments {
            guard argument.hasPrefix("--user-data-dir=") else { continue }
            let value = String(argument.dropFirst("--user-data-dir=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
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
}
