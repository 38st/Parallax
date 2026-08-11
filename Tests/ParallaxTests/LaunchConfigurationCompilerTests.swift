import Foundation
import XCTest
@testable import Parallax

final class LaunchConfigurationCompilerTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var application: ValidApplicationBundleFixture?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-LaunchCompiler-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        application = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConfirmationFingerprintHasStableGoldenVector() throws {
        let fingerprint = LaunchConfigurationCompiler.configurationFingerprint(
            for: try fixedFingerprintSource()
        )

        XCTAssertEqual(
            fingerprint,
            LaunchConfigurationFingerprint(
                digest:
                    "e0ca0d1b7d952f5980257c40ba98c8472a14c55a1f8c05bb635ec39934482b72"
            )
        )
    }

    func testConfirmationFingerprintRejectsFormerDelimiterCollisions() throws {
        let source = try fixedFingerprintSource()
        let fieldBoundaryLeft = replacing(
            source,
            configuredBaseRoot: "/tmp/left\u{1f}right",
            arguments: "tail"
        )
        let fieldBoundaryRight = replacing(
            source,
            configuredBaseRoot: "/tmp/left",
            arguments: "right\u{1f}tail"
        )
        let nestedSequenceLeft = replacing(
            source,
            sensitiveEnvironmentKeys: ["ALPHA\u{1e}BETA", "GAMMA"]
        )
        let nestedSequenceRight = replacing(
            source,
            sensitiveEnvironmentKeys: ["ALPHA", "BETA\u{1e}GAMMA"]
        )

        XCTAssertNotEqual(
            LaunchConfigurationCompiler.configurationFingerprint(
                for: fieldBoundaryLeft
            ),
            LaunchConfigurationCompiler.configurationFingerprint(
                for: fieldBoundaryRight
            )
        )
        XCTAssertNotEqual(
            LaunchConfigurationCompiler.configurationFingerprint(
                for: nestedSequenceLeft
            ),
            LaunchConfigurationCompiler.configurationFingerprint(
                for: nestedSequenceRight
            )
        )
    }

    func testFingerprintBuilderSeparatesDomainAndVersion() {
        func digest(domain: String, version: UInt64) -> String {
            var builder = LengthPrefixedSHA256FingerprintBuilder(
                domain: domain,
                version: version
            )
            builder.append("same-value", for: "same-field")
            return builder.finalizeHexDigest()
        }

        let confirmation = digest(
            domain: "com.parallax.launch-configuration-confirmation",
            version: 1
        )
        XCTAssertNotEqual(
            confirmation,
            digest(
                domain: "com.parallax.imported-launch-trust",
                version: 1
            )
        )
        XCTAssertNotEqual(
            confirmation,
            digest(
                domain: "com.parallax.launch-configuration-confirmation",
                version: 2
            )
        )
    }

    func testMalformedArgumentsRequireFingerprintBoundOverride() async throws {
        let compiler = makeCompiler()
        let source = try makeSource(arguments: "--label 'unfinished")
        let analysis = await compiler.analyze(source)

        XCTAssertTrue(analysis.hasBlockingDiagnostics)
        XCTAssertTrue(
            analysis.diagnostics.contains {
                $0.code == .parsing(.unmatchedSingleQuote)
                    && $0.isOverridable
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source)
        }

        let wrongRequest = LaunchDiagnosticOverride(
            requestID: UUID(),
            configurationFingerprint: analysis.configurationFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source, override: wrongRequest)
        }

        let changed = replacing(
            source,
            arguments: source.argumentsText + " changed"
        )
        let stale = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint: analysis.configurationFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(changed, override: stale)
        }

        let exact = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint: analysis.configurationFingerprint
        )
        let prepared = try await compiler.prepare(source, override: exact)
        XCTAssertEqual(prepared.requestID, source.requestID)
        XCTAssertEqual(
            prepared.configurationFingerprint,
            analysis.configurationFingerprint
        )
    }

    func testSensitiveArgumentsAreRedactedAndCannotBeOverridden()
        async throws
    {
        let compiler = makeCompiler()
        let canary = "canary-private-value"
        let source = try makeSource(
            arguments:
                "--api-key=\(canary) --password \(canary) --password-store=basic"
        )
        let analysis = await compiler.analyze(source)

        XCTAssertEqual(
            analysis.diagnostics.filter {
                $0.code == .sensitiveArgument
            }.count,
            2
        )
        XCTAssertFalse(
            analysis.preview.arguments.contains {
                $0.contains(canary)
            }
        )
        let override = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint:
                analysis.configurationFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(
                source,
                override: override
            )
        }
    }

    func testDuplicateSingletonIsNeverOverridableAndHasNoFilesystemEffects() async throws {
        let compiler = makeCompiler()
        let first = temporaryDirectory.appendingPathComponent("first").path
        let second = temporaryDirectory.appendingPathComponent("second").path
        let source = try makeSource(
            arguments:
                "--user-data-dir=\(first) --user-data-dir \(second)",
            ownership: .explicit
        )
        let analysis = await compiler.analyze(source)
        let duplicate = try XCTUnwrap(
            analysis.diagnostics.first {
                $0.code == .parsing(.duplicateUserDataDirectory)
            }
        )
        XCTAssertFalse(duplicate.isOverridable)

        let override = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint: analysis.configurationFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source, override: override)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent(".parallax")
                    .path
            )
        )
    }

    func testActiveProfileRequiresDedicatedRiskOverride()
        async throws
    {
        let source = try makeSource()
        let compiler = makeCompiler(
            activityProvider: AlwaysActiveProfileProvider()
        )
        let analysis = await compiler.analyze(source)
        XCTAssertTrue(
            analysis.diagnostics.contains {
                $0.code == .profileHealth(.profileActive)
            }
        )

        let ordinary = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint:
                analysis.configurationFingerprint
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(
                source,
                override: ordinary
            )
        }

        let expert = LaunchDiagnosticOverride(
            requestID: source.requestID,
            configurationFingerprint:
                analysis.configurationFingerprint,
            allowsActiveProfileRisk: true
        )
        let prepared = try await compiler.prepare(
            source,
            override: expert
        )
        XCTAssertEqual(prepared.requestID, source.requestID)
    }

    func testRelativeExternalIsolationPathIsRejectedWithoutMutation()
        async throws
    {
        let compiler = makeCompiler()
        let source = try makeSource(
            arguments: "--user-data-dir=relative/profile",
            ownership: .explicit
        )

        let analysis = await compiler.analyze(source)

        XCTAssertTrue(
            analysis.diagnostics.contains {
                $0.code == .profileHealth(.externalPathInvalid)
                    && !$0.isOverridable
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent("relative/profile")
                    .path
            )
        )
    }

    func testPeerCanonicalIsolationCollisionBlocksLaunch()
        async throws
    {
        let shared = temporaryDirectory
            .appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true
        )
        var source = try makeSource(
            arguments: "--user-data-dir=\(shared.path)",
            ownership: .explicit
        )
        source.peerProfiles = [
            LaunchPeerProfileSource(
                profileID: UUID(),
                profileStorageID: UUID(),
                argumentsText:
                    "--user-data-dir \(shared.path)",
                environmentText: "",
                isolationOwnership: .explicit
            ),
        ]
        let compiler = makeCompiler()

        let analysis = await compiler.analyze(source)

        XCTAssertTrue(
            analysis.diagnostics.contains {
                $0.code == .profileHealth(
                    .canonicalPathCollision
                )
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source)
        }
    }

    func testSecretsResolveOnlyDuringPreparationAndPreviewRemainsRedacted() async throws {
        let reference = EnvironmentSecretReference()
        let resolver = RecordingSecretResolver(
            values: [reference: SecretValue("resolved-secret")]
        )
        let compiler = makeCompiler(secretResolver: resolver)
        let source = try makeSource(
            environment:
                "OPENAI_API_KEY=\(reference.token)\nLABEL=~/literal"
        )

        let analysis = await compiler.analyze(source)
        let countAfterAnalysis = await resolver.resolveCount
        XCTAssertEqual(countAfterAnalysis, 0)
        XCTAssertEqual(
            analysis.preview.environment.first {
                $0.key == "OPENAI_API_KEY"
            }?.displayValue,
            .redacted
        )

        let prepared = try await compiler.prepare(source)
        let countAfterPreparation = await resolver.resolveCount
        XCTAssertEqual(countAfterPreparation, 1)
        XCTAssertEqual(
            prepared.environment["OPENAI_API_KEY"],
            "resolved-secret"
        )
        XCTAssertEqual(prepared.environment["LABEL"], "~/literal")
        XCTAssertNil(prepared.environment["PARENT_ONLY_SECRET"])
        XCTAssertEqual(String(describing: prepared), "<prepared launch: redacted>")
        XCTAssertFalse(String(reflecting: prepared).contains("resolved-secret"))
    }

    func testSecretFailureDoesNotCreateGeneratedDirectories() async throws {
        let missing = EnvironmentSecretReference()
        let compiler = makeCompiler()
        let source = try makeSource(
            arguments: "",
            environment: "OPENAI_API_KEY=\(missing.token)",
            ownership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(source)
        }

        let paths = try ManagedPathResolver(
            fileSystem: LocalFileSystem()
        ).resolve(
            configuredBaseRoot: temporaryDirectory.path,
            applicationStorageID: source.applicationStorageID,
            profileStorageID: source.profileStorageID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.profileRoot.url.path)
        )
    }

    func testPreparedLaunchIsAnImmutableSnapshot() async throws {
        let compiler = makeCompiler()
        let source = try makeSource(
            arguments: "--label=before",
            environment: "LABEL=before"
        )
        let prepared = try await compiler.prepare(source)

        let editedSource = replacing(
            source,
            arguments: "--label=after",
            environment: "LABEL=after"
        )

        XCTAssertTrue(prepared.arguments.contains("--label=before"))
        XCTAssertEqual(prepared.environment["LABEL"], "before")
        XCTAssertFalse(prepared.arguments.contains(editedSource.argumentsText))
        XCTAssertEqual(
            prepared.applicationIdentity.bundleIdentifier,
            source.expectedBundleIdentifier
        )
        XCTAssertEqual(
            prepared.applicationIdentity.bundleURL,
            source.applicationURL.resolvingSymlinksInPath()
                .standardizedFileURL
        )
    }

    func testHealthyHistoricalApplicationWithoutStoredBundleIDRequiresRelink()
        async throws
    {
        let linked = try makeSource()
        let unlinked = LaunchConfigurationSource(
            requestID: linked.requestID,
            applicationID: linked.applicationID,
            applicationStorageID: linked.applicationStorageID,
            profileID: linked.profileID,
            profileStorageID: linked.profileStorageID,
            configurationRevision: linked.configurationRevision,
            applicationURL: linked.applicationURL,
            expectedBundleIdentifier: nil,
            configuredBaseRoot: linked.configuredBaseRoot,
            argumentsText: linked.argumentsText,
            environmentText: linked.environmentText,
            isolationOwnership: linked.isolationOwnership,
            childEnvironmentPolicy: linked.childEnvironmentPolicy,
            sensitiveEnvironmentKeys: linked.sensitiveEnvironmentKeys
        )
        let compiler = makeCompiler()

        let analysis = await compiler.analyze(unlinked)
        XCTAssertTrue(
            analysis.diagnostics.contains { diagnostic in
                diagnostic.code == .applicationHealth(
                    .missingBundleIdentifier
                ) && !diagnostic.isOverridable
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(unlinked)
        }
    }

    @MainActor
    func testDelayedPreparationDoesNotBlockMainActorHeartbeat() async throws {
        let gate = PreparationGate()
        let compiler = makeCompiler {
            await gate.wait()
        }
        let source = try makeSource()

        let task = Task {
            try await compiler.prepare(source)
        }
        await gate.waitUntilEntered()

        var heartbeat = false
        await Task.yield()
        heartbeat = true
        XCTAssertTrue(heartbeat)

        await gate.open()
        _ = try await task.value
    }

    func testCancellationBeforeMutationCreatesNoManagedDirectories() async throws {
        let gate = PreparationGate()
        let compiler = makeCompiler {
            await gate.wait()
        }
        let source = try makeSource(
            arguments: "",
            environment: "",
            ownership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )

        let task = Task {
            try await compiler.prepare(source)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await XCTAssertThrowsErrorAsync {
            _ = try await task.value
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent(".parallax")
                    .path
            )
        )
    }

    func testGeneratedDirectoriesAreCreatedOnlyAfterHealthValidation() async throws {
        let source = try makeSource(
            arguments: "",
            environment: "",
            ownership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let compiler = makeCompiler()
        let prepared = try await compiler.prepare(source)

        let userData = try XCTUnwrap(prepared.isolation.userDataURL)
        let codexHome = try XCTUnwrap(prepared.isolation.codexHomeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.path))
        XCTAssertTrue(
            prepared.arguments.contains(
                "--user-data-dir=\(userData.path)"
            )
        )
        XCTAssertEqual(prepared.environment["CODEX_HOME"], codexHome.path)

        let invalidSource = LaunchConfigurationSource(
            requestID: UUID(),
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID(),
            configurationRevision: 1,
            applicationURL: temporaryDirectory
                .appendingPathComponent("Missing.app"),
            expectedBundleIdentifier: nil,
            configuredBaseRoot: temporaryDirectory.path,
            argumentsText: "",
            environmentText: "",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            ),
            childEnvironmentPolicy: .safeDefault,
            sensitiveEnvironmentKeys: []
        )
        let invalidAnalysis = await compiler.analyze(invalidSource)
        XCTAssertTrue(
            invalidAnalysis.diagnostics.contains {
                if case .applicationHealth(.applicationMissing) = $0.code {
                    return true
                }
                return false
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await compiler.prepare(invalidSource)
        }
        let invalidPaths = try ManagedPathResolver(
            fileSystem: LocalFileSystem()
        ).resolve(
            configuredBaseRoot: temporaryDirectory.path,
            applicationStorageID: invalidSource.applicationStorageID,
            profileStorageID: invalidSource.profileStorageID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invalidPaths.profileRoot.url.path)
        )
    }

    func testGeneratedLaunchCreatesAcceptedMissingBaseRootSecurely()
        async throws
    {
        let missingBase = temporaryDirectory
            .appendingPathComponent("fresh/base", isDirectory: true)
        let original = try makeSource(
            arguments: "",
            environment: "",
            ownership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let source = LaunchConfigurationSource(
            requestID: original.requestID,
            applicationID: original.applicationID,
            applicationStorageID: original.applicationStorageID,
            profileID: original.profileID,
            profileStorageID: original.profileStorageID,
            configurationRevision: original.configurationRevision,
            applicationURL: original.applicationURL,
            expectedBundleIdentifier:
                original.expectedBundleIdentifier,
            configuredBaseRoot: missingBase.path,
            argumentsText: original.argumentsText,
            environmentText: original.environmentText,
            isolationOwnership: original.isolationOwnership,
            childEnvironmentPolicy: original.childEnvironmentPolicy,
            sensitiveEnvironmentKeys:
                original.sensitiveEnvironmentKeys
        )

        let prepared = try await makeCompiler().prepare(source)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: missingBase.path)
        )
        XCTAssertTrue(
            prepared.isolation.userDataURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true
        )
        XCTAssertTrue(
            prepared.isolation.codexHomeURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true
        )
    }

    private func makeSource(
        arguments: String = "--label=fixture",
        environment: String = "LABEL=fixture",
        ownership: ProfileIsolationOwnership = .explicit
    ) throws -> LaunchConfigurationSource {
        let application = try XCTUnwrap(application)
        return LaunchConfigurationSource(
            requestID: UUID(),
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID(),
            configurationRevision: 1,
            applicationURL: application.url,
            expectedBundleIdentifier: application.bundleIdentifier,
            configuredBaseRoot: temporaryDirectory.path,
            argumentsText: arguments,
            environmentText: environment,
            isolationOwnership: ownership,
            childEnvironmentPolicy: .safeDefault,
            sensitiveEnvironmentKeys: []
        )
    }

    private func makeCompiler(
        secretResolver: any SecretResolving = RecordingSecretResolver(),
        activityProvider: any ProfileHealthActivityProviding =
            NoProfileHealthActivityProvider(),
        preparationHook: @escaping @Sendable () async throws -> Void = {}
    ) -> LaunchConfigurationCompiler {
        LaunchConfigurationCompiler(
            fileSystem: LocalFileSystem(),
            activityProvider: activityProvider,
            identity: ChildEnvironmentIdentity(
                homeDirectory: "/Users/fixture",
                userName: "fixture",
                temporaryDirectory: "/private/tmp/fixture"
            ),
            processEnvironment: [
                "OPENAI_API_KEY": "must-not-leak",
                "PARENT_ONLY_SECRET": "must-not-leak",
                "LANG": "en_US.UTF-8",
            ],
            secretResolver: secretResolver,
            preparationHook: preparationHook
        )
    }

    private func fixedFingerprintSource() throws -> LaunchConfigurationSource {
        LaunchConfigurationSource(
            requestID: try XCTUnwrap(
                UUID(uuidString: "10000000-0000-4000-8000-000000000001")
            ),
            applicationID: try XCTUnwrap(
                UUID(uuidString: "20000000-0000-4000-8000-000000000001")
            ),
            applicationStorageID: try XCTUnwrap(
                UUID(uuidString: "30000000-0000-4000-8000-000000000001")
            ),
            profileID: try XCTUnwrap(
                UUID(uuidString: "40000000-0000-4000-8000-000000000001")
            ),
            profileStorageID: try XCTUnwrap(
                UUID(uuidString: "50000000-0000-4000-8000-000000000001")
            ),
            configurationRevision: 42,
            applicationURL: URL(
                fileURLWithPath: "/Applications/Fixture.app",
                isDirectory: true
            ),
            expectedBundleIdentifier: "com.example.fixture",
            configuredBaseRoot: "/tmp/parallax",
            argumentsText: "--label 'fixed value'",
            environmentText: "LABEL=fixed\nunset REMOVED",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            ),
            childEnvironmentPolicy: .safeDefault,
            sensitiveEnvironmentKeys: ["Z_TOKEN", "A_SECRET"],
            peerProfiles: [
                LaunchPeerProfileSource(
                    profileID: try XCTUnwrap(
                        UUID(
                            uuidString:
                                "70000000-0000-4000-8000-000000000002"
                        )
                    ),
                    profileStorageID: try XCTUnwrap(
                        UUID(
                            uuidString:
                                "80000000-0000-4000-8000-000000000002"
                        )
                    ),
                    argumentsText: "--peer=second",
                    environmentText: "PEER=second",
                    isolationOwnership: .explicit
                ),
                LaunchPeerProfileSource(
                    profileID: try XCTUnwrap(
                        UUID(
                            uuidString:
                                "70000000-0000-4000-8000-000000000001"
                        )
                    ),
                    profileStorageID: try XCTUnwrap(
                        UUID(
                            uuidString:
                                "80000000-0000-4000-8000-000000000001"
                        )
                    ),
                    argumentsText: "--peer=first",
                    environmentText: "PEER=first",
                    isolationOwnership: ProfileIsolationOwnership(
                        userData: .legacyUnknown,
                        codexHome: .generated
                    )
                ),
            ]
        )
    }

    private func replacing(
        _ source: LaunchConfigurationSource,
        configuredBaseRoot: String? = nil,
        arguments: String? = nil,
        environment: String? = nil,
        sensitiveEnvironmentKeys: [String]? = nil
    ) -> LaunchConfigurationSource {
        LaunchConfigurationSource(
            requestID: source.requestID,
            applicationID: source.applicationID,
            applicationStorageID: source.applicationStorageID,
            profileID: source.profileID,
            profileStorageID: source.profileStorageID,
            configurationRevision: source.configurationRevision,
            applicationURL: source.applicationURL,
            expectedBundleIdentifier: source.expectedBundleIdentifier,
            configuredBaseRoot:
                configuredBaseRoot ?? source.configuredBaseRoot,
            argumentsText: arguments ?? source.argumentsText,
            environmentText: environment ?? source.environmentText,
            isolationOwnership: source.isolationOwnership,
            childEnvironmentPolicy: source.childEnvironmentPolicy,
            sensitiveEnvironmentKeys:
                sensitiveEnvironmentKeys
                    ?? source.sensitiveEnvironmentKeys,
            peerProfiles: source.peerProfiles
        )
    }
}

private struct AlwaysActiveProfileProvider:
    ProfileHealthActivityProviding
{
    func isStorageActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> Bool {
        true
    }
}

private actor RecordingSecretResolver: SecretResolving {
    private let values: [EnvironmentSecretReference: SecretValue]
    private(set) var resolveCount = 0

    init(values: [EnvironmentSecretReference: SecretValue] = [:]) {
        self.values = values
    }

    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue {
        resolveCount += 1
        guard let value = values[reference] else {
            throw SecretStoreError.missing(reference)
        }
        return value
    }
}

private actor PreparationGate {
    private var isOpen = false
    private var entered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntries = entryContinuations
        entryContinuations.removeAll()
        pendingEntries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation {
            continuations.append($0)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation {
            entryContinuations.append($0)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        // Expected.
    }
}
