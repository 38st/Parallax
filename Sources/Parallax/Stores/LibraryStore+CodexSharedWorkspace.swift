import Foundation

extension LibraryStore {
    func codexSharedWorkspace(_ application: ManagedApplication) throws -> CodexSharedWorkspace? {
        if let sharedHistoryInitializationError { throw sharedHistoryInitializationError }
        return try sharedHistoryStore?.codexWorkspace(applicationID: application.storageID)
    }

    func setCodexSharedWorkspace(_ enabled: Bool, application: ManagedApplication,
                                expected: CodexSharedWorkspace?,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) throws {
        guard canMutateLibrary(), !isProfileDataOperationRunning, applications.contains(application),
              Self.resolvedPreset(for: application) == .codex, let sharedHistoryStore else {
            throw SharedHistoryError.changed
        }
        if enabled, try sharedHistoryStore.groups().contains(where: { $0.applicationStorageID == application.storageID }) {
            throw CodexSharedWorkspaceError.linkedGroup
        }
        let binding = enabled ? try CodexSharedWorkspace.bind(home) : nil
        try sharedHistoryStore.setCodexWorkspace(binding, applicationID: application.storageID, expected: expected)
        sharedHistoryRevision &+= 1
    }

    func sourceApplyingSharedCodexWorkspace(_ source: LaunchConfigurationSource,
                                           application: ManagedApplication) -> LaunchConfigurationSource {
        guard Self.resolvedPreset(for: application) == .codex else { return source }
        do {
            guard let workspace = try codexSharedWorkspace(application) else { return source }
            return try workspace.project(source)
        } catch {
            // Never fall back to an empty account home on a damaged preference
            // or missing main workspace: that would look like lost history.
            var blocked = source
            blocked.codexSharedWorkspaceInvalid = true
            return blocked
        }
    }

    func validateSharedCodexLaunch(_ source: LaunchConfigurationSource, application: ManagedApplication,
                                  profile: LaunchProfile) throws {
        guard Self.resolvedPreset(for: application) == .codex else { return }
        let current = try codexSharedWorkspace(application)
        guard current == source.codexSharedWorkspace, !source.codexSharedWorkspaceInvalid else {
            throw SharedHistoryError.changed
        }
        guard let current else { return }
        guard launchConfigurationSource(application: application, profile: profile, requestID: source.requestID) == source else {
            throw SharedHistoryError.changed
        }
        try current.validate()
    }
}
