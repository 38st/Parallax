import AppKit
import Foundation
import Observation

struct ClaudeBlocker {
    var name: String
    var instance: NSRunningApplication
}

struct PendingClaudeOpen: Identifiable {
    var space: Space
    var quitting: [String]
    var pids: Set<pid_t>
    var pending: Int?
    var firstSignIn = false
    var targetRunning = false
    var id: UUID { space.id }
}

enum ClaudeOpenChoice: Equatable { case ask, quit(Set<pid_t>), withoutQuitting }
enum ClaudeOpenStep: Equatable { case showOrLaunch, ask(firstSignIn: Bool), quitThenLaunch, sync(quitFirst: Bool) }
struct SyncProgress: Equatable { var done = 0; var total = 0 }

@MainActor
struct AppHooks {
    var discoverRunningSpaces: ([ManagedApp]) -> [UUID: NSRunningApplication] = { Launcher.discoverRunningSpaces(apps: $0) }
    var runningInstances: (ManagedApp) -> [NSRunningApplication] = { Launcher.runningInstances(of: $0) }
    var processArguments: (pid_t) -> (arguments: [String], environment: [String: String])? = { ProcessArguments.read($0) }
    var activate: (NSRunningApplication) -> Void = { $0.activate() }
    var terminate: (NSRunningApplication) -> Void = { $0.terminate() }
    var isTerminated: (NSRunningApplication) -> Bool = { $0.isTerminated }
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var replyToTermination: () -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
    var locateCLI: (String) -> URL? = { ProviderCLI.locate($0) }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var elapsed: () -> Duration = { .seconds(ProcessInfo.processInfo.systemUptime) }
}

@MainActor
@Observable
final class AppModel {
    var apps: [ManagedApp] = []
    var accounts: [UsageAccount] = []
    /// Running instance per space.
    var running: [UUID: NSRunningApplication] = [:]
    var claudeOutsideSpaces: [pid_t] = []
    var busyAccounts: Set<UUID> = []
    var signingIn: Set<UUID> = []
    var chats: [Chat] = []
    var loadingChats = false
    var syncingClaudeChats = false
    var waitingForQuit = false
    var pendingClaudeOpen: PendingClaudeOpen?
    var syncProgress: SyncProgress?
    var launching: Set<UUID> = []
    var cliPaths: [Provider: String] = [:]
    var lastSync: (date: Date, result: ClaudeChats.SyncResult)?
    /// Disk use per space, filled in when the Storage page measures it.
    var storage: [UUID: SpaceStorage] = [:]
    var backupStorage: Int64?
    private(set) var terminationRequested = false
    var notice: String?
    var importedFromPreviousVersion = false

    @ObservationIgnored private var canSave = true
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var chatSyncCache = ChatSyncCache()
    @ObservationIgnored private let chatSyncCacheURL: URL
    @ObservationIgnored private let backupsURL: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored var hooks: AppHooks
    @ObservationIgnored var usagePageVisible = false
    @ObservationIgnored private var signOutStrikes: Set<UUID> = []
    @ObservationIgnored private var signInTasks: [UUID: Task<ProviderStatus, Error>] = [:]
    @ObservationIgnored private var syncTask: Task<(ClaudeChats.SyncResult, ChatSyncCache), Never>?
    @ObservationIgnored private var reportedSyncIssues: Set<String> = []
    @ObservationIgnored private var terminationReplied = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var savedDate: Date?
    @ObservationIgnored private var warnedCannotSave = false
    @ObservationIgnored private(set) var syncsStarted = 0
    @ObservationIgnored var signInStatus: @MainActor (UsageAccount) async throws -> ProviderStatus = { account in
        switch account.provider {
        case .claude: try await ClaudeProvider.signIn(configFolder: account.homeFolder)
        case .codex: try await CodexProvider.signIn(codexHome: account.homeFolder)
        }
    }
    @ObservationIgnored var syncChats: @Sendable (ClaudeChats.SpaceFolders, [ClaudeChats.SpaceFolders], URL, inout ChatSyncCache, @Sendable (Int, Int) -> Void) -> ClaudeChats.SyncResult = {
        ClaudeChats.syncAll(to: $0, spaces: $1, backups: $2, cache: &$3, progress: $4)
    }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var readStatus: @MainActor (UsageAccount) async throws -> ProviderStatus = { account in
        switch account.provider {
        case .claude: try await ClaudeProvider.status(configFolder: account.homeFolder)
        case .codex: try await CodexProvider.status(codexHome: account.homeFolder)
        }
    }
    @ObservationIgnored var openInstance: @MainActor (ManagedApp, LaunchPlan, URL?) async throws -> NSRunningApplication = {
        try await Launcher.open(app: $0, plan: $1, continueURL: $2)
    }

