import XCTest
@testable import Parallax

final class LegacyImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parallax-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let library = """
    {"version":2,"revision":4,"applications":[
     {"id":"11111111-1111-1111-1111-111111111111","storageID":"AAAAAAAA-1111-1111-1111-111111111111","displayName":"ChatGPT",
      "bundleIdentifier":"com.openai.codex","appPath":"/Applications/ChatGPT.app","preset":"automatic","profiles":[
       {"id":"22222222-2222-2222-2222-222222222222","storageID":"bbbbbbbb-2222-2222-2222-222222222222","name":"Generated",
        "argumentsText":"'--user-data-dir=/old/UserData' --keep","environmentText":"CODEX_HOME=/old/CodexHome\\nKEEP=1","notes":"",
        "isolationOwnership":{"userData":"generated","codexHome":"generated"},"childEnvironmentPolicy":"safeDefault",
        "launchConfigurationTrust":"local","lastLaunchedAt":800000000},
       {"id":"33333333-3333-3333-3333-333333333333","storageID":"cccccccc-3333-3333-3333-333333333333","name":"Account",
        "argumentsText":"--user-data-dir=/explicit","environmentText":"CODEX_HOME=/accounts/x","notes":"",
        "isolationOwnership":{"userData":"explicit","codexHome":"explicit"},"accountLink":{"expectedEmail":" a@b.com "}}]},
     {"id":"44444444-4444-4444-4444-444444444444","storageID":"dddddddd-4444-4444-4444-444444444444","displayName":"Claude",
      "bundleIdentifier":"com.anthropic.claudefordesktop","appPath":"/Applications/Claude.app","baseStoragePath":"/Volumes/Data","profiles":[
       {"id":"55555555-5555-5555-5555-555555555555","storageID":"eeeeeeee-5555-5555-5555-555555555555","name":"Personal",
        "argumentsText":"","environmentText":"","notes":"","isolationOwnership":{"userData":"explicit","codexHome":"explicit"},
        "childEnvironmentPolicy":"inheritProcessEnvironment"}]}]}
    """

    func testLibraryImportKeepsFoldersAndDropsGeneratedOptions() throws {
        try Data(library.utf8).write(to: root.appendingPathComponent("library.json"))
        try Data(#"{"schemaVersion":4,"groups":[],"codexWorkspaces":{"AAAAAAAA-1111-1111-1111-111111111111":{"path":"/x"}}}"#.utf8)
            .write(to: root.appendingPathComponent("shared-history.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))

        let result = LegacyImport.load(support: root, defaults: defaults)
        XCTAssertEqual(result.apps.count, 2)
        XCTAssertTrue(result.accounts.isEmpty)

        let codex = result.apps[0]
        XCTAssertEqual(codex.kind, .codex)
        XCTAssertTrue(codex.sharedCodexHistory)
        let appFolder = root.appendingPathComponent("Profiles/.parallax/Applications/aaaaaaaa-1111-1111-1111-111111111111").path
        XCTAssertEqual(codex.dataFolder, appFolder)
        XCTAssertEqual(codex.spaces[0].folder, appFolder + "/Profiles/bbbbbbbb-2222-2222-2222-222222222222")
        XCTAssertEqual(codex.spaces[0].arguments, "--keep")
        XCTAssertEqual(codex.spaces[0].environment, "KEEP=1")
        XCTAssertEqual(codex.spaces[0].lastOpened, Date(timeIntervalSinceReferenceDate: 800000000))
        XCTAssertEqual(codex.spaces[1].arguments, "--user-data-dir=/explicit")
        XCTAssertEqual(codex.spaces[1].environment, "CODEX_HOME=/accounts/x")
        XCTAssertEqual(codex.spaces[1].email, "a@b.com")

        let claude = result.apps[1]
        XCTAssertEqual(claude.kind, .claude)
        XCTAssertFalse(claude.sharedCodexHistory)
        XCTAssertEqual(claude.spaces[0].folder,
                       "/Volumes/Data/.parallax/Applications/dddddddd-4444-4444-4444-444444444444/Profiles/eeeeeeee-5555-5555-5555-555555555555")
        XCTAssertTrue(claude.spaces[0].inheritEnvironment)
    }

    func testAccountsImportOnlyConnectedOnes() throws {
        let workspace = """
        {"organizationName":"","cycleEndsAt":0,"autoRebalanceEnabled":false,"providerPools":[],"members":[],"transfers":[],
         "trackedAccounts":[
          {"id":"20000000-0000-0000-0000-000000000001","provider":"claude","label":"Main","email":"a@b.com","planName":"Max",
           "usagePercent":6,"resetsAt":809000000,"isConnected":true,"lastSuccessfulRefreshAt":808990000,
           "usageWindows":[{"kind":"session","usagePercent":6,"resetsAt":809000000},{"kind":"weeklyModel","modelName":"Fable","usagePercent":3}]},
          {"id":"10000000-0000-0000-0000-000000000001","provider":"codex","label":"Placeholder","email":"","planName":"",
           "usagePercent":0,"resetsAt":0,"isConnected":false}]}
        """
        let accounts = try LegacyImport.accounts(fromWorkspace: Data(workspace.utf8))
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].provider, .claude)
        XCTAssertEqual(accounts[0].windows.map(\.title), ["Session", "Week · Fable"])
        XCTAssertTrue(accounts[0].homeFolder.path.hasSuffix("AccountSessions/20000000-0000-0000-0000-000000000001/ClaudeConfig"))
    }

    func testCodexSpaceUsingAnAccountLoginGetsItsEmail() throws {
        let accountID = UUID()
        let home = UsageAccount(id: accountID, provider: .codex, label: "x").homeFolder.path
        let library = """
        {"version":2,"applications":[{"id":"\(UUID())","storageID":"\(UUID())","displayName":"ChatGPT","bundleIdentifier":"com.openai.codex",
         "appPath":"/Applications/ChatGPT.app","profiles":[{"id":"\(UUID())","storageID":"\(UUID())","name":"Work","argumentsText":"",
         "environmentText":"CODEX_HOME=\(home)","notes":""}]}]}
        """
        try Data(library.utf8).write(to: root.appendingPathComponent("library.json"))
        let workspace = """
        {"trackedAccounts":[{"id":"\(accountID)","provider":"codex","label":"Work","email":"w@x.com","planName":"Pro",
         "usagePercent":1,"resetsAt":0,"isConnected":true}]}
        """
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(["corporate.workspace.v1": Data(workspace.utf8)], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(LegacyImport.load(support: root, defaults: defaults).apps[0].spaces[0].email, "w@x.com")
    }

    @MainActor
    func testModelImportsOnceAndThenUsesItsOwnFile() throws {
        try Data(library.utf8).write(to: root.appendingPathComponent("library.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let first = AppModel(support: root, defaults: defaults, startServices: false)
        XCTAssertTrue(first.importedFromPreviousVersion)
        XCTAssertEqual(first.apps.count, 2)
        first.removeApp(first.apps[0].id)

        let second = AppModel(support: root, defaults: defaults, startServices: false)
        XCTAssertFalse(second.importedFromPreviousVersion)
        XCTAssertEqual(second.apps.map(\.name), ["Claude"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), Data(library.utf8))
    }

    @MainActor
    func testUnreadableAndFutureStateAreNeverOverwritten() throws {
        let state = root.appendingPathComponent("state.json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        for contents in ["{broken", #"{"version":99,"apps":[],"accounts":[]}"#] {
            let data = Data(contents.utf8)
            try data.write(to: state)
            let model = AppModel(support: root, defaults: defaults, startServices: false)
            XCTAssertNotNil(model.notice)
            model.save()
            model.removeApp(UUID())
            XCTAssertEqual(try Data(contentsOf: state), data)
        }
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        XCTAssertNotNil(model.notice)
        model.save()
        XCTAssertTrue(try state.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @MainActor
    func testSharedAndAliasedSpaceFoldersPreventTrash() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        let folder = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let a = Space(name: "A", folder: folder.path)
        for path in [folder.path, alias.path, alias.appendingPathComponent("child").path] {
            let b = Space(name: "B", folder: path)
            let app = ManagedApp(name: "App", path: "/App.app", kind: .chromium, dataFolder: root.path, spaces: [a, b])
            model.apps = [app]
            let dependent = try XCTUnwrap(model.spacesDepending(on: a).first)
            XCTAssertEqual(dependent.id, b.id)
            XCTAssertThrowsError(try model.deleteSpace(a.id, in: app.id, moveDataToTrash: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @MainActor
    func testUsageAccountMatchingIncludesProvider() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        let codex = UsageAccount(provider: .codex, label: "Codex", email: "same@example.com")
        let claude = UsageAccount(provider: .claude, label: "Claude", email: "same@example.com")
        model.accounts = [codex, claude]
        XCTAssertEqual(model.account(forEmail: "Same@example.com", provider: .claude)?.id, claude.id)
        XCTAssertEqual(model.account(forEmail: "Same@example.com", provider: .codex)?.id, codex.id)
    }

    func testClaudeUsageLoginPathNeverChanges() throws {
        let id = try XCTUnwrap(UUID(uuidString: "53B0FDE6-3B80-4374-A9A2-E224AF08EC20"))
        let path = UsageAccount(id: id, provider: .claude, label: "Test").homeFolder.path
        XCTAssertTrue(path.hasSuffix("/AccountSessions/53b0fde6-3b80-4374-a9a2-e224af08ec20/ClaudeConfig"))
        XCTAssertFalse(path.hasSuffix("/"))
    }

    @MainActor
    func testRefreshAllRecoversSignedOutAccount() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID())"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        model.accounts = [UsageAccount(provider: .claude, label: "Test", lastError: ProviderError.signedOut.localizedDescription)]
        let now = Date(timeIntervalSince1970: 1_000_000)
        model.now = { now }
        var reads = 0
        model.readStatus = { account in
            reads += 1
            XCTAssertTrue(model.busyAccounts.contains(account.id))
            XCTAssertTrue(model.signingIn.isEmpty)
            return ProviderStatus(email: "test@example.com", plan: "Max", windows: [UsageWindow(title: "Session", percent: 6)])
        }
        await model.refreshAllAccounts(onlyIfStale: false)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(model.accounts[0].signedIn)
        XCTAssertEqual(model.accounts[0].windows.first?.percent, 6)
        XCTAssertEqual(model.accounts[0].lastRefreshed, now)
        XCTAssertNil(model.accounts[0].lastError)
        XCTAssertTrue(model.busyAccounts.isEmpty)
    }

    @MainActor
    func testSignedOutAccountsRetryHourlyIncludingTheFirstAttempt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID())"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var now = start
        model.now = { now }
        model.accounts = [UsageAccount(provider: .claude, label: "Test", lastRefreshed: start)]
        var reads = 0
        model.readStatus = { _ in
            reads += 1
            throw ProviderError.signedOut
        }
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(model.accounts[0].signedIn)
        now = start.addingTimeInterval(10 * 60)
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(reads, 1)
        now = start.addingTimeInterval(61 * 60)
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(reads, 2)
        await model.refreshAllAccounts(onlyIfStale: false)
        XCTAssertEqual(reads, 3, "Refresh All bypasses the hourly limit")
    }

    @MainActor
    func testSignedInAccountsKeepTheirStalenessIntervalAndOnlySignOutOnConfirmation() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID())"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var now = start
        model.now = { now }
        model.accounts = [UsageAccount(provider: .claude, label: "Test", lastRefreshed: start, signedIn: true)]
        var reads = 0
        model.readStatus = { _ in
            reads += 1
            return ProviderStatus(windows: [])
        }
        now = start.addingTimeInterval(269)
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(reads, 0)
        now = start.addingTimeInterval(270)
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(reads, 1)
        for error in [ProviderError.timedOut, .failed("Synthetic failure"), .toolMissing("claude")] {
            model.readStatus = { _ in throw error }
            await model.refreshAllAccounts(onlyIfStale: false)
            XCTAssertTrue(model.accounts[0].signedIn)
            XCTAssertEqual(model.accounts[0].lastError, error.localizedDescription)
        }
        model.readStatus = { _ in throw ProviderError.signedOut }
        await model.refreshAllAccounts(onlyIfStale: false)
        XCTAssertFalse(model.accounts[0].signedIn)
        XCTAssertEqual(model.accounts[0].lastError, "This account's command-line login ended (they expire every few weeks). Sign in again to read usage.")
    }

    @MainActor
    func testConcurrentRefreshAllReadsEachAccountOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID())"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        model.accounts = [UsageAccount(provider: .claude, label: "One"), UsageAccount(provider: .codex, label: "Two")]
        model.now = { Date(timeIntervalSince1970: 1_000_000) }
        var reads: [UUID: Int] = [:]
        var finish: CheckedContinuation<Void, Never>?
        var refresh: Task<Void, Never>?
        await withCheckedContinuation { started in
            model.readStatus = { account in
                reads[account.id, default: 0] += 1
                if account.id == model.accounts[0].id {
                    await withCheckedContinuation { continuation in
                        finish = continuation
                        started.resume()
                    }
                }
                return ProviderStatus(windows: [])
            }
            refresh = Task { await model.refreshAllAccounts(onlyIfStale: false) }
        }
        await model.refreshAllAccounts(onlyIfStale: false)
        await model.refresh(model.accounts[0].id)
        XCTAssertEqual(reads[model.accounts[0].id], 1)
        finish?.resume()
        await refresh?.value
        XCTAssertEqual(reads, Dictionary(uniqueKeysWithValues: model.accounts.map { ($0.id, 1) }))
        XCTAssertTrue(model.busyAccounts.isEmpty)
    }

    @MainActor
    func testClaudeBulkOpenRejectsInvalidLaunchBeforeCopyingChats() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        let source = Space(name: "Source", folder: root.appendingPathComponent("source").path)
        var target = Space(name: "Target", folder: root.appendingPathComponent("target").path)
        let sourceFolders = ClaudeChats.folders(for: source)
        let destination = ClaudeChats.folders(for: target).sessions.appendingPathComponent("account/org")
        let sourceNamespace = sourceFolders.sessions.appendingPathComponent("account/org")
        let project = sourceFolders.config.appendingPathComponent("projects/project")
        for folder in [sourceNamespace, destination, project] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(#"{"sessionId":"local_chat","cliSessionId":"chat","cwd":"/work","lastActivityAt":100}"#.utf8)
            .write(to: sourceNamespace.appendingPathComponent("local_chat.json"))
        try Data(#"{"type":"user","sessionId":"chat","cwd":"/work","message":{"role":"user","content":"Keep this chat"}}"#.utf8)
            .write(to: project.appendingPathComponent("chat.jsonl"))

        // Neither a missing app nor malformed saved arguments may trigger a copy or launch.
        for arguments in ["", "'unterminated"] {
            target.arguments = arguments
            let app = ManagedApp(name: "Synthetic Claude", path: root.appendingPathComponent("Missing.app").path,
                                 kind: .claude, dataFolder: root.path, spaces: [source, target])
            model.apps = [app]
            model.notice = nil
            await model.open(target.id, in: app.id)
            XCTAssertNotNil(model.notice)
            XCTAssertFalse(model.syncingClaudeChats)
            XCTAssertNil(model.pendingClaudeSpace)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ChatBackups").path))
        }
    }

    @MainActor
    func testDeletingRefusesTrashWhenAnotherSpaceUsesTheFolder() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "parallax-test-\(UUID().uuidString)"))
        let model = AppModel(support: root, defaults: defaults, startServices: false)
        model.apps = [ManagedApp(name: "Chrome", path: "/Applications/Chrome.app", kind: .chromium, dataFolder: root.path)]
        let appID = model.apps[0].id
        let target = try XCTUnwrap(model.addSpace(to: appID, name: "A", email: "", codexAccount: nil))
        let other = try XCTUnwrap(model.addSpace(to: appID, name: "B", email: "", codexAccount: nil))
        var edited = other
        edited.arguments = "--user-data-dir=\(target.folder)/UserData/Default"
        model.updateSpace(edited, in: appID)

        XCTAssertThrowsError(try model.deleteSpace(target.id, in: appID, moveDataToTrash: true))
        XCTAssertEqual(model.apps[0].spaces.count, 2)
        try model.deleteSpace(target.id, in: appID, moveDataToTrash: false)
        XCTAssertEqual(model.apps[0].spaces.map(\.name), ["B"])
    }
}

