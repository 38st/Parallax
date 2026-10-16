import AppKit
import XCTest
@testable import Parallax

final class SettingsAndStateTests: ChatFixture {
    @MainActor
    private func model() -> AppModel {
        AppModel(support: root, defaults: MemoryDefaults(), startServices: false, hooks: testHooks())
    }

    private func app(_ kind: AppKind = .claude, shared: Bool = false) -> ManagedApp {
        ManagedApp(name: "Synthetic", path: root.appendingPathComponent("Synthetic.app").path,
                   kind: kind, dataFolder: root.path, sharedCodexHistory: shared)
    }

    func testDanglingEmptyRelativeOrQuotedIsolationPathsAreRejected() throws {
        for kind in [AppKind.claude, .chromium, .vscode, .codex] {
            for argument in ["--user-data-dir", "--user-data-dir=", "--user-data-dir ''", "--user-data-dir=rel", "--extensions-dir --flag"] {
                XCTAssertThrowsError(try LaunchPlanner.plan(app: app(kind), space: Space(name: "Test", folder: root.path, arguments: argument)))
            }
            for environment in ["CLAUDE_CONFIG_DIR=", "CODEX_HOME=", "CLAUDE_CONFIG_DIR=\"~/x\"", "CLAUDE_CONFIG_DIR=rel"] {
                XCTAssertThrowsError(try LaunchPlanner.plan(app: app(kind), space: Space(name: "Test", folder: root.path, environment: environment)))
            }
            for argument in ["--user-data-dir=~/ok", "-- --user-data-dir=x"] {
                XCTAssertNoThrow(try LaunchPlanner.plan(app: app(kind), space: Space(name: "Test", folder: root.path, arguments: argument)))
            }
        }
        XCTAssertThrowsError(try LaunchPlanner.plan(app: app(.firefox), space: Space(name: "Test", folder: root.path, arguments: "-profile")))
        XCTAssertNoThrow(try LaunchPlanner.plan(app: app(.firefox), space: Space(name: "Test", folder: root.path, arguments: "-P work")))
        XCTAssertNoThrow(try LaunchPlanner.plan(app: app(.other), space: Space(name: "Test", folder: root.path, arguments: "--user-data-dir=rel")))
    }

