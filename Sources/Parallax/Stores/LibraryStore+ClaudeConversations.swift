import AppKit
import Foundation

extension LibraryStore {
    func claudeConversationService(
        application: ManagedApplication, profile: LaunchProfile
    ) throws -> ClaudeConversationCopyService {
        guard Self.resolvedPreset(for: application) == .claude,
              let current = applications.first(where: { $0.id == application.id }), current == application,
              current.profiles.contains(profile) else { throw ClaudeConversationCopyError.changed }
        let plistURL = URL(fileURLWithPath: application.appPath)
            .appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        let installedVersion = plist?["CFBundleShortVersionString"] as? String
        guard let installedVersion, ClaudeConversationCopyService.supportedDesktopVersions.contains(installedVersion) else {
            throw ClaudeConversationCopyError.incompatibleVersion(installedVersion)
        }
        let paths = try managedPaths(for: application, profile: profile)
        let effective = profileApplyingImplicitClaudeIsolation(profile, for: application)
        let arguments = LaunchArgumentParser.parse(effective.argumentsText)
        let userData = UserDataDirectoryOptionResolver.resolve(in: arguments.tokens)
        let environment = LaunchEnvironmentParser.parse(effective.environmentText)
        let expander = PathSpecificTildeExpander(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        guard !arguments.hasErrors, !environment.hasErrors,
              let dataPath = userData.resolvedValue,
              environment.entries.filter({ $0.name == "CLAUDE_CONFIG_DIR" }).count == 1,
              let configPath = environment.effectiveValues["CLAUDE_CONFIG_DIR"],
              URL(fileURLWithPath: expander.argumentValue(dataPath, forOption: "--user-data-dir")).standardizedFileURL.path == paths.userData.url.standardizedFileURL.path,
              URL(fileURLWithPath: expander.environmentValue(configPath, forKey: "CLAUDE_CONFIG_DIR")).standardizedFileURL.path == paths.claudeConfig.url.standardizedFileURL.path else {
            throw ClaudeConversationCopyError.externalStorage
        }
        _ = try pathResolver.revalidateForMutation(paths.profileRoot)
        let context = paths.profileRoot.validationContext
        let components = Array(paths.profileRoot.url.pathComponents.dropFirst(context.canonicalBaseRootURL.pathComponents.count))
        return ClaudeConversationCopyService(files: try SecureManagedFileSystem(
            anchorURL: context.canonicalBaseRootURL, rootComponents: components, createIfMissing: false
        ))
    }

    func claudeConversations(application: ManagedApplication, profile: LaunchProfile) async throws -> ClaudeConversationCatalog {
        let service = try claudeConversationService(application: application, profile: profile)
        return try await Task.detached(priority: .userInitiated) { try service.catalog() }.value
    }

    func prepareClaudeConversationCopy(
        _ conversation: ClaudeConversation, application: ManagedApplication,
        source: LaunchProfile, destination: LaunchProfile
    ) async throws -> ClaudeConversationCopyPlan {
        guard source.id != destination.id else { throw ClaudeConversationCopyError.sameSpace }
        let sourceService = try claudeConversationService(application: application, profile: source)
        let destinationService = try claudeConversationService(application: application, profile: destination)
        return try await Task.detached(priority: .userInitiated) {
            try sourceService.prepare(conversation, destination: destinationService)
        }.value
    }

    func copyClaudeConversation(
        _ plan: ClaudeConversationCopyPlan, application: ManagedApplication,
        source: LaunchProfile, destination: LaunchProfile,
        applicationIsRunning: (() -> Bool)? = nil
    ) async throws -> ClaudeConversationCopyOutcome {
        guard canMutateLibrary(), requireCommittedProfileDraft(application: application, profile: source),
              requireCommittedProfileDraft(application: application, profile: destination) else {
            throw ClaudeConversationCopyError.changed
        }
        let isRunning = applicationIsRunning ?? {
            NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == application.bundleIdentifier
                    || $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: application.appPath).standardizedFileURL.path
            }
        }
        guard !isRunning() else { throw ClaudeConversationCopyError.running }
        let reservation = try reserveProfileData(application: application, profiles: [source, destination])
        defer { reservation.release() }
        let sourceService = try claudeConversationService(application: application, profile: source)
        let destinationService = try claudeConversationService(application: application, profile: destination)
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        let result = try await Task.detached(priority: .userInitiated) {
            try sourceService.copy(plan, destination: destinationService)
        }.value
        return result
    }
}
