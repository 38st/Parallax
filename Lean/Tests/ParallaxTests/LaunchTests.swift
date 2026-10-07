import XCTest
@testable import Parallax

final class LaunchTextTests: XCTestCase {
    func testWordsFollowShellQuoting() throws {
        XCTAssertEqual(try LaunchText.words(#"--a=1 'two words' "x\"y" C:\\dir"#), ["--a=1", "two words", #"x"y"#, #"C:\dir"#])
        XCTAssertEqual(try LaunchText.words(#""C:\dir" "a\$b""#), [#"C:\dir"#, "a$b"])
        XCTAssertEqual(try LaunchText.words("  "), [])
        XCTAssertEqual(try LaunchText.words("''"), [""])
        XCTAssertThrowsError(try LaunchText.words("'open"))
        XCTAssertThrowsError(try LaunchText.words("\"open"))
    }

    func testQuoteRoundTrips() throws {
        let words = ["plain", "with space", "it's", "", "--user-data-dir=/Library/Application Support/X"]
        XCTAssertEqual(try LaunchText.words(LaunchText.join(words)), words)
    }

    func testEnvironmentParsing() {
        let parsed = LaunchText.environment("""
        # comment
        A=1
        B=two=parts
        unset C
        A=3
        bad-key=x
        """)
        XCTAssertEqual(parsed.values, ["A": "3", "B": "two=parts"])
        XCTAssertEqual(parsed.unset, ["C"])
    }

    func testRemovingOption() {
        XCTAssertEqual(["--user-data-dir=/x", "--keep", "--user-data-dir", "/y", "z"].removingOption(["--user-data-dir"]), ["--keep", "z"])
        XCTAssertEqual(LaunchText.removingEnvironment(["CODEX_HOME"], from: "CODEX_HOME=/x\nKEEP=1\nunset CODEX_HOME"), "KEEP=1")
    }
}

final class LaunchPlanTests: XCTestCase {
    private let parent = ["PATH": "/opt/bin", "LANG": "en_US.UTF-8", "SECRET": "s", "CODEX_HOME": "/leak", "VSCODE_PORTABLE": "/p", "DYLD_X": "1"]

    private func app(_ kind: AppKind, shared: Bool = false) -> ManagedApp {
        ManagedApp(name: "App", path: "/Applications/App.app", bundleID: "com.example.app", kind: kind, dataFolder: "/data/app", sharedCodexHistory: shared)
    }

    private func space(arguments: String = "", environment: String = "", inherit: Bool = false) -> Space {
        Space(name: "Work", folder: "/data/app/Profiles/s1", arguments: arguments, environment: environment, inheritEnvironment: inherit)
    }

    func testClaudeGetsUserDataAndConfigFolder() throws {
        let plan = try LaunchPlanner.plan(app: app(.claude), space: space(arguments: "--flag"), parentEnvironment: parent, home: "/Users/me")
        XCTAssertEqual(plan.arguments, ["--flag", "--user-data-dir=/data/app/Profiles/s1/UserData"])
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], "/data/app/Profiles/s1/UserData/ClaudeConfig")
        XCTAssertEqual(plan.folders, ["/data/app/Profiles/s1/UserData", "/data/app/Profiles/s1/UserData/ClaudeConfig"])
        XCTAssertTrue(plan.newInstance)
        XCTAssertEqual(plan.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(plan.environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(plan.environment["SECRET"])
        XCTAssertNil(plan.environment["CODEX_HOME"])
        XCTAssertEqual(plan.environment["HOME"], "/Users/me")
    }

    func testExplicitSettingsWin() throws {
        let plan = try LaunchPlanner.plan(
            app: app(.claude),
            space: space(arguments: "--user-data-dir=~/Custom", environment: "CLAUDE_CONFIG_DIR=~/Config"),
            parentEnvironment: parent, home: "/Users/me"
        )
        XCTAssertEqual(plan.arguments, ["--user-data-dir=/Users/me/Custom"])
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], "/Users/me/Config")
        XCTAssertEqual(plan.folders, [])
    }

    func testCodexSeparateAndShared() throws {
        let separate = try LaunchPlanner.plan(app: app(.codex), space: space(environment: "CODEX_HOME=/accounts/a"), parentEnvironment: parent)
        XCTAssertEqual(separate.environment["CODEX_HOME"], "/accounts/a")
        XCTAssertEqual(separate.arguments, ["--user-data-dir=/data/app/Profiles/s1/UserData"])

        let generated = try LaunchPlanner.plan(app: app(.codex), space: space(), parentEnvironment: parent)
        XCTAssertEqual(generated.environment["CODEX_HOME"], "/data/app/Profiles/s1/CodexHome")

        let shared = try LaunchPlanner.plan(
            app: app(.codex, shared: true),
            space: space(arguments: "--user-data-dir=/x", environment: "CODEX_HOME=/accounts/a\nCODEX_SQLITE_HOME=/s"),
            parentEnvironment: parent, home: "/Users/me"
        )
        XCTAssertEqual(shared.arguments, [])
        XCTAssertEqual(shared.environment["CODEX_HOME"], "/Users/me/.codex")
        XCTAssertNil(shared.environment["CODEX_SQLITE_HOME"])
        XCTAssertFalse(shared.newInstance)
        XCTAssertEqual(shared.folders, [])
    }

    func testVSCodeAndFirefox() throws {
        let code = try LaunchPlanner.plan(app: app(.vscode), space: space(arguments: "-- file"), parentEnvironment: parent)
        XCTAssertEqual(code.arguments, ["--user-data-dir=/data/app/Profiles/s1/UserData", "--extensions-dir=/data/app/Profiles/s1/Extensions", "--", "file"])

        let firefox = try LaunchPlanner.plan(app: app(.firefox), space: space(), parentEnvironment: parent)
        XCTAssertEqual(firefox.arguments, ["-profile", "/data/app/Profiles/s1/FirefoxProfile", "-no-remote"])

        let chosen = try LaunchPlanner.plan(app: app(.firefox), space: space(arguments: "-P work"), parentEnvironment: parent)
        XCTAssertEqual(chosen.arguments, ["-P", "work", "-no-remote"])
    }

    func testInheritedEnvironmentDropsRedirectingVariables() throws {
        let plan = try LaunchPlanner.plan(app: app(.vscode), space: space(inherit: true), parentEnvironment: parent)
        XCTAssertEqual(plan.environment["SECRET"], "s")
        XCTAssertEqual(plan.environment["PATH"], "/opt/bin")
        XCTAssertNil(plan.environment["VSCODE_PORTABLE"])
        XCTAssertNil(plan.environment["CODEX_HOME"])
        XCTAssertNil(plan.environment["DYLD_X"])
    }

    func testUnsetRemovesVariable() throws {
        let plan = try LaunchPlanner.plan(app: app(.chromium), space: space(environment: "LANG=fr\nunset LANG"), parentEnvironment: parent)
        XCTAssertNil(plan.environment["LANG"])
    }

    func testIsolationMarker() {
        XCTAssertEqual(LaunchPlanner.isolationMarker(app: app(.claude), space: space()), "/data/app/Profiles/s1/UserData")
        XCTAssertEqual(LaunchPlanner.isolationMarker(app: app(.chromium), space: space(arguments: "--user-data-dir=/other")), "/other")
        XCTAssertNil(LaunchPlanner.isolationMarker(app: app(.other), space: space()))
    }

    func testDetection() {
        XCTAssertEqual(AppKind.detect(name: "ChatGPT", bundleID: "com.openai.codex"), .codex)
        XCTAssertEqual(AppKind.detect(name: "Claude", bundleID: "com.anthropic.claudefordesktop"), .claude)
        XCTAssertEqual(AppKind.detect(name: "Google Chrome", bundleID: "com.google.Chrome"), .chromium)
        XCTAssertEqual(AppKind.detect(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"), .vscode)
        XCTAssertEqual(AppKind.detect(name: "Firefox", bundleID: "org.mozilla.firefox"), .firefox)
        XCTAssertEqual(AppKind.detect(name: "Arc", bundleID: "company.thebrowser.Browser"), .other)
    }
}
