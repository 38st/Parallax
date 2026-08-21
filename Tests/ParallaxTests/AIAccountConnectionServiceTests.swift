import Darwin
import Foundation
import XCTest
@testable import Parallax

final class AIAccountConnectionServiceTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-AIAccountConnection-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testExecutableDiscoveryUsesOnlyApprovedLocations() throws {
        let hostilePath = directory("hostile-path")
        let approved = directory("approved")
        _ = try executable(named: "codex", in: hostilePath)
        let expected = try executable(named: "codex", in: approved)

        let located = try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [approved]
        ).locate(named: "codex")

        XCTAssertEqual(
            located.url.path,
            try canonicalPath(expected)
        )
    }

    func testExecutableDiscoveryRejectsGroupWritableCandidate() throws {
        let unsafeDirectory = directory("unsafe")
        let safeDirectory = directory("safe")
        let unsafe = try executable(named: "codex", in: unsafeDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: unsafe.path
        )
        let expected = try executable(named: "codex", in: safeDirectory)

        let located = try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [unsafeDirectory, safeDirectory]
        ).locate(named: "codex")

        XCTAssertEqual(
            located.url.path,
            try canonicalPath(expected)
        )
    }

    func testKnownHomebrewRootAllowsAdminGroupWritableAncestors() throws {
        let homebrewRoot = directory("homebrew")
        let homebrewBin = homebrewRoot.appendingPathComponent("bin")
        let caskroom = homebrewRoot.appendingPathComponent("Caskroom")
        let payloadBin = caskroom
            .appendingPathComponent("codex/1.0.0/bin", isDirectory: true)
        let payload = try executable(named: "codex", in: payloadBin)
        try FileManager.default.createDirectory(
            at: homebrewBin,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: homebrewBin.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: caskroom.path
        )
        try FileManager.default.createSymbolicLink(
            at: homebrewBin.appendingPathComponent("codex"),
            withDestinationURL: payload
        )

        let located = try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [],
            homebrewRoots: [homebrewRoot]
        ).locate(named: "codex")

        XCTAssertEqual(
            located.url.path,
            try canonicalPath(payload)
        )
        XCTAssertEqual(try located.revalidatedURL().path, located.url.path)
    }

    func testUserManagedToolOutsideApprovedRootsIsNotDiscovered() throws {
        let userManaged = try executable(
            named: "claude",
            in: directory("nvm/versions/node/v24/bin")
        )
        let locator = ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: []
        )

        XCTAssertThrowsError(try locator.locate(named: "claude")) { error in
            XCTAssertEqual(
                error as? ProviderExecutableLocatorError,
                .missing("claude")
            )
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: userManaged.path))
    }

    func testHomebrewBoundaryStillRejectsGroupWritableLeaf() throws {
        let homebrewRoot = directory("unsafe-homebrew-leaf")
        let homebrewBin = homebrewRoot.appendingPathComponent("bin")
        let executable = try executable(named: "codex", in: homebrewBin)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: homebrewBin.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: executable.path
        )

        XCTAssertThrowsError(
            try ProviderExecutableLocator(
                currentUserID: getuid(),
                fixedDirectories: [],
                homebrewRoots: [homebrewRoot]
            ).locate(named: "codex")
        ) { error in
            XCTAssertEqual(
                error as? ProviderExecutableLocatorError,
                .missing("codex")
            )
        }
    }

    func testInstalledHomebrewRootIsLocatableWhenPresent() throws {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.fileExists(atPath: brew.path) else {
            throw XCTSkip("Apple Silicon Homebrew is not installed")
        }

        let located = try ProviderExecutableLocator().locate(named: "brew")

        XCTAssertTrue(located.url.path.hasPrefix("/opt/homebrew/"))
        XCTAssertEqual(try located.revalidatedURL(), located.url)
    }

    func testExecutableDiscoveryRejectsWritableTrustRoot() throws {
        let unsafeRoot = directory("writable-root")
        _ = try executable(named: "codex", in: unsafeRoot)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeRoot.path
        )

        XCTAssertThrowsError(
            try ProviderExecutableLocator(
                currentUserID: getuid(),
                fixedDirectories: [unsafeRoot]
            ).locate(named: "codex")
        ) { error in
            XCTAssertEqual(
                error as? ProviderExecutableLocatorError,
                .missing("codex")
            )
        }
    }

    func testProviderEnvironmentDoesNotInheritSecretsOrLoaderState() {
        let identity = ChildEnvironmentIdentity(
            homeDirectory: "/Users/fixture",
            userName: "fixture",
            temporaryDirectory: "/private/tmp/fixture"
        )
        let environment = ProviderSubprocessEnvironment.make(
            processEnvironment: [
                "PATH": "/tmp/hostile-bin",
                "OPENAI_API_KEY": "secret",
                "ANTHROPIC_API_KEY": "secret",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "LD_PRELOAD": "/tmp/inject.so",
                "LANG": "en_US.UTF-8",
                "UNRELATED": "value",
            ],
            identity: identity,
            additions: [
                "CODEX_HOME": "/isolated/codex",
                "CLAUDE_CONFIG_DIR": "/isolated/claude",
                "LANG": "C",
                "LC_ALL": "C",
                "TZ": "UTC",
                "OPENAI_API_KEY": "addition-secret",
            ]
        )

        XCTAssertEqual(environment["HOME"], identity.homeDirectory)
        XCTAssertEqual(environment["USER"], identity.userName)
        XCTAssertEqual(environment["LOGNAME"], identity.userName)
        XCTAssertEqual(environment["TMPDIR"], identity.temporaryDirectory)
        XCTAssertEqual(environment["LANG"], "C")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["TZ"], "UTC")
        XCTAssertEqual(environment["CODEX_HOME"], "/isolated/codex")
        XCTAssertEqual(
            environment["CLAUDE_CONFIG_DIR"],
            "/isolated/claude"
        )
        XCTAssertEqual(
            environment["PATH"],
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["LD_PRELOAD"])
        XCTAssertNil(environment["UNRELATED"])
    }

    func testAccountSessionDirectoriesAreCodexOnly() throws {
        let firstID = UUID()
        let secondID = UUID()

        let firstCodex = try AIAccountConnectionService.accountSessionDirectory(
            accountID: firstID,
            component: "CodexHome",
            applicationSupportURL: temporaryDirectory
        )
        let secondCodex = try AIAccountConnectionService.accountSessionDirectory(
            accountID: secondID,
            component: "CodexHome",
            applicationSupportURL: temporaryDirectory
        )

        XCTAssertNotEqual(firstCodex, secondCodex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCodex.path))
        XCTAssertEqual(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: firstCodex.path)[
                    .posixPermissions
                ] as? NSNumber
            ).intValue & 0o777,
            0o700
        )
        XCTAssertThrowsError(
            try AIAccountConnectionService.accountSessionDirectory(
                accountID: firstID,
                component: "ClaudeConfig",
                applicationSupportURL: temporaryDirectory
            )
        )
    }

    func testClaudeControlCenterUsesCurrentMacOSUserConfiguration() {
        let environment = AIAccountConnectionService.claudeTrackingEnvironment

        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(environment["TZ"], "UTC")
    }

    func testCodexAuthURLRequiresHTTPSOnApprovedOpenAIHost() {
        XCTAssertNotNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "https://auth.openai.com/oauth/authorize?state=fixture"
            )
        )
        XCTAssertNotNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "https://chatgpt.com/auth/login"
            )
        )
        XCTAssertNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "http://auth.openai.com/oauth/authorize"
            )
        )
        XCTAssertNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "https://openai.com.evil.example/oauth/authorize"
            )
        )
        XCTAssertNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "https://user:password@auth.openai.com/oauth/authorize"
            )
        )
        XCTAssertNil(
            ProviderAuthURLPolicy.validatedCodexURL(
                "file:///tmp/provider-login.html"
            )
        )
    }

    func testAuthURLOpenerUsesTypedWorkspaceBoundary() async throws {
        let recorder = URLRecorder()
        let opener = ProviderAuthURLOpener { url in
            recorder.record(url)
            return true
        }
        let url = try XCTUnwrap(
            ProviderAuthURLPolicy.validatedCodexURL(
                "https://auth.openai.com/oauth/authorize?state=fixture"
            )
        )

        let opened = await opener.open(url)

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.urls, [url])
    }

    func testSurfacedProviderErrorsAreFixedAndCannotCarryProviderText() {
        XCTAssertEqual(
            AIAccountConnectionError.executableMissing("Claude")
                .errorDescription,
            "A trusted Claude executable was not found in an approved system location."
        )
        XCTAssertEqual(
            AIAccountConnectionError.loginFailed.errorDescription,
            "Sign-in did not complete. Try again."
        )
        XCTAssertEqual(
            AIAccountConnectionError.statusUnavailable.errorDescription,
            "Account status is unavailable. Try again."
        )
    }

    func testNumericDecoderRejectsNonFiniteOutOfRangeAndLossyValues() {
        XCTAssertEqual(ProviderNumericDecoder.percentage("99.6"), 100)
        XCTAssertNil(ProviderNumericDecoder.percentage(Double.nan))
        XCTAssertNil(ProviderNumericDecoder.percentage(Double.infinity))
        XCTAssertNil(ProviderNumericDecoder.percentage(-0.1))
        XCTAssertNil(ProviderNumericDecoder.percentage(100.1))
        XCTAssertNil(ProviderNumericDecoder.percentage(true))

        XCTAssertEqual(ProviderNumericDecoder.tokenCount("12345"), 12_345)
        XCTAssertNil(ProviderNumericDecoder.tokenCount(1.5))
        XCTAssertNil(ProviderNumericDecoder.tokenCount(-1))
        XCTAssertNil(ProviderNumericDecoder.tokenCount("nan"))
        XCTAssertNil(
            ProviderNumericDecoder.tokenCount(
                ProviderNumericDecoder.maximumExactInteger + 1
            )
        )

        XCTAssertNotNil(ProviderNumericDecoder.unixDate(1_700_000_000))
        XCTAssertNil(ProviderNumericDecoder.unixDate(-1))
        XCTAssertNil(ProviderNumericDecoder.unixDate("inf"))
        XCTAssertNil(
            ProviderNumericDecoder.unixDate(
                ProviderNumericDecoder.maximumUnixTimestamp + 1
            )
        )
    }

    func testClaudeAuthenticationStatusRequiresExplicitAuthenticationField()
        throws
    {
        XCTAssertThrowsError(
            try ClaudeAuthenticationStatusDecoder.decode(
                #"{"email":"claude@example.com"}"#
            )
        ) { error in
            guard case AIAccountConnectionError.statusUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        for numericBoolean in ["0", "1"] {
            XCTAssertThrowsError(
                try ClaudeAuthenticationStatusDecoder.decode(
                    #"{"loggedIn":\#(numericBoolean)}"#
                )
            ) { error in
                guard case AIAccountConnectionError.statusUnavailable = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        let authenticated = try ClaudeAuthenticationStatusDecoder.decode(
            #"{"isAuthenticated":true,"account":{"email":"claude@example.com"},"subscriptionType":"max"}"#
        )
        XCTAssertTrue(authenticated.isAuthenticated)
        XCTAssertEqual(authenticated.email, "claude@example.com")
        XCTAssertEqual(authenticated.planName, "max")

        let signedOut = try ClaudeAuthenticationStatusDecoder.decode(
            #"{"loggedIn":false}"#
        )
        XCTAssertFalse(signedOut.isAuthenticated)
    }

    func testClaudeUsageParserReadsSessionWeeklyAndModelWindows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 20,
                    hour: 12
                )
            )
        )
        let output = try claudeUsageEnvelope(
            result: """
            You are currently using your subscription to power Claude Code usage

            Current session: 6% used · resets Aug 20 at 4:36pm (UTC)
            Current week (all models): 2% used · resets Aug 27 at 1:59pm (UTC)
            Current week (Fable): 3% used · resets Aug 27 at 1:59pm (UTC)
            """
        )

        let windows = try ClaudeUsageOutputParser.parse(output, now: now)

        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map(\.kind), [
            .session,
            .weeklyAllModels,
            .weeklyModel,
        ])
        XCTAssertEqual(windows.map(\.usagePercent), [6, 2, 3])
        XCTAssertEqual(windows.last?.modelName, "Fable")
        XCTAssertEqual(
            windows.first?.resetsAt,
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 20,
                    hour: 16,
                    minute: 36
                )
            )
        )
    }

    func testClaudeUsageParserReadsRelativeResetAndDeduplicatesUpdates()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_000)
        let output = try claudeUsageEnvelope(
            result: """
            Current session: 5% used · resets in 4 hr 36 min
            Current session: 6% used · resets in 4 hr 36 min
            """
        )

        let windows = try ClaudeUsageOutputParser.parse(output, now: now)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usagePercent, 6)
        XCTAssertEqual(
            windows[0].resetsAt,
            now.addingTimeInterval((4 * 3_600) + (36 * 60))
        )
    }

    func testClaudeUsageParserRejectsInferenceAndMissingLimits() throws {
        let inferred = try claudeUsageEnvelope(
            result: "Current session: 1% used",
            totalCost: 0.01
        )
        XCTAssertThrowsError(try ClaudeUsageOutputParser.parse(inferred)) {
            XCTAssertEqual(
                $0 as? ClaudeUsageOutputParserError,
                .inferenceDetected
            )
        }

        let tokenUsing = try claudeUsageEnvelope(
            result: "Current session: 1% used",
            inputTokens: 1
        )
        XCTAssertThrowsError(try ClaudeUsageOutputParser.parse(tokenUsing)) {
            XCTAssertEqual(
                $0 as? ClaudeUsageOutputParserError,
                .inferenceDetected
            )
        }

        let missing = try claudeUsageEnvelope(result: "No plan limits")
        XCTAssertThrowsError(try ClaudeUsageOutputParser.parse(missing)) {
            XCTAssertEqual(
                $0 as? ClaudeUsageOutputParserError,
                .usageUnavailable
            )
        }
    }

    func testProcessRunnerRevalidatesExecutableImmediatelyBeforeSpawn() throws {
        let marker = temporaryDirectory.appendingPathComponent("spawned")
        let script = try executable(
            named: "provider",
            in: directory("revalidation"),
            contents: "#!/bin/sh\nprintf spawned > \"$1\"\n"
        )
        let trusted = try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [script.deletingLastPathComponent()]
        ).locate(named: "provider")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: script.path
        )

        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: trusted,
                arguments: [marker.path],
                environment: [:],
                timeout: 1
            )
        ) { error in
            XCTAssertEqual(error as? ProviderProcessFailure, .unsafeExecutable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAlreadyCancelledProcessRequestDoesNotSpawn() throws {
        let marker = temporaryDirectory.appendingPathComponent("cancelled-spawn")
        let script = try executable(
            named: "provider",
            in: directory("cancel-before-spawn"),
            contents: "#!/bin/sh\nprintf spawned > \"$1\"\n"
        )
        let trusted = try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [script.deletingLastPathComponent()]
        ).locate(named: "provider")

        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: trusted,
                arguments: [marker.path],
                environment: [:],
                timeout: 1,
                cancellationCheck: { true }
            )
        ) { error in
            XCTAssertEqual(error as? ProviderProcessFailure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testProcessTimeoutTerminatesKillsAndReapsUncooperativeChild() throws {
        let trusted = try uncooperativeProvider(named: "timeout-provider")
        let processRecorder = ProcessIDRecorder()
        let startedAt = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: trusted,
                arguments: [],
                environment: [:],
                timeout: 0.15,
                startedHandler: { processRecorder.record($0) }
            )
        ) { error in
            XCTAssertEqual(error as? ProviderProcessFailure, .timedOut)
        }

        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            2
        )
        try assertProcessIsGone(pid: try XCTUnwrap(processRecorder.pid))
    }

    func testProcessCancellationTerminatesAndReapsChild() throws {
        let trusted = try uncooperativeProvider(named: "cancel-provider")
        let processRecorder = ProcessIDRecorder()
        let cancellationDeadline = ProviderDeadline(after: 0.1)

        XCTAssertThrowsError(
            try ProviderProcessRunner.run(
                executable: trusted,
                arguments: [],
                environment: [:],
                timeout: 5,
                cancellationCheck: { cancellationDeadline.hasExpired },
                startedHandler: { processRecorder.record($0) }
            )
        ) { error in
            XCTAssertEqual(error as? ProviderProcessFailure, .cancelled)
        }

        try assertProcessIsGone(pid: try XCTUnwrap(processRecorder.pid))
    }

    func testTerminationWaiterReapsAcrossExecutorThreads() throws {
        let process = Process()
        let terminationWaiter = ProviderProcessTerminationWaiter()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        terminationWaiter.install(on: process)
        try process.run()
        let pid = process.processIdentifier

        let finished = expectation(description: "cross-thread process reap")
        DispatchQueue.global(qos: .userInitiated).async {
            ProviderProcessLifecycle.terminateAndReap(
                process,
                terminationWaiter: terminationWaiter
            )
            finished.fulfill()
        }

        wait(for: [finished], timeout: 3)
        try assertProcessIsGone(pid: pid)
    }

    private func directory(_ name: String) -> URL {
        temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func claudeUsageEnvelope(
        result: String,
        totalCost: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "type": "result",
                "subtype": "success",
                "result": result,
                "total_cost_usd": totalCost,
                "usage": [
                    "input_tokens": inputTokens,
                    "output_tokens": outputTokens,
                ],
            ],
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func executable(
        named name: String,
        in directory: URL,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func uncooperativeProvider(
        named name: String
    ) throws -> TrustedProviderExecutable {
        let script = try executable(
            named: name,
            in: directory(name),
            contents: """
            #!/bin/sh
            trap '' TERM
            while :; do :; done
            """
        )
        return try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [script.deletingLastPathComponent()]
        ).locate(named: name)
    }

    private func assertProcessIsGone(pid: pid_t) throws {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func canonicalPath(_ url: URL) throws -> String {
        let pointer = try XCTUnwrap(realpath(url.path, nil))
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    func record(_ url: URL) {
        lock.withLock { recordedURLs.append(url) }
    }

    var urls: [URL] {
        lock.withLock { recordedURLs }
    }
}

private final class ProcessIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPID: pid_t?

    func record(_ pid: pid_t) {
        lock.withLock { recordedPID = pid }
    }

    var pid: pid_t? {
        lock.withLock { recordedPID }
    }
}
