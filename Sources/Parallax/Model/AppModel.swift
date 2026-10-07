import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var apps: [ManagedApp] = []
    var accounts: [UsageAccount] = []
    /// Running instance per space.
    var running: [UUID: NSRunningApplication] = [:]
    var busyAccounts: Set<UUID> = []
    var chats: [Chat] = []
    var loadingChats = false
    var notice: String?
    var importedFromPreviousVersion = false

    @ObservationIgnored private var canSave = true
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let backupsURL: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTimer: Timer?

    /// - Parameters:
    ///   - support: Folder holding the saved state, chat backups, and the previous version's files.
    ///   - defaults: Where the previous version kept its usage accounts.
    init(support: URL = Paths.support, defaults: UserDefaults = .standard, startServices: Bool = true) {
        stateURL = support.appendingPathComponent("state.json")
        backupsURL = support.appendingPathComponent("ChatBackups", isDirectory: true)
        load(previousVersion: { LegacyImport.load(support: support, defaults: defaults) })
        if startServices { start() }
    }

    // MARK: Saving

    private func load(previousVersion: () -> LegacyImport.Result) {
        do {
            let data = try Data(contentsOf: stateURL)
            do {
                let state = try JSONDecoder().decode(SavedState.self, from: data)
                guard state.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                apps = state.apps
                accounts = state.accounts
            } catch {
                canSave = false
                notice = "Parallax couldn't read its saved spaces (\(error.localizedDescription)). Nothing was changed on disk."
            }
            return
        } catch {
            guard (error as? CocoaError)?.code == .fileReadNoSuchFile else {
                canSave = false
                notice = "Parallax couldn't read its saved spaces (\(error.localizedDescription)). Nothing was changed on disk."
                return
            }
        }
        let previous = previousVersion()
        apps = previous.apps
        accounts = previous.accounts
        importedFromPreviousVersion = !previous.apps.isEmpty || !previous.accounts.isEmpty
        save()
    }

    func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedState(apps: apps, accounts: accounts))
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let backup = stateURL.deletingPathExtension().appendingPathExtension("backup.json")
                _ = try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: stateURL, to: backup)
            }
            try data.write(to: stateURL, options: .atomic)
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await self?.refreshAllAccounts(onlyIfStale: true)
            }
        })
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAllAccounts(onlyIfStale: true) }
        }
        refreshRunning()
        Task { await refreshAllAccounts(onlyIfStale: true) }
    }

    // MARK: Apps

    func app(_ id: UUID?) -> ManagedApp? { apps.first { $0.id == id } }

    func addApp(at url: URL) {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        if let existing = apps.first(where: { $0.bundleID != nil && $0.bundleID == bundleID }) {
            notice = "\(existing.name) is already in Parallax."
            return
        }
        let id = UUID()
        apps.append(ManagedApp(
            id: id, name: name, path: url.path, bundleID: bundleID,
            kind: AppKind.detect(name: name, bundleID: bundleID), dataFolder: Paths.newAppFolder(id: id)
        ))
        save()
    }

    func updateApp(_ app: ManagedApp) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index] = app
        save()
    }

    /// Removes the app from Parallax. Space data folders stay on disk.
    func removeApp(_ id: UUID) {
        apps.removeAll { $0.id == id }
        save()
    }

    // MARK: Spaces

    @discardableResult
    func addSpace(to appID: UUID, name: String, email: String, codexAccount: UsageAccount?) -> Space? {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return nil }
        let id = UUID()
        var space = Space(id: id, name: name, folder: Paths.newSpaceFolder(app: apps[index], spaceID: id), email: email)
        if let codexAccount { space.environment = "CODEX_HOME=\(codexAccount.homeFolder.path)" }
        apps[index].spaces.append(space)
        save()
        return space
    }

    func updateSpace(_ space: Space, in appID: UUID) {
        guard let appIndex = apps.firstIndex(where: { $0.id == appID }),
              let index = apps[appIndex].spaces.firstIndex(where: { $0.id == space.id }) else { return }
        apps[appIndex].spaces[index] = space
        save()
    }

    /// Other spaces whose folder or settings point inside this space's folder.
    func spacesDepending(on space: Space) -> [Space] {
        func resolved(_ path: String) -> String {
            var url = URL(fileURLWithPath: path).standardizedFileURL
            var suffix: [String] = []
            // Foundation doesn't resolve ancestor symlinks when the final path doesn't exist.
            while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
                suffix.insert(url.lastPathComponent, at: 0)
                url.deleteLastPathComponent()
            }
            url = url.resolvingSymlinksInPath()
            for component in suffix { url.appendPathComponent(component) }
            return url.path
        }
        let folder = resolved(space.folder)
        return apps.flatMap(\.spaces).filter { other in
            let otherFolder = resolved(other.folder)
            return other.id != space.id && (otherFolder == folder || otherFolder.hasPrefix(folder + "/")
                || other.arguments.contains(space.folder) || other.environment.contains(space.folder))
        }
    }

    func deleteSpace(_ spaceID: UUID, in appID: UUID, moveDataToTrash: Bool) throws {
        guard let appIndex = apps.firstIndex(where: { $0.id == appID }),
              let space = apps[appIndex].spaces.first(where: { $0.id == spaceID }) else { return }
        guard running[spaceID] == nil else { throw SpaceError.running(space.name) }
        if moveDataToTrash {
            let dependents = spacesDepending(on: space)
            guard dependents.isEmpty else { throw SpaceError.inUse(space.name, dependents.map(\.name)) }
            if FileManager.default.fileExists(atPath: space.folder) {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: space.folder), resultingItemURL: nil)
            }
        }
        apps[appIndex].spaces.removeAll { $0.id == spaceID }
        save()
    }

    // MARK: Running instances

    func refreshRunning() {
        running = running.filter { !$0.value.isTerminated }
        for (spaceID, instance) in Launcher.discoverRunningSpaces(apps: apps) where running[spaceID] == nil {
            running[spaceID] = instance
        }
    }

    func open(_ spaceID: UUID, in appID: UUID, continueURL: URL? = nil) async {
        guard let app = app(appID), let space = app.spaces.first(where: { $0.id == spaceID }) else { return }
        if let instance = running[spaceID], !instance.isTerminated, continueURL == nil {
            instance.activate()
            return
        }
        do {
            let plan = try LaunchPlanner.plan(app: app, space: space)
            let instance = try await Launcher.open(app: app, plan: plan, continueURL: continueURL)
            if !(app.kind == .codex && app.sharedCodexHistory) { running[spaceID] = instance }
            guard var updated = self.app(appID)?.spaces.first(where: { $0.id == spaceID }) else { return }
            updated.lastOpened = Date()
            updateSpace(updated, in: appID)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Opens Codex with the one shared history in ~/.codex.
    func openSharedCodex(_ appID: UUID) async {
        guard let app = app(appID) else { return }
        do {
            let plan = try LaunchPlanner.plan(app: app, space: nil)
            _ = try await Launcher.open(app: app, plan: plan)
        } catch {
            notice = error.localizedDescription
        }
    }

    func show(_ spaceID: UUID) {
        running[spaceID]?.activate()
    }

    func quit(_ spaceID: UUID) {
        running[spaceID]?.terminate()
    }

    /// Quits the given spaces' instances and waits up to 15 seconds for them to close.
    func quitAndWait(_ spaceIDs: [UUID]) async -> Bool {
        let instances = spaceIDs.compactMap { running[$0] }.filter { !$0.isTerminated }
        instances.forEach { $0.terminate() }
        for _ in 0..<100 {
            if instances.allSatisfy(\.isTerminated) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        refreshRunning()
        return instances.allSatisfy(\.isTerminated)
    }

    // MARK: Usage accounts

    func account(forEmail email: String, provider: Provider? = nil) -> UsageAccount? {
        let wanted = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return accounts.first { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted && (provider == nil || $0.provider == provider) }
    }

    func addAccount(provider: Provider, label: String) async {
        let account = UsageAccount(provider: provider, label: label.isEmpty ? "\(provider.label) account" : label)
        accounts.append(account)
        save()
        await signIn(account.id)
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        save()
    }

    func renameAccount(_ id: UUID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = label
        save()
    }

    func signIn(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !busyAccounts.contains(id) else { return }
        busyAccounts.insert(id)
        defer { busyAccounts.remove(id) }
        do {
            let status = switch account.provider {
            case .claude: try await ClaudeProvider.signIn(configFolder: account.homeFolder)
            case .codex: try await CodexProvider.signIn(codexHome: account.homeFolder)
            }
            apply(status, to: id)
        } catch {
            record(error, for: id)
        }
    }

    func refresh(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !busyAccounts.contains(id) else { return }
        busyAccounts.insert(id)
        defer { busyAccounts.remove(id) }
        do {
            let status = switch account.provider {
            case .claude: try await ClaudeProvider.status(configFolder: account.homeFolder)
            case .codex: try await CodexProvider.status(codexHome: account.homeFolder)
            }
            apply(status, to: id)
        } catch {
            record(error, for: id)
        }
    }

    func refreshAllAccounts(onlyIfStale: Bool) async {
        for account in accounts where account.signedIn {
            if onlyIfStale, let last = account.lastRefreshed, Date().timeIntervalSince(last) < 270 { continue }
            await refresh(account.id)
        }
    }

    private func apply(_ status: ProviderStatus, to id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].signedIn = true
        if let email = status.email, !email.isEmpty { accounts[index].email = email }
        if let plan = status.plan, !plan.isEmpty { accounts[index].plan = plan }
        if status.usageError == nil {
            accounts[index].windows = status.windows
            accounts[index].lastRefreshed = Date()
        }
        accounts[index].lastError = status.usageError
        save()
    }

    private func record(_ error: Error, for id: UUID) {
        guard !(error is CancellationError), let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if (error as? ProviderError) == .signedOut { accounts[index].signedIn = false }
        accounts[index].lastError = error.localizedDescription
        save()
    }

    // MARK: Chats

    var claudeSpaces: [(app: ManagedApp, space: Space)] {
        apps.filter { $0.kind == .claude }.flatMap { app in app.spaces.map { (app, $0) } }
    }

    func reloadChats() async {
        loadingChats = true
        let folders = claudeSpaces.map { ClaudeChats.folders(for: $0.space) }
        chats = await Task.detached { ClaudeChats.scan(folders) }.value
        loadingChats = false
    }

    func prepareContinue(_ chat: Chat, in spaceID: UUID) async throws -> ChatTransfer {
        let folders = claudeSpaces.map { ClaudeChats.folders(for: $0.space) }
        guard let target = folders.first(where: { $0.spaceID == spaceID }) else { throw ChatError.transcriptMissing }
        return try await Task.detached { try ClaudeChats.prepare(chat: chat, target: target, spaces: folders) }.value
    }

    /// Instances that must be closed before a chat can be written: the source and target spaces.
    func instancesBlocking(_ transfer: ChatTransfer) -> [UUID] {
        guard transfer.kind != .upToDate else { return [] }
        return [transfer.source.spaceID, transfer.targetSpaceID].filter { running[$0] != nil }
    }

    func continueChat(_ transfer: ChatTransfer) async {
        guard let pair = claudeSpaces.first(where: { $0.space.id == transfer.targetSpaceID }) else { return }
        do {
            let backups = backupsURL
            try await Task.detached { try ClaudeChats.apply(transfer, backups: backups) }.value
            await open(transfer.targetSpaceID, in: pair.app.id, continueURL: ClaudeChats.continueURL(chatID: transfer.chatID))
            await reloadChats()
        } catch {
            notice = error.localizedDescription
        }
    }
}

enum SpaceError: LocalizedError {
    case running(String)
    case inUse(String, [String])

    var errorDescription: String? {
        switch self {
        case .running(let name): "Quit \(name) before deleting it."
        case .inUse(let name, let others):
            "\(others.joined(separator: ", ")) use files inside \(name)'s folder, so its data wasn't moved to the Trash."
        }
    }
}
