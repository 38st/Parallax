import AppKit
import XCTest
@testable import Parallax

private final class SyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class OpenFlowTests: ChatFixture {
    @MainActor
    private func model(_ spaces: [ClaudeChats.SpaceFolders]) throws -> AppModel {
        let appURL = root.appendingPathComponent("Synthetic.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let model = AppModel(support: root.appendingPathComponent("support"), defaults: MemoryDefaults(), startServices: false, hooks: testHooks())
        model.apps = [ManagedApp(name: "Claude", path: appURL.path, kind: .claude, dataFolder: root.path,
                                 spaces: spaces.map { Space(id: $0.spaceID, name: $0.name, folder: $0.sessions.deletingLastPathComponent().deletingLastPathComponent().path) })]
        model.openInstance = { _, _, _ in throw LaunchError.appMissing("Synthetic launch") }
        return model
    }

    @MainActor
    func testClaudeOpenDecisionTable() {
        let cases: [(ClaudeOpenChoice, Bool, Int, Set<pid_t>, Set<pid_t>, ClaudeOpenStep)] = [
            (.ask, false, 0, [], [], .showOrLaunch),
            (.ask, false, 0, [], [1], .ask(firstSignIn: true)),
            (.withoutQuitting, false, 1, [1], [2], .showOrLaunch),
            (.quit([1]), false, 0, [], [1], .quitThenLaunch),
            (.quit([1]), false, 0, [], [1, 2], .ask(firstSignIn: true)),
            (.ask, true, 0, [1], [2], .showOrLaunch),
            (.withoutQuitting, true, 3, [1], [], .showOrLaunch),
            (.ask, true, 3, [], [2], .sync(quitFirst: false)),
            (.ask, true, 3, [1], [], .ask(firstSignIn: false)),
            (.quit([1]), true, 3, [1], [], .sync(quitFirst: true)),
            (.quit([1]), true, 3, [1, 2], [], .ask(firstSignIn: false)),
        ]
        for (choice, signedIn, pending, blockers, others, expected) in cases {
            for running in [false, true] {
                XCTAssertEqual(AppModel.claudeOpenStep(choice: choice, signedIn: signedIn, pending: pending,
                    folderProblem: pending == 0 ? "folder" : nil, targetRunning: running,
                    blockerPIDs: blockers, otherPIDs: others), expected)
            }
        }
    }

    @MainActor
    func testUnchangedOpenLaunchesWithoutSyncingAndChangedOpenAsks() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        let model = try model([a, b])
        var launches = 0, activations = 0
        model.openInstance = { _, _, _ in launches += 1; throw LaunchError.appMissing("Synthetic") }
        model.hooks.activate = { _ in activations += 1 }
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(model.syncsStarted, 1)
        XCTAssertEqual(launches, 1)
        XCTAssertNil(model.pendingClaudeOpen)
        let bytes = try Data(contentsOf: recordURL(b))
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(model.syncsStarted, 1)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(try Data(contentsOf: recordURL(b)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("support/ChatBackups").path))
        model.running[b.spaceID] = .current
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(model.syncsStarted, 1)
        try append("two", to: native(a))
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(model.pendingClaudeOpen?.quitting, ["B"])
        XCTAssertEqual(model.pendingClaudeOpen?.targetRunning, true)
        XCTAssertEqual(model.syncsStarted, 1)
        await model.openClaudeSpace(b.spaceID, choice: .withoutQuitting)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(model.syncsStarted, 1)
        model.running.removeAll()
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(model.syncsStarted, 2)
    }

    @MainActor
    func testBrandNewSpaceAndFirstSignInRouting() async throws {
        let a = space("A"), b = space("B")
        let model = try model([a, b])
        var launches = 0
        model.openInstance = { _, _, _ in launches += 1; throw LaunchError.appMissing("Synthetic") }
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(model.syncsStarted, 0)
        XCTAssertNil(model.pendingClaudeOpen)
        XCTAssertTrue(model.notice?.contains("open the Code tab once") == true)
        model.running[a.spaceID] = .current
        await model.open(b.spaceID, in: model.apps[0].id)
        XCTAssertEqual(model.pendingClaudeOpen?.firstSignIn, true)
        XCTAssertEqual(model.pendingClaudeOpen?.quitting, ["A"])
        await model.openClaudeSpace(b.spaceID, choice: .withoutQuitting)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(model.syncsStarted, 0)
    }

