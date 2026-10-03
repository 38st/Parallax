import Foundation

enum AllAccountHistoryError: LocalizedError, Equatable {
    case multipleLibraries
    case chooseHistory(String)

    var errorDescription: String? {
        switch self {
        case .multipleLibraries:
            String(localized: "This app has separate shared-history groups. Keep one shared library before enabling history for all accounts.")
        case .chooseHistory(let name):
            String(localized: "Choose the history for \(name) in Shared Conversations → Reconnect Accounts. More than one account history is available.")
        }
    }
}

extension LibraryStore {
    func usesAllAccountHistory(_ application: ManagedApplication) throws -> Bool {
        if let sharedHistoryInitializationError { throw sharedHistoryInitializationError }
        return try sharedHistoryStore?.includesAllAccounts(applicationID: application.storageID) == true
    }

    func allAccountHistoryGroup(_ application: ManagedApplication) throws -> SharedHistoryGroup? {
        guard try usesAllAccountHistory(application) else { return nil }
        let groups = try sharedHistoryStore?.groups().filter { $0.applicationStorageID == application.storageID } ?? []
        guard groups.count <= 1 else { throw AllAccountHistoryError.multipleLibraries }
        return groups.first
    }

    func setAllAccountHistory(_ enabled: Bool, application: ManagedApplication, expected: Bool,
                             applicationIsRunning: (() -> Bool)? = nil) async throws {
        guard canMutateLibrary(), !isProfileDataOperationRunning, applications.contains(application),
              Self.resolvedPreset(for: application) == .claude, let sharedHistoryStore else {
            throw SharedHistoryError.changed
        }
        // Enabling future inclusion for an already fully linked application is
        // metadata-only. No account admission or native history read is needed,
        // so a currently running Claude task need not be interrupted.
        if enabled, !expected, try enableAllAccountHistoryForExistingLibrary(application, receipts: sharedHistoryStore) { return }
        let isRunning = applicationIsRunning ?? { self.sharedHistoryApplicationIsRunning(application) }
        guard !isRunning() else { throw ConversationLibraryError.waitingForQuit }
        isProfileDataOperationRunning = true
        do {
            try await withProfileDataReservation(application: application, profiles: application.profiles) {
                try Task.checkCancellation()
                guard applications.contains(application), !isRunning() else { throw SharedHistoryError.changed }
                for group in try sharedHistoryStore.groups() where group.applicationStorageID == application.storageID {
                    if group.conversationLibraryID != nil {
                        guard try conversationLibraryStore(group).read()?.handoff == nil else { throw ConversationLibraryError.busy }
                    }
                }
                try sharedHistoryStore.setIncludesAllAccounts(enabled, applicationID: application.storageID, expected: expected)
                sharedHistoryRevision &+= 1
            }
        } catch {
            isProfileDataOperationRunning = false
            throw error
        }
        isProfileDataOperationRunning = false
        if enabled { try await includeReadyAccounts(application: application) }
    }

    private func enableAllAccountHistoryForExistingLibrary(_ application: ManagedApplication,
                                                           receipts: SharedHistoryStore) throws -> Bool {
        let groups = try receipts.groups().filter { $0.applicationStorageID == application.storageID }
        guard groups.count == 1, let group = groups.first, group.conversationLibraryID != nil,
              Set(group.profileStorageIDs) == Set(application.profiles.map(\.storageID)) else { return false }
        let catalog = try conversationLibraryStore(group)
        try catalog.transaction { document in
            guard let library = document, library.applicationStorageID == application.storageID else {
                throw ConversationLibraryError.unavailable
            }
            guard library.handoff == nil else { throw ConversationLibraryError.busy }
            guard Set(library.bindings.keys) == Set(group.profileStorageIDs.map(\.uuidString)),
                  group.rootPaths.allSatisfy({ library.bindings[$0.key]?.rootPath == $0.value }),
                  try receipts.groups().contains(group) else { throw ConversationLibraryError.changed }
            try receipts.setIncludesAllAccounts(true, applicationID: application.storageID, expected: false)
        }
        sharedHistoryRevision &+= 1
        return true
    }

    /// Runs before each launch, including launches from links and the menu bar.
    /// A fresh space can open for sign-in; its next open joins the same library.
    func includeAllAccountHistoryForLaunch(_ source: LaunchConfigurationSource) async throws {
        guard let application = applications.first(where: { $0.id == source.applicationID }),
              Self.resolvedPreset(for: application) == .claude,
              try usesAllAccountHistory(application) else { return }
        guard let profile = application.profiles.first(where: { $0.id == source.profileID }),
              launchInputsMatch(source, application: application, profile: profile) else {
            throw SharedHistoryError.changed
        }
        try await includeReadyAccounts(application: application, target: profile)
        if try sharedHistoryGroup(application: application, profile: profile) == nil {
            conversationSwitchMessage = usesExternalClaudeStorage(application: application, profile: profile)
                ? String(localized: "This space uses its own Claude data folders, so its history is not part of the shared library.")
                : String(localized: "Sign in and open Code in this space once. Its history will join the shared library the next time you open it through Parallax.")
        }
    }

