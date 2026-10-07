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
        defaults.set(Data(workspace.utf8), forKey: "corporate.workspace.v1")
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
