import AppKit
import Foundation
import XCTest
@testable import Parallax

final class LaunchPreparationIntegrationTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var applicationFixture: ValidApplicationBundleFixture?
    private var defaults: UserDefaults?
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-LaunchIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        applicationFixture = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory
        )
        let suiteName = "parallax.launch-integration.\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults?.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let defaults, let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testMalformedConfigurationRequiresFingerprintBoundConfirmation()
        async throws
    {
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(
            name: "Broken",
            argumentsText: "--label 'unterminated"
        )
        let store = try makeStore(launcher: launcher, profile: profile)

        store.launch(profile)
        await waitUntil {
            store.isShowingLaunchDiagnosticOverride
        }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertEqual(launcher.legacyLaunchCount, 0)
        XCTAssertTrue(
            store.pendingLaunchDiagnosticMessage?
                .contains("unmatched single quote") == true
        )

        store.applications[0].profiles[0].argumentsText =
            "--label=replaced-after-analysis"
        store.confirmLaunchDiagnosticOverride()
        await waitUntil {
            launcher.preparedLaunchCount == 1
        }

        XCTAssertEqual(
            launcher.lastPreparedLaunch?.arguments,
            ["--label", "unterminated"]
        )
        XCTAssertFalse(store.isShowingLaunchDiagnosticOverride)
    }

    @MainActor
    func testDuplicateSingletonCannotBeOverriddenOrOpened()
        async throws
    {
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(
            name: "Ambiguous",
            argumentsText:
                "--user-data-dir=/tmp/one --user-data-dir /tmp/two"
        )
        let store = try makeStore(launcher: launcher, profile: profile)

        store.launch(profile)
        await waitUntil {
            store.launchStatusMessage(
                for: store.applications[0],
                profile: store.applications[0].profiles[0]
            )?.contains("only once") == true
        }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertFalse(store.isShowingLaunchDiagnosticOverride)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(
            store.launchStatusMessage(
                for: store.applications[0],
                profile: store.applications[0].profiles[0]
            )?.contains("only once") == true
        )
    }

    @MainActor
    func testCancellingDiagnosticOverrideTerminatesOnlyThatLaunchRequest()
        async throws
    {
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(
            name: "Broken",
            argumentsText: "--label 'unterminated"
        )
        let store = try makeStore(launcher: launcher, profile: profile)
        store.errorMessage = "Existing library error"

        store.launch(profile)
        await waitUntil {
            store.isShowingLaunchDiagnosticOverride
        }
        store.cancelLaunchDiagnosticOverride()

        XCTAssertEqual(
            store.launchStatusMessage(
                for: store.applications[0],
                profile: store.applications[0].profiles[0]
            ),
            "Open cancelled"
        )
        XCTAssertEqual(store.errorMessage, "Existing library error")
        XCTAssertEqual(launcher.preparedLaunchCount, 0)
    }

    @MainActor
    func testPreparedSnapshotIsImmutableAndUsesSafeEnvironment()
        async throws
    {
        let gate = LaunchPreparationIntegrationGate()
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(
            name: "Snapshot",
            argumentsText: "--label=before",
            environmentText: "LABEL=before"
        )
        let compiler = makeCompiler {
            await gate.wait()
        }
        let store = try makeStore(
            launcher: launcher,
            profile: profile,
            compiler: compiler
        )

        store.launch(profile)
        await gate.waitUntilEntered()
        store.applications[0].profiles[0].argumentsText = "--label=after"
        store.applications[0].profiles[0].environmentText = "LABEL=after"
        await gate.open()
        await waitUntil {
            launcher.preparedLaunchCount == 1
        }

        let prepared = try XCTUnwrap(launcher.lastPreparedLaunch)
        XCTAssertEqual(prepared.arguments, ["--label=before"])
        XCTAssertEqual(prepared.environment["LABEL"], "before")
        XCTAssertNil(prepared.environment["OPENAI_API_KEY"])
        XCTAssertNil(prepared.environment["CODEX_HOME"])
        XCTAssertEqual(launcher.legacyLaunchCount, 0)
    }

    func testWorkspaceUntrackedPreparedLaunchCannotBypassProcessBinding()
        throws
    {
        let opener = CapturingWorkspaceOpener()
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: NoopTerminationObserver(),
            processProvenanceInspector: TestWorkspaceProcessState(),
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let applicationURL = temporaryDirectory
            .appendingPathComponent("Prepared.app", isDirectory: true)
        let prepared = PreparedLaunch(
            requestID: UUID(),
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID(),
            applicationIdentity: WorkspaceApplicationBundleIdentity(
                bundleURL: applicationURL,
                bundleIdentifier: "com.parallax.prepared-test"
            ),
            arguments: ["--literal=~", "--user-data-dir=/validated/path"],
            environment: ["PATH": "/safe/path", "LABEL": "~/literal"],
            isolation: PreparedLaunchIsolation(
                userDataURL: URL(fileURLWithPath: "/validated/path"),
                codexHomeURL: nil,
                managesUserData: false,
                managesCodexHome: false
            ),
            configurationFingerprint:
                LaunchConfigurationFingerprint(digest: "prepared")
        )

        XCTAssertThrowsError(
            try launcher.launch(prepared: prepared) { _ in }
        ) { error in
            guard case LaunchError.trackedLaunchRequired = error else {
                return XCTFail("Expected tracked-launch-only enforcement.")
            }
        }
        XCTAssertNil(opener.lastURL)
        XCTAssertNil(opener.lastArguments)
        XCTAssertNil(opener.lastEnvironment)
    }

    @MainActor
    func testSensitiveLiteralExportRequiresConfirmationButReferenceDoesNot()
        throws
    {
        let launcher = RecordingPreparedLauncher()
        let literal = LaunchProfile(
            name: "Literal",
            environmentText: "OPENAI_API_KEY=plaintext"
        )
        let literalStore = try makeStore(
            launcher: launcher,
            profile: literal
        )
        XCTAssertTrue(
            literalStore.libraryExportContainsSensitiveLiterals()
        )
        let omitted = try XCTUnwrap(
            literalStore.libraryDocumentForExport(
                sensitivePolicy: .omit
            ).applications.first?.profiles.first
        )
        XCTAssertFalse(
            omitted.environmentText.contains("plaintext")
        )
        XCTAssertTrue(
            omitted.environmentText.contains(
                "# Omitted sensitive value: OPENAI_API_KEY"
            )
        )
        let redacted = try XCTUnwrap(
            literalStore.libraryDocumentForExport(
                sensitivePolicy: .redact
            ).applications.first?.profiles.first
        )
        XCTAssertEqual(
            redacted.environmentText,
            "OPENAI_API_KEY=<redacted>"
        )
        let included = try XCTUnwrap(
            literalStore.libraryDocumentForExport(
                sensitivePolicy: .include
            ).applications.first?.profiles.first
        )
        XCTAssertEqual(
            included.environmentText,
            "OPENAI_API_KEY=plaintext"
        )

        let reference = EnvironmentSecretReference()
        let referenced = LaunchProfile(
            name: "Referenced",
            environmentText: "OPENAI_API_KEY=\(reference.token)"
        )
        let referenceStore = try makeStore(
            launcher: launcher,
            profile: referenced
        )
        XCTAssertFalse(
            referenceStore.libraryExportContainsSensitiveLiterals()
        )

        let shadowedByReference = LaunchProfile(
            name: "Shadowed by reference",
            environmentText:
                "OPENAI_API_KEY=shadowed-plaintext\nOPENAI_API_KEY=\(reference.token)"
        )
        let shadowedReferenceStore = try makeStore(
            launcher: launcher,
            profile: shadowedByReference
        )
        XCTAssertTrue(
            shadowedReferenceStore.libraryExportContainsSensitiveLiterals()
        )
        let shadowedReferenceExport = try XCTUnwrap(
            shadowedReferenceStore.libraryDocumentForExport(
                sensitivePolicy: .omit
            ).applications.first?.profiles.first
        )
        XCTAssertFalse(
            shadowedReferenceExport.environmentText.contains(
                "shadowed-plaintext"
            )
        )

        let shadowedByUnset = LaunchProfile(
            name: "Shadowed by unset",
            environmentText:
                "OPENAI_API_KEY=unset-plaintext\nunset OPENAI_API_KEY"
        )
        let shadowedUnsetStore = try makeStore(
            launcher: launcher,
            profile: shadowedByUnset
        )
        XCTAssertTrue(
            shadowedUnsetStore.libraryExportContainsSensitiveLiterals()
        )
        let shadowedUnsetExport = try XCTUnwrap(
            shadowedUnsetStore.libraryDocumentForExport(
                sensitivePolicy: .redact
            ).applications.first?.profiles.first
        )
        XCTAssertFalse(
            shadowedUnsetExport.environmentText.contains(
                "unset-plaintext"
            )
        )
    }

    @MainActor
    func testKeychainSecretWorkflowStoresOnlyReferenceAndCanRemoveIt()
        async throws
    {
        let secretStore = RecordingIntegrationSecretStore()
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(name: "Keychain")
        let store = try makeStore(
            launcher: launcher,
            profile: profile,
            secretStore: secretStore
        )

        let stored = await store.storeKeychainSecret(
            "actual-secret",
            environmentKey: "OPENAI_API_KEY",
            for: profile
        )
        XCTAssertTrue(stored)
        let updated = try XCTUnwrap(store.selectedProfile)
        let storedText = try XCTUnwrap(
            LaunchEnvironmentParser.parse(
                updated.environmentText
            ).effectiveValues["OPENAI_API_KEY"]
        )
        XCTAssertNotNil(EnvironmentSecretReference(token: storedText))
        XCTAssertFalse(updated.environmentText.contains("actual-secret"))
        let storedSnapshot = await secretStore.snapshot()
        XCTAssertEqual(storedSnapshot.value, "actual-secret")

        let removed = await store.removeKeychainSecret(
            environmentKey: "OPENAI_API_KEY",
            for: updated
        )
        XCTAssertTrue(removed)
        XCTAssertEqual(
            store.selectedProfile?.environment["OPENAI_API_KEY"],
            ""
        )
        let removedSnapshot = await secretStore.snapshot()
        XCTAssertEqual(removedSnapshot.removeCount, 1)
    }

    @MainActor
    func testProfileEditorDraftActionsDoNotPersistBeforeApply()
        async throws
    {
        let secretStore = RecordingIntegrationSecretStore()
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(name: "Draft")
        let fixture = try XCTUnwrap(applicationFixture)
        let seedApplication = ManagedApplication(
            displayName: "Fixture",
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.url.path,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let support = temporaryDirectory.appendingPathComponent(
            "Draft-Edit-Support",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        _ = try repository.save(
            [seedApplication],
            expectedVersion: .missing
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            launcher: launcher,
            launchConfigurationCompiler: makeCompiler(),
            secretStore: secretStore,
            settings: AppSettings(
                userDefaults: try XCTUnwrap(defaults)
            )
        )
        store.selectedApplicationID = seedApplication.id
        store.selectedProfileID = profile.id
        var application = try XCTUnwrap(store.selectedApplication)
        application.preset = .chrome

        let recommended = try XCTUnwrap(
            store.profileDraftApplyingRecommendedSettings(
                profile,
                for: application
            )
        )
        XCTAssertNotEqual(recommended, profile)
        XCTAssertEqual(store.selectedProfile, profile)

        let codexHome = temporaryDirectory.appendingPathComponent(
            "External Codex Home",
            isDirectory: true
        )
        let imported = store.profileDraftUsingCodexHome(
            codexHome,
            profile: recommended
        )
        XCTAssertEqual(
            imported.environment["CODEX_HOME"],
            codexHome.path
        )
        XCTAssertEqual(store.selectedProfile, profile)

        let stagedResult = await store.stageKeychainSecret(
            "draft-only-secret",
            environmentKey: "OPENAI_API_KEY",
            in: imported
        )
        let staged = try XCTUnwrap(stagedResult)
        XCTAssertNotEqual(staged.profile, imported)
        XCTAssertEqual(store.selectedProfile, profile)
        let storedSnapshot = await secretStore.snapshot()
        XCTAssertEqual(storedSnapshot.value, "draft-only-secret")
        XCTAssertEqual(storedSnapshot.removeCount, 0)

        let discarded = await store.discardKeychainSecret(
            staged.reference
        )
        XCTAssertTrue(discarded)
        let revertedSnapshot = await secretStore.snapshot()
        XCTAssertEqual(revertedSnapshot.removeCount, 1)
        XCTAssertEqual(store.selectedProfile, profile)
    }

    @MainActor
    func testKeychainRemovalDraftDefersDeletionUntilSuccessfulApply()
        async throws
    {
        let secretStore = RecordingIntegrationSecretStore()
        let launcher = RecordingPreparedLauncher()
        let profile = LaunchProfile(name: "Draft")
        let fixture = try XCTUnwrap(applicationFixture)
        let application = ManagedApplication(
            displayName: "Fixture",
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.url.path,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let support = temporaryDirectory.appendingPathComponent(
            "Keychain-Edit-Support",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        _ = try repository.save(
            [application],
            expectedVersion: .missing
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            launcher: launcher,
            launchConfigurationCompiler: makeCompiler(),
            secretStore: secretStore,
            settings: AppSettings(
                userDefaults: try XCTUnwrap(defaults)
            )
        )
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        let stagedResult = await store.stageKeychainSecret(
            "persist-after-apply",
            environmentKey: "OPENAI_API_KEY",
            in: profile
        )
        let staged = try XCTUnwrap(stagedResult)
        let initialVersion = try XCTUnwrap(
            store.currentLibraryVersion
        )
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: staged.profile,
                baseline: profile,
                applicationID: try XCTUnwrap(
                    store.selectedApplication?.id
                ),
                baselineVersion: initialVersion
            )
        )
        let persisted = try XCTUnwrap(store.selectedProfile)
        let removal = try XCTUnwrap(
            store.profileDraftRemovingKeychainSecret(
                environmentKey: "OPENAI_API_KEY",
                from: persisted
            )
        )
        let beforeApplyDeletion = await secretStore.snapshot()
        XCTAssertEqual(beforeApplyDeletion.removeCount, 0)
        XCTAssertNotEqual(removal.profile, persisted)
        XCTAssertEqual(store.selectedProfile, persisted)

        XCTAssertTrue(
            store.applyProfileEdit(
                draft: removal.profile,
                baseline: persisted,
                applicationID: try XCTUnwrap(
                    store.selectedApplication?.id
                ),
                baselineVersion: try XCTUnwrap(
                    store.currentLibraryVersion
                )
            )
        )
        let afterApplyDeletion = await secretStore.snapshot()
        XCTAssertEqual(afterApplyDeletion.removeCount, 0)
        let discarded = await store.discardKeychainSecret(
            removal.reference
        )
        XCTAssertTrue(discarded)
        let afterDiscard = await secretStore.snapshot()
        XCTAssertEqual(afterDiscard.removeCount, 1)
    }

    @MainActor
    private func makeStore(
        launcher: RecordingPreparedLauncher,
        profile: LaunchProfile,
        compiler: LaunchConfigurationCompiler? = nil,
        secretStore: (any SecretStoring)? = nil
    ) throws -> LibraryStore {
        let fixture = try XCTUnwrap(applicationFixture)
        let application = ManagedApplication(
            displayName: "Fixture",
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.url.path,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let settings = AppSettings(
            userDefaults: try XCTUnwrap(defaults)
        )
        settings.confirmBeforeLaunch = false
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: launcher,
            launchConfigurationCompiler: compiler ?? makeCompiler(),
            secretStore: secretStore,
            settings: settings
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        return store
    }

    private func makeCompiler(
        preparationHook:
            @escaping @Sendable () async throws -> Void = {}
    ) -> LaunchConfigurationCompiler {
        LaunchConfigurationCompiler(
            fileSystem: LocalFileSystem(),
            identity: ChildEnvironmentIdentity(
                homeDirectory: "/Users/fixture",
                userName: "fixture",
                temporaryDirectory: "/private/tmp/fixture"
            ),
            processEnvironment: [
                "OPENAI_API_KEY": "must-not-leak",
                "CODEX_HOME": "/hidden/codex",
                "LANG": "en_US.UTF-8",
            ],
            secretResolver: EmptySecretResolver(),
            preparationHook: preparationHook
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class RecordingPreparedLauncher:
    PreparedApplicationLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var preparedLaunches: [PreparedLaunch] = []
    private var legacyLaunches = 0

    var preparedLaunchCount: Int {
        lock.withLock { preparedLaunches.count }
    }

    var legacyLaunchCount: Int {
        lock.withLock { legacyLaunches }
    }

    var lastPreparedLaunch: PreparedLaunch? {
        lock.withLock { preparedLaunches.last }
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock {
            legacyLaunches += 1
        }
        completion(.success(()))
    }

    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock {
            preparedLaunches.append(prepared)
        }
        completion(.success(()))
    }
}

private actor LaunchPreparationIntegrationGate {
    private var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation {
            entryWaiters.append($0)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor EmptySecretResolver: SecretResolving {
    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue {
        throw SecretStoreError.missing(reference)
    }
}

private actor RecordingIntegrationSecretStore: SecretStoring {
    private(set) var lastStoredValue: String?
    private(set) var removeCount = 0
    private var values:
        [EnvironmentSecretReference: SecretValue] = [:]

    func store(
        _ value: SecretValue,
        for reference: EnvironmentSecretReference
    ) async throws {
        lastStoredValue = value.withValue { $0 }
        values[reference] = value
    }

    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue {
        guard let value = values[reference] else {
            throw SecretStoreError.missing(reference)
        }
        return value
    }

    func remove(
        _ reference: EnvironmentSecretReference
    ) async throws {
        removeCount += 1
        values.removeValue(forKey: reference)
    }

    func snapshot() -> (value: String?, removeCount: Int) {
        (lastStoredValue, removeCount)
    }
}

private final class CapturingWorkspaceOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var capturedURL: URL?
    private var capturedArguments: [String]?
    private var capturedEnvironment: [String: String]?

    var lastURL: URL? {
        lock.withLock { capturedURL }
    }

    var lastArguments: [String]? {
        lock.withLock { capturedArguments }
    }

    var lastEnvironment: [String: String]? {
        lock.withLock { capturedEnvironment }
    }

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        lock.withLock {
            capturedURL = url
            capturedArguments = configuration.arguments
            capturedEnvironment = configuration.environment
        }
    }
}

private struct NoopTerminationObserver:
    RunningApplicationTerminationObserving,
    Sendable
{
    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        NoopTerminationObservation()
    }
}

private final class NoopTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    func cancel() {}
}