final class UsageParsingTests: XCTestCase {
    private func envelope(_ result: String, cost: Double = 0, tokens: Int = 0) -> Data {
        let object: [String: Any] = ["type": "result", "total_cost_usd": cost, "usage": ["input_tokens": tokens, "output_tokens": 0], "result": result]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")!

    func testClaudeUsageLines() throws {
        let text = "You are currently using your subscription\n\nCurrent session: 6% used · resets Aug 20 at 4:36pm (UTC)\nCurrent week (all models): 2% used · resets Aug 27 at 1:59pm (UTC)\nCurrent week (Fable): 3% used · resets Aug 27 at 1:59pm (UTC)"
        let windows = try ClaudeProvider.parseUsage(envelope(text), now: now)
        XCTAssertEqual(windows.map(\.title), ["Session", "Week", "Week · Fable"])
        XCTAssertEqual(windows.map(\.percent), [6, 2, 3])
        XCTAssertEqual(windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-08-20T16:36:00Z"))
        XCTAssertEqual(windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-08-27T13:59:00Z"))
    }

    func testClaudeRelativeAndPastResets() throws {
        let windows = try ClaudeProvider.parseUsage(envelope("Current session: 40% used · resets in 4 hr 36 min\nCurrent week (all models): 90% used · resets Aug 1 at 1pm"), now: now)
        XCTAssertEqual(windows[0].resetsAt, now.addingTimeInterval(4 * 3600 + 36 * 60))
        XCTAssertEqual(windows[1].percent, 0, "A window that already reset reads as unused")
    }

    func testClaudeRejectsModelAnswersAndEmptyReports() {
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(envelope("Current session: 6% used", cost: 0.01), now: now))
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(envelope("No plan limits"), now: now))
    }

    func testClaudeCostSummaryExplainsPossibleExpiredLogin() {
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(envelope("Total cost: $0.00\nTotal duration: 1s"), now: now)) {
            XCTAssertEqual($0 as? ProviderError, .failed("Claude answered without plan limits, so this account's login may have ended. Sign in again if this keeps happening."))
        }
    }

