import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsRuntimeTests: XCTestCase {
    func testBootstrapPublishesDefaultsAndReturnsVersionedAuthority() throws {
        let support = try temporaryDirectory()
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])

        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.bootstrap",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()

        guard case .ready(let runtime) = result else {
            return XCTFail(
                "Expected a ready versioned settings runtime: \(result)"
            )
        }
        XCTAssertEqual(runtime.initialState, .defaults)
        XCTAssertEqual(
            runtime.initialSnapshot.document.revision,
            SettingsRevision(rawValue: 1)
        )

        let settingsDirectory = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("Settings", isDirectory: true)
        let inspection = SettingsRepository(
            primaryFileAccess: SettingsPrimaryFileAccess(
                settingsDirectoryURL: settingsDirectory
            )
        ).inspect()
        guard case .current(let snapshot) = inspection else {
            return XCTFail("Expected the published primary to be current.")
        }
        XCTAssertEqual(
            try SettingsState(document: snapshot.document),
            .defaults
        )
    }

    func testPresentCorruptPrimaryNeverFallsBackToValidLegacy() throws {
        let support = try temporaryDirectory()
        let container = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        let settingsDirectory = container.appendingPathComponent(
            "Settings",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(container.path, 0o700), 0)
        XCTAssertEqual(chmod(settingsDirectory.path, 0o700), 0)
        let primary = settingsDirectory.appendingPathComponent("settings.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: primary)
        XCTAssertEqual(chmod(primary.path, 0o600), 0)
        let legacy = SettingsLegacySnapshotClassifier.classify([
            SettingsLegacyKey.appearance.rawValue: "dark",
        ])

        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.corrupt",
            legacyCaptureOverride: { legacy }
        ).bootstrap()

        guard case .recoveryRequired(let recovery) = result else {
            return XCTFail("Expected fail-closed recovery.")
        }
        XCTAssertEqual(
            recovery.preservedPrimaryBytes,
            corrupt,
            "Recovery was \(recovery)"
        )
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settingsDirectory
                    .appendingPathComponent(".settings.lock").path
            ),
            "Bootstrap establishes the secure mutation authority without replacing the corrupt primary."
        )
    }

    func testPresentFuturePrimaryNeverFallsBackToValidLegacy() throws {
        let support = try temporaryDirectory()
        let container = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        let settingsDirectory = container.appendingPathComponent(
            "Settings",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(container.path, 0o700), 0)
        XCTAssertEqual(chmod(settingsDirectory.path, 0o700), 0)
        let primary = settingsDirectory.appendingPathComponent("settings.json")
        let future = Data("{\"schemaVersion\":999}".utf8)
        try future.write(to: primary)
        XCTAssertEqual(chmod(primary.path, 0o600), 0)
        let legacy = SettingsLegacySnapshotClassifier.classify([
            SettingsLegacyKey.appearance.rawValue: "dark",
        ])

        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.future",
            legacyCaptureOverride: { legacy }
        ).bootstrap()

        guard case .recoveryRequired(let recovery) = result else {
            return XCTFail("Expected fail-closed recovery.")
        }
        XCTAssertEqual(recovery.preservedPrimaryBytes, future)
        XCTAssertEqual(try Data(contentsOf: primary), future)
    }

    func testPrimaryAppearingAtCommitBoundaryExportsLockedExactBytes() throws {
        let support = try temporaryDirectory()
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let appearedState = SettingsState(
            profileTemplates: ProfileTemplate.defaults,
            defaultBaseStoragePath: "/Appeared",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: true,
            appearance: .dark,
            profileVisualIdentities: [:]
        )
        let appearedDocument = appearedState.document(
            revision: SettingsRevision(rawValue: 7)
        )
        let appearedBytes = try SettingsDocumentCodec().encode(
            appearedDocument
        )
        let primary = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("settings.json")

        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.appeared",
            legacyCaptureOverride: { emptyLegacy },
            beforeMigrationCommit: {
                try! appearedBytes.write(to: primary)
                precondition(chmod(primary.path, 0o600) == 0)
            }
        ).bootstrap()

        guard case .recoveryRequired(let recovery) = result else {
            return XCTFail("Expected boundary-change recovery.")
        }
        XCTAssertEqual(recovery.preservedPrimaryBytes, appearedBytes)
        guard case .migration(let evidence) = recovery else {
            return XCTFail("Expected migration evidence.")
        }
        XCTAssertEqual(
            evidence.lockedPrimary?.preservedPrimaryBytes,
            appearedBytes
        )
    }

    func testExistingCurrentIsAdoptedUnderLockAndBoundaryChangeIsRejected()
        throws
    {
        let support = try temporaryDirectory()
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let first = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.adopt",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()
        guard case .ready(let original) = first else {
            return XCTFail("Expected initial publication.")
        }

        let unchanged = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.adopt",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()
        guard case .ready(let adopted) = unchanged else {
            return XCTFail("Expected locked current adoption.")
        }
        XCTAssertEqual(
            adopted.initialSnapshot.originalBytes,
            original.initialSnapshot.originalBytes
        )

        let changedState = SettingsState(
            profileTemplates: ProfileTemplate.defaults,
            defaultBaseStoragePath: "/Changed During Adoption",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true,
            appearance: .light,
            profileVisualIdentities: [:]
        )
        let changedDocument = changedState.document(
            revision: SettingsRevision(
                rawValue:
                    original.initialSnapshot.document.revision.rawValue + 1
            )
        )
        let changedBytes = try SettingsDocumentCodec().encode(
            changedDocument
        )
        let primary = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("settings.json")
        let changed = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.adopt",
            legacyCaptureOverride: { emptyLegacy },
            beforeMigrationCommit: {
                try! changedBytes.write(to: primary)
                precondition(chmod(primary.path, 0o600) == 0)
            }
        ).bootstrap()

        guard case .recoveryRequired(let recovery) = changed else {
            return XCTFail("Expected locked adoption change recovery.")
        }
        XCTAssertEqual(recovery.preservedPrimaryBytes, changedBytes)
    }

    @MainActor
    func testProductionConstructionNeverSelectsLegacyCompatibility() throws {
        let support = try temporaryDirectory()
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let bootstrap = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.production",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()

        let settings = AppSettings(production: bootstrap)

        XCTAssertEqual(
            settings.persistenceAuthority,
            .versionedRepository,
            "Bootstrap was \(bootstrap)"
        )
        XCTAssertNotEqual(settings.persistenceAuthority, .legacyCompatibility)
        XCTAssertTrue(settings.canModifySettings)
        XCTAssertNotNil(settings.migrationEvidence)
    }

    @MainActor
    func testFacadeMutationCommitsThroughVersionedRepository() async throws {
        let support = try temporaryDirectory()
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let bootstrap = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.facade",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()
        let settings = AppSettings(production: bootstrap)

        settings.appearance = .dark
        await settings.waitForPendingPersistence()

        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertTrue(settings.persistenceIssues.isEmpty)
        let settingsDirectory = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("Settings", isDirectory: true)
        let inspection = SettingsRepository(
            primaryFileAccess: SettingsPrimaryFileAccess(
                settingsDirectoryURL: settingsDirectory
            )
        ).inspect()
        guard case .current(let snapshot) = inspection else {
            return XCTFail("Expected a current committed primary.")
        }
        XCTAssertEqual(
            try SettingsState(document: snapshot.document).appearance,
            .dark
        )
    }

    @MainActor
    func testRecoveryFacadeRejectsWritesAndGatesLibraryEntryPoints() throws {
        let recovery = SettingsRuntimeBootstrapRecovery.container(
            .systemCall(operation: "test recovery", code: EIO)
        )
        let settings = AppSettings(
            production: .recoveryRequired(recovery)
        )
        let originalAppearance = settings.appearance

        settings.appearance = .dark

        XCTAssertEqual(settings.appearance, originalAppearance)
        XCTAssertFalse(settings.canModifySettings)
        let support = try temporaryDirectory()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            settings: settings
        )
        store.beginAddingApplication()
        XCTAssertFalse(store.isShowingAppImporter)
        XCTAssertFalse(store.prepareImport(data: Data()))
        XCTAssertFalse(store.canUseSettingsAuthority())
        XCTAssertTrue(
            store.errorMessage?.contains("Settings require recovery") == true
        )
    }

    func testTypedMutationReappliesAfterCASConflictWithoutLosingOtherField()
        async throws
    {
        let initial = try snapshot(state: .defaults, revision: 0)
        let repository = RaceSettingsRepository(initial: initial)
        let coordinator = SettingsMutationCoordinator(
            initialState: .defaults,
            initialSnapshot: initial,
            inspect: { repository.inspect() },
            commit: { content, expectation in
                repository.commit(content, expecting: expectation)
            },
            maximumCASRetries: 2
        )

        let result = await coordinator.apply(.setAppearance(.dark))

        guard case .committed(let state, _) = result else {
            return XCTFail("Expected the retry to commit.")
        }
        XCTAssertEqual(state.appearance, .dark)
        XCTAssertEqual(state.defaultBaseStoragePath, "/External Change")
        XCTAssertEqual(repository.commitCount, 2)
    }

    @MainActor
    func testPendingMutationBlocksLaunchActionsAndSettingsExports()
        async throws
    {
        let support = try temporaryDirectory()
        let base = try readyRuntime(in: support, identifier: "pending")
        let repository = BlockingSettingsRepository(
            initial: base.initialSnapshot
        )
        let coordinator = SettingsMutationCoordinator(
            initialState: base.initialState,
            initialSnapshot: base.initialSnapshot,
            inspect: { repository.inspect() },
            commit: { content, expectation in
                repository.commit(content, expecting: expectation)
            }
        )
        let settings = AppSettings(
            production: .ready(
                SettingsRuntime(
                    initialState: base.initialState,
                    initialSnapshot: base.initialSnapshot,
                    migrationEvidence: base.migrationEvidence,
                    coordinator: coordinator
                )
            )
        )
        let launcher = SettingsRuntimeRecordingLauncher()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            launcher: launcher,
            settings: settings
        )
        let profile = LaunchProfile(name: "Pending")
        let application = ManagedApplication(
            displayName: "Pending",
            appPath: "/Applications/Pending.app",
            profiles: [profile]
        )

        settings.defaultBaseStoragePath = "/Optimistic"

        XCTAssertTrue(settings.hasPendingVersionedMutations)
        XCTAssertFalse(settings.canProvideVerifiedSettings)
        store.beginAddingApplication()
        XCTAssertFalse(store.isShowingAppImporter)
        store.beginLaunch(
            profile,
            application: application,
            requireGlobalConfirmation: false
        )
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertThrowsError(
            try store.portableExportData(
                kind: .settingsAndTemplates,
                sensitivePolicy: .omit
            )
        )
        XCTAssertThrowsError(
            try store.portableExportData(
                kind: .portableConfiguration,
                sensitivePolicy: .omit
            )
        )
        XCTAssertNoThrow(
            try store.portableExportData(
                kind: .libraryMetadata,
                sensitivePolicy: .omit
            )
        )

        repository.releaseCommit()
        await settings.waitForPendingPersistence()

        XCTAssertFalse(settings.hasPendingVersionedMutations)
        XCTAssertTrue(settings.canProvideVerifiedSettings)
        XCTAssertEqual(settings.defaultBaseStoragePath, "/Optimistic")
    }

    @MainActor
    func testTerminalConflictRollsBackAndRetainsExactEvidence() async throws {
        let support = try temporaryDirectory()
        let base = try readyRuntime(in: support, identifier: "terminal")
        let repository = AlwaysConflictingSettingsRepository(
            initial: base.initialSnapshot,
            advancesOnConflict: false
        )
        let coordinator = SettingsMutationCoordinator(
            initialState: base.initialState,
            initialSnapshot: base.initialSnapshot,
            inspect: { repository.inspect() },
            commit: { content, expectation in
                repository.commit(content, expecting: expectation)
            },
            maximumCASRetries: 0
        )
        let settings = AppSettings(
            production: .ready(
                SettingsRuntime(
                    initialState: base.initialState,
                    initialSnapshot: base.initialSnapshot,
                    migrationEvidence: base.migrationEvidence,
                    coordinator: coordinator
                )
            )
        )

        settings.defaultBaseStoragePath = "/Unverified"
        XCTAssertEqual(settings.defaultBaseStoragePath, "/Unverified")
        await settings.waitForPendingPersistence()

        XCTAssertEqual(
            settings.defaultBaseStoragePath,
            base.initialState.defaultBaseStoragePath
        )
        XCTAssertEqual(settings.persistenceAuthority, .recoveryOnly)
        XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        let lastEvidence = try XCTUnwrap(repository.lastEvidence)
        XCTAssertTrue(
            settings.persistenceIssues.contains(
                .versionedMutationRecovery(
                    .retryLimitExceeded(
                        attempts: 1,
                        lastConflict: lastEvidence
                    )
                )
            )
        )
    }

    func testRepeatedConflictsRetainFinalEvidenceAtRetryExhaustion()
        async throws
    {
        let initial = try snapshot(state: .defaults, revision: 4)
        let repository = AlwaysConflictingSettingsRepository(
            initial: initial,
            advancesOnConflict: true
        )
        let coordinator = SettingsMutationCoordinator(
            initialState: .defaults,
            initialSnapshot: initial,
            inspect: { repository.inspect() },
            commit: { content, expectation in
                repository.commit(content, expecting: expectation)
            },
            maximumCASRetries: 2
        )

        let result = await coordinator.apply(.setAppearance(.dark))

        guard case .recoveryRequired(let failure, _) = result,
              case .retryLimitExceeded(let attempts, let lastConflict) =
                failure
        else {
            return XCTFail("Expected retry exhaustion.")
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(lastConflict, repository.lastEvidence)
        XCTAssertEqual(repository.commitCount, 3)
    }

    @MainActor
    func testPreparedLaunchLosesAuthorityWhilePreparationIsSuspended()
        async throws
    {
        let support = try temporaryDirectory()
        let base = try readyRuntime(in: support, identifier: "launch-boundary")
        let settingsRepository = BlockingSettingsRepository(
            initial: base.initialSnapshot
        )
        let coordinator = SettingsMutationCoordinator(
            initialState: base.initialState,
            initialSnapshot: base.initialSnapshot,
            inspect: { settingsRepository.inspect() },
            commit: { content, expectation in
                settingsRepository.commit(content, expecting: expectation)
            }
        )
        let settings = AppSettings(
            production: .ready(
                SettingsRuntime(
                    initialState: base.initialState,
                    initialSnapshot: base.initialSnapshot,
                    migrationEvidence: base.migrationEvidence,
                    coordinator: coordinator
                )
            )
        )
        let gate = SettingsRuntimeLaunchGate()
        let compiler = LaunchConfigurationCompiler(
            fileSystem: LocalFileSystem(),
            preparationHook: { await gate.wait() }
        )
        let launcher = SettingsRuntimePreparedLauncher()
        let fixture = try ValidApplicationBundleFixture.create(
            in: support,
            name: "PendingLaunch.app",
            bundleIdentifier: "com.example.pending-launch"
        )
        let profile = LaunchProfile(name: "Pending Launch")
        let application = ManagedApplication(
            displayName: "Pending Launch",
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.url.path,
            baseStoragePath: support.path,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            launcher: launcher,
            launchConfigurationCompiler: compiler,
            settings: settings
        )
        store.applications = [application]

        store.beginLaunch(
            profile,
            application: application,
            requireGlobalConfirmation: false
        )
        await gate.waitUntilEntered()

        settings.appearance = .dark
        XCTAssertTrue(settings.hasPendingVersionedMutations)
        await gate.open()
        for _ in 0..<200 where !store.launchPreparationTasks.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertTrue(
            store.errorMessage?.contains("settings change") == true
        )

        settingsRepository.releaseCommit()
        await settings.waitForPendingPersistence()
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "parallax-settings-runtime-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func readyRuntime(
        in support: URL,
        identifier: String
    ) throws -> SettingsRuntime {
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.\(identifier)",
            legacyCaptureOverride: { emptyLegacy }
        ).bootstrap()
        guard case .ready(let runtime) = result else {
            throw SettingsRuntimeTestError.bootstrapFailed
        }
        return runtime
    }

    private func snapshot(
        state: SettingsState,
        revision: UInt64
    ) throws -> SettingsRepositorySnapshot {
        let document = state.document(
            revision: SettingsRevision(rawValue: revision)
        )
        let bytes = try SettingsDocumentCodec().encode(document)
        return SettingsRepositorySnapshot(
            document: document,
            versionToken: SettingsVersionToken(
                revision: document.revision,
                sourceSHA256: SettingsSourceSHA256(bytes)
            ),
            originalBytes: bytes
        )
    }
}

