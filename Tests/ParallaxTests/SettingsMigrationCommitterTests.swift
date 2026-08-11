import Darwin
import Foundation
@testable import Parallax
import XCTest

final class SettingsMigrationCommitterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testExactLegacyPlanPublishesCanonicalRevisionOneAndReceipt()
        throws
    {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)
        let captures = LegacyCaptureBox(legacy)

        let result = committer(
            container,
            capture: captures.capture
        ).commit(plan)

        guard case .committed(let receipt) = result else {
            return XCTFail("Expected committed migration, got \(result)")
        }
        XCTAssertEqual(receipt.snapshot.document.revision.rawValue, 1)
        XCTAssertEqual(
            receipt.snapshot.document.schemaVersion,
            SettingsDocument.currentSchemaVersion
        )
        XCTAssertTrue(receipt.snapshot.document.confirmBeforeLaunch)
        XCTAssertEqual(
            receipt.snapshot.originalBytes,
            try Data(contentsOf: primary(container))
        )
        XCTAssertEqual(
            receipt.snapshot.originalBytes,
            try SettingsDocumentCodec().encode(receipt.snapshot.document)
        )
        XCTAssertEqual(
            receipt.snapshot.versionToken.sourceSHA256,
            SettingsSourceSHA256(receipt.snapshot.originalBytes)
        )
        XCTAssertEqual(receipt.migrationEvidence, evidence(plan))
        XCTAssertEqual(receipt.lockedPrimary, .missing)
        XCTAssertEqual(receipt.recapturedLegacy, legacyAssessment(legacy))
        XCTAssertEqual(receipt.preflightInventory.entries, [])
        XCTAssertEqual(receipt.preflightInventory.completion, .complete)
        XCTAssertTrue(receipt.publication.targetProofEligible)
        XCTAssertNil(receipt.residual)
        XCTAssertEqual(captures.count, 1)
    }

    func testLockedPrimaryFailureRetainsExactTypedEvidence() throws {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)

        let result = committer(
            container,
            capture: LegacyCaptureBox(legacy).capture,
            inspectionSystem: { call in
                call == .inspectPinnedParentBeforeRead ? EACCES : nil
            }
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .currentPrimaryChanged = recovery.failure
        else {
            return XCTFail("Expected locked-read recovery evidence: \(result)")
        }
        XCTAssertEqual(
            recovery.lockedReadFailure,
            .fileAccess(
                .systemCall(
                    operation:
                        "inspect pinned settings directory before read",
                    code: EACCES
                )
            )
        )
        XCTAssertEqual(recovery.classification, .indeterminate)
    }

    func testCurrentPrimaryAppearingSupersedesPlanBeforeLegacyCapture()
        throws
    {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)
        let current = try SettingsDocumentCodec().encode(
            document(revision: 7, appearance: "dark")
        )
        try installPrimary(current, in: container)
        let captures = LegacyCaptureBox(legacy)

        let result = committer(
            container,
            capture: captures.capture
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .currentPrimaryChanged(let observed) = recovery.failure,
              case .current(let snapshot) = observed
        else {
            return XCTFail("Expected typed primary supersession: \(result)")
        }
        XCTAssertEqual(recovery.classification, .neither)
        XCTAssertEqual(snapshot.originalBytes, current)
        XCTAssertEqual(recovery.lockedPrimary, observed)
        XCTAssertEqual(recovery.planned, evidence(plan))
        XCTAssertNil(recovery.residualInventory)
        XCTAssertNil(recovery.recapturedLegacy)
        XCTAssertEqual(captures.count, 0)
        XCTAssertEqual(try Data(contentsOf: primary(container)), current)
        XCTAssertEqual(try publicationTemporaries(container), [])
    }

    func testLegacyRecaptureDriftBlocksBeforePreparationAndPublication()
        throws
    {
        let container = try fixture()
        let planned = legacySnapshot(confirm: true)
        let changed = legacySnapshot(confirm: false)
        let plan = migrationPlan(planned)
        let captures = LegacyCaptureBox(changed)

        let result = committer(
            container,
            capture: captures.capture
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .legacyRecaptureChanged(let actual) = recovery.failure
        else {
            return XCTFail("Expected legacy drift evidence: \(result)")
        }
        XCTAssertEqual(recovery.classification, .prior)
        XCTAssertEqual(actual, legacyAssessment(changed))
        XCTAssertEqual(recovery.recapturedLegacy, actual)
        XCTAssertEqual(recovery.residualInventory?.completion, .complete)
        XCTAssertEqual(recovery.planned, evidence(plan))
        XCTAssertEqual(captures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
        XCTAssertEqual(try publicationTemporaries(container), [])
    }

    func testAnyPreexistingResidualBlocksAndIsPreserved() throws {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)
        let captures = LegacyCaptureBox(legacy)
        let residualName = SettingsPublicationResidualNaming.generatedName(7)
        let residualURL = settings(container).appendingPathComponent(
            residualName
        )
        let residualBytes = try SettingsDocumentCodec().encode(
            document(revision: 3)
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: residualURL.path,
            contents: residualBytes
        ))
        try chmod(residualURL, 0o600)

        let result = committer(
            container,
            capture: captures.capture
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .preexistingResiduals(let inventory) = recovery.failure
        else {
            return XCTFail("Expected residual interlock: \(result)")
        }
        XCTAssertEqual(recovery.classification, .prior)
        XCTAssertEqual(inventory.entries.count, 1)
        XCTAssertEqual(recovery.residualInventory, inventory)
        XCTAssertEqual(try Data(contentsOf: residualURL), residualBytes)
        XCTAssertEqual(captures.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
    }

    func testPrimaryChangeAtPublicationCASPreservesUnexpectedCurrent()
        throws
    {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)
        let unexpected = try SettingsDocumentCodec().encode(
            document(revision: 22, appearance: "light")
        )
        let primaryURL = primary(container)
        let result = committer(
            container,
            capture: LegacyCaptureBox(legacy).capture,
            publicationBoundary: { boundary in
                guard boundary == .beforeCompareAndSwap else { return }
                _ = FileManager.default.createFile(
                    atPath: primaryURL.path,
                    contents: unexpected
                )
                _ = Darwin.chmod(primaryURL.path, 0o600)
            },
            publicationName: { 0x91 }
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .publication(let publication) = recovery.failure
        else {
            return XCTFail("Expected publication CAS evidence: \(result)")
        }
        XCTAssertEqual(recovery.classification, .neither)
        XCTAssertEqual(publication.failure, .compareAndSwapMismatch)
        XCTAssertEqual(recovery.targetToken?.revision.rawValue, 1)
        XCTAssertEqual(try Data(contentsOf: primaryURL), unexpected)
        XCTAssertEqual(try publicationTemporaries(container).count, 1)
    }

    func testCommittedPublicationPlusUnlockFailureRetainsTargetProof()
        throws
    {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)

        let result = committer(
            container,
            capture: LegacyCaptureBox(legacy).capture,
            lockSystem: { call in call == .unlock ? EIO : nil }
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .committedPublicationAndLock(
                let receipt,
                let lock
              ) = recovery.failure
        else {
            return XCTFail("Expected committed-plus-cleanup evidence: \(result)")
        }
        XCTAssertEqual(recovery.classification, .target)
        XCTAssertTrue(receipt.publication.targetProofEligible)
        XCTAssertEqual(receipt.publication.classification, .target)
        XCTAssertEqual(
            receipt.publication.targetToken,
            recovery.targetToken
        )
        XCTAssertEqual(recovery.lockedPrimary, receipt.lockedPrimary)
        XCTAssertEqual(
            recovery.residualInventory,
            receipt.preflightInventory
        )
        XCTAssertEqual(
            recovery.recapturedLegacy,
            receipt.recapturedLegacy
        )
        guard case .cleanup(let cleanup) = lock else {
            return XCTFail("Expected cleanup failure, got \(lock)")
        }
        XCTAssertEqual(cleanup.failures.first?.code, EIO)
        XCTAssertEqual(
            try SettingsDocumentCodec().decode(
                Data(contentsOf: primary(container))
            ).currentDocument?.revision.rawValue,
            1
        )
    }

    func testPublicationFailurePlusCleanupPreservesBothEvidenceLayers()
        throws
    {
        let container = try fixture()
        let legacy = legacySnapshot(confirm: true)
        let plan = migrationPlan(legacy)

        let result = committer(
            container,
            capture: LegacyCaptureBox(legacy).capture,
            lockSystem: { call in call == .unlock ? EIO : nil },
            publicationSystem: { call in
                call == .syncSettings ? ENOSPC : nil
            }
        ).commit(plan)

        guard case .recoveryRequired(let recovery) = result,
              case .publicationAndLock(
                let publication,
                let lock
              ) = recovery.failure
        else {
            return XCTFail("Expected publication-plus-lock evidence: \(result)")
        }
        XCTAssertEqual(recovery.classification, .target)
        guard case .system(let failure) = publication.failure else {
            return XCTFail("Expected publication system failure.")
        }
        XCTAssertEqual(failure.code, ENOSPC)
        XCTAssertEqual(publication.classification, .target)
        guard case .cleanup(let cleanup) = lock else {
            return XCTFail("Expected cleanup failure.")
        }
        XCTAssertEqual(cleanup.failures.first?.code, EIO)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
    }

    private func committer(
        _ container: URL,
        capture: @escaping SettingsMigrationCommitter.LegacyCapture,
        lockSystem:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = { _ in nil },
        publicationSystem:
            @escaping SettingsPrimaryPublication.SystemCallHook = { _ in nil },
        inspectionSystem:
            @escaping SettingsPrimaryFileAccess.SystemCallHook = { _ in nil },
        publicationBoundary:
            @escaping SettingsPrimaryPublication.BoundaryHook = { _ in },
        publicationName:
            @escaping SettingsPrimaryPublication.NameSource = { 41 }
    ) -> SettingsMigrationCommitter {
        SettingsMigrationCommitter(
            mutationLock: SettingsPrimaryMutationLock(
                trustedContainerURL: container,
                systemCallHook: lockSystem,
                inspectionSystemCallHook: inspectionSystem,
                publicationSystemCallHook: publicationSystem,
                publicationBoundaryHook: publicationBoundary,
                publicationNameSource: publicationName
            ),
            legacyCapture: capture
        )
    }

    private func migrationPlan(
        _ legacy: SettingsLegacySnapshot
    ) -> SettingsMigrationPlan {
        SettingsMigrationPlanner(
            current: SettingsCurrentMigrationAssessor(
                source: .missing
            ).assess(),
            legacy: legacyAssessment(legacy)
        ).plan()
    }

    private func legacyAssessment(
        _ snapshot: SettingsLegacySnapshot
    ) -> SettingsLegacyMigrationAssessment {
        SettingsLegacyMigrationAssessor(
            source: SettingsLegacySnapshotDecoder(
                source: snapshot
            ).decode()
        ).assess()
    }

    private func legacySnapshot(confirm: Bool) -> SettingsLegacySnapshot {
        SettingsLegacySnapshotClassifier.classify([
            SettingsLegacyKey.confirmBeforeLaunch.rawValue: confirm,
        ])
    }

    private func evidence(
        _ plan: SettingsMigrationPlan
    ) -> SettingsMigrationEvidence? {
        switch plan {
        case .publishLegacy(let ready), .publishDefaults(let ready),
             .useCurrent(let ready):
            ready.evidence
        case .recoveryRequired(let recovery):
            recovery.evidence
        }
    }

    private func document(
        revision: UInt64,
        appearance: String = "system"
    ) -> SettingsDocument {
        SettingsDocument(
            revision: .init(rawValue: revision),
            profileTemplates: [],
            defaultBaseStoragePath: "",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true,
            appearance: appearance,
            profileVisualIdentities: []
        )
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "px-settings-migration-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try chmod(root, 0o700)
        temporaryDirectories.append(root)

        let settingsURL = settings(root)
        try FileManager.default.createDirectory(
            at: settingsURL,
            withIntermediateDirectories: false
        )
        try chmod(settingsURL, 0o700)
        let lockURL = settingsURL.appendingPathComponent(
            SettingsPrimaryMutationLock.lockName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data()
        ))
        try chmod(lockURL, 0o600)
        return root
    }

    private func installPrimary(_ bytes: Data, in container: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: primary(container).path,
            contents: bytes
        ))
        try chmod(primary(container), 0o600)
    }

    private func publicationTemporaries(_ container: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: settings(container).path
        ).filter {
            $0.hasPrefix(SettingsPrimaryPublication.temporaryPrefix)
        }.sorted()
    }

    private func settings(_ container: URL) -> URL {
        container.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
    }

    private func primary(_ container: URL) -> URL {
        settings(container).appendingPathComponent(
            SettingsPrimaryFileAccess.primaryName
        )
    }

    private func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class LegacyCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: SettingsLegacySnapshot
    private var capturedCount = 0

    init(_ snapshot: SettingsLegacySnapshot) {
        self.snapshot = snapshot
    }

    var count: Int { lock.withLock { capturedCount } }

    func capture() -> SettingsLegacySnapshot {
        lock.withLock { capturedCount += 1 }
        return snapshot
    }
}

private extension SettingsDocumentDecodeResult {
    var currentDocument: SettingsDocument? {
        guard case .current(let document) = self else { return nil }
        return document
    }
}