    func testMalformedUsageDoesNotCrashOrHideModelTokenUse() throws {
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(envelope("6% used: Current session"), now: now))
        let data = Data(#"{"result":"Current session: 6% used","usage":{"input_tokens":9223372036854775807,"output_tokens":9223372036854775807}}"#.utf8)
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(data, now: now))
        let cached = Data(#"{"result":"Current session: 6% used","usage":{"cache_read_input_tokens":5}}"#.utf8)
        XCTAssertThrowsError(try ClaudeProvider.parseUsage(cached, now: now))
        for reset in ["in -1 hr", "in nan hr", "in inf hr", "in "] {
            XCTAssertNil(ClaudeProvider.parseReset(reset, now: now))
        }
    }

    func testClaudeAuthStatus() throws {
        let status = try ClaudeProvider.parseAuthStatus(Data(#"{"isAuthenticated":true,"account":{"email":"c@d.com"},"subscriptionType":"max"}"#.utf8))
        XCTAssertEqual(status.email, "c@d.com")
        XCTAssertEqual(status.plan, "Max")
        XCTAssertThrowsError(try ClaudeProvider.parseAuthStatus(Data(#"{"loggedIn":false}"#.utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .signedOut)
        }
        XCTAssertThrowsError(try ClaudeProvider.parseAuthStatus(Data("{}".utf8)))
    }

    func testCodexRateLimits() {
        let windows = CodexProvider.windows(fromRateLimits: ["rateLimits": [
            "secondary": ["usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 1800500000],
            "primary": ["usedPercent": 12.4, "windowDurationMins": 300, "resetsAt": 1800000000],
        ]])
        XCTAssertEqual(windows, [
            UsageWindow(title: "Session", percent: 12, resetsAt: Date(timeIntervalSince1970: 1800000000)),
            UsageWindow(title: "Week", percent: 100, resetsAt: Date(timeIntervalSince1970: 1800500000)),
        ])
        let single = CodexProvider.windows(fromRateLimits: ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 5, "windowDurationMins": 10080]]]])
        XCTAssertEqual(single.map(\.title), ["Week"])
        XCTAssertTrue(CodexProvider.windows(fromRateLimits: [:]).isEmpty)
    }
}

private actor ScriptedClaudeRunner {
    struct Call: Sendable {
        var tool: String
        var arguments: [String]
        var environment: [String: String]
        var timeout: TimeInterval
    }

    private var results: [CLIResult]
    private(set) var calls: [Call] = []

    init(_ results: [CLIResult]) { self.results = results }

    func run(_ tool: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) throws -> CLIResult {
        calls.append(Call(tool: tool, arguments: arguments, environment: environment, timeout: timeout))
        guard !results.isEmpty else { throw ProviderError.failed("Unexpected CLI call.") }
        return results.removeFirst()
    }
}

final class ClaudeStatusTests: XCTestCase {
    private func result(_ text: String, status: Int32 = 0) -> CLIResult {
        CLIResult(status: status, stdout: Data(text.utf8), stderr: Data())
    }

