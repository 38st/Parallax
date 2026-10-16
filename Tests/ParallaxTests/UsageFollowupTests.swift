import XCTest
@testable import Parallax

private final class SignInGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderStatus, Error>?
    private var cancelled = false
    func install(_ continuation: CheckedContinuation<ProviderStatus, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}

final class UsageFollowupTests: ChatFixture {
    @MainActor
    private func model() -> AppModel {
        AppModel(support: root, defaults: MemoryDefaults(), startServices: false, hooks: testHooks())
    }

    @MainActor
    func testTwoConsecutiveSignOutAnswersForEveryProviderAndSuccessResetsStrikes() async {
        let model = model()
        for provider in Provider.allCases {
            let account = UsageAccount(provider: provider, label: "Test", signedIn: true)
            model.accounts = [account]
            model.readStatus = { _ in throw ProviderError.signedOut }
            await model.refresh(account.id)
            XCTAssertTrue(model.accounts[0].signedIn)
            XCTAssertEqual(model.accounts[0].lastError, ProviderError.signedOut.localizedDescription)
            await model.refresh(account.id)
            XCTAssertFalse(model.accounts[0].signedIn)
            model.readStatus = { _ in ProviderStatus(email: "test@example.com", windows: []) }
            await model.refresh(account.id)
            XCTAssertTrue(model.accounts[0].signedIn)
            model.readStatus = { _ in throw ProviderError.signedOut }
            await model.refresh(account.id)
            XCTAssertTrue(model.accounts[0].signedIn)
            model.readStatus = { _ in ProviderStatus(windows: []) }
            await model.refresh(account.id)
            model.readStatus = { _ in throw ProviderError.signedOut }
            await model.refresh(account.id)
            XCTAssertTrue(model.accounts[0].signedIn)
        }
        XCTAssertFalse(ProviderError.signedOut.localizedDescription.contains("Claude"))
        XCTAssertFalse(ProviderError.signedOut.localizedDescription.contains("week"))
    }

