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
    private var pendingLaunchProfile: LaunchProfile?

    var pendingLaunchProfileName: String? {
        pendingLaunchProfile?.name
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

        let bundle = Bundle(url: url)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        let trimmedDefaultBase = settings.defaultBaseStoragePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBasePath = trimmedDefaultBase.isEmpty ? nil : trimmedDefaultBase
        let app = ManagedApplication(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            appPath: url.path,
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
        let profile = Self.profile(named: name, for: applications[index])
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
        copy.name = String(localized: "\(profile.name) Copy")
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
        guard let profile = selectedProfile else { return }
        launch(profile)
    }

    func launch(_ profile: LaunchProfile) {
        if settings.confirmBeforeLaunch {
            pendingLaunchProfile = profile
            isShowingLaunchConfirmation = true
            return
        }
        performLaunch(profile)
    }

    func confirmLaunch() {
        guard let profile = pendingLaunchProfile else { return }
        pendingLaunchProfile = nil
        isShowingLaunchConfirmation = false
        performLaunch(profile)
    }

    func cancelLaunch() {
        pendingLaunchProfile = nil
        isShowingLaunchConfirmation = false
    }

    private func performLaunch(_ profile: LaunchProfile) {
        guard
            let application = selectedApplication,
            let selectedApplicationID
        else { return }

        let profileID = profile.id
        let profileName = profile.name
        selectedProfileID = profile.id

        do {
            try launcher.launch(application: application, profile: profile) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        guard let self else { return }
                        let now = Date()
                        if let appIndex = self.applications.firstIndex(where: { $0.id == selectedApplicationID }),
                           let profileIndex = self.applications[appIndex].profiles.firstIndex(where: { $0.id == profileID }) {
                            self.applications[appIndex].profiles[profileIndex].lastLaunchedAt = now
                            self.save()
                        }
                        self.launchStatusMessage = String(localized: "Launched \(profileName) at \(Self.launchTimeFormatter.string(from: now))")
                    case .failure(let error):
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
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

        if preset.needsCodexHome, profile.environment["CODEX_HOME"] == nil {
            warnings.append(String(localized: "Codex profiles need CODEX_HOME to avoid sharing the signed-in account."))
        }

        if preset.supportsUserDataDir,
           !profile.arguments.contains(where: { $0.hasPrefix("--user-data-dir=") }) {
            warnings.append(String(localized: "This app may share browser state unless --user-data-dir is set."))
        }

        return warnings
    }

    func healthItems(for application: ManagedApplication, profile: LaunchProfile) -> [(label: String, isHealthy: Bool)] {
        let preset = Self.resolvedPreset(for: application)
        var items: [(label: String, isHealthy: Bool)] = [
            (String(localized: "Profile folder"), FileManager.default.fileExists(atPath: profileFolderPath(for: application, profile: profile)))
        ]

        if preset.supportsUserDataDir {
            items.append((String(localized: "User data flag"), profile.arguments.contains { $0.hasPrefix("--user-data-dir=") }))
            items.append((String(localized: "User data folder"), userDataPath(for: application, profile: profile).map { FileManager.default.fileExists(atPath: $0) } ?? false))
        }

        if preset.needsCodexHome {
            items.append(("CODEX_HOME", profile.environment["CODEX_HOME"] != nil))
            items.append((String(localized: "Codex home folder"), codexHomePath(for: application, profile: profile).map { FileManager.default.fileExists(atPath: $0) } ?? false))
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
        return NSString(string: "\(Self.profileDirectory(for: application, profile: profile))/CodexHome").expandingTildeInPath
    }

    func userDataPath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
        guard Self.resolvedPreset(for: application).supportsUserDataDir else { return nil }
        return NSString(string: "\(Self.profileDirectory(for: application, profile: profile))/UserData").expandingTildeInPath
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
            applications = Self.migratingApplications(imported)
            selectedApplicationID = applications.first?.id
            selectedProfileID = applications.first?.profiles.first?.id
            save()
            launchStatusMessage = String(localized: "Imported library")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var selectedApplicationIndex: Int? {
        guard let selectedApplicationID else { return nil }
        return applications.firstIndex { $0.id == selectedApplicationID }
    }

    private func load() {
        do {
            let loaded = try persistence.load()
            let migrated = Self.migratingApplications(loaded)
            applications = migrated
            selectedApplicationID = applications.first?.id
            selectedProfileID = applications.first?.profiles.first?.id
            if migrated != loaded {
                save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try persistence.save(applications)
        } catch {
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

    private static func profile(named name: String, for application: ManagedApplication) -> LaunchProfile {
        let storageName = uniqueStorageName(
            basedOn: name,
            existingProfiles: application.profiles
        )
        return applyingRecommendedSettings(
            to: LaunchProfile(name: name, storageName: storageName),
            for: application
        )
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

        if preset.needsCodexHome, replacingExistingIsolation || profile.environment["CODEX_HOME"] == nil {
            migratedProfile.environmentText = settingEnvironmentValue(
                "CODEX_HOME",
                to: "\(profileDirectory(for: application, profile: migratedProfile))/CodexHome",
                in: migratedProfile.environmentText
            )
        }

        if preset.supportsUserDataDir,
           replacingExistingIsolation || !profile.arguments.contains(where: { $0.hasPrefix("--user-data-dir=") }) {
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
}