    func testTransientSignOutIsConfirmedBeforeUsageAndUsesSafeTimeouts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parallax-status-\(UUID())/ClaudeConfig")
        let runner = ScriptedClaudeRunner([
            result(#"{"loggedIn":false}"#, status: 1),
            result(#"{"loggedIn":true,"email":"test@example.com","subscriptionType":"max"}"#),
            result(#"{"result":"Current session: 6% used"}"#),
        ])
        let status = try await ClaudeProvider.status(configFolder: folder, run: { try await runner.run($0, $1, $2, $3) }, confirmDelay: .zero)
        XCTAssertEqual(status.email, "test@example.com")
        XCTAssertEqual(status.plan, "Max")
        XCTAssertEqual(status.windows, [UsageWindow(title: "Session", percent: 6)])
        XCTAssertNil(status.usageError)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.tool), ["claude", "claude", "claude"])
        XCTAssertEqual(calls[0].arguments, ["auth", "status", "--json"])
        XCTAssertEqual(calls[1].arguments, calls[0].arguments)
        XCTAssertTrue(calls[2].arguments.contains("/usage"))
        XCTAssertEqual(calls.prefix(2).map(\.timeout), [15, 15])
        XCTAssertGreaterThanOrEqual(calls[2].timeout, 120)
        XCTAssertTrue(calls.allSatisfy { $0.environment["CLAUDE_CONFIG_DIR"] == folder.path })
    }