    @MainActor
    func testChangedOpenQuitsOnlyPolicyBlockersAndRequiresConfirmedPIDs() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        let model = try model([a, b])
        let target = model.apps[0].spaces[1]
        model.running[a.spaceID] = .current
        XCTAssertTrue(model.claudeBlockers(writingInto: target).isEmpty)
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.syncsStarted, 1)
        XCTAssertNotNil(model.running[a.spaceID])
        try append("two", to: native(a))
        model.running.removeAll()
        model.running[b.spaceID] = .current
        await model.openClaudeSpace(b.spaceID, choice: .quit([]))
        XCTAssertEqual(model.pendingClaudeOpen?.quitting, ["B"])
        var terminated = false
        model.hooks.terminate = { _ in terminated = true }
        model.hooks.isTerminated = { _ in terminated }
        await model.openClaudeSpace(b.spaceID, choice: .quit([NSRunningApplication.current.processIdentifier]))
        XCTAssertTrue(terminated)
        XCTAssertEqual(model.syncsStarted, 2)
    }

    @MainActor
    func testUnmanagedClaudeBlocksBeforeAnythingIsQuit() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        let model = try model([a, b])
        model.hooks.runningInstances = { _ in [.current] }
        model.hooks.processArguments = { _ in nil }
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.pendingClaudeOpen?.quitting, ["Claude without a space"])
        XCTAssertEqual(model.syncsStarted, 0)
        XCTAssertTrue(ClaudeChats.records(in: try namespace(b), spaceID: b.spaceID).isEmpty)
    }

    @MainActor
    func testSharedFoldersAndContinueRunningTargetAreBlocked() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        let model = try model([a, b])
        model.running[a.spaceID] = .current
        var transfer = try transfer(to: b, spaces: [a, b])
        XCTAssertTrue(model.instancesBlocking(transfer).isEmpty)
        model.apps[0].spaces[0].environment = "CLAUDE_CONFIG_DIR=\(b.config.path)"
        XCTAssertEqual(model.instancesBlocking(transfer).map(\.name), ["A"])
        transfer.kind = .upToDate
        XCTAssertTrue(model.instancesBlocking(transfer).isEmpty)
        model.running[b.spaceID] = .current
        XCTAssertEqual(model.instancesBlocking(transfer).map(\.name), ["B"])
        model.openInstance = { _, _, _ in XCTFail("Must not launch"); return .current }
        do {
            try await model.launch(model.apps[0].spaces[1], in: model.apps[0], continueURL: ClaudeChats.continueURL(chatID: chatID))
            XCTFail("Must refuse a second process")
        } catch LaunchError.alreadyRunning { }
    }

    @MainActor
    func testQuitWaitHonorsStopAndTerminationRepliesOnce() async throws {
        for terminateApp in [false, true] {
            let a = space("A-\(terminateApp)"), b = space("B-\(terminateApp)")
            try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
            _ = try namespace(b)
            let model = try model([a, b])
            XCTAssertFalse(model.quitRequested())
            model.running[b.spaceID] = .current
            var replies = 0, opens = 0
            model.hooks.replyToTermination = { replies += 1 }
            model.openInstance = { _, _, _ in opens += 1; throw LaunchError.appMissing("Synthetic") }
            model.hooks.terminate = { _ in
                if terminateApp { XCTAssertTrue(model.quitRequested()); XCTAssertTrue(model.quitRequested()) }
                else { model.stopWaitingForQuit() }
            }
            await model.openClaudeSpace(b.spaceID, choice: .quit([NSRunningApplication.current.processIdentifier]))
            XCTAssertEqual(replies, terminateApp ? 1 : 0)
            XCTAssertEqual(opens, 0)
            XCTAssertEqual(model.syncsStarted, 0)
            XCTAssertFalse(model.waitingForQuit)
            XCTAssertFalse(model.syncingClaudeChats)
        }
    }

    @MainActor
    func testQuitWaitActivatesOnceAfterTwoSecondsAndNeverForcesQuit() async throws {
        let model = try model([])
        var elapsed: Duration = .zero
        var activations = 0, terminations = 0
        model.hooks.elapsed = { elapsed }
        model.hooks.sleep = { elapsed += $0 }
        model.hooks.activate = { _ in activations += 1 }
        model.hooks.terminate = { _ in terminations += 1 }
        let quit = await model.quitAndWait([.current, .current], timeout: .seconds(3))
        XCTAssertFalse(quit)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(terminations, 1)
        XCTAssertEqual(elapsed, .seconds(3))
    }

    @MainActor
    func testStoppedSyncRecordsNoWatermarkAndQuitNeverLaunches() async throws {
        for quit in [false, true] {
            let a = space("A-\(quit)"), b = space("B-\(quit)")
            for index in 0..<3 {
                try writeNativeChat(in: a, lines: [line("user", "\(index)")], lastActivity: Double(index),
                                    chatID: "local_\(index)", cliSessionID: "cli-\(index)")
            }
            _ = try namespace(b)
            let model = try model([a, b])
            let gate = SyncGate()
            var work: Task<Void, Never>?
            var opens = 0, replies = 0
            model.openInstance = { _, _, _ in opens += 1; throw LaunchError.appMissing("Synthetic") }
            model.hooks.replyToTermination = { replies += 1 }
            await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
                model.syncChats = { target, spaces, backups, cache, progress in
                    ClaudeChats.syncAll(to: target, spaces: spaces, backups: backups, cache: &cache, progress: { done, total in
                        progress(done, total)
                        if done == 1 { started.resume(); gate.wait() }
                    })
                }
                work = Task { await model.openClaudeSpace(b.spaceID) }
            }
            if quit { XCTAssertTrue(model.quitRequested()); XCTAssertTrue(model.quitRequested()) }
            else { model.stopSync() }
            gate.release()
            await work?.value
            XCTAssertEqual(model.lastSync?.result.checked, 1)
            XCTAssertEqual(model.lastSync?.result.stopped, true)
            XCTAssertEqual(opens, quit ? 0 : 1)
            XCTAssertEqual(replies, quit ? 1 : 0)
            XCTAssertEqual(ClaudeChats.records(in: try namespace(b), spaceID: b.spaceID).count, 1)
            XCTAssertNil(model.syncProgress)
            if !quit {
                model.syncChats = { ClaudeChats.syncAll(to: $0, spaces: $1, backups: $2, cache: &$3, progress: $4) }
                await model.openClaudeSpace(b.spaceID)
                XCTAssertEqual(model.syncsStarted, 2)
                XCTAssertEqual(ClaudeChats.records(in: try namespace(b), spaceID: b.spaceID).count, 3)
            }
        }
    }

    @MainActor
    func testFailedChatRetriesWhenChangedAndNewNamespaceForcesSync() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: ["broken"], lastActivity: 100)
        _ = try namespace(b)
        let model = try model([a, b])
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.lastSync?.result.issues.count, 1)
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.syncsStarted, 1, "Unchanged failures must not cause every open to sync")
        try Data((line("user", "fixed") + "\n").utf8).write(to: native(a))
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.syncsStarted, 2)
        _ = try namespace(b, account: "new")
        try Data(#"{"lastKnownAccountUuid":"new"}"#.utf8).write(to: b.sessions.deletingLastPathComponent().appendingPathComponent("config.json"))
        await model.openClaudeSpace(b.spaceID)
        XCTAssertEqual(model.syncsStarted, 3)
        XCTAssertEqual(ClaudeChats.records(in: try namespace(b, account: "new"), spaceID: b.spaceID).count, 1)
    }

    @MainActor
    func testRepeatedSyncIssueAlertsOnceAndLaunchErrorKeepsEarlierNotice() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: ["broken"], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "good")], lastActivity: 200, chatID: "local_good", cliSessionID: "good")
        _ = try namespace(b)
        let model = try model([a, b])
        model.report("Earlier notice")
        await model.openClaudeSpace(b.spaceID)
        XCTAssertTrue(model.notice?.contains("Earlier notice") == true)
        XCTAssertTrue(model.notice?.contains("Fix the build") == true)
        XCTAssertTrue(model.notice?.contains("Synthetic launch") == true)
        XCTAssertFalse(model.chats.isEmpty)
        model.notice = nil
        try append("changed", to: native(a, cli: "good"))
        model.openInstance = { _, _, _ in .current }
        await model.openClaudeSpace(b.spaceID)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.lastSync?.result.issues.count, 1)
    }

    @MainActor
    func testContinueChatReportsBusyMissingAndBlockingSpaces() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        let transfer = try transfer(to: b, spaces: [a, b])
        let model = try model([a, b])
        model.syncingClaudeChats = true
        await model.continueChat(transfer)
        XCTAssertTrue(model.notice?.contains("still carrying") == true)
        model.syncingClaudeChats = false
        model.running[b.spaceID] = .current
        await model.continueChat(transfer)
        XCTAssertTrue(model.notice?.contains("Quit Claude in B") == true)
        XCTAssertTrue(ClaudeChats.records(in: try namespace(b), spaceID: b.spaceID).isEmpty)
        model.apps = []
        await model.continueChat(transfer)
        XCTAssertTrue(model.notice?.contains("no longer in Parallax") == true)
        var fresh = transfer
        XCTAssertFalse(fresh.needsReconfirmation(after: transfer, blockers: []))
        XCTAssertTrue(fresh.needsReconfirmation(after: transfer, blockers: [123]))
        fresh.kind = .replaceDiverged
        XCTAssertTrue(fresh.needsReconfirmation(after: transfer, blockers: []))
    }
}