    func testEnvironmentValidationAndIdentityFilter() {
        let text = "# comment\n\nA=1\nunset A\nexport B=2\nD = 2\nMY-VAR=1"
        XCTAssertEqual(LaunchText.ignoredEnvironmentLines(text), ["export B=2", "D = 2", "MY-VAR=1"])
        XCTAssertEqual(LaunchText.environmentProblem(text), "Remove “export” on line 5.")
        XCTAssertNil(LaunchText.environmentProblem("A=\nunset B\n# comment"))
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDECODE", "ANTHROPIC_API_KEY", "CODEX_HOME", "VSCODE_PID", "ELECTRON_X", "DYLD_X", "XRE_PROFILE_PATH"] {
            XCTAssertTrue(LaunchPlanner.isInheritedIdentity(key))
        }
        for key in ["PARALLAX_SUPPORT_DIR", "HOME", "PATH"] { XCTAssertFalse(LaunchPlanner.isInheritedIdentity(key)) }
    }

    func testCodexElectronUserDataAndTwoWordRewrite() throws {
        let cases: [(String, String, String?)] = [
            ("", "", root.appendingPathComponent("UserData").path),
            ("--user-data-dir ~/X", "", "/synthetic-home/X"),
            ("", "CODEX_ELECTRON_USER_DATA_PATH=/explicit", "/explicit"),
            ("", "unset CODEX_ELECTRON_USER_DATA_PATH", nil),
        ]
        for (arguments, environment, expected) in cases {
            let space = Space(name: "Test", folder: root.path, arguments: arguments, environment: environment)
            let plan = try LaunchPlanner.plan(app: app(.codex), space: space, home: "/synthetic-home")
            XCTAssertEqual(plan.environment["CODEX_ELECTRON_USER_DATA_PATH"], expected)
            XCTAssertNil(try LaunchPlanner.plan(app: app(.codex, shared: true), space: space).environment["CODEX_ELECTRON_USER_DATA_PATH"])
        }
        for kind in [AppKind.chromium, .claude] {
            let plan = try LaunchPlanner.plan(app: app(kind), space: Space(name: "Test", folder: root.path, arguments: "--user-data-dir /u --extensions-dir /e -- file"))
            XCTAssertEqual(plan.arguments, ["--user-data-dir=/u", "--extensions-dir=/e", "--", "file"])
        }
        XCTAssertFalse(try LaunchPlanner.plan(app: app(.other), space: Space(name: "Test", folder: root.path)).newInstance)
        for space in [Space(name: "Test", folder: root.path, arguments: "--flag"), Space(name: "Test", folder: root.path, environment: "unset A")] {
            XCTAssertTrue(try LaunchPlanner.plan(app: app(.other), space: space).newInstance)
        }
    }

    func testChatFoldersAgreeWithLaunchPlanAndDetectionUsesBundleIDs() throws {
        for (args, env) in [("", ""), ("--user-data-dir=/u", ""), ("--user-data-dir /u", ""), ("-user-data-dir=~/u", "CLAUDE_CONFIG_DIR=~/c")] {
            let space = Space(name: "Test", folder: root.path, arguments: args, environment: env)
            let folders = ClaudeChats.folders(for: space)
            let plan = try LaunchPlanner.plan(app: app(), space: space)
            XCTAssertEqual(folders.sessions.deletingLastPathComponent().path, plan.arguments.optionValue(LaunchPlanner.userDataOptions))
            XCTAssertEqual(folders.config.path, plan.environment["CLAUDE_CONFIG_DIR"])
        }
        XCTAssertEqual(AppKind.detect(name: "Claude Code", bundleID: "com.apple.applet"), .other)
        XCTAssertEqual(AppKind.detect(name: "CodexBar", bundleID: "com.example.codexbar"), .other)
        XCTAssertEqual(AppKind.detect(name: "Preview", bundleID: "com.openai.codex.preview"), .codex)
        XCTAssertEqual(AppKind.detect(name: "Preview", bundleID: "com.anthropic.claudefordesktop.preview"), .claude)
    }

    func testProcessArgumentsParseEnvironmentAndTruncation() throws {
        var argc: Int32 = 2
        var buffer = withUnsafeBytes(of: &argc) { Array($0) }
        buffer += Array("/Synthetic\0\0\0Synthetic\0--flag\0CLAUDE_CONFIG_DIR=/test\0A=one\0A=two\0\0apple=value\0".utf8)
        let parsed = try XCTUnwrap(ProcessArguments.parse(buffer))
        XCTAssertEqual(parsed.arguments, ["Synthetic", "--flag"])
        XCTAssertEqual(parsed.environment, ["CLAUDE_CONFIG_DIR": "/test", "A": "one"])
        for length in 0..<buffer.count { _ = ProcessArguments.parse(Array(buffer.prefix(length))) }
        XCTAssertNil(ProcessArguments.parse(Array(buffer.prefix(9))))
        XCTAssertEqual(ProcessArguments.arguments(of: getpid()), CommandLine.arguments)
    }

    func testDefaultClaudeFoldersAndLinksAreExcludedFromCarryover() throws {
        let config = root.appendingPathComponent(".claude")
        let sessions = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/account/org")
        for folder in [config, sessions] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertTrue(ClaudeChats.isDefaultFolder(config, home: root.path))
        XCTAssertTrue(ClaudeChats.isDefaultFolder(sessions, home: root.path))
        XCTAssertTrue(ClaudeChats.isDefaultFolder(link.appendingPathComponent("projects"), home: root.path))
        XCTAssertFalse(ClaudeChats.isDefaultFolder(root.appendingPathComponent("space/UserData/ClaudeConfig"), home: root.path))
    }

    @MainActor
    func testFolderSharingResolvesLinksAndDependencyPaths() throws {
        let a = space("A"), b = space("B")
        try FileManager.default.createDirectory(at: b.sessions, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b.sessions.deletingLastPathComponent())
        XCTAssertTrue(AppModel.sharesChatFolders(userData: alias.path, config: a.config.path, with: b))
        XCTAssertTrue(AppModel.sharesChatFolders(userData: a.sessions.deletingLastPathComponent().path, config: b.config.path, with: b))
        XCTAssertFalse(AppModel.sharesChatFolders(userData: a.sessions.deletingLastPathComponent().path, config: a.config.path, with: b))
        let model = model()
        let target = Space(name: "Target", folder: root.appendingPathComponent("with space/nested").path)
        let relativeToHome = "~/../../" + target.folder.dropFirst()
        let variants = [Space(name: "Other", folder: root.appendingPathComponent("elsewhere").path, environment: "CONFIG=\(relativeToHome)"),
                        Space(name: "Other", folder: root.appendingPathComponent("elsewhere").path, arguments: "--user-data-dir=" + target.folder.replacingOccurrences(of: " ", with: "\\ ")),
                        Space(name: "Other", folder: root.path)]
        for other in variants {
            var app = app()
            app.spaces = [target, other]
            model.apps = [app]
            XCTAssertEqual(model.spacesDepending(on: target).map(\.id), [other.id])
        }
    }

    @MainActor
    func testTrashRefusesUnusualFoldersAndRefreshesRunningBeforeRemoval() throws {
        let model = model()
        var app = app()
        let target = Space(name: "Target", folder: root.appendingPathComponent("unusual").path)
        app.spaces = [target]
        model.apps = [app]
        model.save()
        let before = try Data(contentsOf: root.appendingPathComponent("state.json"))
        var trashed: [URL] = []
        model.hooks.trash = { trashed.append($0) }
        XCTAssertThrowsError(try model.deleteSpace(target.id, in: app.id, moveDataToTrash: true)) {
            guard case SpaceError.unusualFolder = $0 else { return XCTFail("Expected unusual folder") }
        }
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(model.apps[0].spaces.count, 1)
        model.hooks.discoverRunningSpaces = { _ in [target.id: .current] }
        XCTAssertThrowsError(try model.deleteSpace(target.id, in: app.id, moveDataToTrash: false))
        model.removeApp(app.id)
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json")), before)
    }

    @MainActor
    func testBackupRotatesOnlyBeforeRemovalsAndNeverAutoRestores() throws {
        let model = model()
        var app = app()
        let target = Space(name: "Target", folder: Paths.newSpaceFolder(app: app, spaceID: UUID()))
        app.spaces = [target]
        model.apps = [app]
        model.accounts = [UsageAccount(provider: .claude, label: "Account")]
        model.save()
        let state = root.appendingPathComponent("state.json")
        let backup = root.appendingPathComponent("state.backup.json")
        let before = try Data(contentsOf: state)
        try model.deleteSpace(target.id, in: app.id, moveDataToTrash: false)
        XCTAssertEqual(try Data(contentsOf: backup), before)
        model.renameAccount(model.accounts[0].id, to: "Renamed")
        XCTAssertEqual(try Data(contentsOf: backup), before)
        let beforeAccount = try Data(contentsOf: state)
        model.removeAccount(model.accounts[0].id)
        XCTAssertEqual(try Data(contentsOf: backup), beforeAccount)
        let beforeApp = try Data(contentsOf: state)
        model.removeApp(app.id)
        XCTAssertEqual(try Data(contentsOf: backup), beforeApp)
        try Data("broken".utf8).write(to: state)
        let broken = self.model()
        XCTAssertTrue(broken.apps.isEmpty)
        broken.save()
        XCTAssertTrue(broken.notice?.contains("isn't saving changes") == true)
        XCTAssertEqual(try Data(contentsOf: state), Data("broken".utf8))
    }

    @MainActor
    func testSecondWriterStopsSavingWithoutChangingItsBytes() throws {
        let first = model(), second = model()
        second.apps = [app()]
        second.save()
        let state = root.appendingPathComponent("state.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: state.path)
        let expected = try Data(contentsOf: state)
        first.save()
        XCTAssertTrue(first.notice?.contains("another copy") == true)
        XCTAssertEqual(try Data(contentsOf: state), expected)
    }

    @MainActor
    func testUnreadableLibraryIsRetriedNextLaunch() throws {
        for contents in ["broken", #"{"version":1,"applications":[]}"#] {
            try Data(contents.utf8).write(to: root.appendingPathComponent("library.json"))
            let first = model()
            XCTAssertTrue(first.notice?.contains("previous version") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
        }
        try Data(#"{"version":2,"applications":[]}"#.utf8).write(to: root.appendingPathComponent("library.json"))
        XCTAssertNil(model().notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }

    func testStateDecodesWithAndWithoutOptionalFields() throws {
        let minimal = #"{"version":1,"apps":[{"id":"11111111-1111-4111-8111-111111111111","name":"Claude","path":"/Synthetic.app","kind":"claude","dataFolder":"/data","sharedCodexHistory":false,"spaces":[{"id":"22222222-2222-4222-8222-222222222222","name":"Work","folder":"/space","email":"","arguments":"","environment":"","inheritEnvironment":false}]}],"accounts":[{"id":"33333333-3333-4333-8333-333333333333","provider":"claude","label":"Usage","email":"","plan":"","windows":[{"title":"Week","percent":12}],"signedIn":false}]}"#
        let full = #"{"version":1,"apps":[{"id":"11111111-1111-4111-8111-111111111111","name":"Claude","path":"/Synthetic.app","bundleID":"com.anthropic.claudefordesktop","kind":"claude","dataFolder":"/data","sharedCodexHistory":false,"spaces":[{"id":"22222222-2222-4222-8222-222222222222","name":"Work","folder":"/space","email":"","arguments":"","environment":"","inheritEnvironment":false,"lastOpened":100}]}],"accounts":[{"id":"33333333-3333-4333-8333-333333333333","provider":"claude","label":"Usage","email":"","plan":"","windows":[{"title":"Week","percent":12,"resetsAt":100}],"signedIn":false,"lastRefreshed":100,"lastError":"error"}]}"#
        for text in [minimal, full] {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(text.utf8))
            XCTAssertEqual(state.apps[0].spaces[0].name, "Work")
            XCTAssertEqual(state.accounts[0].windows[0].percent, 12)
        }
    }

    @MainActor
    func testSharedCodexGuardAndReportDeduplication() async throws {
        let model = model()
        var app = app(.codex, shared: true)
        let target = Space(name: "Work", folder: root.appendingPathComponent("space").path)
        app.spaces = [target]
        model.apps = [app]
        model.openInstance = { _, _, _ in XCTFail("Shared open must be blocked"); return .current }
        model.running[target.id] = .current
        await model.openSharedCodex(app.id)
        XCTAssertTrue(model.notice?.contains("Quit Work first") == true)
        model.running = [:]
        model.hooks.runningInstances = { _ in [.current] }
        model.hooks.processArguments = { _ in nil }
        await model.openSharedCodex(app.id)
        XCTAssertTrue(model.notice?.contains("isolated Codex") == true)
        model.notice = nil
        model.report("One"); model.report("Two"); model.report("Two"); model.report(nil)
        XCTAssertEqual(model.notice, "One\n\nTwo")
    }
}
