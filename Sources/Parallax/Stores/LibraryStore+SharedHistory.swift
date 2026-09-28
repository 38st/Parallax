import AppKit
import Foundation

extension LibraryStore {
    func sharedHistoryGroup(application: ManagedApplication, profile: LaunchProfile) throws -> SharedHistoryGroup? {
        if let sharedHistoryInitializationError { throw sharedHistoryInitializationError }
        return try sharedHistoryStore?.groups().first {
            $0.applicationStorageID == application.storageID && $0.profileStorageIDs.contains(profile.storageID)
        }
    }

    func sharedHistoryParticipant(application: ManagedApplication, profile: LaunchProfile) throws -> SharedHistoryParticipant {
        guard applications.contains(application), application.profiles.contains(profile) else { throw SharedHistoryError.changed }
        let preset = Self.resolvedPreset(for: application)
        if preset == .claude {
            let service = try claudeConversationService(application: application, profile: profile)
            return SharedHistoryParticipant(storageID: profile.storageID, files: service.files, provider: "claude")
        }
        guard preset == .codex else { throw SharedHistoryError.unavailable }
        let paths = try managedPaths(for: application, profile: profile)
        let parsed = LaunchEnvironmentParser.parse(profile.environmentText)
        guard !parsed.hasErrors, parsed.entries.filter({ $0.name == "CODEX_HOME" }).count <= 1,
              parsed.effectiveValues["CODEX_SQLITE_HOME"] == nil else { throw SharedHistoryError.unavailable }
        let configured = Self.environmentValue("CODEX_HOME", in: profile) ?? paths.codexHome.url.path
        let expanded = PathSpecificTildeExpander(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            .environmentValue(configured, forKey: "CODEX_HOME")
        let home = URL(fileURLWithPath: expanded).standardizedFileURL
        let files: SecureManagedFileSystem
        if home.path == paths.codexHome.url.standardizedFileURL.path {
            _ = try pathResolver.revalidateForMutation(paths.codexHome)
            let context = paths.profileRoot.validationContext
            files = try SecureManagedFileSystem(anchorURL: context.canonicalBaseRootURL,
                rootComponents: Array(home.pathComponents.dropFirst(context.canonicalBaseRootURL.pathComponents.count)),
                createIfMissing: false)
        } else if let container = libraryPrimaryURL?.deletingLastPathComponent() {
            // Only the exact Parallax account-tracker namespace is additionally
            // accepted. Arbitrary explicit CODEX_HOME paths remain user-owned.
            let components = Array(home.pathComponents.dropFirst(container.pathComponents.count))
            guard home.path.hasPrefix(container.path + "/"), components.count == 3,
                  components[0] == "AccountSessions", UUID(uuidString: components[1]) != nil,
                  components[2] == "CodexHome" else { throw SharedHistoryError.unavailable }
            files = try SecureManagedFileSystem(anchorURL: container, rootComponents: components, createIfMissing: false)
        } else { throw SharedHistoryError.unavailable }
        return SharedHistoryParticipant(storageID: profile.storageID, files: files, provider: "codex")
    }

    func setSharedHistory(
        application: ManagedApplication, source: LaunchProfile, members: Set<UUID>,
        expected: SharedHistoryGroup?, applicationIsRunning: (() -> Bool)? = nil,
        refreshCodexIndex: @Sendable (URL) async throws -> Void = SharedHistoryCodexIndex.refresh
    ) async throws {
        guard canMutateLibrary(), let sharedHistoryStore,
              applications.contains(application), application.profiles.contains(source),
              try sharedHistoryGroup(application: application, profile: source) == expected else {
            throw SharedHistoryError.changed
        }
        if members.isEmpty {
            // Disconnecting never deletes or reverts the copies already shared.
            try sharedHistoryStore.replace(expected, with: nil)
            sharedHistoryRevision &+= 1
            return
        }
        guard members.contains(source.storageID), (2...8).contains(members.count),
              members.isSubset(of: Set(application.profiles.map(\.storageID))) else {
            throw SharedHistoryError.invalidSelection
        }
        let profiles = application.profiles.filter { members.contains($0.storageID) }
        var roots: [String: String] = [:]
        for profile in profiles {
            guard requireCommittedProfileDraft(application: application, profile: profile) else { throw SharedHistoryError.changed }
            roots[profile.storageID.uuidString] = try sharedHistoryParticipant(application: application, profile: profile).files.rootPath
        }
        guard !(applicationIsRunning?() ?? sharedHistoryApplicationIsRunning(application)) else { throw SharedHistoryError.running }
        let provider = Self.resolvedPreset(for: application) == .claude ? "claude" : "codex"
        // Save opt-in first: an interrupted initial sync can be retried by Open.
        // Changing membership starts a fresh union; existing copies are retained.
        let group = SharedHistoryGroup(id: expected?.id ?? UUID(), applicationStorageID: application.storageID,
            provider: provider, profileStorageIDs: members.sorted { $0.uuidString < $1.uuidString },
            rootPaths: roots,
            knownConversationIDs: Set(expected?.profileStorageIDs ?? []) == members ? expected?.knownConversationIDs ?? [] : [],
            baselines: Set(expected?.profileStorageIDs ?? []) == members ? expected?.baselines ?? [:] : [:])
        try sharedHistoryStore.replace(expected, with: group)
        sharedHistoryRevision &+= 1
        try await synchronizeSharedHistory(group, application: application, applicationIsRunning: applicationIsRunning,
            refreshCodexIndex: refreshCodexIndex)
    }

    func synchronizeSharedHistory(
        _ group: SharedHistoryGroup, application: ManagedApplication,
        applicationIsRunning: (() -> Bool)? = nil,
        refreshCodexIndex: @Sendable (URL) async throws -> Void = SharedHistoryCodexIndex.refresh
    ) async throws {
        guard let sharedHistoryStore, !isProfileDataOperationRunning,
              try sharedHistoryStore.groups().contains(group),
              group.provider == (Self.resolvedPreset(for: application) == .claude ? "claude" : "codex") else {
            throw SharedHistoryError.changed
        }
        let profiles = application.profiles.filter { group.profileStorageIDs.contains($0.storageID) }
        guard profiles.count == group.profileStorageIDs.count else { throw SharedHistoryError.changed }
        let running = applicationIsRunning ?? { self.sharedHistoryApplicationIsRunning(application) }
        guard !running() else { throw SharedHistoryError.running }
        let reservation = try reserveProfileData(application: application, profiles: profiles)
        defer { reservation.release() }
        let participants = try profiles.map { try sharedHistoryParticipant(application: application, profile: $0) }
        guard participants.allSatisfy({ group.rootPaths[$0.storageID.uuidString] == $0.files.rootPath }) else {
            throw SharedHistoryError.changed
        }
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        let worker = Task.detached(priority: .userInitiated) {
            let ids = try SharedHistoryService.synchronize(participants, knownIDs: group.knownConversationIDs,
                baselines: group.baselines)
            guard let first = participants.first else { throw SharedHistoryError.invalidSelection }
            let baselines = try SharedHistoryService.catalog(first).mapValues { SharedHistoryBaseline($0.normalized) }
            guard Set(baselines.keys) == ids else { throw SharedHistoryError.changed }
            return (ids, baselines)
        }
        let (ids, baselines) = try await worker.value
        guard !running(), applications.contains(application) else { throw SharedHistoryError.changed }
        var updated = group
        updated.knownConversationIDs = ids
        updated.baselines = baselines
        try sharedHistoryStore.replace(group, with: updated)
        sharedHistoryRevision &+= 1
        if group.provider == "codex" {
            for participant in participants { try await refreshCodexIndex(URL(fileURLWithPath: participant.files.rootPath)) }
        }
        guard !running(), applications.contains(application), try sharedHistoryStore.groups().contains(updated) else {
            throw SharedHistoryError.changed
        }
    }

    func prepareSharedHistoryForLaunch(_ source: LaunchConfigurationSource) async throws {
        guard let application = applications.first(where: { $0.id == source.applicationID }),
              let profile = application.profiles.first(where: { $0.id == source.profileID }) else { throw SharedHistoryError.changed }
        guard let group = try sharedHistoryGroup(application: application, profile: profile) else { return }
        guard launchConfigurationSource(application: application, profile: profile, requestID: source.requestID) == source else {
            throw SharedHistoryError.changed
        }
        try await synchronizeSharedHistory(group, application: application)
        try Task.checkCancellation()
        guard applications.contains(application) else { throw SharedHistoryError.changed }
    }

    func sharedHistoryApplicationIsRunning(_ application: ManagedApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == application.bundleIdentifier
                || $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: application.appPath).standardizedFileURL.path
        }
    }

    func canChangeSharedHistoryData(application: ManagedApplication, profile: LaunchProfile? = nil) -> Bool {
        do {
            if let sharedHistoryInitializationError { throw sharedHistoryInitializationError }
            let groups = try sharedHistoryStore?.groups() ?? []
            if groups.contains(where: { group in
                group.applicationStorageID == application.storageID
                    && (profile.map { group.profileStorageIDs.contains($0.storageID) } ?? true)
            }) {
                errorMessage = String(localized: "Turn off shared history before moving, duplicating, removing, or clearing these spaces.")
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