private final class RaceSettingsRepository: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SettingsRepositorySnapshot
    private var shouldInjectConflict = true
    private var commits = 0

    init(initial: SettingsRepositorySnapshot) {
        current = initial
    }

    var commitCount: Int {
        lock.withLock { commits }
    }

    func inspect() -> SettingsRepositoryInspection {
        lock.withLock { .current(current) }
    }

    func commit(
        _ content: SettingsContent,
        expecting expectation: SettingsCommitExpectation
    ) -> SettingsRepositoryCommitResult {
        lock.withLock {
            commits += 1
            if shouldInjectConflict {
                shouldInjectConflict = false
                var external = try! SettingsState(document: current.document)
                external = SettingsState(
                    profileTemplates: external.profileTemplates,
                    defaultBaseStoragePath: "/External Change",
                    confirmBeforeLaunch: external.confirmBeforeLaunch,
                    automaticallyRecoverCrashedApps:
                        external.automaticallyRecoverCrashedApps,
                    appearance: external.appearance,
                    profileVisualIdentities:
                        external.profileVisualIdentities
                )
                current = makeSnapshot(
                    state: external,
                    revision: current.document.revision.rawValue + 1
                )
                return .rejected(
                    SettingsRepositoryMutationEvidence(
                        classification: .neither,
                        failure: .expectationMismatch,
                        priorToken: expectation.token,
                        targetToken: nil,
                        residual: nil
                    )
                )
            }

            guard expectation == .version(current.versionToken) else {
                return .rejected(
                    SettingsRepositoryMutationEvidence(
                        classification: .neither,
                        failure: .expectationMismatch,
                        priorToken: expectation.token,
                        targetToken: nil,
                        residual: nil
                    )
                )
            }
            let document = content.document(
                revision: SettingsRevision(
                    rawValue: current.document.revision.rawValue + 1
                )
            )
            let bytes = try! SettingsDocumentCodec().encode(document)
            current = SettingsRepositorySnapshot(
                document: document,
                versionToken: SettingsVersionToken(
                    revision: document.revision,
                    sourceSHA256: SettingsSourceSHA256(bytes)
                ),
                originalBytes: bytes
            )
            return .committed(current, residual: nil)
        }
    }

    private func makeSnapshot(
        state: SettingsState,
        revision: UInt64
    ) -> SettingsRepositorySnapshot {
        let document = state.document(
            revision: SettingsRevision(rawValue: revision)
        )
        let bytes = try! SettingsDocumentCodec().encode(document)
        return SettingsRepositorySnapshot(
            document: document,
            versionToken: SettingsVersionToken(
                revision: document.revision,
                sourceSHA256: SettingsSourceSHA256(bytes)
            ),
            originalBytes: bytes
        )
    }
}