    @MainActor
    func testCancelledSignInLeavesAccountUnchangedAndRemovalCancels() async {
        for remove in [false, true] {
            let model = model()
            let account = UsageAccount(provider: .codex, label: "Test", email: "old@example.com", signedIn: true)
            model.accounts = [account]
            let gate = SignInGate()
            var work: Task<Void, Never>?
            await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
                model.signInStatus = { _ in
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            gate.install(continuation)
                            started.resume()
                        }
                    } onCancel: { gate.cancel() }
                }
                work = Task { await model.signIn(account.id) }
            }
            XCTAssertTrue(model.signingIn.contains(account.id))
            if remove { model.removeAccount(account.id) } else { model.cancelSignIn(account.id) }
            await work?.value
            XCTAssertTrue(model.signingIn.isEmpty)
            XCTAssertTrue(model.busyAccounts.isEmpty)
            XCTAssertEqual(model.accounts, remove ? [] : [account])
        }
    }

    @MainActor
    func testSignInSuccessAndVisiblePageCadence() async {
        let model = model()
        let now = Date(timeIntervalSince1970: 1_000_000)
        model.now = { now }
        let account = UsageAccount(provider: .claude, label: "Test", lastRefreshed: now.addingTimeInterval(-300), signedIn: true)
        model.accounts = [account]
        var calls = 0
        model.readStatus = { _ in calls += 1; return ProviderStatus(windows: []) }
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(calls, 0)
        model.usagePageVisible = true
        await model.refreshAllAccounts(onlyIfStale: true)
        XCTAssertEqual(calls, 1)
        model.signInStatus = { _ in ProviderStatus(email: "new@example.com", plan: "Pro", windows: []) }
        await model.signIn(account.id)
        XCTAssertEqual(model.accounts[0].email, "new@example.com")
        XCTAssertTrue(model.accounts[0].signedIn)
        XCTAssertTrue(model.busyAccounts.isEmpty)
    }

    func testSmallNpmPlaceholderIsSkippedButShebangIsAccepted() throws {
        let good = root.appendingPathComponent("good/claude"), stub = root.appendingPathComponent("bad/claude")
        for file in [good, stub] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: good)
        try Data(repeating: 65, count: 100).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700, .modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: good.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700, .modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: stub.path)
        XCTAssertEqual(ProviderCLI.locate("claude", home: root.path, directories: [stub.deletingLastPathComponent().path, good.deletingLastPathComponent().path]), good)
    }

    func testClaudeConfigPathIsPassedExactlyToEveryRead() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "53B0FDE6-3B80-4374-A9A2-E224AF08EC20"))
        let home = UsageAccount(id: id, provider: .claude, label: "Test").homeFolder
        let expected = Paths.support.path + "/AccountSessions/53b0fde6-3b80-4374-a9a2-e224af08ec20/ClaudeConfig"
        _ = try await ClaudeProvider.status(configFolder: home, run: { _, arguments, environment, _ in
            XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], expected)
            let json = arguments.first == "auth" ? #"{"loggedIn":true}"# : #"{"result":"Current session: 4% used"}"#
            return CLIResult(status: 0, stdout: Data(json.utf8), stderr: Data())
        }, confirmDelay: .zero)
    }

    func testCodexDrainMessagesHandlesSplitBatchedAndOversizedLines() {
        var buffer = Data(#"{"id":1"#.utf8)
        XCTAssertTrue(CodexSession.drainMessages(&buffer).isEmpty)
        buffer.append(Data("}\n{\"id\":2}\nbad\n{\"id\":3".utf8))
        XCTAssertEqual(CodexSession.drainMessages(&buffer).compactMap { $0["id"] as? Int }, [1, 2])
        buffer.append(Data("}\n".utf8))
        XCTAssertEqual(CodexSession.drainMessages(&buffer).compactMap { $0["id"] as? Int }, [3])
        buffer = Data(repeating: 65, count: 4_000_001) + Data("\n{\"id\":4}\n".utf8)
        XCTAssertEqual(CodexSession.drainMessages(&buffer).compactMap { $0["id"] as? Int }, [4])
        buffer = Data(repeating: 65, count: 8_000_001)
        XCTAssertTrue(CodexSession.drainMessages(&buffer).isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCodexStatusMappingAndDurationTitles() throws {
        XCTAssertThrowsError(try CodexProvider.status(accountReply: ["result": [:]], limitsReply: [:])) {
            guard case ProviderError.failed = $0 else { return XCTFail("Expected failed") }
        }
        XCTAssertThrowsError(try CodexProvider.status(accountReply: ["result": ["account": NSNull()]], limitsReply: [:])) {
            XCTAssertEqual($0 as? ProviderError, .signedOut)
        }
        let account: [String: Any] = ["result": ["account": ["email": "a@example.com"]]]
        XCTAssertEqual(try CodexProvider.status(accountReply: account, limitsReply: [:]).usageError, "Codex didn't report usage limits.")
        XCTAssertEqual(try CodexProvider.status(accountReply: account, limitsReply: ["error": ["message": "Specific failure"]]).usageError, "Specific failure")
        func titles(_ minutes: [Int]) -> [String] {
            var limits: [String: Any] = [:]
            for (index, value) in minutes.enumerated() { limits[index == 0 ? "primary" : "secondary"] = ["windowDurationMins": value, "usedPercent": 12] }
            return CodexProvider.windows(fromRateLimits: ["rateLimits": limits]).map(\.title)
        }
        XCTAssertEqual(titles([300, 10080]), ["Session", "Week"])
        XCTAssertEqual(titles([43200]), ["30-day"])
        XCTAssertEqual(titles([10080]), ["Week"])
        XCTAssertEqual(titles([300, 1440]), ["5-hour", "1-day"])
        XCTAssertEqual(Set(titles([300, 300])).count, 2)
    }

    func testResetAcrossYearBoundaryAndExpiredBadgeDisplay() throws {
        let iso = ISO8601DateFormatter()
        let december = try XCTUnwrap(iso.date(from: "2026-12-28T00:00:00Z"))
        XCTAssertEqual(ClaudeProvider.parseReset("Jan 2, 2027 at 1pm", now: december), iso.date(from: "2027-01-02T13:00:00Z"))
        let newYearsEve = try XCTUnwrap(iso.date(from: "2026-12-31T20:00:00Z"))
        XCTAssertEqual(ClaudeProvider.parseReset("4:36pm", now: newYearsEve), iso.date(from: "2027-01-01T16:36:00Z"))
        XCTAssertEqual(ClaudeProvider.parseReset("9pm", now: newYearsEve), iso.date(from: "2026-12-31T21:00:00Z"))
        let window = UsageWindow(title: "Session", percent: 98, resetsAt: december)
        XCTAssertEqual(window.percent(at: december), 0)
        XCTAssertEqual(window.percent(at: december.addingTimeInterval(-1)), 98)
        var account = UsageAccount(provider: .claude, label: "Test", windows: [window])
        XCTAssertEqual(account.badgeState(at: december), .hidden)
        account.signedIn = true
        XCTAssertEqual(account.badgeState(at: december), .stale)
        account.lastRefreshed = december.addingTimeInterval(-1801)
        XCTAssertEqual(account.badgeState(at: december), .stale)
        account.lastRefreshed = december
        XCTAssertEqual(account.badgeState(at: december), .live)
        XCTAssertEqual(account.headline(at: december)?.percent, 0)
        XCTAssertEqual(account.windows[0].percent, 98)
    }
}
