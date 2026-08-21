import Foundation
import SwiftUI
import XCTest
@testable import Parallax

final class Wave8RegressionGapTests: XCTestCase {
    private var temporaryDirectory =
        FileManager.default.temporaryDirectory
    private var defaultsSuiteName = ""

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Wave8-Gaps-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defaultsSuiteName =
            "parallax.wave8-gaps.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(
            forName: defaultsSuiteName
        )
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testRemoveOnlyThenReduplicatePreservesKeptManagedData()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "Support",
            isDirectory: true
        )
        let managedRoot = temporaryDirectory.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let recoveryRoot = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        let backupStore = LibraryBackupStore(
            recoveryRoot: recoveryRoot
        )
        let repository = LibraryRepository(
            applicationSupportURL: support,
            backupHook: { bytes, reason in
                _ = try backupStore.createBackup(
                    of: bytes,
                    reason: reason
                )
            }
        )
        let sourceProfile = LaunchProfile(
            name: "Work",
            argumentsText: "--flag --flag"
        )
        let application = ManagedApplication(
            displayName: "Fixture Browser",
            appPath: "/Applications/Fixture Browser.app",
            preset: .custom,
            baseStoragePath: managedRoot.path,
            profiles: [sourceProfile]
        )
        _ = try repository.save(
            [application],
            expectedVersion: .missing
        )
        let transactionCoordinator =
            try ProfileDataTransactionCoordinator(
                applicationSupportURL: support
            )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            backupStore: backupStore,
            profileDataTransactions: transactionCoordinator,
            profileActivityRegistry: ProfileActivityRegistry(),
            launcher: Wave8NoopLauncher(),
            settings: try makeSettings()
        )
        let sourceRoot = try store.managedPaths(
            for: application,
            profile: sourceProfile
        ).profileRoot.url
        try writeSentinel("original managed data", at: sourceRoot)

        XCTAssertTrue(store.duplicateSelectedProfile())
        let firstCopy = try XCTUnwrap(store.selectedProfile)
        XCTAssertNotEqual(firstCopy.id, sourceProfile.id)
        let keptRoot = try store.managedPaths(
            for: application,
            profile: firstCopy
        ).profileRoot.url
        XCTAssertEqual(
            try readSentinel(at: keptRoot),
            "original managed data"
        )

        XCTAssertTrue(
            store.removeSelectedProfile(dataRemoval: .keep)
        )
        XCTAssertFalse(
            store.applications[0].profiles.contains {
                $0.storageID == firstCopy.storageID
            }
        )
        XCTAssertEqual(
            try readSentinel(at: keptRoot),
            "original managed data"
        )

        XCTAssertEqual(store.selectedProfileID, sourceProfile.id)
        XCTAssertTrue(store.duplicateSelectedProfile())
        let secondCopy = try XCTUnwrap(store.selectedProfile)
        let secondCopyRoot = try store.managedPaths(
            for: application,
            profile: secondCopy
        ).profileRoot.url

        XCTAssertEqual(firstCopy.name, secondCopy.name)
        XCTAssertNotEqual(firstCopy.storageID, secondCopy.storageID)
        XCTAssertNotEqual(
            keptRoot.standardizedFileURL,
            secondCopyRoot.standardizedFileURL
        )
        XCTAssertEqual(
            try readSentinel(at: keptRoot),
            "original managed data",
            "Allocating the second same-name copy must not replace or remove the orphaned folder kept by metadata-only removal."
        )
        XCTAssertEqual(
            try readSentinel(at: secondCopyRoot),
            "original managed data"
        )
    }

    @MainActor
    func testImporterFailureRemainsOnOriginatingWindowAfterFocusChanges()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "ImporterSupport",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let originSceneID = UUID()
        let focusedSceneID = UUID()
        let origin = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            profileActivityRegistry: ProfileActivityRegistry(),
            launcher: Wave8NoopLauncher(),
            settings: try makeSettings(),
            sceneID: originSceneID
        )
        let focused = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            profileActivityRegistry: ProfileActivityRegistry(),
            launcher: Wave8NoopLauncher(),
            settings: try makeSettings(),
            sceneID: focusedSceneID
        )
        let router = FocusedSceneRouter()
        router.register(originSceneID)
        router.register(focusedSceneID)
        router.setFocusedScene(originSceneID)

        let importerCompletion:
            (Result<[URL], Error>) -> Void =
        { result in
            guard case let .failure(error) = result else {
                return
            }
            origin.errorMessage =
                FileImporterFailure.userFacingMessage(for: error)
        }

        router.setFocusedScene(focusedSceneID)
        let providerFailure = NSError(
            domain: "FileProvider",
            code: 73,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The originating import provider failed.",
            ]
        )
        importerCompletion(.failure(providerFailure))

        XCTAssertEqual(
            router.targetSceneID(
                for: SceneRoutingRequest(
                    originatingSceneID: originSceneID
                )
            ),
            originSceneID
        )
        XCTAssertEqual(
            origin.errorMessage,
            "The originating import provider failed."
        )
        XCTAssertNil(focused.errorMessage)

        let contentSource = try productionSource(
            "Sources/Parallax/Views/ContentView.swift"
        )
        let importerBlock = try sourceSlice(
            contentSource,
            from: ".fileImporter(",
            through: ".alert(\n                \"Start Over"
        )
        XCTAssertTrue(
            importerBlock.contains(
                "FileImporterFailure.userFacingMessage("
            )
        )
        XCTAssertTrue(
            importerBlock.contains("store.errorMessage = message"),
            "The scene-owned ContentView importer callback must report through its captured scene-owned store."
        )
    }

    func testRepeatedIdenticalLaunchArgumentsUseStableOffsetIdentity()
        throws
    {
        let arguments = ["--flag", "--flag", "--flag"]
        let renderedIdentities =
            Array(arguments.enumerated()).map(\.offset)

        XCTAssertEqual(renderedIdentities, [0, 1, 2])
        XCTAssertEqual(
            Set(renderedIdentities).count,
            arguments.count
        )

        let reviewSource = try productionSource(
            "Sources/Parallax/Views/ImportReviewViews.swift"
        )
        let argumentsSection = try sourceSlice(
            reviewSource,
            from: "private func argumentsSection(",
            through: "private func environmentSection("
        )
        XCTAssertTrue(
            argumentsSection.contains(
                "Array(review.arguments.enumerated())"
            )
        )
        XCTAssertTrue(
            argumentsSection.contains("id: \\.offset"),
            "Identical argument values must be keyed by their stable render position, not by value."
        )
        XCTAssertFalse(
            argumentsSection.contains("id: \\.self")
        )
    }

    @MainActor
    func testAppearanceMappingIsAppliedToMainAndSettingsScenes()
        throws
    {
        XCTAssertNil(appColorScheme(for: .system))
        XCTAssertEqual(appColorScheme(for: .light), .light)
        XCTAssertEqual(appColorScheme(for: .dark), .dark)

        let appSource = try productionSource(
            "Sources/Parallax/App/ParallaxApp.swift"
        )
        let settingsStart = try XCTUnwrap(
            appSource.range(of: "\n        Settings {")
        )
        let sceneRootStart = try XCTUnwrap(
            appSource.range(of: "private struct ParallaxSceneRoot")
        )
        let windowStart = try XCTUnwrap(
            appSource.range(of: "WindowGroup(\"Parallax\", id: \"main\")")
        )
        let windowScene = String(
            appSource[
                windowStart.lowerBound..<settingsStart.lowerBound
            ]
        )
        let settingsScene = String(
            appSource[
                settingsStart.lowerBound..<sceneRootStart.lowerBound
            ]
        )
        let mainSceneRoot = String(
            appSource[sceneRootStart.lowerBound...]
        )
        let mapping =
            "appColorScheme(for: settings.appearance)"

        XCTAssertTrue(
            windowScene.contains("ParallaxSceneRoot("),
            "The actual main WindowGroup must be wired through the scene root whose appearance is tested."
        )
        XCTAssertTrue(settingsScene.contains("SettingsView(settings: settings)"))
        XCTAssertTrue(settingsScene.contains(mapping))
        XCTAssertTrue(
            mainSceneRoot.contains("ContentView(")
        )
        XCTAssertTrue(
            mainSceneRoot.contains(
                "corporateAccountOperationCoordinator:"
            )
        )
        XCTAssertTrue(mainSceneRoot.contains(mapping))
        XCTAssertEqual(
            appSource.components(separatedBy: mapping).count - 1,
            2,
            "Appearance mapping must be applied exactly once to the main scene root and once to Settings."
        )
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        AppSettings(
            userDefaults: try XCTUnwrap(
                UserDefaults(suiteName: defaultsSuiteName)
            )
        )
    }

    private func writeSentinel(
        _ value: String,
        at directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(
            to: directory.appendingPathComponent("sentinel.txt")
        )
    }

    private func readSentinel(at directory: URL) throws -> String {
        try String(
            contentsOf:
                directory.appendingPathComponent("sentinel.txt"),
            encoding: .utf8
        )
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        _ source: String,
        from startMarker: String,
        through endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private struct Wave8NoopLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion:
            @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        completion(.success(()))
    }
}
