import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SpaceTerminalAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = root.appendingPathComponent("Parallax-Terminal-Audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testCommandQuotesValuesDeletesItselfBeforeShellAndHasPrivateModes() throws {
        let path = root.appendingPathComponent("space 'quotes' $dollar `backticks` $(id) \\backslash").path
        let shell = root.appendingPathComponent("login 'shell' $ `backticks` $(id) \\\nnext")
        let output = root.appendingPathComponent("result")
        let temporary = root.appendingPathComponent("temporary 'quotes' $cash `backticks` $(id) \\backslash\nnext")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let probe = """
        #!/bin/sh
        test ! -e "$COMMAND_PATH" || exit 31
        test "$1" = '-l' || exit 32
        test . -ef "$EXPECTED_DIRECTORY" || exit 33
        /usr/bin/printf '%s' "$CODEX_HOME" > "$RESULT_PATH"
        """
        try Data(probe.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let command = try service().prepare(source(environment: "CODEX_HOME=\(path)"), preset: .codex,
                                            loginShell: shell.path, temporaryDirectory: temporary)
        defer { command.cleanup() }
        XCTAssertEqual(command.url.pathExtension, "command")
        for url in [command.url, command.url.deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let process = Process()
        process.executableURL = command.url
        process.currentDirectoryURL = command.url.deletingLastPathComponent()
        process.environment = ["COMMAND_PATH": command.url.path, "RESULT_PATH": output.path,
                               "EXPECTED_DIRECTORY": root.resolvingSymlinksInPath().path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.url.deletingLastPathComponent().path))
    }

    func testOnlyPresetDirectoryIsWrittenAndSecretsAreNeverResolvedOrCopied() throws {
        let reference = EnvironmentSecretReference().token
        let command = try service().prepare(source(environment: """
            CODEX_HOME=\(root.path)/Codex
            CLAUDE_CONFIG_DIR=\(root.path)/Other
            API_KEY=sensitive-literal
            OTHER=\(reference)
            """), preset: .codex, loginShell: "/bin/zsh", temporaryDirectory: root)
        defer { command.cleanup() }
        let script = try String(contentsOf: command.url, encoding: .utf8)
        XCTAssertTrue(script.contains("CODEX_HOME="))
        XCTAssertFalse(script.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertFalse(script.contains("sensitive-literal"))
        XCTAssertFalse(script.contains(reference))
        XCTAssertFalse(script.contains("API_KEY"))
    }

    func testSensitiveOrKeychainDirectoryIsRefusedBeforeWritingScript() throws {
        for value in [EnvironmentSecretReference().token, root.path + "/private-directory"] {
            var source = try source(environment: "CODEX_HOME=\(value)")
            if !value.hasPrefix("{{") { source = replacingSensitiveKeys(source, keys: ["CODEX_HOME"]) }
            XCTAssertThrowsError(try service().prepare(source, preset: .codex,
                loginShell: "/bin/zsh", temporaryDirectory: root)) { error in
                guard case SpaceTerminalError.sensitiveDirectory = error else {
                    return XCTFail("Expected sensitive-directory refusal, got \(error)")
                }
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("Parallax-Terminal-") })
    }

    func testUnavailableForOtherPresetsAndMissingDirectory() throws {
        let source = try source(environment: "CODEX_HOME=\(root.path)/Codex")
        for preset in AppPreset.allCases where preset != .codex && preset != .claude {
            XCTAssertFalse(SpaceTerminalService.supports(preset))
            XCTAssertThrowsError(try service().prepare(source, preset: preset,
                loginShell: "/bin/zsh", temporaryDirectory: root))
        }
        XCTAssertThrowsError(try service().prepare(self.source(environment: ""), preset: .codex,
            loginShell: "/bin/zsh", temporaryDirectory: root))
    }

    func testReservationRefusesTerminalAndDoesNotPrepareManagedFolders() throws {
        let registry = ProfileActivityRegistry()
        let source = try source(environment: "", managed: true)
        let reservation = try registry.acquireDataOperationLease(identities: [identity(source)])
        defer { reservation.release() }
        XCTAssertThrowsError(try service(registry: registry).prepare(source, preset: .codex,
            loginShell: "/bin/zsh", temporaryDirectory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Storage/.parallax").path))
    }

    func testManagedCodexAndClaudePathsMatchLaunchAndArePrivate() async throws {
        for preset in [AppPreset.codex, .claude] {
            var source = try source(environment: "", managed: true)
            let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(configuredBaseRoot: source.configuredBaseRoot,
                applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
            if preset == .claude {
                source = try self.source(environment: "CLAUDE_CONFIG_DIR=\(paths.claudeConfig.url.path)",
                    managed: false, applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
            }
            let prepared = try await LaunchConfigurationCompiler(processEnvironment: [:]).prepare(source)
            for path in [paths.userData.url, paths.codexHome.url, paths.claudeConfig.url]
                where FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
            let command = try service().prepare(source, preset: preset, loginShell: "/bin/zsh", temporaryDirectory: root)
            defer { command.cleanup() }
            let key = preset == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            let path = try XCTUnwrap(prepared.environment[key])
            let script = try String(contentsOf: command.url, encoding: .utf8)
            XCTAssertTrue(script.contains("\(key)='\(path)'"))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testExternalDirectoryIsNotCreatedAndTildeMatchesLaunch() async throws {
        let source = try source(environment: "CODEX_HOME=~/External")
        let identity = ChildEnvironmentIdentity(homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path)
        let command = try SpaceTerminalService(activityRegistry: ProfileActivityRegistry(), identity: identity)
            .prepare(source, preset: .codex, loginShell: "/bin/zsh", temporaryDirectory: root)
        defer { command.cleanup() }
        let prepared = try await LaunchConfigurationCompiler(identity: identity, processEnvironment: [:]).prepare(source)
        let script = try String(contentsOf: command.url, encoding: .utf8)
        XCTAssertTrue(script.contains("CODEX_HOME='\(try XCTUnwrap(prepared.environment["CODEX_HOME"]))'"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("External").path))
    }

    func testCleanupFailureDoesNotPreventShellStarting() throws {
        let shell = root.appendingPathComponent("probe")
        let output = root.appendingPathComponent("started")
        try Data("#!/bin/sh\n/usr/bin/touch \"$RESULT_PATH\"\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let command = try service().prepare(source(environment: "CODEX_HOME=\(root.path)/Codex"),
            preset: .codex, loginShell: shell.path, temporaryDirectory: root)
        defer { command.cleanup() }
        try Data().write(to: command.url.deletingLastPathComponent().appendingPathComponent("leftover"))
        let process = Process()
        process.executableURL = command.url
        process.environment = ["RESULT_PATH": output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.url.path))
    }

    private func service(registry: ProfileActivityRegistry = ProfileActivityRegistry()) -> SpaceTerminalService {
        SpaceTerminalService(activityRegistry: registry, identity: ChildEnvironmentIdentity(
            homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path))
    }

    private func source(environment: String, managed: Bool = false,
                        applicationStorageID: UUID = UUID(), profileStorageID: UUID = UUID()) throws -> LaunchConfigurationSource {
        let fixtureRoot = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let fixture = try ValidApplicationBundleFixture.create(in: fixtureRoot)
        return LaunchConfigurationSource(requestID: UUID(), applicationID: UUID(), applicationStorageID: applicationStorageID,
            profileID: UUID(), profileStorageID: profileStorageID, configurationRevision: 0,
            applicationURL: fixture.url, expectedBundleIdentifier: fixture.bundleIdentifier,
            configuredBaseRoot: root.appendingPathComponent("Storage").path, argumentsText: "", environmentText: environment,
            isolationOwnership: .init(userData: .explicit, codexHome: managed ? .generated : .explicit),
            childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [])
    }

    private func identity(_ source: LaunchConfigurationSource) -> ProfileActivityIdentity {
        .init(applicationID: source.applicationID, applicationStorageID: source.applicationStorageID,
              profileID: source.profileID, profileStorageID: source.profileStorageID)
    }

    private func replacingSensitiveKeys(_ source: LaunchConfigurationSource, keys: [String]) -> LaunchConfigurationSource {
        .init(requestID: source.requestID, applicationID: source.applicationID, applicationStorageID: source.applicationStorageID,
              profileID: source.profileID, profileStorageID: source.profileStorageID, configurationRevision: 0,
              applicationURL: source.applicationURL, expectedBundleIdentifier: source.expectedBundleIdentifier,
              configuredBaseRoot: source.configuredBaseRoot, argumentsText: source.argumentsText, environmentText: source.environmentText,
              isolationOwnership: source.isolationOwnership, childEnvironmentPolicy: source.childEnvironmentPolicy,
              sensitiveEnvironmentKeys: keys)
    }
}
