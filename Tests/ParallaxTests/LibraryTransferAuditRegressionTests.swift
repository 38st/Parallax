import Foundation
import XCTest
@testable import Parallax

final class LibraryTransferAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-Transfer-Audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func app(_ name: String, profiles: [LaunchProfile] = []) -> ManagedApplication {
        ManagedApplication(displayName: name, appPath: "/Applications/\(name).app",
                           baseStoragePath: root.path, profiles: profiles)
    }

    private func data(_ apps: [ManagedApplication]) throws -> Data {
        try JSONEncoder().encode(LibraryDocument(applications: apps))
    }

    private func candidate(_ app: ManagedApplication) -> LibraryImportApplication {
        LibraryImportApplication(application: app, canonicalApplicationPath: app.appPath)
    }

    @MainActor
    private func fixture(_ apps: [ManagedApplication], fileSystem: any FileSystem = LocalFileSystem(),
                         backupAvailable: Bool = true) throws
        -> (LibraryStore, LibraryRepository, LibraryBackupStore) {
        let support = root.appendingPathComponent(UUID().uuidString)
        let backups = LibraryBackupStore(recoveryRoot: support.appendingPathComponent("Recovery"))
        let repository = LibraryRepository(fileSystem: fileSystem, applicationSupportURL: support,
                                          backupHook: { bytes, reason in
            guard backupAvailable else { throw LibraryRepositoryError.backupUnavailable }
            _ = try backups.createBackup(of: bytes, reason: reason)
        })
        _ = try repository.save(apps, expectedVersion: .missing)
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: support),
                                 repository: repository, backupStore: backups,
                                 fileSystem: fileSystem, settings: AppSettings(),
                                 libraryChangeBroadcaster: LibraryChangeBroadcaster())
        return (store, repository, backups)
    }

    @MainActor
    func testSameSessionRejectsEarlierConflictPrompt() throws {
        let original = app("Browser", profiles: [LaunchProfile(name: "Work")])
        let (store, _, _) = try fixture([original])
        var incoming = original
        incoming.profiles = [LaunchProfile(name: "work", argumentsText: "--first"),
                             LaunchProfile(name: "WORK", argumentsText: "--second")]
        XCTAssertTrue(store.prepareImport(data: try data([incoming])))
        store.confirmImport(replacing: false)
        let first = try XCTUnwrap(store.pendingImportConflictPrompt)
        store.resolvePendingImportConflict(.keepBoth, expectedPrompt: first)
        let second = try XCTUnwrap(store.pendingImportConflictPrompt)
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(first.conflictID, second.conflictID)
        store.resolvePendingImportConflict(.skip, expectedPrompt: first)
        XCTAssertEqual(store.pendingImportConflictPrompt, second)
        XCTAssertEqual(store.pendingImportResolutions.count, 1)
    }

    func testValidationPresentationPrioritizesErrorsAndAllowsWarnings() {
        let warnings = (0..<25).map {
            LibraryImportIssue(code: .normalizedDisplayName, severity: .warning,
                               path: "$.applications[\($0)]", message: "Warning \($0)")
        }
        let failure = LibraryImportIssue(code: .invalidFieldValue, severity: .error,
                                         path: "$.invalid", message: "Actual error")
        let rejected = LibraryImportValidationReport(document: nil, issues: warnings + [failure])
        XCTAssertEqual(rejected.presentationMessages.first, "$.invalid: Actual error")
        XCTAssertLessThanOrEqual(rejected.presentationMessages.count, 21)
        let accepted = LibraryImportValidationReport(document: LibraryDocument(applications: []),
                                                     issues: warnings)
        XCTAssertTrue(accepted.isValid)
        XCTAssertEqual(accepted.presentationMessages.last,
                       String(localized: "Additional validation issues were omitted from this summary."))
    }

    @MainActor
    func testReplacementFailureReloadsReadableRepositoryAndPublishes() throws {
        let original = app("Original", profiles: [LaunchProfile(name: "Selected")])
        let (store, repository, _) = try fixture([original])
        store.selectedApplicationID = original.id
        store.selectedProfileID = original.profiles[0].id
        var updated = original
        updated.displayName = "Changed"
        let snapshot = try repository.save([updated], expectedVersion: XCTUnwrap(store.libraryVersionToken))
        store.handleImportReplacementFailure(LibraryImportReplacementError(.recoveryRequired))
        XCTAssertEqual(store.applications, [updated])
        XCTAssertEqual(store.libraryVersionToken, snapshot.versionToken)
        XCTAssertEqual(store.selectedApplicationID, original.id)
        XCTAssertEqual(store.selectedProfileID, original.profiles[0].id)
        if case .loaded = store.loadState {} else { XCTFail("Expected a readable library") }
        XCTAssertNotNil(store.libraryChangeBroadcaster?.latestEvent)
        XCTAssertTrue(store.save())
    }

    @MainActor
    func testReplacementFailureUsesRepositoryRecoveryStatesAndBytes() throws {
        for kind in ["missing", "legacy", "future", "corrupt"] {
            let support = root.appendingPathComponent(kind)
            let persistence = LibraryPersistence(applicationSupportURL: support)
            let repository = LibraryRepository(applicationSupportURL: support)
            _ = try repository.save([app("Original")], expectedVersion: .missing)
            let store = LibraryStore(persistence: persistence, repository: repository,
                                     settings: AppSettings(), libraryChangeBroadcaster: LibraryChangeBroadcaster())
            let url = try persistence.libraryURL()
            let bytes: Data
            switch kind {
            case "missing":
                bytes = Data()
                try FileManager.default.removeItem(at: url)
            case "legacy":
                bytes = Data("[]".utf8)
                try bytes.write(to: url)
            case "future":
                bytes = Data(#"{"version":999,"applications":[]}"#.utf8)
                try bytes.write(to: url)
            default:
                bytes = Data("{".utf8)
                try bytes.write(to: url)
            }
            store.handleImportReplacementFailure(LibraryImportReplacementError(.recoveryRequired))
            XCTAssertTrue(store.applications.isEmpty, kind)
            XCTAssertNil(store.selectedApplicationID, kind)
            XCTAssertNil(store.selectedProfileID, kind)
            XCTAssertNotNil(store.libraryChangeBroadcaster?.latestEvent, kind)
            switch kind {
            case "missing":
                if case .loaded = store.loadState {} else { XCTFail("Expected a readable library") }
                XCTAssertEqual(store.libraryVersionToken, .missing)
            case "future":
                guard case .unsupportedNewerVersion(let actual, _) = store.loadState else {
                    XCTFail("Newer library must remain read-only"); continue
                }
                XCTAssertEqual(actual, bytes)
                XCTAssertNil(store.libraryVersionToken)
            default:
                guard case .recoveryRequired(let actual, _) = store.loadState else {
                    XCTFail("Expected recovery for \(kind)"); continue
                }
                XCTAssertEqual(actual, bytes)
                XCTAssertNil(store.libraryVersionToken)
                if kind == "legacy" { XCTAssertNotNil(store.migrationRequiredLibrary) }
            }
        }
    }

    func testSpaceStorageIdentityCollidingWithApplicationIsConflict() throws {
        let original = app("Original")
        let incoming = app("Incoming", profiles: [LaunchProfile(storageID: original.storageID, name: "Work")])
        let preview = try LibraryImportConflictEngine.resolve(existing: [candidate(original)],
                                                               imported: [candidate(incoming)])
        XCTAssertFalse(preview.isFullyResolved)
        let conflict = try XCTUnwrap(preview.conflicts.first)
        XCTAssertEqual(conflict.scope, .application)
        let skipped = try LibraryImportConflictEngine.resolve(existing: [candidate(original)],
            imported: [candidate(incoming)], resolutions: [conflict.id: .skip])
        XCTAssertEqual(skipped.applications, [original])
        let identity = LibraryImportFreshApplicationIdentity(id: UUID(), storageID: UUID(),
            profileIdentities: [incoming.profiles[0].id: .init(id: UUID(), storageID: UUID())])
        let copied = try LibraryImportConflictEngine.resolve(existing: [candidate(original)],
            imported: [candidate(incoming)], resolutions: [conflict.id: .keepBoth(
                .application(renamedTo: "Incoming Imported", identity: identity))])
        XCTAssertNoThrow(try LibraryPersistence.validateCurrentApplications(XCTUnwrap(copied.applications)))
        XCTAssertThrowsError(try LibraryImportConflictEngine.resolve(existing: [candidate(original)],
            imported: [candidate(incoming)], resolutions: [conflict.id: .useImported(applicationID: original.id)]))
    }

    @MainActor
    func testReplacePreservesKnownStorageLocationsAndDisclosesChanges() throws {
        let original = app("Original", profiles: [LaunchProfile(name: "Work")])
        let (store, repository, _) = try fixture([original])
        let incoming = ManagedApplication(storageID: original.storageID,
            displayName: original.displayName, appPath: original.appPath,
            baseStoragePath: root.appendingPathComponent("Elsewhere").path,
            profiles: original.profiles)
        XCTAssertNotEqual(incoming.id, original.id)
        XCTAssertTrue(store.prepareImport(data: try data([original])))
        let ordinaryWarnings = try XCTUnwrap(store.pendingImportSummary).warnings
        store.cancelImport()
        XCTAssertTrue(store.prepareImport(data: try data([incoming])))
        XCTAssertEqual(try XCTUnwrap(store.pendingImportSummary).warnings.count, ordinaryWarnings.count + 1)
        let evidence = try LibraryImportReplacementPlanBuilder(repository: repository,
            validator: LibraryImportValidator(), makePreviewID: UUID.init)
            .makeEvidence(importData: data([incoming]), expectedVersion: store.libraryVersionToken)
        XCTAssertEqual(evidence.preparedCommit.applications[0].baseStoragePath, original.baseStoragePath)
        XCTAssertFalse(evidence.validationWarnings.isEmpty)
        store.confirmImport(replacing: true)
        XCTAssertEqual(store.applications[0].baseStoragePath, original.baseStoragePath)
        XCTAssertEqual(store.applications[0].profiles[0].storageID, original.profiles[0].storageID)
    }

    func testClaudeSafePathFormsRoundTripThroughExport() throws {
        for path in ["/tmp/Claude/", "/tmp//Claude", "/"] {
            let original = app("Claude", profiles: [LaunchProfile(name: "Work",
                environmentText: "# Preserve this comment\nCLAUDE_CONFIG_DIR=\(path)\nOTHER=value")])
            let service = PortableConfigurationService()
            let artifact = try service.makeLibraryMetadataExport(library: LibraryDocument(applications: [original]),
                                                                 sensitiveLiteralPolicy: .omit)
            let report = try LibraryImportArtifactDecoder().decode(service.encode(artifact)).validation
            XCTAssertTrue(report.isValid, path)
            let profile = try XCTUnwrap(report.document?.applications.first?.profiles.first)
            XCTAssertEqual(LaunchEnvironmentParser.parse(profile.environmentText).effectiveValues["CLAUDE_CONFIG_DIR"],
                           URL(fileURLWithPath: path).standardizedFileURL.path)
            XCTAssertTrue(profile.environmentText.hasPrefix("# Preserve this comment\n"))
            XCTAssertTrue(profile.environmentText.hasSuffix("\nOTHER=value"))
        }
        for path in ["relative", "/tmp/../Claude", "/tmp/./Claude", "secret://fixture"] {
            let report = LibraryImportValidator().validate(try data([app("Claude", profiles: [
                LaunchProfile(name: "Work", environmentText: "CLAUDE_CONFIG_DIR=\(path)")])]))
            XCTAssertFalse(report.isValid, path)
        }
    }

    @MainActor
    func testUndoFailureReloadsCommittedTargetOrEntersRecovery() throws {
        for behavior: TransferAuditFileSystem.ReplaceBehavior in [.replaceThenThrow, .corruptThenThrow] {
            let fs = TransferAuditFileSystem()
            let original = app("Original")
            let (store, repository, _) = try fixture([original], fileSystem: fs)
            XCTAssertTrue(store.prepareImport(data: try data([app("Imported")])))
            store.confirmImport(replacing: true)
            let previousEvent = store.libraryChangeBroadcaster?.latestEvent
            fs.replaceBehavior = behavior
            XCTAssertFalse(store.undoLastImportReplacement())
            XCTAssertNotEqual(store.libraryChangeBroadcaster?.latestEvent, previousEvent)
            switch repository.load() {
            case .loaded(let snapshot):
                XCTAssertEqual(store.applications, [original])
                XCTAssertEqual(store.libraryVersionToken, snapshot.versionToken)
                if case .loaded = store.loadState {} else { XCTFail("Expected a readable library") }
                XCTAssertTrue(store.save())
            case .recoveryRequired(let failure):
                guard case .recoveryRequired(let bytes, _) = store.loadState else {
                    XCTFail("Corrupt undo must enter recovery"); continue
                }
                XCTAssertEqual(bytes, failure.originalBytes)
                XCTAssertTrue(store.applications.isEmpty)
                XCTAssertNil(store.libraryVersionToken)
            default: XCTFail("Unexpected repository state")
            }
        }
    }

    @MainActor
    func testStorageLocationOnlyDifferenceDoesNotPromptOrWrite() throws {
        let original = app("Original")
        let (store, _, _) = try fixture([original])
        let version = store.libraryVersionToken
        var incoming = original
        incoming.baseStoragePath = root.appendingPathComponent("Elsewhere").path
        XCTAssertTrue(store.prepareImport(data: try data([incoming])))
        XCTAssertTrue(try XCTUnwrap(store.pendingImportSummary).warnings.contains(
            LibraryImportContentTransformer.storageLocationNotice))
        store.confirmImport(replacing: false)
        XCTAssertNil(store.pendingImportConflictPrompt)
        XCTAssertEqual(store.libraryImportFlowPhase, .idle)
        XCTAssertEqual(store.applications, [original])
        XCTAssertEqual(store.libraryVersionToken, version)
    }

    func testRenameCollisionDoesNotRequestUnavailableField() {
        XCTAssertEqual(LibraryImportConflictEngineError.renameCollision.localizedDescription,
            String(localized: "The imported copy's name is already in use. Cancel and review the import again."))
    }

    func testDuplicateKeyRejectionExplainsTheCause() throws {
        let bytes = Data(#"{"version":2,"version":2,"applications":[]}"#.utf8)
        let report = try LibraryImportArtifactDecoder().decode(bytes).validation
        XCTAssertFalse(report.isValid)
        let message = String(localized: "The selected file contains duplicate JSON keys. Remove the duplicate entries and try again.")
        XCTAssertEqual(report.issues.first?.code, .duplicateJSONKey)
        XCTAssertEqual(report.issues.first?.message, message)
        XCTAssertThrowsError(try PortableConfigurationService().decodeLibraryMetadataExport(from: bytes)) {
            XCTAssertEqual($0.localizedDescription, message)
        }
    }

    func testImportReadRejectsGrowthDuringReadLoop() throws {
        let url = root.appendingPathComponent("growth-during-read.json")
        try Data(repeating: 32, count: 64 * 1_024).write(to: url)
        var requests: [Int] = []
        XCTAssertThrowsError(try LibraryImportFileReader.read(at: url, maximumBytes: 70 * 1_024,
            readChunk: { handle, count in
                requests.append(count)
                let chunk = try handle.read(upToCount: count)
                if requests.count == 1 {
                    let writer = try FileHandle(forWritingTo: url)
                    defer { try? writer.close() }
                    try writer.seekToEnd()
                    try writer.write(contentsOf: Data(repeating: 32, count: 64 * 1_024))
                }
                return chunk
            }))
        XCTAssertEqual(requests, [64 * 1_024, 6 * 1_024 + 1])
    }

    func testUseImportedPreservesStorageAndRequiresReviewForRetargetedSpaces() throws {
        let original = app("Original", profiles: [LaunchProfile(name: "Local")])
        for field in ["path", "bundle", "preset"] {
            var incoming = original
            incoming.baseStoragePath = root.appendingPathComponent("Other").path
            switch field {
            case "path": incoming.appPath = "/Applications/Other.app"
            case "bundle": incoming.bundleIdentifier = "example.other"
            default: incoming.preset = .codex
            }
            let merged = LibraryImportContentTransformer.applicationUsingImportedFields(
                existing: candidate(original), imported: candidate(incoming)).application
            XCTAssertEqual(merged.baseStoragePath, original.baseStoragePath)
            XCTAssertEqual(merged.profiles[0].storageID, original.profiles[0].storageID)
            XCTAssertEqual(merged.profiles[0].launchConfigurationTrust, .importedPendingReview)
        }
        var renamed = original
        renamed.displayName = "Renamed"
        XCTAssertEqual(LibraryImportContentTransformer.applicationUsingImportedFields(
            existing: candidate(original), imported: candidate(renamed)).application.profiles,
                       original.profiles)
    }

    @MainActor
    func testLibraryExportsRequireLoadedState() throws {
        let (store, _, _) = try fixture([])
        for state: LibraryStore.LoadState in [
            .recoveryRequired(originalBytes: nil, message: "fixture"),
            .unsupportedNewerVersion(originalBytes: nil, message: "fixture"),
            .unrecoverable(originalBytes: nil, message: "fixture")
        ] {
            store.loadState = state
            for kind: LibraryPortableExportKind in [.libraryMetadata, .portableConfiguration] {
                XCTAssertFalse(store.canExportPortable(kind))
                XCTAssertThrowsError(try store.portableExportData(kind: kind, sensitivePolicy: .omit))
            }
            XCTAssertTrue(store.canExportPortable(.settingsAndTemplates))
        }
    }

    @MainActor
    func testMergeReplaceAndUndoPreserveOnlySurvivingSelection() throws {
        let first = app("First", profiles: [LaunchProfile(name: "First")])
        let second = app("Second", profiles: [LaunchProfile(name: "Second")])
        let (store, _, _) = try fixture([first, second])
        store.selectedApplicationID = second.id
        store.selectedProfileID = second.profiles[0].id
        XCTAssertTrue(store.prepareImport(data: try data([app("Third")])))
        store.confirmImport(replacing: false)
        XCTAssertEqual(store.selectedApplicationID, second.id)
        XCTAssertEqual(store.selectedProfileID, second.profiles[0].id)
        XCTAssertTrue(store.prepareImport(data: try data([first, second])))
        store.confirmImport(replacing: true)
        XCTAssertEqual(store.selectedApplicationID, second.id)
        XCTAssertEqual(store.selectedProfileID, second.profiles[0].id)
        XCTAssertTrue(store.undoLastImportReplacement())
        XCTAssertEqual(store.selectedApplicationID, second.id)
        XCTAssertEqual(store.selectedProfileID, second.profiles[0].id)
        XCTAssertTrue(store.prepareImport(data: try data([app("Replacement")])))
        store.confirmImport(replacing: true)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertTrue(store.undoLastImportReplacement())
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
    }

    @MainActor
    func testKeepBothAvoidsNamesAlreadyProjectedByImport() throws {
        let original = app("Browser", profiles: [LaunchProfile(name: "Work")])
        let (store, _, _) = try fixture([original])
        var duplicate = app("browser")
        duplicate.appPath = "/Applications/Duplicate.app"
        let occupied = app("browser Imported")
        XCTAssertTrue(store.prepareImport(data: try data([occupied, duplicate])))
        store.confirmImport(replacing: false)
        store.resolvePendingImportConflict(.keepBoth)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.libraryImportFlowPhase, .idle)
        XCTAssertEqual(store.applications.count, 3)

        let (profileStore, _, _) = try fixture([original])
        var incoming = original
        incoming.profiles = [LaunchProfile(name: "Work Imported"),
                             LaunchProfile(name: "Work", argumentsText: "--new")]
        XCTAssertTrue(profileStore.prepareImport(data: try data([incoming])))
        profileStore.confirmImport(replacing: false)
        profileStore.resolvePendingImportConflict(.keepBoth)
        XCTAssertNil(profileStore.errorMessage)
        XCTAssertEqual(profileStore.libraryImportFlowPhase, .idle)
        XCTAssertEqual(profileStore.applications[0].profiles.count, 3)
    }

    func testConflictErrorsHaveLocalizedDescriptions() {
        let errors: [LibraryImportConflictEngineError] = [.conflictResolutionDoesNotMatch,
            .wrongKeepBothScope, .missingFreshProfileIdentity(UUID()), .freshIdentityCollision,
            .emptyRename, .renameCollision]
        for error in errors {
            XCTAssertNotNil((error as Error as? LocalizedError)?.errorDescription)
        }
    }

    @MainActor
    func testSensitiveArgumentsTriggerExportChoiceForSpacesAndTemplates() throws {
        let (store, _, _) = try fixture([app("Sensitive", profiles: [
            LaunchProfile(name: "Work", argumentsText: "--api-key=fixture-secret")])])
        XCTAssertTrue(store.portableExportContainsSensitiveLiterals(kind: .libraryMetadata))
        store.settings.profileTemplates = [ProfileTemplate(name: "Sensitive",
            argumentsText: "--api-key=fixture-secret", environmentText: "", notes: "")]
        XCTAssertTrue(store.portableExportContainsSensitiveLiterals(kind: .settingsAndTemplates))
    }

    @MainActor
    func testFailedReplacementReloadsRolledBackVersionAndCanSaveAgain() throws {
        let fs = TransferAuditFileSystem()
        let original = app("Original")
        let (store, repository, _) = try fixture([original], fileSystem: fs)
        XCTAssertTrue(store.prepareImport(data: try data([app("Imported")])))
        fs.replaceBehavior = .replaceThenThrow
        store.confirmImport(replacing: true)
        guard case .loaded(let snapshot) = repository.load() else { return XCTFail("Expected rollback") }
        XCTAssertEqual(snapshot.applications, [original])
        XCTAssertEqual(store.libraryVersionToken, snapshot.versionToken)
        XCTAssertNotNil(store.libraryChangeBroadcaster?.latestEvent)
        XCTAssertEqual(store.libraryImportFlowPhase, .idle)
        XCTAssertTrue(store.commit([original], selectedApplicationID: nil, selectedProfileID: nil))
    }

    @MainActor
    func testUndoHonorsMutationAuthority() throws {
        let (store, _, _) = try fixture([app("Original")])
        XCTAssertTrue(store.prepareImport(data: try data([app("Imported")])))
        store.confirmImport(replacing: true)
        let version = store.libraryVersionToken
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertFalse(store.undoLastImportReplacement())
        XCTAssertEqual(store.libraryVersionToken, version)
    }

    func testCrossApplicationProfileIdentityRequiresDecision() throws {
        let profile = LaunchProfile(name: "Shared")
        let one = app("One", profiles: [profile])
        let two = app("Two")
        var incoming = two
        incoming.profiles = [profile]
        let preview = try LibraryImportConflictEngine.resolve(existing: [candidate(one), candidate(two)],
                                                              imported: [candidate(incoming)])
        let conflict = try XCTUnwrap(preview.conflicts.first(where: { $0.scope == .application }))
        let result = try LibraryImportConflictEngine.resolve(existing: [candidate(one), candidate(two)],
            imported: [candidate(incoming)], resolutions: [conflict.id: .keepExisting(applicationID: two.id)])
        XCTAssertTrue(result.conflicts.contains { $0.scope == .profile })
        XCTAssertFalse(result.isFullyResolved)
    }

    func testApplicationStorageIdentityCollidingWithSpaceIsConflict() throws {
        let original = app("Original", profiles: [LaunchProfile(name: "Work")])
        let incoming = ManagedApplication(storageID: original.profiles[0].storageID,
            displayName: "Incoming", appPath: "/Applications/Incoming.app")
        let result = try LibraryImportConflictEngine.resolve(existing: [candidate(original)],
                                                             imported: [candidate(incoming)])
        XCTAssertFalse(result.isFullyResolved)
        XCTAssertEqual(result.conflicts.first?.scope, .application)
    }

    func testFuturePortableHeaderWinsOverUnknownEnums() throws {
        let service = PortableConfigurationService()
        let artifact = try service.makeLibraryMetadataExport(library: LibraryDocument(applications: []),
                                                             sensitiveLiteralPolicy: .omit)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: service.encode(artifact)) as? [String: Any])
        var header = try XCTUnwrap(object["header"] as? [String: Any])
        header["schemaVersion"] = 999
        header["warnings"] = ["futureWarning"]
        header["kind"] = "futureKind"
        object["header"] = header
        let bytes = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try LibraryImportArtifactDecoder().decode(bytes)) {
            XCTAssertEqual($0 as? PortableConfigurationError, .unsupportedSchemaVersion(999))
        }
        XCTAssertThrowsError(try service.decodeLibraryMetadataExport(from: bytes)) {
            XCTAssertEqual($0 as? PortableConfigurationError, .unsupportedSchemaVersion(999))
        }
    }

    @MainActor
    func testImportReadDoesNotUseUnboundedFileSystemRead() throws {
        let fs = TransferAuditFileSystem()
        let (store, _, _) = try fixture([], fileSystem: fs)
        let url = root.appendingPathComponent("import.json")
        try data([app("Imported")]).write(to: url)
        fs.watchedReadURL = url
        XCTAssertTrue(store.prepareImport(at: url))
        XCTAssertEqual(fs.watchedReadCount, 0)
    }

    @MainActor
    func testImportReadRejectsGrowthAfterInitialSizeCheck() throws {
        let fs = TransferAuditFileSystem()
        let (store, _, _) = try fixture([], fileSystem: fs)
        let url = root.appendingPathComponent("growing.json")
        try data([app("Imported")]).write(to: url)
        fs.watchedReadURL = url
        fs.growOnInspectURL = url
        XCTAssertFalse(store.prepareImport(at: url))
        XCTAssertEqual(fs.watchedReadCount, 0)
        XCTAssertNil(store.pendingLibraryImport)
    }

    @MainActor
    func testValidationAlertIsBounded() throws {
        let (store, _, _) = try fixture([])
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 2,
            "applications": Array(repeating: ["displayName": ""], count: 200)])
        XCTAssertFalse(store.prepareImport(data: bytes))
        XCTAssertLessThan(try XCTUnwrap(store.errorMessage).count, 8_000)
    }

    func testClaudeConfigurationPathIsValidated() throws {
        for path in ["relative", "/tmp/../other", "secret://fixture"] {
            let report = LibraryImportValidator().validate(try data([app("Claude", profiles: [
                LaunchProfile(name: "Work", environmentText: "CLAUDE_CONFIG_DIR=\(path)")])]))
            XCTAssertFalse(report.isValid)
            XCTAssertTrue(report.issues.contains { $0.code == .invalidIsolationPath })
        }
    }

    func testExportCannotExceedImportByteLimit() throws {
        let service = PortableConfigurationService(maximumEncodedArtifactBytes: 256)
        let artifact = try service.makeLibraryMetadataExport(library: LibraryDocument(applications: [app("Large")]),
                                                             sensitiveLiteralPolicy: .omit)
        XCTAssertThrowsError(try service.encode(artifact)) {
            XCTAssertEqual($0 as? PortableConfigurationError, .inputTooLarge)
        }
    }

    @MainActor
    func testMergeOverwritesHaveVerifiedBackup() throws {
        let original = app("Original")
        let (store, _, backups) = try fixture([original])
        var incoming = original
        incoming.displayName = "Renamed"
        XCTAssertTrue(store.prepareImport(data: try data([incoming])))
        store.confirmImport(replacing: false)
        store.resolvePendingImportConflict(.useImported, target: try XCTUnwrap(store.pendingImportConflictTargets.first))
        XCTAssertNil(store.errorMessage)
        let artifact = try XCTUnwrap(backups.inspectArtifacts(kind: .backup).first)
        let restored = try JSONDecoder().decode(LibraryDocument.self, from: backups.prepareRestore(from: artifact.artifact).bytes)
        XCTAssertEqual(restored.applications, [original])
    }

    @MainActor
    func testMergeBackupFailurePreservesLibrary() throws {
        let original = app("Original")
        let (store, repository, _) = try fixture([original], backupAvailable: false)
        let version = store.libraryVersionToken
        var incoming = original
        incoming.displayName = "Renamed"
        XCTAssertTrue(store.prepareImport(data: try data([incoming])))
        store.confirmImport(replacing: false)
        store.resolvePendingImportConflict(.useImported,
            target: try XCTUnwrap(store.pendingImportConflictTargets.first))
        XCTAssertEqual(store.errorMessage, LibraryRepositoryError.backupUnavailable.localizedDescription)
        XCTAssertEqual(store.applications, [original])
        XCTAssertEqual(store.libraryVersionToken, version)
        guard case .loaded(let snapshot) = repository.load() else { return XCTFail("Expected prior library") }
        XCTAssertEqual(snapshot.versionToken, version)
    }

    @MainActor
    func testUnchangedMergeDoesNotWriteLibrary() throws {
        let original = app("Original")
        let (store, _, _) = try fixture([original])
        let version = store.libraryVersionToken
        XCTAssertTrue(store.prepareImport(data: try data([original])))
        store.confirmImport(replacing: false)
        XCTAssertEqual(store.libraryVersionToken, version)
        XCTAssertEqual(store.libraryImportFlowPhase, .idle)
    }

    @MainActor
    func testPendingMigrationBlocksLibraryExport() throws {
        let (store, _, _) = try fixture([])
        store.migrationRequiredLibrary = LegacyLibrary(format: .versioned(1), applications: [])
        XCTAssertFalse(store.canExportPortable(.libraryMetadata))
        XCTAssertThrowsError(try store.portableExportData(kind: .libraryMetadata, sensitivePolicy: .omit))
    }

    @MainActor
    func testUnrecoverableReplacementEntersRecovery() throws {
        let fs = TransferAuditFileSystem()
        let (store, _, _) = try fixture([app("Original")], fileSystem: fs)
        XCTAssertTrue(store.prepareImport(data: try data([app("Imported")])))
        fs.replaceBehavior = .corruptThenThrow
        store.confirmImport(replacing: true)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Unverified replacement must block mutations")
        }
        XCTAssertFalse(store.canMutateLibrary())
    }

    func testLockTimeoutDoesNotBecomeRecoveryAfterPeerWrite() throws {
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        let prior = try repository.save([app("Original")], expectedVersion: .missing)
        let evidence = try LibraryImportReplacementPlanBuilder(repository: repository,
            validator: LibraryImportValidator(), makePreviewID: UUID.init)
            .makeEvidence(importData: data([app("Imported")]), expectedVersion: prior.versionToken)
        _ = try repository.save([app("Peer")], expectedVersion: prior.versionToken)
        XCTAssertNoThrow(try LibraryImportReplacementRecovery(repository: repository)
            .recoverFailedReplacementIfNeeded(evidence: evidence,
                originalError: LibraryAdvisoryLockError.timedOut(
                    url: root.appendingPathComponent(".library.lock"), timeout: 0)))
    }

    @MainActor
    func testPortableWarningDoesNotOfferSettingsImport() throws {
        let (store, _, _) = try fixture([])
        let service = PortableConfigurationService()
        let artifact = try service.makePortableConfigurationExport(
            library: LibraryDocument(applications: []),
            settings: PortableSettingsSnapshot(profileTemplates: [], defaultBaseStoragePath: root.path,
                confirmBeforeLaunch: true, appearance: .system), sensitiveLiteralPolicy: .omit)
        XCTAssertTrue(store.prepareImport(data: try service.encode(artifact)))
        XCTAssertFalse(try XCTUnwrap(store.pendingImportSummary).message.contains("import settings separately"))
    }

    @MainActor
    func testImportReviewFallbacksAndTemplateOwnerHaveTranslations() throws {
        for language in ["en"] {
            let url = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: "Localizable",
                withExtension: "strings", subdirectory: nil, localization: language))
            let translations = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let catalog = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(catalog.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            for obsolete in [
                "Export plaintext sensitive environment values?",
                "This library contains environment values classified as sensitive. Choose whether to omit, redact, or explicitly include those literals. Keychain-backed secrets remain references.",
                "This import applies library metadata only. Review and import settings separately; profile data and Keychain secret values are not included.",
                "CODEX_HOME must be absolute and traversal-free."
            ] {
                XCTAssertNil(translations[obsolete])
            }
            let bundle = try XCTUnwrap(Bundle(url: url.deletingLastPathComponent()))
            XCTAssertEqual(ImportedLaunchReviewView.expectedBundleText(nil, bundle: bundle),
                String(format: try XCTUnwrap(translations["Expected bundle: %@"]),
                       try XCTUnwrap(translations["Not recorded"])))
            XCTAssertEqual(ImportedLaunchReviewView.verifiedBundleText(nil, bundle: bundle),
                String(format: try XCTUnwrap(translations["Verified bundle: %@"]),
                       try XCTUnwrap(translations["Not verified"])))
            XCTAssertEqual(ImportedLaunchReviewView.expectedBundleText("example.app", bundle: bundle),
                String(format: try XCTUnwrap(translations["Expected bundle: %@"]), "example.app"))
            for invalidArguments in [true, false] {
                let settings = PortableSettingsSnapshot(profileTemplates: [ProfileTemplate(
                    name: "Fixture", argumentsText: invalidArguments ? "'unterminated" : "",
                    environmentText: invalidArguments ? "" : "INVALID LINE", notes: "")],
                    defaultBaseStoragePath: root.path, confirmBeforeLaunch: true, appearance: .system)
                XCTAssertThrowsError(try PortableConfigurationSanitizerAdapter.settings(
                    settings, policy: .omit, bundle: bundle)) { error in
                    let expectedOwner = String(format: translations["Template / %@"] ?? "", "Fixture")
                    if invalidArguments {
                        XCTAssertEqual(error as? PortableConfigurationError, .invalidArguments(owner: expectedOwner))
                    } else {
                        XCTAssertEqual(error as? PortableConfigurationError, .invalidEnvironment(owner: expectedOwner))
                    }
                }
            }
            for key in ["Not recorded", "Not verified", "Template / %@"] {
                XCTAssertNotNil(translations[key], "Missing \(language): \(key)")
            }
        }
    }

    func testDuplicateJSONKeysAreRejectedBeforeEitherDecoder() throws {
        for bytes in [Data(#"{"version":2,"version":2,"revision":0,"applications":[]}"#.utf8),
                      Data(#"{"version":2,"revision":0,"applications":[],"\u0061pplications":[]}"#.utf8)] {
            XCTAssertFalse(LibraryImportValidator().validate(bytes).isValid)
            XCTAssertFalse(try LibraryImportArtifactDecoder().decode(bytes).validation.isValid)
        }
        let service = PortableConfigurationService()
        let artifact = try service.makeLibraryMetadataExport(library: LibraryDocument(applications: []),
                                                             sensitiveLiteralPolicy: .omit)
        let encoded = try XCTUnwrap(String(data: service.encode(artifact), encoding: .utf8))
        let duplicate = Data(encoded.replacingOccurrences(of: "\"schemaVersion\" : 1", with:
            "\"schemaVersion\" : 1, \"schemaVersion\" : 1").utf8)
        XCTAssertFalse(try LibraryImportArtifactDecoder().decode(duplicate).validation.isValid)
    }
}

private enum TransferAuditTestError: Error {
    case injected
    case unexpectedRepositoryState
}

private final class TransferAuditFileSystem:
    FileSystem,
    @unchecked Sendable
{
    enum ReplaceBehavior {
        case normal
        case throwBeforeReplace
        case replaceThenThrow
        case corruptThenThrow
    }

    private let underlying = LocalFileSystem()
    private let lock = NSLock()
    private var storedReplaceBehavior = ReplaceBehavior.normal

    var replaceBehavior: ReplaceBehavior {
        get { lock.withLock { storedReplaceBehavior } }
        set { lock.withLock { storedReplaceBehavior = newValue } }
    }

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    var growOnInspectURL: URL?

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        let attributes = try underlying.attributesOfItem(at: url)
        if url == growOnInspectURL {
            growOnInspectURL = nil
            try underlying.writeDataAtomically(Data(repeating: 32,
                count: LibraryImportLimits().maximumBytes + 1), to: url)
        }
        return attributes
    }

    func canonicalURL(for url: URL) throws -> URL {
        try underlying.canonicalURL(for: url)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try underlying.contentsOfDirectory(at: url)
    }

    var watchedReadURL: URL?
    var watchedReadCount = 0

    func readData(at url: URL) throws -> Data {
        if url == watchedReadURL { watchedReadCount += 1 }
        return try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(
        at destinationURL: URL,
        withItemAt sourceURL: URL
    ) throws {
        let behavior = lock.withLock { () -> ReplaceBehavior in
            let value = storedReplaceBehavior
            storedReplaceBehavior = .normal
            return value
        }
        switch behavior {
        case .normal:
            try underlying.replaceItem(
                at: destinationURL,
                withItemAt: sourceURL
            )
        case .throwBeforeReplace:
            throw TransferAuditTestError.injected
        case .corruptThenThrow:
            try underlying.writeDataAtomically(Data("{".utf8), to: destinationURL)
            throw TransferAuditTestError.injected
        case .replaceThenThrow:
            try underlying.replaceItem(
                at: destinationURL,
                withItemAt: sourceURL
            )
            throw TransferAuditTestError.injected
        }
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}
