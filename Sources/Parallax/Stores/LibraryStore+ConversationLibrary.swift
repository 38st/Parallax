import AppKit
import Foundation

extension LibraryStore {
    func conversationContinuationURL(_ source: LaunchConfigurationSource) throws -> URL? {
        guard let application = applications.first(where: { $0.id == source.applicationID }),
              let profile = application.profiles.first(where: { $0.id == source.profileID }),
              let library = try conversationLibrary(application: application, profile: profile),
              let handoff = library.handoff, handoff.id == source.requestID,
              handoff.targetProfileID == source.profileStorageID, handoff.phase == .opening,
              let id = handoff.conversationID else { return nil }
        return try Self.claudeContinuationURL(conversationID: id)
    }

    static func claudeContinuationURL(conversationID: String) throws -> URL {
        guard ConversationLibraryStore.isConversationID(conversationID) else { throw ConversationLibraryError.changed }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: conversationID)]
        guard let url = components.url else { throw ConversationLibraryError.changed }
        return url
    }

    func conversationLibraryStore(_ group: SharedHistoryGroup, create: Bool = false) throws -> ConversationLibraryStore {
        guard let container = libraryPrimaryURL?.deletingLastPathComponent(), group.provider == "claude" else {
            throw ConversationLibraryError.unavailable
        }
        return try ConversationLibraryStore(applicationSupportURL: container, id: group.id, create: create)
    }

    func conversationLibrary(application: ManagedApplication, profile: LaunchProfile) throws -> ConversationLibrary? {
        guard let group = try sharedHistoryGroup(application: application, profile: profile), group.conversationLibraryID != nil else { return nil }
        guard let library = try conversationLibraryStore(group).read(), library.applicationStorageID == application.storageID else {
            throw ConversationLibraryError.unavailable
        }
        return library
    }

    func enrollConversationLibrary(application: ManagedApplication, source: LaunchProfile,
                                   namespaces: [UUID: [String]], expected: SharedHistoryGroup?) async throws {
        let allAccounts = try usesAllAccountHistory(application)
        let sourceGroup = try sharedHistoryGroup(application: application, profile: source)
        let applicationGroup = try allAccountHistoryGroup(application)
        guard canMutateLibrary(), let sharedHistoryStore, !isProfileDataOperationRunning,
              Self.resolvedPreset(for: application) == .claude,
              sourceGroup == expected || (sourceGroup == nil && applicationGroup == expected),
              namespaces[source.storageID] != nil, !namespaces.isEmpty,
              namespaces.count >= 2 || allAccounts else { throw ConversationLibraryError.changed }
        guard !sharedHistoryApplicationIsRunning(application) else { throw ConversationLibraryError.waitingForQuit }
        let profiles = application.profiles.filter { namespaces[$0.storageID] != nil }
        guard profiles.count == namespaces.count else { throw ConversationLibraryError.changed }
        for profile in profiles {
            let linked = try sharedHistoryGroup(application: application, profile: profile)
            guard requireCommittedProfileDraft(application: application, profile: profile),
                  linked == nil || linked == expected else { throw ConversationLibraryError.changed }
        }
        var group = SharedHistoryGroup(id: expected?.id ?? UUID(), applicationStorageID: application.storageID,
            provider: "claude", profileStorageIDs: profiles.map(\.storageID).sorted { $0.uuidString < $1.uuidString })
        let participants = try profiles.map { try sharedHistoryParticipant(application: application, profile: $0) }
        let bindings = try zip(profiles, participants).map { profile, participant in
            guard let namespace = namespaces[profile.storageID] else { throw ConversationLibraryError.changed }
            return try ConversationLibraryClaudeAdapter.bind(profileID: profile.storageID, label: profile.name,
                namespace: namespace, files: participant.files)
        }
        group.rootPaths = Dictionary(uniqueKeysWithValues: bindings.map { ($0.profileStorageID.uuidString, $0.rootPath) })
        let canonical = try conversationLibraryStore(group, create: true)
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        try await withProfileDataReservation(application: application, profiles: profiles) {
            guard !sharedHistoryApplicationIsRunning(application) else { throw ConversationLibraryError.waitingForQuit }
            _ = try await Task.detached(priority: .userInitiated) {
                if expected?.conversationLibraryID != nil {
                    try ConversationLibraryService.includeAccounts(store: canonical, bindings: bindings,
                        participants: participants, allowRebinding: true)
                    return try canonical.read()
                }
                return try ConversationLibraryService.enroll(store: canonical, applicationID: application.storageID,
                    bindings: bindings, participants: participants, previouslySharedIDs: expected?.knownConversationIDs ?? [],
                    previousMembers: Set(expected?.profileStorageIDs ?? []))
            }.value
            guard !sharedHistoryApplicationIsRunning(application), applications.contains(application) else { throw ConversationLibraryError.changed }
            group.conversationLibraryID = group.id
            try sharedHistoryStore.replace(expected, with: group)
            sharedHistoryRevision &+= 1
        }
    }

    /// Enter the durable handoff before requesting graceful process shutdown.
    /// Unknown/unlinked instances are never terminated by an account switch.
    func beginConversationSwitch(_ source: LaunchConfigurationSource) async throws {
        guard let application = applications.first(where: { $0.id == source.applicationID }),
              let profile = application.profiles.first(where: { $0.id == source.profileID }),
              let group = try sharedHistoryGroup(application: application, profile: profile), group.conversationLibraryID != nil else { return }
        let canonical = try conversationLibraryStore(group)
        guard let library = try canonical.read() else { throw ConversationLibraryError.unavailable }
        guard applications.contains(application), application.storageID == source.applicationStorageID,
              profile.storageID == source.profileStorageID,
              launchInputsMatch(source, application: application, profile: profile) else {
            throw ConversationLibraryError.changed
        }
        for linked in application.profiles where group.profileStorageIDs.contains(linked.storageID) {
            let participant = try sharedHistoryParticipant(application: application, profile: linked)
            guard let binding = library.bindings[linked.storageID.uuidString] else { throw ConversationLibraryError.changed }
            try ConversationLibraryClaudeAdapter.validate(binding, files: participant.files)
        }
        let instances = runningApplicationInstances(for: application)
        guard instances.allSatisfy({ instance in
            guard let profileID = instance.profileStorageID else { return false }
            return instance.isActionable && group.profileStorageIDs.contains(profileID)
        }) else {
            throw ConversationLibraryError.waitingForQuit
        }
        try ConversationLibraryService.beginSwitch(store: canonical, targetID: profile.storageID,
            selectedID: library.selectedConversationID, requestID: source.requestID)
        sharedHistoryRevision &+= 1
        conversationSwitchMessage = String(localized: "Waiting for Claude to quit…")
        for instance in instances {
            guard requestQuit(instance, from: application) else { throw ConversationLibraryError.waitingForQuit }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while sharedHistoryApplicationIsRunning(application) {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ConversationLibraryError.waitingForQuit }
            try await Task.sleep(for: .milliseconds(150))
        }
        conversationSwitchMessage = String(localized: "Saving conversations…")
    }

    /// Releases a handoff that the request entered but never moved past
    /// waiting, so later opens in the group are not reported as busy.
    func releaseWaitingConversationSwitch(_ source: LaunchConfigurationSource) {
        guard let application = applications.first(where: { $0.id == source.applicationID }),
              let profile = application.profiles.first(where: { $0.id == source.profileID }),
              let group = try? sharedHistoryGroup(application: application, profile: profile),
              group.conversationLibraryID != nil, let canonical = try? conversationLibraryStore(group) else { return }
        do {
            if try ConversationLibraryService.releaseWaiting(store: canonical, requestID: source.requestID) {
                sharedHistoryRevision &+= 1
            }
        } catch {
            AppLog.launch.error("Could not release a waiting conversation switch: \(error.localizedDescription)")
        }
    }

    func prepareConversationLibrary(_ group: SharedHistoryGroup, application: ManagedApplication,
                                    source: LaunchConfigurationSource) async throws {
        guard !sharedHistoryApplicationIsRunning(application), !isProfileDataOperationRunning else {
            throw ConversationLibraryError.waitingForQuit
        }
        let canonical = try conversationLibraryStore(group)
        let profiles = application.profiles.filter { group.profileStorageIDs.contains($0.storageID) }
        let participants = try profiles.map { try sharedHistoryParticipant(application: application, profile: $0) }
        guard let library = try canonical.read(), library.applicationStorageID == application.storageID,
              participants.allSatisfy({ group.rootPaths[$0.storageID.uuidString] == $0.files.rootPath }) else {
            throw ConversationLibraryError.changed
        }
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        try await withProfileDataReservation(application: application, profiles: profiles) {
            guard !sharedHistoryApplicationIsRunning(application) else { throw ConversationLibraryError.waitingForQuit }
            conversationSwitchMessage = String(localized: "Preparing the selected account…")
            _ = try await Task.detached(priority: .userInitiated) {
                try ConversationLibraryService.prepare(store: canonical, targetID: source.profileStorageID,
                    selectedID: library.selectedConversationID, participants: participants, requestID: source.requestID)
            }.value
            try Task.checkCancellation()
            guard !sharedHistoryApplicationIsRunning(application), applications.contains(application),
                  try sharedHistoryStore?.groups().contains(group) == true else { throw ConversationLibraryError.changed }
            try ConversationLibraryService.markOpening(store: canonical, targetID: source.profileStorageID, requestID: source.requestID)
            conversationSwitchMessage = String(localized: "Opening the selected account…")
            sharedHistoryRevision &+= 1
        }
    }

    func finishConversationSwitch(_ lifecycle: ProfileLaunchLifecycleSnapshot, application: ManagedApplication, profile: LaunchProfile) {
        do {
            guard let group = try sharedHistoryGroup(application: application, profile: profile), group.conversationLibraryID != nil,
                  let pending = try conversationLibraryStore(group).read()?.handoff,
                  pending.id == lifecycle.requestID else { return }
            let opened: Bool
            switch lifecycle.state {
            case .running, .runningDegraded: opened = true
            default: opened = false
            }
            if opened,
               runningApplicationInstances(for: application).contains(where: { $0.requestID == lifecycle.requestID && $0.isActionable }) {
                try ConversationLibraryService.completeOpening(store: conversationLibraryStore(group),
                    targetID: profile.storageID, requestID: lifecycle.requestID)
                conversationSwitchMessage = String(localized: "Opened the configured account space. Select the chat in Claude if needed and review any import prompt.")
                sharedHistoryRevision &+= 1
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func updateConversationLibrary(application: ManagedApplication, profile: LaunchProfile,
                                   _ operation: (ConversationLibraryStore) throws -> Void) async throws {
        guard canMutateLibrary(), !isProfileDataOperationRunning,
              !sharedHistoryApplicationIsRunning(application),
              let group = try sharedHistoryGroup(application: application, profile: profile), group.conversationLibraryID != nil else {
            throw ConversationLibraryError.waitingForQuit
        }
        let profiles = application.profiles.filter { group.profileStorageIDs.contains($0.storageID) }
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        try await withProfileDataReservation(application: application, profiles: profiles) {
            guard !sharedHistoryApplicationIsRunning(application), applications.contains(application),
                  try sharedHistoryGroup(application: application, profile: profile) == group else {
                throw ConversationLibraryError.changed
            }
            try operation(conversationLibraryStore(group))
            sharedHistoryRevision &+= 1
        }
    }
}