    /// - Parameters:
    ///   - support: Folder holding the saved state, chat backups, and the previous version's files.
    ///   - defaults: Where the previous version kept its usage accounts.
    init(support: URL = Paths.support, defaults: UserDefaults = .standard, startServices: Bool = true, hooks: AppHooks = AppHooks()) {
        self.hooks = hooks
        stateURL = support.appendingPathComponent("state.json")
        chatSyncCacheURL = support.appendingPathComponent("ChatSyncCache.json")
        backupsURL = support.appendingPathComponent("ChatBackups", isDirectory: true)
        load(previousVersion: { LegacyImport.load(support: support, defaults: defaults) })
        chatSyncCache = ChatSyncCache.load(from: chatSyncCacheURL)
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
                savedDate = stateModificationDate()
            } catch {
                canSave = false
                report("Parallax couldn't read its saved spaces (\(error.localizedDescription)). Nothing was changed on disk.")
            }
            return
        } catch {
            guard (error as? CocoaError)?.code == .fileReadNoSuchFile else {
                canSave = false
                report("Parallax couldn't read its saved spaces (\(error.localizedDescription)). Nothing was changed on disk.")
                return
            }
        }
        let previous = previousVersion()
        apps = previous.apps
        accounts = previous.accounts
        importedFromPreviousVersion = !previous.apps.isEmpty || !previous.accounts.isEmpty
        if previous.libraryProblem {
            report("Parallax couldn't read the previous version's library.json, so your spaces weren't brought over. It tries again the next time it starts unless you make changes now.")
        } else { save() }
    }

    func report(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        if let current = notice, !current.isEmpty {
            if !current.contains(message) { notice = current + "\n\n" + message }
        } else { notice = message }
    }

    private func stateModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate]) as? Date
    }

    func save(backup: Bool = false) {
        guard canSave else {
            if !warnedCannotSave {
                warnedCannotSave = true
                report("Parallax couldn't read state.json, so it isn't saving changes. Changes made now are lost when Parallax quits.")
            }
            return
        }
        if FileManager.default.fileExists(atPath: stateURL.path), stateModificationDate() != savedDate {
            canSave = false
            warnedCannotSave = true
            report("state.json was changed by another copy of Parallax. Quit the other copy and reopen Parallax; this copy stopped saving.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedState(apps: apps, accounts: accounts))
            if backup, FileManager.default.fileExists(atPath: stateURL.path) {
                let backup = stateURL.deletingPathExtension().appendingPathExtension("backup.json")
                _ = try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: stateURL, to: backup)
            }
            try data.write(to: stateURL, options: .atomic)
            savedDate = stateModificationDate()
        } catch {
            report("Couldn't save: \(error.localizedDescription)")
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
        cleanUpLeftovers()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanUpLeftovers() }
        }
    }

    /// Prunes old chat backups and stale caches of Claude spaces that aren't open.
    @discardableResult
    func cleanUpLeftovers() -> Task<Void, Never> {
        refreshRunning()
        let backups = backupsURL, now = now()
        let idle = apps.filter { $0.kind == .claude }.flatMap(\.spaces).filter { running[$0.id] == nil }
            .map { URL(fileURLWithPath: $0.folder, isDirectory: true).appendingPathComponent("UserData", isDirectory: true) }
        return Task.detached(priority: .background) {
            Housekeeping.pruneBackups(in: backups, now: now)
            Housekeeping.pruneCaches(userData: idle, now: now)
        }
    }

    // MARK: Storage

    /// Measures every space's folder plus Parallax's own chat backups.
    func measureStorage() async {
        let spaces = apps.flatMap(\.spaces).map { ($0.id, URL(fileURLWithPath: $0.folder, isDirectory: true)) }
        let backups = backupsURL
        let (measured, backupSize) = await Task.detached(priority: .utility) {
            (spaces.map { SpaceStorage.measure(spaceID: $0.0, folder: $0.1) }, Housekeeping.size(of: backups))
        }.value
        storage = Dictionary(uniqueKeysWithValues: measured.map { ($0.id, $0) })
        backupStorage = backupSize
    }

    func cleanUpNow() async {
        await cleanUpLeftovers().value
        await measureStorage()
    }

    func removeVMImage(_ spaceID: UUID) async {
        refreshRunning()
        guard let space = apps.flatMap(\.spaces).first(where: { $0.id == spaceID }) else { return }
        guard running[spaceID] == nil else {
            report(SpaceError.running(space.name).localizedDescription)
            return
        }
        let folder = URL(fileURLWithPath: space.folder, isDirectory: true)
        do {
            try await Task.detached { try Housekeeping.removeVMImage(folder: folder) }.value
        } catch {
            report("Couldn't remove \(space.name)'s VM image: \(error.localizedDescription)")
        }
        await measureStorage()
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
            report("\(existing.name) is already in Parallax.")
            return
        }
        let id = UUID()
        let kind = AppKind.detect(name: name, bundleID: bundleID)
        apps.append(ManagedApp(
            id: id, name: name, path: url.path, bundleID: bundleID,
            kind: kind, dataFolder: Paths.newAppFolder(id: id), sharedCodexHistory: kind == .codex
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
        refreshRunning()
        guard let app = app(id), !app.spaces.contains(where: { running[$0.id] != nil }) else {
            report("Quit this app's spaces before removing it.")
            return
        }
        apps.removeAll { $0.id == id }
        save(backup: true)
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

    nonisolated static func resolvedPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: LaunchPlanner.expandTilde(path, home: NSHomeDirectory())).standardizedFileURL
        var suffix: [String] = []
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            suffix.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for component in suffix { url.appendPathComponent(component) }
        return url.path
    }

    static func sharesChatFolders(userData: String, config: String, with target: ClaudeChats.SpaceFolders) -> Bool {
        resolvedPath(userData + "/claude-code-sessions") == resolvedPath(target.sessions.path)
            || resolvedPath(config) == resolvedPath(target.config.path)
    }

    /// Include ancestors too: moving a nested space can remove data another space uses.
    func spacesDepending(on space: Space) -> [Space] {
        let folder = Self.resolvedPath(space.folder)
        return apps.flatMap(\.spaces).filter { other in
            guard other.id != space.id else { return false }
            let words = ((try? LaunchText.words(other.arguments)) ?? []).map { word in
                if word.hasPrefix("-"), let equals = word.firstIndex(of: "=") { return String(word[word.index(after: equals)...]) }
                return word
            }
            let paths = [other.folder] + words + Array(LaunchText.environment(other.environment).values.values)
            return paths.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }.contains {
                let path = Self.resolvedPath($0)
                return path == folder || path.hasPrefix(folder + "/") || folder.hasPrefix(path + "/")
            }
        }
    }

    func deleteSpace(_ spaceID: UUID, in appID: UUID, moveDataToTrash: Bool) throws {
        guard let appIndex = apps.firstIndex(where: { $0.id == appID }),
              let space = apps[appIndex].spaces.first(where: { $0.id == spaceID }) else { return }
        refreshRunning()
        guard running[spaceID] == nil else { throw SpaceError.running(space.name) }
        if moveDataToTrash {
            let folder = URL(fileURLWithPath: space.folder).standardizedFileURL
            let profiles = URL(fileURLWithPath: apps[appIndex].dataFolder).appendingPathComponent("Profiles").standardizedFileURL
            guard folder.deletingLastPathComponent() == profiles, UUID(uuidString: folder.lastPathComponent) != nil else {
                throw SpaceError.unusualFolder(space.name)
            }
            let dependents = spacesDepending(on: space)
            guard dependents.isEmpty else { throw SpaceError.inUse(space.name, dependents.map(\.name)) }
            if FileManager.default.fileExists(atPath: space.folder) {
                try hooks.trash(URL(fileURLWithPath: space.folder))
            }
        }
        apps[appIndex].spaces.removeAll { $0.id == spaceID }
        save(backup: true)
    }

    // MARK: Running instances

    func refreshRunning() {
        running = running.filter { !hooks.isTerminated($0.value) }
        for (spaceID, instance) in hooks.discoverRunningSpaces(apps) where running[spaceID] == nil && !hooks.isTerminated(instance) {
            running[spaceID] = instance
        }
        claudeOutsideSpaces = Array(Set(apps.filter { $0.kind == .claude }
            .flatMap { instancesOutsideSpaces(of: $0).map(\.processIdentifier) })).sorted()
    }

    func instancesOutsideSpaces(of app: ManagedApp) -> [NSRunningApplication] {
        hooks.runningInstances(app).filter { instance in
            !hooks.isTerminated(instance) && Launcher.isOutsideSpaces(hooks.processArguments(instance.processIdentifier)?.arguments, kind: app.kind)
                && !running.values.contains(where: { $0.processIdentifier == instance.processIdentifier })
        }
    }

    func open(_ spaceID: UUID, in appID: UUID, continueURL: URL? = nil) async {
        guard let app = app(appID), let space = app.spaces.first(where: { $0.id == spaceID }) else { return }
        if app.kind == .claude {
            guard !syncingClaudeChats else { return }
            if continueURL == nil {
                await openClaudeSpace(spaceID)
                return
            }
        }
        if let instance = running[spaceID], !hooks.isTerminated(instance), continueURL == nil {
            hooks.activate(instance)
            return
        }
        do {
            try await launch(space, in: app, continueURL: continueURL)
        } catch {
            report(error.localizedDescription)
        }
    }

    func launch(_ space: Space, in app: ManagedApp, continueURL: URL? = nil) async throws {
        guard !terminationRequested, launching.insert(space.id).inserted else { return }
        defer { launching.remove(space.id) }
        refreshRunning()
        if let instance = running[space.id], !hooks.isTerminated(instance) {
            if continueURL != nil { throw LaunchError.alreadyRunning(space.name) }
            hooks.activate(instance)
            return
        }
        let plan = try LaunchPlanner.plan(app: app, space: space)
        let instance = try await openInstance(app, plan, continueURL)
        if !(app.kind == .codex && app.sharedCodexHistory) { running[space.id] = instance }
        guard var updated = self.app(app.id)?.spaces.first(where: { $0.id == space.id }) else { return }
        updated.lastOpened = now()
        updateSpace(updated, in: app.id)
    }

    static func claudeOpenStep(choice: ClaudeOpenChoice, signedIn: Bool, pending: Int, folderProblem: String?,
                               targetRunning: Bool, blockerPIDs: Set<pid_t>, otherPIDs: Set<pid_t>) -> ClaudeOpenStep {
        if !signedIn {
            let quitOthers: Bool
            if otherPIDs.isEmpty || choice == .withoutQuitting { quitOthers = false }
            else if case .quit(let confirmed) = choice, otherPIDs.isSubset(of: confirmed) { quitOthers = true }
            else { return .ask(firstSignIn: true) }
            // An ended login keeps its account's chat folder, so fill it before the user signs back in.
            if pending > 0, !targetRunning, quitOthers || blockerPIDs.isEmpty { return .sync(quitFirst: quitOthers) }
            return quitOthers ? .quitThenLaunch : .showOrLaunch
        }
        if pending == 0 || choice == .withoutQuitting { return .showOrLaunch }
        if blockerPIDs.isEmpty { return .sync(quitFirst: false) }
        if case .quit(let confirmed) = choice, blockerPIDs.isSubset(of: confirmed) { return .sync(quitFirst: true) }
        return .ask(firstSignIn: false)
    }

    private func allClaudeInstances() -> [ClaudeBlocker] {
        var result: [ClaudeBlocker] = []
        var seen: Set<pid_t> = []
        for pair in claudeSpaces {
            if let instance = running[pair.space.id], !hooks.isTerminated(instance) {
                if seen.insert(instance.processIdentifier).inserted {
                    result.append(ClaudeBlocker(name: pair.space.name, instance: instance))
                } else if let index = result.firstIndex(where: { $0.instance.processIdentifier == instance.processIdentifier }) {
                    result[index].name += " / " + pair.space.name
                }
            }
        }
        for app in apps where app.kind == .claude {
            for instance in hooks.runningInstances(app) where !hooks.isTerminated(instance) && seen.insert(instance.processIdentifier).inserted {
                result.append(ClaudeBlocker(name: "Claude without a space", instance: instance))
            }
        }
        return result
    }

    func otherClaudeInstances(except id: UUID) -> [ClaudeBlocker] {
        let own = running[id]?.processIdentifier
        return allClaudeInstances().filter { $0.instance.processIdentifier != own }
    }

    func claudeBlockers(writingInto target: Space) -> [ClaudeBlocker] {
        let folders = ClaudeChats.folders(for: target)
        return allClaudeInstances().filter { blocker in
            let pid = blocker.instance.processIdentifier
            // Unreadable arguments always block, including managed instances.
            guard let process = hooks.processArguments(pid) else { return true }
            if running[target.id]?.processIdentifier == pid { return true }
            let managed = claudeSpaces.filter { running[$0.space.id]?.processIdentifier == pid }
            if managed.contains(where: {
                let own = ClaudeChats.folders(for: $0.space)
                return Self.sharesChatFolders(userData: own.sessions.deletingLastPathComponent().path, config: own.config.path, with: folders)
            }) { return true }
            // Check actual process folders too, in case settings changed since it launched.
            let userData = process.arguments.optionValue(LaunchPlanner.userDataOptions) ?? "~/Library/Application Support/Claude"
            let config = process.environment["CLAUDE_CONFIG_DIR"] ?? "~/.claude"
            return Self.sharesChatFolders(userData: userData, config: config, with: folders)
        }
    }

    func openClaudeSpace(_ spaceID: UUID, choice: ClaudeOpenChoice = .ask) async {
        guard !syncingClaudeChats, !terminationRequested,
              let target = claudeSpaces.first(where: { $0.space.id == spaceID }) else { return }
        pendingClaudeOpen = nil
        do { _ = try Launcher.validate(app: target.app, plan: LaunchPlanner.plan(app: target.app, space: target.space)) }
        catch { report(error.localizedDescription); return }
        syncingClaudeChats = true
        defer { finishClaudeWork() }
        refreshRunning()
        let folders = claudeSpaces.map { ClaudeChats.folders(for: $0.space) }
        let destination = ClaudeChats.folders(for: target.space)
        let initial = chatSyncCache
        let (signedIn, pending, layout, folderProblem): (Bool, Int, Bool, String?) = await Task.detached {
            let hasChats = !ClaudeChats.namespaces(in: destination).isEmpty
            let signedIn = ClaudeChats.hasSignIn(destination) ?? hasChats
            guard hasChats, folders.count > 1 else { return (signedIn, 0, false, nil) }
            // Copying the sidebar layout needs the same stopped Claude as a chat.
            let layout = ClaudeChats.carriedLayout(to: destination, spaces: folders) != nil
            do { return (signedIn, try ClaudeChats.pendingChatCount(to: destination, spaces: folders, cache: initial, otherSpacesOnly: true), layout, nil) }
            catch { return (signedIn, 0, layout, signedIn ? error.localizedDescription : nil) }
        }.value
        guard !terminationRequested else { return }
        refreshRunning()
        let writers = claudeBlockers(writingInto: target.space)
        let blockers = signedIn ? writers : otherClaudeInstances(except: spaceID)
        let pids = Set(blockers.map { $0.instance.processIdentifier })
        let step = Self.claudeOpenStep(choice: choice, signedIn: signedIn, pending: pending + (layout ? 1 : 0), folderProblem: folderProblem,
                                      targetRunning: running[spaceID] != nil,
                                      blockerPIDs: Set(writers.map { $0.instance.processIdentifier }), otherPIDs: pids)
        if case .ask(let firstSignIn) = step {
            pendingClaudeOpen = PendingClaudeOpen(space: target.space, quitting: blockers.map(\.name), pids: pids,
                                                  pending: pending, firstSignIn: firstSignIn, targetRunning: running[spaceID] != nil)
            return
        }
        if step == .quitThenLaunch || step == .sync(quitFirst: true) {
            guard await quitAndWait(blockers.map(\.instance)) else {
                if !terminationRequested { report(Self.quitFailure(blockers.map(\.name))) }
                return
            }
            let remaining = signedIn ? claudeBlockers(writingInto: target.space) : otherClaudeInstances(except: spaceID)
            guard remaining.isEmpty else {
                report("Claude is still open in \(remaining.map(\.name).joined(separator: ", ")). Quit it there, then open this space again.")
                return
            }
        }
        guard !terminationRequested else { return }
        guard claudeSpaces.contains(where: { $0.space == target.space && $0.app == target.app }) else {
            report("This space changed while Claude was closing. Open it again to carry over its chats.")
            return
        }
        if case .sync = step {
            // Re-check immediately before handing the destination to the writer.
            refreshRunning()
            let remaining = claudeBlockers(writingInto: target.space)
            guard remaining.isEmpty else { report("Quit Claude in \(remaining.map(\.name).joined(separator: ", ")), then try again."); return }
            syncProgress = .init(total: pending)
            syncsStarted += 1
            let generation = syncsStarted
            let reportProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                guard done == total || done % max(1, total / 50) == 0 else { return }
                Task { @MainActor in
                    if self?.syncsStarted == generation, self?.syncProgress != nil { self?.syncProgress = .init(done: done, total: total) }
                }
            }
            let backups = backupsURL
            let cacheURL = chatSyncCacheURL
            let sync = syncChats
            let task = Task.detached {
                var cache = initial
                let result = sync(destination, folders, backups, &cache, reportProgress)
                cache.save(to: cacheURL)
                return (result, cache)
            }
            syncTask = task
            let (result, cache) = await task.value
            chatSyncCache = cache
            syncProgress = nil
            lastSync = (now(), result)
            guard !terminationRequested else { return }
            report(result.summary(excluding: reportedSyncIssues))
            reportedSyncIssues.formUnion(result.issues)
            if result.stopped {
                report("Stopped after \(result.checked) of \(result.total) chats. The rest carry over the next time you open \(target.space.name).")
            }
            guard claudeSpaces.contains(where: { $0.space == target.space && $0.app == target.app }) else {
                report("The space changed while chats were being carried over. Open it again to continue.")
                await reloadChats()
                return
            }
        } else {
            report(folderProblem)
            if !signedIn, folders.count > 1, target.space.lastOpened == nil {
                report("After you sign in, open the Code tab once, then open this space again here to bring in chats from your other spaces.")
            }
        }
        do { try await launch(target.space, in: target.app) }
        catch { report(error.localizedDescription) }
        if case .sync = step { await reloadChats() }
    }

    func stopSync() { syncTask?.cancel() }

    func quitRequested() -> Bool {
        guard syncingClaudeChats || waitingForQuit || (terminationRequested && !terminationReplied) else { return false }
        terminationRequested = true
        stopSync()
        stopWaitingForQuit()
        return true
    }

    private func finishClaudeWork() {
        syncingClaudeChats = false
        syncProgress = nil
        syncTask = nil
        if terminationRequested, !terminationReplied {
            terminationReplied = true
            hooks.replyToTermination()
        }
    }

    func openSharedCodex(_ appID: UUID) async {
        guard let app = app(appID) else { return }
        refreshRunning()
        let isolated = app.spaces.first { running[$0.id] != nil }?.name
        let other = hooks.runningInstances(app).contains { instance in
            guard !hooks.isTerminated(instance) else { return false }
            guard let args = hooks.processArguments(instance.processIdentifier)?.arguments else { return true }
            return args.containsOption(LaunchPlanner.userDataOptions)
        }
        guard isolated == nil && !other else {
            report("Quit \(isolated ?? "the isolated Codex window") first. Codex would switch to it instead of opening the shared history.")
            return
        }
        do { _ = try await openInstance(app, LaunchPlanner.plan(app: app, space: nil), nil) }
        catch { report(error.localizedDescription) }
    }

    func show(_ spaceID: UUID) { if let instance = running[spaceID] { hooks.activate(instance) } }
    func quit(_ spaceID: UUID) { if let instance = running[spaceID] { hooks.terminate(instance) } }

    static let quitWaitingText = "Waiting for Claude to quit. Claude may ask you to confirm, or wait until its running Code sessions finish."
    static func quitFailure(_ names: [String]) -> String {
        "Claude is still open in \(names.joined(separator: ", ")). If you chose “Wait for Claude”, it quits by itself when its sessions finish; open the space again then."
    }

    func quitAndWait(_ requested: [NSRunningApplication], timeout: Duration = .seconds(600)) async -> Bool {
        var seen: Set<pid_t> = []
        let instances = requested.filter { !hooks.isTerminated($0) && seen.insert($0.processIdentifier).inserted }
        guard !instances.isEmpty else { return true }
        guard !waitingForQuit, !terminationRequested else { return false }
        waitingForQuit = true
        defer {
            waitingForQuit = false
            refreshRunning()
            if !syncingClaudeChats { finishClaudeWork() }
        }
        let start = hooks.elapsed()
        instances.forEach { hooks.terminate($0) }
        var activated = false
        while waitingForQuit && !Task.isCancelled && !terminationRequested {
            let alive = instances.filter { !hooks.isTerminated($0) }
            if alive.isEmpty { return true }
            let elapsed = hooks.elapsed() - start
            if elapsed >= .seconds(2), !activated { hooks.activate(alive[0]); activated = true }
            guard elapsed < timeout else { return false }
            do { try await hooks.sleep(min(.milliseconds(250), timeout - elapsed)) }
            catch { return false }
        }
        return false
    }

    func stopWaitingForQuit() { waitingForQuit = false }

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
        cancelSignIn(id)
        accounts.removeAll { $0.id == id }
        signOutStrikes.remove(id)
        save(backup: true)
    }

    func renameAccount(_ id: UUID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = label
        save()
    }

    func signIn(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !busyAccounts.contains(id) else { return }
        busyAccounts.insert(id)
        signingIn.insert(id)
        defer {
            busyAccounts.remove(id)
            signingIn.remove(id)
            signInTasks[id] = nil
        }
        cliPaths[account.provider] = hooks.locateCLI(account.provider.rawValue)?.resolvingSymlinksInPath().path
        let task = Task { try await signInStatus(account) }
        signInTasks[id] = task
        do {
            let status = try await task.value
            guard !task.isCancelled else { return }
            apply(status, to: id)
        } catch {
            record(error, for: id)
        }
    }

    func cancelSignIn(_ id: UUID) { signInTasks[id]?.cancel() }

    func refresh(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !busyAccounts.contains(id) else { return }
        busyAccounts.insert(id)
        lastAttempt[id] = now()
        defer { busyAccounts.remove(id) }
        do {
            let status = try await readStatus(account)
            apply(status, to: id)
        } catch {
            record(error, for: id)
        }
    }

    func refreshAllAccounts(onlyIfStale: Bool) async {
        for provider in Set(accounts.map(\.provider)) {
            cliPaths[provider] = hooks.locateCLI(provider.rawValue)?.resolvingSymlinksInPath().path
        }
        for id in accounts.map(\.id) {
            guard let account = accounts.first(where: { $0.id == id }), !busyAccounts.contains(id) else { continue }
            if onlyIfStale {
                let last = account.signedIn ? account.lastRefreshed : lastAttempt[id]
                let interval: TimeInterval = account.signedIn ? (usagePageVisible ? 270 : 870) : 3600
                if let last, now().timeIntervalSince(last) < interval { continue }
            }
            await refresh(id)
        }
    }

    private func apply(_ status: ProviderStatus, to id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        signOutStrikes.remove(id)
        accounts[index].signedIn = true
        if let email = status.email, !email.isEmpty { accounts[index].email = email }
        if let plan = status.plan, !plan.isEmpty { accounts[index].plan = plan }
        if status.usageError == nil {
            accounts[index].windows = status.windows
            accounts[index].lastRefreshed = now()
        }
        accounts[index].lastError = status.usageError
        save()
    }

    private func record(_ error: Error, for id: UUID) {
        guard !(error is CancellationError), let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if (error as? ProviderError) == .signedOut {
            if signOutStrikes.contains(id) || !accounts[index].signedIn { accounts[index].signedIn = false }
            signOutStrikes.insert(id)
        } else { signOutStrikes.remove(id) }
        accounts[index].lastError = error.localizedDescription
        save()
    }

    // MARK: Chats

    var claudeSpaces: [(app: ManagedApp, space: Space)] {
        apps.filter { $0.kind == .claude }.flatMap { app in app.spaces.map { (app, $0) } }
    }

    func reloadChats() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loadingChats = true
        let folders = claudeSpaces.map { ClaudeChats.folders(for: $0.space) }
        let loaded = await Task.detached {
            let all = ClaudeChats.scan(folders)
            let deleted = Set(ClaudeChats.deletedElsewhere(all, spaces: folders).map(\.chat.id)
                + ClaudeChats.archivedElsewhere(all, spaces: folders).map(\.id))
            return all.filter { !deleted.contains($0.id) }
        }.value
        guard generation == reloadGeneration else { return }
        chats = loaded
        loadingChats = false
    }

    func prepareContinue(_ chat: Chat, in spaceID: UUID) async throws -> ChatTransfer {
        let folders = claudeSpaces.map { ClaudeChats.folders(for: $0.space) }
        guard let target = folders.first(where: { $0.spaceID == spaceID }) else { throw ChatError.transcriptMissing }
        return try await Task.detached {
            try ClaudeChats.prepare(chat: chat, target: target, spaces: folders, targetNamespace: ClaudeChats.primaryNamespace(in: target))
        }.value
    }

    func instancesBlocking(_ transfer: ChatTransfer) -> [ClaudeBlocker] {
        guard let pair = claudeSpaces.first(where: { $0.space.id == transfer.targetSpaceID }) else { return [] }
        if transfer.kind == .upToDate {
            guard let instance = running[pair.space.id], !hooks.isTerminated(instance) else { return [] }
            return [ClaudeBlocker(name: pair.space.name, instance: instance)]
        }
        return claudeBlockers(writingInto: pair.space)
    }

    func continueChat(_ transfer: ChatTransfer) async {
        guard !syncingClaudeChats else { report("Parallax is still carrying over chats. Try again when it finishes."); return }
        guard !terminationRequested else { return }
        guard let pair = claudeSpaces.first(where: { $0.space.id == transfer.targetSpaceID }) else {
            report("That space is no longer in Parallax."); return
        }
        do { _ = try Launcher.validate(app: pair.app, plan: LaunchPlanner.plan(app: pair.app, space: pair.space)) }
        catch { report(error.localizedDescription); return }
        syncingClaudeChats = true
        defer { finishClaudeWork() }
        refreshRunning()
        let blockers = instancesBlocking(transfer)
        guard blockers.isEmpty else {
            report("Quit Claude in \(blockers.map(\.name).joined(separator: ", ")), then try again.")
            return
        }
        do {
            let backups = backupsURL
            try await Task.detached { try ClaudeChats.apply(transfer, backups: backups) }.value
            guard !terminationRequested else { return }
            try await launch(pair.space, in: pair.app, continueURL: ClaudeChats.continueURL(chatID: transfer.chatID))
            await reloadChats()
        } catch {
            report(error.localizedDescription)
        }
    }
}

enum SpaceError: LocalizedError {
    case running(String)
    case inUse(String, [String])
    case unusualFolder(String)

    var errorDescription: String? {
        switch self {
        case .unusualFolder(let name): "\(name) isn’t in Parallax’s spaces folder, so it wasn’t moved to the Trash."
        case .running(let name): "Quit \(name) before deleting it."
        case .inUse(let name, let others):
            "\(others.joined(separator: ", ")) use files inside \(name)'s folder, so its data wasn't moved to the Trash."
        }
    }
}
