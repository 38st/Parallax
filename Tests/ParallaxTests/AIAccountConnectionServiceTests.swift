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
                "OPENAI_API_KEY": "addition-secret",
            ]
        )

        XCTAssertEqual(environment["HOME"], identity.homeDirectory)
        XCTAssertEqual(environment["USER"], identity.userName)
        XCTAssertEqual(environment["LOGNAME"], identity.userName)
        XCTAssertEqual(environment["TMPDIR"], identity.temporaryDirectory)
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["CODEX_HOME"], "/isolated/codex")
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

    private func directory(_ name: String) -> URL {
        temporaryDirectory.appendingPathComponent(name, isDirectory: true)
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
