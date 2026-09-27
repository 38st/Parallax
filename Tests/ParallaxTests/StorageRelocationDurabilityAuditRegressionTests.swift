import Foundation
import XCTest
@testable import Parallax

final class StorageRelocationDurabilityAuditRegressionTests: XCTestCase {
    func testPlanAndReceiptAreAbsentUntilAtomicPublication() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let events = RelocationAuditEventLog()
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
            fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
            supportsPermissions: { _ in true }, transactionBoundary: { boundary in
                if case .beforeControlPublication(let path) = boundary {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
                    events.record(path.lastPathComponent)
                }
            })
        let preview = try fixture.preview()
        _ = try coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository)
        XCTAssertEqual(events.values.count, 2)
        XCTAssertTrue(events.values.contains { $0.hasSuffix(".plan.json") })
        XCTAssertTrue(events.values.contains { $0.hasSuffix(".receipt.json") })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: coordinator.controlRootURL.path)
            .contains { $0.hasSuffix(".pending") })
    }

    func testInterruptedAtomicPlanAndReceiptPublicationConverges() throws {
        for suffix in [".plan.json", ".receipt.json"] {
            let fixture = try RelocationAuditFixture()
            defer { fixture.remove() }
            let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
                fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
                supportsPermissions: { _ in true }, transactionBoundary: { boundary in
                    if case .beforeControlPublication(let path) = boundary, path.lastPathComponent.hasSuffix(suffix) {
                        throw DurabilityAuditError.interrupted
                    }
                })
            let preview = try fixture.preview()
            XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository))
            let pending = try fixture.coordinator.pendingRelocations()
            if suffix == ".plan.json" {
                XCTAssertTrue(pending.isEmpty)
                XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
            } else {
                XCTAssertEqual(pending.map(\.transactionID), [preview.requestID])
                guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected recovery") }
                XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
            }
        }
    }

    func testDestinationSyncFailurePreservesSourceAndPriorLibrary() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
            fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
            supportsPermissions: { _ in true }, transactionBoundary: { boundary in
                if case .beforeDestinationSync = boundary { throw DurabilityAuditError.interrupted }
            })
        let preview = try fixture.preview()
        XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository))
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
        XCTAssertFalse(fixture.exists(preview.destination.applicationRoot.url))
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail("Missing library") }
        XCTAssertEqual(snapshot.versionToken, fixture.version)
        XCTAssertTrue(fixture.registry.activeProfileStorageIDs(applicationStorageID: fixture.application.storageID,
            profileStorageIDs: Set(fixture.application.profiles.map(\.storageID))).isEmpty)
    }

    func testPreviewBlocksVolumesWithoutVerifiedPOSIXPermissions() throws {
        let cases: [Bool?] = [false, nil]
        for supported in cases {
            let fixture = try RelocationAuditFixture()
            defer { fixture.remove() }
            let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
                fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
                supportsPermissions: { _ in supported })
            let preview = try coordinator.prepare(application: fixture.application,
                destinationBaseRoot: fixture.destination.path, expectedVersion: fixture.version)
            XCTAssertTrue(preview.blockers.contains(.unsupportedDestinationPermissions))
            XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository))
            XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
            XCTAssertFalse(fixture.exists(preview.destination.applicationRoot.url))
        }
    }

    func testTildePathsUseLaunchExpansionAndNeverMasqueradeAsExternal() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
            fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
            supportsPermissions: { _ in true }, homeDirectory: fixture.root)
        var application = fixture.application
        let old = try XCTUnwrap(coordinator.userDataValue(in: application.profiles[0]))
        let tilde = "~" + String(old.dropFirst(fixture.root.path.count))
        application.profiles[0].argumentsText = ShellWordsParser.quote("--user-data-dir=\(tilde)")
        application.profiles[0].isolationOwnership.userData = .legacyUnknown
        let generated = try coordinator.prepare(application: application,
            destinationBaseRoot: fixture.destination.path, expectedVersion: fixture.version)
        XCTAssertEqual(generated.generatedRewrites.map(\.field), [.userData])
        XCTAssertTrue(generated.blockers.isEmpty)
        application.profiles[0].isolationOwnership.userData = .explicit
        let explicit = try coordinator.prepare(application: application,
            destinationBaseRoot: fixture.destination.path, expectedVersion: fixture.version)
        XCTAssertTrue(explicit.blockers.contains(.configuredPathInsideManagedStorage))
        XCTAssertTrue(explicit.preservedExternalPaths.isEmpty)
    }

    func testCommittedRecoveryPreservesRetargetedSourceBase() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        _ = try fixture.repository.save([preview.relocatedApplication], expectedVersion: fixture.version)
        let retained = fixture.root.appendingPathComponent("Retained")
        try FileManager.default.moveItem(at: fixture.source, to: retained)
        let unrelated = fixture.root.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: unrelated.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: unrelated)
        guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected recovery") }
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("sentinel")), Data("untouched".utf8))
        XCTAssertTrue(fixture.exists(retained))
    }

    func testPreviousBuildInlinePlanStillRecoversPartialDelete() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let coordinator = fixture.coordinator
        let plan = try coordinator.makeControlPlan(preview: preview, preparedCommit: fixture.prepared(preview))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: coordinator.canonicalBytes(plan.unsigned)) as? [String: Any])
        object["version"] = 1
        object["sourceApplicationSnapshot"] = try JSONSerialization.jsonObject(with: coordinator.canonicalBytes(XCTUnwrap(preview.sourceApplicationSnapshot)))
        let unsigned = try coordinator.decoder.decode(StorageRelocationControlPlan.Unsigned.self,
            from: JSONSerialization.data(withJSONObject: object))
        let legacy = StorageRelocationControlPlan(unsigned: unsigned, planSHA256: LibraryPersistence.sha256(try coordinator.canonicalBytes(unsigned)))
        try coordinator.control.write(coordinator.canonicalBytes(legacy), to: coordinator.controlPlanPath(preview.requestID))
        try fixture.publishCopy(preview)
        _ = try fixture.repository.save([preview.relocatedApplication], expectedVersion: fixture.version)
        try FileManager.default.removeItem(at: preview.source.applicationRoot.url.appendingPathComponent("data"))
        guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected legacy recovery") }
        XCTAssertFalse(fixture.exists(preview.source.applicationRoot.url))
    }

    func testChangedPublishedCopyIsPreservedDuringRollback() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        let changed = preview.destination.applicationRoot.url.appendingPathComponent("data")
        try Data("different".utf8).write(to: changed)
        XCTAssertThrowsError(try fixture.recover(preview))
        XCTAssertEqual(try Data(contentsOf: changed), Data("different".utf8))
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
    }

    func testRelocationCountsUseNaturalEnglishAndSpanishPlurals() throws {
        for language in ["en", "es"] {
            let locale = Locale(identifier: language)
            let bundle = try localizedBundle(language)
            let format = String(localized: "relocation-active-profile-count", bundle: bundle, locale: locale)
            let one = String(format: format, locale: locale, arguments: [Int64(1)])
            let many = String(format: format, locale: locale, arguments: [Int64(2)])
            XCTAssertTrue(one.contains(language == "en" ? "1 profile is active" : "1 perfil activo"), one)
            XCTAssertTrue(many.contains(language == "en" ? "2 profiles are active" : "2 perfiles activos"), many)
            let conflicts = String(localized: "application-relink-conflict-count", bundle: bundle, locale: locale)
            let single = String(format: conflicts, locale: locale, arguments: [Int64(1), "Synthetic"])
            let plural = String(format: conflicts, locale: locale, arguments: [Int64(2), "Synthetic"])
            XCTAssertTrue(single.contains(language == "en" ? "1 existing record:" : "1 registro existente:"), single)
            XCTAssertTrue(plural.contains(language == "en" ? "2 existing records:" : "2 registros existentes:"), plural)
            XCTAssertTrue(single.contains("Synthetic"))
        }
    }

    func testProgressAndCopyStrategyHaveBothTranslations() throws {
        let keys = ["Preparing relocation…", "Copying managed profiles…", "Copying managed archives…",
            "Publishing managed profiles…", "Publishing managed archives…", "Updating the library…",
            "Removing verified source data…", "Restoring the original storage location…", "Storage relocation completed.",
            "Same-volume copy and verification"]
        let english = try localizedBundle("en")
        let spanish = try localizedBundle("es")
        for key in keys {
            XCTAssertEqual(english.localizedString(forKey: key, value: "MISSING", table: nil), key)
            XCTAssertNotEqual(spanish.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING")
            XCTAssertNotEqual(spanish.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(PackagedRuntimeResources.bundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
}

private enum DurabilityAuditError: Error { case interrupted }

private final class RelocationAuditEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func record(_ event: String) { lock.withLock { events.append(event) } }
}
