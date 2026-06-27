import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class LibraryStore {
    static let defaultProfileTemplateNames = AppSettings.defaultProfileTemplateNames
    static let defaultProfilesRootPath = "~/Library/Application Support/Parallax/Profiles"

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
    private var pendingImportedApplications: [ManagedApplication]?
    private var pendingLaunchRequest: LaunchRequest?

    var pendingLaunchProfileName: String? {
        guard let request = pendingLaunchRequest else { return nil }
        return launchTarget(for: request)?.profile.name ?? request.profileName
    }

    private let persistence: LibraryPersistence
    private let launcher: ApplicationLaunching
    var settings: AppSettings

    init(
        persistence: LibraryPersistence = LibraryPersistence(),
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        settings: AppSettings = AppSettings()
    ) {
        self.persistence = persistence
        self.launcher = launcher
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
        guard url.pathExtension == "app" else {
            errorMessage = String(localized: "The selected item is not an application bundle.")
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = String(localized: "The selected application could not be found.")
            return
        }

        let appURL = url.standardizedFileURL
        let bundle = Bundle(url: appURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent

        if let existingIndex = applications.firstIndex(where: {
            Self.matchesApplication($0, appPath: appURL.path, bundleIdentifier: bundle?.bundleIdentifier)
        }) {
            selectedApplicationID = applications[existingIndex].id
            selectedProfileID = applications[existingIndex].profiles.first?.id
            launchStatusMessage = String(localized: "\(displayName) is already in the library.")
            return
        }

        let trimmedDefaultBase = settings.defaultBaseStoragePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBasePath = trimmedDefaultBase.isEmpty ? nil : trimmedDefaultBase
        let app = ManagedApplication(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            appPath: appURL.path,
            preset: .automatic,
            baseStoragePath: resolvedBasePath,
            profiles: [Self.defaultProfile(
                for: displayName,
                bundleIdentifier: bundle?.bundleIdentifier,
                baseStoragePath: resolvedBasePath
            )]
        )

        applications.append(app)
        selectedApplicationID = app.id
        selectedProfileID = app.profiles.first?.id
        save()
    }

    func removeSelectedApplication() {
        guard let selectedApplicationID else { return }
        applications.removeAll { $0.id == selectedApplicationID }
        self.selectedApplicationID = applications.first?.id
        selectedProfileID = applications.first?.profiles.first?.id
        save()
    }

    func addProfile() {
        addProfile(named: Self.nextProfileName(for: selectedApplication, templates: profileTemplateNames))
    }

    func addProfile(named name: String) {
        guard let index = selectedApplicationIndex else { return }
        let template = profileTemplates.first { $0.name == name }
        let profileName = Self.uniqueProfileName(
            basedOn: name,
            existingProfiles: applications[index].profiles
        )
        let profile = Self.profile(named: profileName, template: template, for: applications[index])
        applications[index].profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func duplicateSelectedProfile() {
        guard
            let appIndex = selectedApplicationIndex,
            let profile = selectedProfile
        else { return }

        var copy = profile
        copy.id = UUID()
        copy.name = Self.uniqueProfileName(
            basedOn: String(localized: "\(profile.name) Copy"),
            existingProfiles: applications[appIndex].profiles
        )
        copy.storageName = Self.uniqueStorageName(
            basedOn: copy.name,
            existingProfiles: applications[appIndex].profiles
        )
        copy = Self.applyingRecommendedSettings(
            to: copy,
            for: applications[appIndex],
            replacingExistingIsolation: true
        )
        applications[appIndex].profiles.append(copy)
        selectedProfileID = copy.id
        save()
        duplicateProfileData(from: profile, to: copy, application: applications[appIndex])
    }

    func removeSelectedProfile(dataRemoval: ProfileDataRemoval = .keep) {
        guard
            let selectedProfile = selectedProfile
        else { return }

        remove(profile: selectedProfile, dataRemoval: dataRemoval)
    }

    func remove(profile: LaunchProfile, dataRemoval: ProfileDataRemoval) {
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        let application = applications[appIndex]
        let profileToRemove = applications[appIndex].profiles[profileIndex]

        switch dataRemoval {
        case .keep:
            break
        case .archive:
            archiveProfileData(for: application, profile: profileToRemove)
        case .delete:
            deleteProfileData(for: application, profile: profileToRemove)
        }

        applications[appIndex].profiles.remove(at: profileIndex)
        self.selectedProfileID = applications[appIndex].profiles.first?.id
        save()
    }

    func updateApplication(_ application: ManagedApplication) {
        guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
        var updated = application
        updated.profiles = updated.profiles.map {
            Self.applyingRecommendedSettings(to: $0, for: updated, replacingExistingIsolation: true)
        }
        applications[index] = updated
        save()
    }

    func updateProfile(_ profile: LaunchProfile) {
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        applications[appIndex].profiles[profileIndex] = profile
        save()
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
                            self.save()
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
        var items: [(label: String, isHealthy: Bool)] = [
            (String(localized: "Profile folder"), FileManager.default.fileExists(atPath: profileFolderPath(for: application, profile: profile)))
        ]

        if preset.supportsUserDataDir {
            let hasUserDataDir = hasUserDataDirectoryConfigured(in: profile)
            items.append((String(localized: "User data flag"), hasUserDataDir))
            items.append((String(localized: "User data folder"), hasUserDataDir && (userDataPath(for: application, profile: profile).map { FileManager.default.fileExists(atPath: $0) } ?? false)))
        }

        if preset.needsCodexHome {
            let hasCodexHome = hasCodexHomeConfigured(in: profile)
            items.append(("CODEX_HOME", hasCodexHome))
            items.append((String(localized: "Codex home folder"), hasCodexHome && (codexHomePath(for: application, profile: profile).map { FileManager.default.fileExists(atPath: $0) } ?? false)))
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
        NSString(string: Self.profileDirectory(for: application, profile: profile)).expandingTildeInPath
    }

    func codexHomePath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).needsCodexHome else { return nil }
        let path = Self.environmentValue("CODEX_HOME", in: profile)
            ?? "\(Self.profileDirectory(for: application, profile: profile))/CodexHome"
        return NSString(string: path).expandingTildeInPath
    }

    func userDataPath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).supportsUserDataDir else { return nil }
        let path = Self.userDataDirectoryArgumentValue(in: profile)
            ?? "\(Self.profileDirectory(for: application, profile: profile))/UserData"
        return NSString(string: path).expandingTildeInPath
    }

    func revealProfileFolder(for application: ManagedApplication, profile: LaunchProfile) {
        revealFolder(at: profileFolderPath(for: application, profile: profile))
    }

    func revealCodexHome(for application: ManagedApplication, profile: LaunchProfile) {
        guard let path = codexHomePath(for: application, profile: profile) else { return }
        revealFolder(at: path)
    }

    func revealUserData(for application: ManagedApplication, profile: LaunchProfile) {
        guard let path = userDataPath(for: application, profile: profile) else { return }
        revealFolder(at: path)
    }

    func clearProfileData(for application: ManagedApplication, profile: LaunchProfile) {
        let path = profileFolderPath(for: application, profile: profile)

        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try Self.moveToArchive(atPath: path)
            }
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
            launchStatusMessage = String(localized: "Archived and cleared data for \(profile.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateProfileData(from source: LaunchProfile, to destination: LaunchProfile, application: ManagedApplication) {
        let sourcePath = profileFolderPath(for: application, profile: source)
        let destinationPath = profileFolderPath(for: application, profile: destination)

        do {
            if FileManager.default.fileExists(atPath: sourcePath) {
                if FileManager.default.fileExists(atPath: destinationPath) {
                    try FileManager.default.removeItem(atPath: destinationPath)
                }
                try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
            } else {
                if FileManager.default.fileExists(atPath: destinationPath) {
                    try FileManager.default.removeItem(atPath: destinationPath)
                }
                try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
            }
            launchStatusMessage = String(localized: "Copied profile data to \(destination.name)")
        } catch {
            if FileManager.default.fileExists(atPath: destinationPath) == false {
                try? FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
            }
            errorMessage = error.localizedDescription
        }
    }

    func useCodexHome(_ url: URL, for profile: LaunchProfile) {
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
        save()
    }

    func applyRecommendedSettings(to profile: LaunchProfile) {
        guard
            let appIndex = selectedApplicationIndex,
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
        else { return }

        applications[appIndex].profiles[profileIndex] = Self.applyingRecommendedSettings(
            to: profile,
            for: applications[appIndex],
            replacingExistingIsolation: false
        )
        save()
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
            try data.write(to: url, options: [.atomic])
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
            let data = try Data(contentsOf: url)
            let imported = try LibraryPersistence.decodeApplications(from: data)
            pendingImportedApplications = Self.migratingApplications(imported)
            isShowingImportChoice = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmImport(replacing: Bool) {
        guard let imported = pendingImportedApplications else { return }
        pendingImportedApplications = nil
        isShowingImportChoice = false

        if replacing {
            applications = imported
        } else {
            applications = Self.mergingApplications(into: applications, from: imported)
        }
        selectedApplicationID = applications.first?.id
        selectedProfileID = applications.first?.profiles.first?.id
        save()
        launchStatusMessage = String(localized: "Imported library")
    }

    func cancelImport() {
        pendingImportedApplications = nil
        isShowingImportChoice = false
    }

    private var selectedApplicationIndex: Int? {
        guard let selectedApplicationID else { return nil }
        return applications.firstIndex { $0.id == selectedApplicationID }
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
            let loaded = try persistence.load()
            let migrated = Self.migratingApplications(loaded)
            applications = migrated
            selectedApplicationID = applications.first?.id
            selectedProfileID = applications.first?.profiles.first?.id
            if migrated != loaded {
                AppLog.persistence.info("Library migrated on load, saving")
                save()
            }
        } catch {
            AppLog.persistence.error("Failed to load library: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try persistence.save(applications)
        } catch {
            AppLog.persistence.error("Failed to save library: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func revealFolder(at path: String) {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archiveProfileData(for application: ManagedApplication, profile: LaunchProfile) {
        let path = profileFolderPath(for: application, profile: profile)
        guard FileManager.default.fileExists(atPath: path) else { return }

        do {
            _ = try Self.moveToArchive(atPath: path)
            launchStatusMessage = String(localized: "Archived data for \(profile.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProfileData(for application: ManagedApplication, profile: LaunchProfile) {
        let path = profileFolderPath(for: application, profile: profile)
        guard FileManager.default.fileExists(atPath: path) else { return }

        do {
            try FileManager.default.removeItem(atPath: path)
            launchStatusMessage = String(localized: "Deleted data for \(profile.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func defaultProfile(for displayName: String, bundleIdentifier: String?, baseStoragePath: String?) -> LaunchProfile {
        let preset = AppPreset.detected(displayName: displayName, bundleIdentifier: bundleIdentifier)

        if preset.supportsUserDataDir {
            let placeholderApplication = ManagedApplication(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                appPath: "",
                preset: preset,
                baseStoragePath: baseStoragePath,
                profiles: []
            )
            let profile = LaunchProfile(name: "Personal", storageName: "Personal")
            let profileDirectory = profileDirectory(for: placeholderApplication, profile: profile)
            return LaunchProfile(
                name: "Personal",
                argumentsText: "--user-data-dir=\"\(profileDirectory)/UserData\"",
                environmentText: preset.needsCodexHome ? "CODEX_HOME=\(profileDirectory)/CodexHome" : "",
                notes: preset.needsCodexHome
                    ? String(localized: "Codex stores account state in CODEX_HOME, so Parallax sets a separate Codex home in addition to --user-data-dir.")
                    : String(localized: "Apps built on Chromium or Electron often support isolated profiles with --user-data-dir."),
                storageName: "Personal"
            )
        }

        return LaunchProfile(
            name: "Default",
            notes: String(localized: "This app may reuse its normal macOS container, Keychain items, or account store unless it supports profile-specific launch arguments.")
        )
    }

    private static func migratingApplications(_ applications: [ManagedApplication]) -> [ManagedApplication] {
        applications.map { application in
            var migrated = application
            var existingProfiles: [LaunchProfile] = []
            migrated.profiles = migrated.profiles.map { profile in
                var migratedProfile = profile
                if migratedProfile.storageName == nil {
                    migratedProfile.storageName = uniqueStorageName(
                        basedOn: migratedProfile.name,
                        existingProfiles: existingProfiles
                    )
                }
                migratedProfile = applyingRecommendedSettings(to: migratedProfile, for: application)
                existingProfiles.append(migratedProfile)
                return migratedProfile
            }
            return migrated
        }
    }

    private static func mergingApplications(into existing: [ManagedApplication], from imported: [ManagedApplication]) -> [ManagedApplication] {
        var result = existing
        for importedApp in imported {
            if let existingIndex = result.firstIndex(where: {
                matchesApplication($0, appPath: importedApp.appPath, bundleIdentifier: importedApp.bundleIdentifier)
            }) {
                var mergedApp = result[existingIndex]
                let existingProfileNames = Set(mergedApp.profiles.map(\.name))
                for importedProfile in importedApp.profiles where !existingProfileNames.contains(importedProfile.name) {
                    var profile = importedProfile
                    profile.id = UUID()
                    profile.storageName = uniqueStorageName(
                        basedOn: importedProfile.name,
                        existingProfiles: mergedApp.profiles
                    )
                    profile = applyingRecommendedSettings(
                        to: profile,
                        for: mergedApp,
                        replacingExistingIsolation: true
                    )
                    mergedApp.profiles.append(profile)
                }
                result[existingIndex] = mergedApp
            } else {
                result.append(importedApp)
            }
        }
        return result
    }

    private static func resolvedPreset(for application: ManagedApplication) -> AppPreset {
        application.preset == .automatic
            ? AppPreset.detected(displayName: application.displayName, bundleIdentifier: application.bundleIdentifier)
            : application.preset
    }

    private static func profileDirectory(for application: ManagedApplication, profile: LaunchProfile) -> String {
        let trimmed = application.baseStoragePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rootPath = trimmed.isEmpty ? Self.defaultProfilesRootPath : trimmed
        let appFolderName = sanitizedFolderName(application.displayName)
        let profileFolderName = profile.storageName ?? sanitizedFolderName(profile.name)
        return "\(rootPath)/\(appFolderName)/\(profileFolderName)"
    }

    private static func profile(named name: String, template: ProfileTemplate?, for application: ManagedApplication) -> LaunchProfile {
        let storageName = uniqueStorageName(
            basedOn: name,
            existingProfiles: application.profiles
        )
        var profile = LaunchProfile(
            name: name,
            argumentsText: template?.argumentsText ?? "",
            environmentText: template?.environmentText ?? "",
            notes: template?.notes ?? "",
            storageName: storageName
        )
        profile = applyingRecommendedSettings(
            to: profile,
            for: application
        )
        return profile
    }

    private static func applyingRecommendedSettings(
        to profile: LaunchProfile,
        for application: ManagedApplication,
        replacingExistingIsolation: Bool = false
    ) -> LaunchProfile {
        var migratedProfile = profile
        if migratedProfile.storageName == nil {
            migratedProfile.storageName = sanitizedFolderName(profile.name)
        }

        let preset = resolvedPreset(for: application)

        if preset.needsCodexHome, replacingExistingIsolation || environmentValue("CODEX_HOME", in: profile) == nil {
            migratedProfile.environmentText = settingEnvironmentValue(
                "CODEX_HOME",
                to: "\(profileDirectory(for: application, profile: migratedProfile))/CodexHome",
                in: migratedProfile.environmentText
            )
        }

        if preset.supportsUserDataDir,
           replacingExistingIsolation || userDataDirectoryArgumentValue(in: profile) == nil {
            migratedProfile.argumentsText = settingArgument(
                named: "--user-data-dir",
                to: "\(profileDirectory(for: application, profile: migratedProfile))/UserData",
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

    private static func sanitizedFolderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return sanitized.isEmpty ? "Profile" : sanitized
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

    private static func uniqueStorageName(basedOn name: String, existingProfiles: [LaunchProfile]) -> String {
        let baseName = sanitizedFolderName(name)
        let existingNames = Set(existingProfiles.map { $0.storageName ?? sanitizedFolderName($0.name) })
        guard existingNames.contains(baseName) else { return baseName }

        var index = 2
        while existingNames.contains("\(baseName)-\(index)") {
            index += 1
        }
        return "\(baseName)-\(index)"
    }

    private static func matchesApplication(_ application: ManagedApplication, appPath: String, bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier,
           !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           application.bundleIdentifier == bundleIdentifier {
            return true
        }

        return normalizedApplicationPath(application.appPath) == normalizedApplicationPath(appPath)
    }

    private static func normalizedApplicationPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
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

    private static func archivePath(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let folder = (path as NSString).lastPathComponent
        let archiveDirectory = "\(parent)/Archives"
        let stamp = archiveDateFormatter.string(from: Date())
        let basePath = "\(archiveDirectory)/\(folder)-\(stamp)"
        var candidate = basePath
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(basePath)-\(suffix)"
            suffix += 1
        }

        return candidate
    }

    private static func moveToArchive(atPath path: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: ((archivePath(for: path) as NSString).deletingLastPathComponent),
            withIntermediateDirectories: true
        )
        var destination = archivePath(for: path)
        var attempts = 0
        while true {
            do {
                try FileManager.default.moveItem(atPath: path, toPath: destination)
                return destination
            } catch {
                attempts += 1
                if attempts > 8 { throw error }
                destination = archivePath(for: path)
            }
        }
    }

    private static let launchTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private struct LaunchRequest {
        var applicationID: ManagedApplication.ID
        var profileID: LaunchProfile.ID
        var profileName: String
    }
}