    func includeReadyAccounts(application: ManagedApplication, target: LaunchProfile? = nil) async throws {
        guard try usesAllAccountHistory(application) else { return }
        guard canMutateLibrary(), !isProfileDataOperationRunning, applications.contains(application),
              Self.resolvedPreset(for: application) == .claude, let sharedHistoryStore else { throw SharedHistoryError.changed }
        let expected = try allAccountHistoryGroup(application)
        let previous: ConversationLibrary?
        if let expected, expected.conversationLibraryID != nil {
            guard let saved = try conversationLibraryStore(expected).read(), saved.applicationStorageID == application.storageID else {
                throw ConversationLibraryError.unavailable
            }
            previous = saved
            guard Set(expected.profileStorageIDs.map(\.uuidString)).isSubset(of: Set(saved.bindings.keys)),
                  expected.rootPaths.allSatisfy({ saved.bindings[$0.key]?.rootPath == $0.value }) else {
                throw ConversationLibraryError.changed
            }
            // No new account is being admitted. The normal handoff saves and
            // prepares histories after gracefully quitting the current account.
            if let target, saved.bindings[target.storageID.uuidString] != nil,
               Set(expected.profileStorageIDs.map(\.uuidString)) == Set(saved.bindings.keys) { return }
            guard saved.handoff == nil else { throw ConversationLibraryError.busy }
        } else { previous = nil }
        guard !sharedHistoryApplicationIsRunning(application) else { throw ConversationLibraryError.waitingForQuit }
        isProfileDataOperationRunning = true
        defer { isProfileDataOperationRunning = false }
        try await withProfileDataReservation(application: application, profiles: application.profiles) {
            try Task.checkCancellation()
            guard applications.contains(application), !sharedHistoryApplicationIsRunning(application),
                  try allAccountHistoryGroup(application) == expected,
                  try usesAllAccountHistory(application) else { throw SharedHistoryError.changed }
            var bindings = previous?.bindings ?? [:]
            var participants: [SharedHistoryParticipant] = []
            let required = Set(expected?.profileStorageIDs ?? []).union(bindings.values.map(\.profileStorageID))
            guard required.isSubset(of: Set(application.profiles.map(\.storageID))) else { throw SharedHistoryError.changed }
            for profile in application.profiles {
                let key = profile.storageID.uuidString
                guard target == nil || target?.id == profile.id || required.contains(profile.storageID) else { continue }
                guard requireCommittedProfileDraft(application: application, profile: profile) else { throw SharedHistoryError.changed }
                guard let participant = try initializedHistoryParticipant(application: application, profile: profile) else {
                    if required.contains(profile.storageID) { throw ConversationLibraryError.unavailable }
                    continue
                }
                if let binding = bindings[key] {
                    try ConversationLibraryClaudeAdapter.validate(binding, files: participant.files)
                } else {
                    let candidates = try ConversationLibraryClaudeAdapter.candidates(participant.files)
                    let populated = candidates.filter { $0.conversationCount > 0 }
                    let choices = populated.isEmpty ? candidates : populated
                    guard choices.count <= 1 else { throw AllAccountHistoryError.chooseHistory(profile.name) }
                    guard let choice = choices.first else {
                        if required.contains(profile.storageID) { throw ConversationLibraryError.unavailable }
                        continue
                    }
                    bindings[key] = try ConversationLibraryClaudeAdapter.bind(profileID: profile.storageID, label: profile.name,
                        namespace: choice.namespace, files: participant.files)
                }
                participants.append(participant)
            }
            guard !bindings.isEmpty else { return }
            if let expected, expected.conversationLibraryID != nil, previous?.bindings == bindings,
               Set(expected.profileStorageIDs.map(\.uuidString)) == Set(bindings.keys) { return }
            var group = SharedHistoryGroup(id: expected?.id ?? UUID(), applicationStorageID: application.storageID,
                provider: "claude", profileStorageIDs: bindings.values.map(\.profileStorageID).sorted { $0.uuidString < $1.uuidString },
                rootPaths: bindings.mapValues(\.rootPath))
            let canonical = try conversationLibraryStore(group, create: true)
            let confirmedBindings = Array(bindings.values)
            let confirmedParticipants = participants
            try await Task.detached(priority: .userInitiated) {
                if previous != nil {
                    try ConversationLibraryService.includeAccounts(store: canonical, bindings: confirmedBindings, participants: confirmedParticipants)
                } else {
                    _ = try ConversationLibraryService.enroll(store: canonical, applicationID: application.storageID,
                        bindings: confirmedBindings, participants: confirmedParticipants, previouslySharedIDs: expected?.knownConversationIDs ?? [],
                        previousMembers: Set(expected?.profileStorageIDs ?? []))
                }
            }.value
            try Task.checkCancellation()
            guard applications.contains(application), !sharedHistoryApplicationIsRunning(application) else { throw SharedHistoryError.changed }
            group.conversationLibraryID = group.id
            try sharedHistoryStore.replace(expected, with: group, requiringAllAccountsFor: application.storageID)
            sharedHistoryRevision &+= 1
        }
    }

    private func usesExternalClaudeStorage(application: ManagedApplication, profile: LaunchProfile) -> Bool {
        do { _ = try claudeConversationService(application: application, profile: profile) }
        catch ClaudeConversationCopyError.externalStorage { return true }
        catch { return false }
        return false
    }

    private func initializedHistoryParticipant(application: ManagedApplication, profile: LaunchProfile) throws -> SharedHistoryParticipant? {
        do { return try sharedHistoryParticipant(application: application, profile: profile) }
        catch ClaudeConversationCopyError.externalStorage {
            // A space with its own data folders opens on its own. It cannot
            // join the library, and an existing member must still be reported.
            return nil
        }
        catch SecureManagedFileSystemError.invalidRoot {
            // Configuration and ownership validation ran first. Only a missing
            // fresh managed root is onboarding, never an external or unsafe path.
            let paths = try managedPaths(for: application, profile: profile)
            do { _ = try FileManager.default.attributesOfItem(atPath: paths.profileRoot.url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
            throw SecureManagedFileSystemError.invalidRoot
        }
    }
}