    func testTwoSignedOutAnswersNeverRunUsage() async {
        let runner = ScriptedClaudeRunner([result(#"{"loggedIn":false}"#, status: 1), result(#"{"loggedIn":false}"#, status: 1)])
        do {
            _ = try await ClaudeProvider.status(configFolder: FileManager.default.temporaryDirectory,
                                                run: { try await runner.run($0, $1, $2, $3) }, confirmDelay: .zero)
            XCTFail("Expected a confirmed sign-out")
        } catch {
            XCTAssertEqual(error as? ProviderError, .signedOut)
        }
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), Array(repeating: ["auth", "status", "--json"], count: 2))
    }

    func testUndecodableAuthIsFailureEvenAfterASignedOutAnswer() async {
        for prefix in [[], [result(#"{"loggedIn":false}"#, status: 1)]] {
            let runner = ScriptedClaudeRunner(prefix + [result("not JSON", status: 1)])
            do {
                _ = try await ClaudeProvider.status(configFolder: FileManager.default.temporaryDirectory,
                                                    run: { try await runner.run($0, $1, $2, $3) }, confirmDelay: .zero)
                XCTFail("Expected unreadable status")
            } catch {
                XCTAssertEqual(error as? ProviderError, .failed("Claude's sign-in status couldn't be read."))
            }
            let calls = await runner.calls
            XCTAssertEqual(calls.count, prefix.count + 1)
            XCTAssertTrue(calls.allSatisfy { !$0.arguments.contains("/usage") })
        }
    }

    func testSuccessfulAuthDoesNotNeedConfirmationAndPreservesUsageFailure() async throws {
        let runner = ScriptedClaudeRunner([
            result(#"{"loggedIn":true,"subscriptionType":"pro"}"#),
            result(#"{"result":"Total cost: $0.00"}"#),
        ])
        let status = try await ClaudeProvider.status(configFolder: FileManager.default.temporaryDirectory,
                                                    run: { try await runner.run($0, $1, $2, $3) }, confirmDelay: .zero)
        XCTAssertEqual(status.plan, "Pro")
        XCTAssertEqual(status.usageError, "Claude answered without plan limits, so this account's login may have ended. Sign in again if this keeps happening.")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }
}

final class ProviderLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parallax-tools-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func executable(_ path: String, date: TimeInterval, mode: Int = 0o700) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
        return url
    }

    func testNewestResolvedExecutableWinsAndTiesKeepFolderOrder() throws {
        let first = try executable("first/claude", date: 100)
        let second = try executable("second/claude", date: 200)
        _ = try executable("not-executable/claude", date: 400, mode: 0o600)
        let directories = ["first", "second", "not-executable"].map { root.appendingPathComponent($0).path }
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: directories), second)

        let target = try executable("package/cli.js", date: 50)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: target)
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: directories), second,
                       "A new symlink does not make an old tool newer")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: target.path)
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: directories), first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: second.path)
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: directories), first)
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: directories.reversed()), second)
    }

    func testLocalAndEveryNvmVersionAreSearched() throws {
        let name = "parallax-synthetic-\(UUID())"
        let local = try executable(".claude/local/\(name)", date: 100)
        XCTAssertEqual(ProviderCLI.locate(name, home: root.path), local)
        _ = try executable(".nvm/versions/node/v20/bin/\(name)", date: 200)
        let newest = try executable(".nvm/versions/node/v26/bin/\(name)", date: 300)
        XCTAssertEqual(ProviderCLI.locate(name, home: root.path), newest)
    }

    func testPathUsesTheUnresolvedCandidateFolderBeforeExtraPath() throws {
        let target = try executable("package/cli.js", date: 100)
        let bin = root.appendingPathComponent("node/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let candidate = bin.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
        let selected = try XCTUnwrap(ProviderCLI.locate("claude", home: root.path, directories: [bin.path]))
        let environment = ProviderCLI.environment(adding: ["PATH": "/custom/bin", "CLAUDE_CONFIG_DIR": root.path], executable: selected)
        XCTAssertEqual(environment["PATH"], bin.path + ":/custom/bin")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], root.path)
        XCTAssertTrue(ProviderCLI.environment(adding: [:], executable: selected)["PATH"]?.hasPrefix(bin.path + ":") == true)
    }
}

final class ProviderProcessTests: XCTestCase {
    func testPipesAreDrainedCompletely() async throws {
        let result = try await ProviderCLI.run("env", ["/bin/sh", "-c", "i=0; while [ $i -lt 20000 ]; do printf 'abcdefghij'; printf '0123456789' >&2; i=$((i + 1)); done"], environment: [:], timeout: 15, directories: ["/usr/bin"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(String(repeating: "abcdefghij", count: 20000).utf8))
        XCTAssertEqual(result.stderr, Data(String(repeating: "0123456789", count: 20000).utf8))
    }

    func testStoppedProcessCannotStartLater() {
        let box = ProcessBox()
        box.process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        box.stop()
        XCTAssertThrowsError(try box.run()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(box.process.isRunning)
    }

    func testCancelledTaskDoesNotReturnAProcessResult() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProviderCLI.run("env", ["/usr/bin/true"], environment: [:], timeout: 5, directories: ["/usr/bin"])
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTimeoutStopsProcess() async {
        do {
            _ = try await ProviderCLI.run("env", ["/bin/sh", "-c", "while :; do :; done"], environment: [:], timeout: 0.001, directories: ["/usr/bin"])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ProviderError, .timedOut)
        }
    }
}