private extension SettingsCommitExpectation {
    var token: SettingsVersionToken? {
        guard case .version(let token) = self else { return nil }
        return token
    }
}

private enum SettingsRuntimeTestError: Error {
    case bootstrapFailed
}

private final class SettingsRuntimeRecordingLauncher:
    ApplicationLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var launchCount: Int {
        lock.withLock { count }
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock { count += 1 }
        completion(.success(()))
    }
}

private final class SettingsRuntimePreparedLauncher:
    PreparedApplicationLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var preparedLaunchCount: Int {
        lock.withLock { count }
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        completion(.success(()))
    }

    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock { count += 1 }
        completion(.success(()))
    }
}

private actor SettingsRuntimeLaunchGate {
    private var entered = false
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pending = entryWaiters
        entryWaiters.removeAll()
        pending.forEach { $0.resume() }
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class BlockingSettingsRepository: @unchecked Sendable {
    private let lock = NSLock()
    private let commitGate = DispatchSemaphore(value: 0)
    private var current: SettingsRepositorySnapshot

    init(initial: SettingsRepositorySnapshot) {
        current = initial
    }

    func inspect() -> SettingsRepositoryInspection {
        lock.withLock { .current(current) }
    }

    func releaseCommit() {
        commitGate.signal()
    }

    func commit(
        _ content: SettingsContent,
        expecting expectation: SettingsCommitExpectation
    ) -> SettingsRepositoryCommitResult {
        commitGate.wait()
        return lock.withLock {
            guard expectation == .version(current.versionToken) else {
                return .rejected(conflictEvidence(expectation: expectation))
            }
            let document = content.document(
                revision: SettingsRevision(
                    rawValue: current.document.revision.rawValue + 1
                )
            )
            let bytes = try! SettingsDocumentCodec().encode(document)
            current = SettingsRepositorySnapshot(
                document: document,
                versionToken: SettingsVersionToken(
                    revision: document.revision,
                    sourceSHA256: SettingsSourceSHA256(bytes)
                ),
                originalBytes: bytes
            )
            return .committed(current, residual: nil)
        }
    }

    private func conflictEvidence(
        expectation: SettingsCommitExpectation
    ) -> SettingsRepositoryMutationEvidence {
        SettingsRepositoryMutationEvidence(
            classification: .neither,
            failure: .expectationMismatch,
            priorToken: expectation.token,
            targetToken: nil,
            residual: nil
        )
    }
}

private final class AlwaysConflictingSettingsRepository:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let advancesOnConflict: Bool
    private var current: SettingsRepositorySnapshot
    private var commits = 0
    private var evidence: SettingsRepositoryMutationEvidence?

    init(
        initial: SettingsRepositorySnapshot,
        advancesOnConflict: Bool
    ) {
        current = initial
        self.advancesOnConflict = advancesOnConflict
    }

    var commitCount: Int {
        lock.withLock { commits }
    }

    var lastEvidence: SettingsRepositoryMutationEvidence? {
        lock.withLock { evidence }
    }

    func inspect() -> SettingsRepositoryInspection {
        lock.withLock { .current(current) }
    }

    func commit(
        _ content: SettingsContent,
        expecting expectation: SettingsCommitExpectation
    ) -> SettingsRepositoryCommitResult {
        lock.withLock {
            commits += 1
            if advancesOnConflict {
                let state = try! SettingsState(document: current.document)
                current = makeSnapshot(
                    state: state,
                    revision: current.document.revision.rawValue + 1
                )
            }
            let conflict = SettingsRepositoryMutationEvidence(
                classification: .neither,
                failure: .expectationMismatch,
                priorToken: current.versionToken,
                targetToken: nil,
                residual: nil
            )
            evidence = conflict
            return .rejected(conflict)
        }
    }

    private func makeSnapshot(
        state: SettingsState,
        revision: UInt64
    ) -> SettingsRepositorySnapshot {
        let document = state.document(
            revision: SettingsRevision(rawValue: revision)
        )
        let bytes = try! SettingsDocumentCodec().encode(document)
        return SettingsRepositorySnapshot(
            document: document,
            versionToken: SettingsVersionToken(
                revision: document.revision,
                sourceSHA256: SettingsSourceSHA256(bytes)
            ),
            originalBytes: bytes
        )
    }
}
