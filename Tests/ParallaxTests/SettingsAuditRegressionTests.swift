import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsAuditRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        guard let canonical = realpath(url.path, nil) else {
            throw POSIXError(.ENOENT)
        }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    private func bootstrap(_ support: URL) -> SettingsRuntimeBootstrapResult {
        SettingsRuntimeBootstrapper(
            applicationSupportURL: support,
            legacyApplicationIdentifier: "test.settings.audit",
            legacyCaptureOverride: { SettingsLegacySnapshotClassifier.classify([:]) }
        ).bootstrap()
    }

    private func content(_ appearance: String = "dark") -> SettingsContent {
        SettingsContent(
            profileTemplates: [], defaultBaseStoragePath: "",
            confirmBeforeLaunch: false, automaticallyRecoverCrashedApps: true,
            appearance: appearance, profileVisualIdentities: []
        )
    }

    private func seed(_ container: URL) throws -> SettingsRepositorySnapshot {
        let result = SettingsRepositoryWriter(
            mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: container)
        ).commit(content(), expecting: .missing)
        guard case .committed(let snapshot, _) = result else {
            throw NSError(domain: "SettingsAuditSeed", code: 1)
        }
        return snapshot
    }

    @MainActor
    func testOversizedEditsRevertBeforeEnqueueAndOtherSettingsStillCommit() async throws {
        let settings = AppSettings(production: bootstrap(try directory()))
        let prior = settings.profileTemplates
        settings.defaultBaseStoragePath = String(repeating: "é", count: 2_049)
        XCTAssertEqual(settings.defaultBaseStoragePath, "")
        XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        for field in [\ProfileTemplate.notes, \.argumentsText, \.environmentText] {
            var template = try XCTUnwrap(settings.profileTemplates.first)
            template[keyPath: field] = String(repeating: "é", count: 32_769)
            XCTAssertFalse(settings.replaceProfileTemplate(template))
            XCTAssertEqual(settings.profileTemplates, prior)
            XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        }
        XCTAssertFalse(settings.persistenceIssues.isEmpty)
        await settings.waitForPendingPersistence()
        XCTAssertEqual(settings.persistenceAuthority, .versionedRepository)
        settings.confirmBeforeLaunch = true
        await settings.waitForPendingPersistence()
        XCTAssertTrue(settings.confirmBeforeLaunch)
        XCTAssertEqual(settings.persistenceAuthority, .versionedRepository)
    }

    func testCoordinatorRejectsInvalidTargetWithoutRecovery() async throws {
        guard case .ready(let runtime) = bootstrap(try directory()) else {
            return XCTFail("Expected runtime")
        }
        let result = await runtime.coordinator.apply(
            .setDefaultBaseStoragePath(String(repeating: "x", count: 4_097))
        )
        XCTAssertEqual(result, .rejected(
            .stringTooLong(path: "$.defaultBaseStoragePath", maximum: 4_096),
            lastKnownState: runtime.initialState
        ))
        let next = await runtime.coordinator.apply(.setConfirmBeforeLaunch(true))
        guard case .committed(let state, _) = next else { return XCTFail("Expected later commit") }
        XCTAssertEqual(state.defaultBaseStoragePath, "")
        XCTAssertTrue(state.confirmBeforeLaunch)
    }

    @MainActor
    func testUnchangedLegacyBlankNameAllowsOtherTemplateEdits() {
        let settings = AppSettings()
        let template = ProfileTemplate(name: "")
        settings.profileTemplates = [template]
        var edited = template
        edited.notes = "Updated notes"
        XCTAssertTrue(settings.replaceProfileTemplate(edited))
        XCTAssertEqual(settings.profileTemplates, [edited])
        edited.name = "\n"
        XCTAssertFalse(settings.replaceProfileTemplate(edited))
    }

    func testPersistenceIssueUsesLocalizedErrorWitness() {
        let issue = AppSettingsPersistenceIssue.profileTemplatesEncodingFailed
        XCTAssertEqual(issue.localizedDescription, issue.errorDescription)
    }

    func testBOMInValuesRoundTripsAndBOMKeysRemainDistinct() throws {
        for value in ["\u{FEFF}start", "a\n\u{FEFF}b", "a\\\u{FEFF}b", "a\"\u{FEFF}b"] {
            let document = SettingsDocument(
                revision: SettingsRevision(rawValue: 1), profileTemplates: [],
                defaultBaseStoragePath: value, confirmBeforeLaunch: false,
                automaticallyRecoverCrashedApps: true, appearance: "system",
                profileVisualIdentities: []
            )
            let bytes = try SettingsDocumentCodec().encode(document)
            guard case .current(let decoded) = SettingsDocumentCodec().decode(bytes) else {
                return XCTFail("Expected valid document")
            }
            XCTAssertEqual(decoded, document)
            let altered = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\"revision\"", with: "\"\u{FEFF}revision\"")
            if case .current = SettingsDocumentCodec().decode(Data(altered.utf8)) {
                XCTFail("A BOM-prefixed key is not the revision key")
            }
        }
    }

    func testSiblingContainerWriteDoesNotInvalidateCommit() throws {
        let container = try directory()
        let prior = try seed(container)
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            publicationBoundaryHook: { boundary in
                guard boundary == .beforeCompareAndSwap else { return }
                do { try Data("library".utf8).write(to: container.appendingPathComponent("library.json")) }
                catch { XCTFail("Fixture: \(error)") }
            }
        )
        let result = SettingsRepositoryWriter(mutationLock: lock)
            .commit(content("light"), expecting: .version(prior.versionToken))
        guard case .committed = result else { return XCTFail("Sibling write invalidated commit: \(result)") }
    }

    func testWaiterRefreshesSettingsDirectoryAfterPeerPublication() throws {
        let container = try directory()
        let prior = try seed(container)
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            boundaryHook: { boundary in
                guard boundary == .beforeFlock else { return }
                let peer = SettingsRepositoryWriter(
                    mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: container)
                ).commit(selfContent(), expecting: .version(prior.versionToken))
                guard case .committed = peer else { return XCTFail("Peer failed") }
            }
        )
        try lock.withLock { authority in
            guard case .success(.bytes) = authority.readPrimary() else { return XCTFail("Waiter read failed") }
        }
    }

    func testLockCreationPeerChmodDoesNotInvalidateIdentity() throws {
        let container = try directory()
        _ = try seed(container)
        let path = container.appendingPathComponent("Settings/.settings.lock")
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            systemCallHook: { call in
                if call == .reopenLock { XCTAssertEqual(chmod(path.path, 0o600), 0) }
                return nil
            }
        )
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testOwnerReadOnlyPriorCanBeReplacedAndVerifiedPriorIsRemoved() throws {
        let container = try directory()
        let prior = try seed(container)
        let settings = container.appendingPathComponent("Settings")
        XCTAssertEqual(chmod(settings.appendingPathComponent("settings.json").path, 0o400), 0)
        let result = SettingsRepositoryWriter(
            mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: container)
        ).commit(content("light"), expecting: .version(prior.versionToken))
        guard case .committed(_, let residual) = result else { return XCTFail("Read-only prior: \(result)") }
        XCTAssertNil(residual)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: settings.path)
            .contains { $0.hasPrefix(".settings.publish-") })
    }

    func testSuccessfulSwapDoesNotRetainPriorSettings() throws {
        let container = try directory()
        let prior = try seed(container)
        let result = SettingsRepositoryWriter(
            mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: container)
        ).commit(content("light"), expecting: .version(prior.versionToken))
        guard case .committed(_, let residual) = result else { return XCTFail("Commit failed") }
        XCTAssertNil(residual)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("Settings").path)
            .contains { $0.hasPrefix(".settings.publish-") })
    }

    func testSymlinkedAncestorIsAcceptedButContainerSymlinkIsRejected() throws {
        let root = try directory()
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        guard case .ready = bootstrap(alias) else { return XCTFail("Safe ancestor alias rejected") }
        let linkedContainer = root.appendingPathComponent("linked-container")
        try FileManager.default.createSymbolicLink(at: linkedContainer, withDestinationURL: actual.appendingPathComponent("Parallax"))
        XCTAssertThrowsError(try SettingsPrimaryMutationLock(trustedContainerURL: linkedContainer).withLock {})
    }

    func testBootstrapTightensLegacyContainerMode() throws {
        let support = try directory()
        let container = support.appendingPathComponent("Parallax")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(container.path, 0o755), 0)
        guard case .ready = bootstrap(support) else { return XCTFail("Legacy container rejected") }
        var status = stat()
        XCTAssertEqual(lstat(container.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o700)
    }

    func testPublicationRetriesInterruptedStatusCalls() throws {
        for call in [SettingsPrimaryPublicationSystemCall.setTemporaryMode, .syncTemporary, .syncSettings] {
            let container = try directory()
            let once = SettingsAuditOnce()
            let lock = SettingsPrimaryMutationLock(
                trustedContainerURL: container,
                publicationSystemCallHook: { current in current == call && once.take() ? EINTR : nil }
            )
            let result = SettingsRepositoryWriter(mutationLock: lock).commit(content(), expecting: .missing)
            guard case .committed = result else { return XCTFail("Interrupted \(call): \(result)") }
        }
    }

    func testPublicationFallsBackToFsyncWhenFullSyncIsUnsupported() throws {
        let container = try directory()
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            publicationSystemCallHook: { call in
                call == .syncTemporary || call == .syncSettings ? ENOTSUP : nil
            }
        )
        let result = SettingsRepositoryWriter(mutationLock: lock).commit(content(), expecting: .missing)
        guard case .committed = result else { return XCTFail("Unsupported full sync: \(result)") }
    }

    func testFirstRunCanResumeWithByteExactTargetResidual() throws {
        let support = try directory()
        let container = support.appendingPathComponent("Parallax")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(container.path, 0o700), 0)
        try SettingsPrimaryMutationLock(trustedContainerURL: container).withLock {}
        let residual = container.appendingPathComponent("Settings/.settings.publish-123")
        let bytes = try SettingsDocumentCodec().encode(SettingsState.defaults.document(revision: SettingsRevision(rawValue: 1)))
        try bytes.write(to: residual)
        XCTAssertEqual(chmod(residual.path, 0o600), 0)
        guard case .ready = bootstrap(support) else { return XCTFail("Exact interrupted target blocked migration") }
        XCTAssertEqual(try Data(contentsOf: residual), bytes)
    }

    @MainActor
    func testFailedPreservedExportCanBeRetriedAndOnlySuccessDismisses() throws {
        let support = try directory()
        guard case .ready = bootstrap(support) else { return XCTFail("Expected fixture") }
        let primary = support.appendingPathComponent("Parallax/Settings/settings.json")
        let corrupt = Data("{corrupt".utf8)
        try corrupt.write(to: primary)
        let settings = AppSettings(production: bootstrap(support))
        let issue = try XCTUnwrap(settings.persistenceIssues.first)
        let presentation = SettingsIssuePresentation.binding(settings: settings) { false }
        presentation.wrappedValue = false
        XCTAssertTrue(presentation.wrappedValue)
        XCTAssertThrowsError(try settings.exportPreservedSettings(
            for: issue, to: support.appendingPathComponent("missing/export.json")
        ))
        XCTAssertEqual(settings.persistenceIssues, [issue])
        XCTAssertTrue(presentation.wrappedValue)
        XCTAssertEqual(settings.quarantinedSettingsData(for: issue), corrupt)
        let exported = support.appendingPathComponent("export.json")
        try Data("previous export".utf8).write(to: exported)
        XCTAssertTrue(try settings.exportPreservedSettings(for: issue, to: exported))
        XCTAssertEqual(try Data(contentsOf: exported), corrupt)
        XCTAssertTrue(settings.persistenceIssues.isEmpty)
        XCTAssertFalse(presentation.wrappedValue)
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
    }

    @MainActor
    func testCodecBoundaryValuesCommitAndDirectOversizedTemplateEditReverts() async throws {
        let settings = AppSettings(production: bootstrap(try directory()))
        let path = String(repeating: "é", count: 2_048)
        settings.defaultBaseStoragePath = path
        var template = try XCTUnwrap(settings.profileTemplates.first)
        template.notes = String(repeating: "é", count: 32_768)
        XCTAssertTrue(settings.replaceProfileTemplate(template))
        await settings.waitForPendingPersistence()
        XCTAssertEqual(settings.defaultBaseStoragePath, path)
        XCTAssertEqual(settings.profileTemplate(id: template.id)?.notes, template.notes)
        settings.profileTemplates[0].notes.append("x")
        XCTAssertEqual(settings.profileTemplate(id: template.id)?.notes, template.notes)
        XCTAssertEqual(settings.pendingVersionedMutationCount, 0)
        XCTAssertEqual(settings.persistenceAuthority, .versionedRepository)
    }

    func testTrailingProofReadRetriesEINTRAndPreservesOtherErrors() throws {
        let root = try directory()
        let file = root.appendingPathComponent("proof")
        let bytes = Data("proof".utf8)
        try bytes.write(to: file)
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let once = SettingsAuditOnce()
        let token = SettingsVersionToken(revision: .zero, sourceSHA256: SettingsSourceSHA256(bytes))
        let publication = SettingsPrimaryPublication(systemCallHook: { call in
            call == .readProofTrailing && once.take() ? EINTR : nil
        })
        XCTAssertTrue(try publication.exactDescriptorBytes(descriptor, expected: bytes, token: token))
        let broken = SettingsPrimaryPublication(systemCallHook: { call in
            call == .readProofTrailing ? EIO : nil
        })
        XCTAssertThrowsError(try broken.exactDescriptorBytes(descriptor, expected: bytes, token: token)) { error in
            guard case .system(let failure) = error as? SettingsPrimaryPublicationFailure else {
                return XCTFail("Expected read error: \(error)")
            }
            XCTAssertEqual(failure.code, EIO)
        }
    }

    func testPriorRemovalFailurePreservesVerifiedBytes() throws {
        let container = try directory()
        let prior = try seed(container)
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            publicationSystemCallHook: { $0 == .removeDisplacedPrior ? EACCES : nil },
            publicationNameSource: { 42 }
        )
        let result = SettingsRepositoryWriter(mutationLock: lock)
            .commit(content("light"), expecting: .version(prior.versionToken))
        guard case .committed(let committed, let residual) = result else {
            return XCTFail("Cleanup must not undo a durable commit: \(result)")
        }
        XCTAssertEqual(committed.document.appearance, "light")
        XCTAssertEqual(residual, .displacedPrior(
            name: ".settings.publish-2a", token: prior.versionToken
        ))
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent(
            "Settings/.settings.publish-2a"
        )), prior.originalBytes)
    }

    func testChangedDisplacedPriorIsNeverRemoved() throws {
        let container = try directory()
        let prior = try seed(container)
        let residual = container.appendingPathComponent("Settings/.settings.publish-2a")
        let unknown = Data("unknown replacement".utf8)
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            publicationBoundaryHook: { boundary in
                guard boundary == .beforePostflight else { return }
                do { try unknown.write(to: residual) }
                catch { XCTFail("Fixture: \(error)") }
            },
            publicationNameSource: { 42 }
        )
        let result = SettingsRepositoryWriter(mutationLock: lock)
            .commit(content("light"), expecting: .version(prior.versionToken))
        guard case .committed(let committed, let residualEvidence) = result else {
            return XCTFail("Verified target remains committed: \(result)")
        }
        XCTAssertEqual(committed.document.appearance, "light")
        XCTAssertEqual(residualEvidence, .possiblePreservedPath(name: ".settings.publish-2a"))
        XCTAssertEqual(try Data(contentsOf: residual), unknown)
    }

    func testFirstRunLockCreationRaceAcceptsPeerFinalChmod() throws {
        let container = try directory()
        let settings = container.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(settings.path, 0o700), 0)
        let path = settings.appendingPathComponent(".settings.lock")
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            boundaryHook: { boundary in
                guard boundary == .afterLockPreflight else { return }
                let peer = open(path.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
                XCTAssertGreaterThanOrEqual(peer, 0)
                if peer >= 0 { close(peer) }
            },
            systemCallHook: { call in
                if call == .reopenLock { XCTAssertEqual(chmod(path.path, 0o600), 0) }
                return nil
            }
        )
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testLockCreationFallsBackToFsyncWhenFullSyncIsUnsupported() throws {
        let container = try directory()
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            systemCallHook: { call in
                call == .syncContainer || call == .syncSettings ? ENOTSUP : nil
            }
        )
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testPeerPublicationDuringSettingsOpenDoesNotInvalidateWaiter() throws {
        let container = try directory()
        let prior = try seed(container)
        let lock = SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            boundaryHook: { boundary in
                guard boundary == .afterSettingsPreflight else { return }
                let peer = SettingsRepositoryWriter(
                    mutationLock: SettingsPrimaryMutationLock(trustedContainerURL: container)
                ).commit(selfContent(), expecting: .version(prior.versionToken))
                guard case .committed = peer else { return XCTFail("Peer failed") }
            }
        )
        XCTAssertNoThrow(try lock.withLock {})
    }

    func testBootstrapClearsSpecialBitsOnOwnedContainer() throws {
        let support = try directory()
        let container = support.appendingPathComponent("Parallax")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(container.path, 0o1700), 0)
        guard case .ready = bootstrap(support) else { return XCTFail("Owned container should be tightened") }
        var status = stat()
        XCTAssertEqual(lstat(container.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o700)
    }

    func testFullSyncUnsupportedErrorsFallBackButIOErrorsDoNot() throws {
        for code in [ENOTSUP, ENOTTY, EINVAL, EIO, EACCES] {
            let container = try directory()
            let unsupported = [ENOTSUP, ENOTTY, EINVAL].contains(code)
            let lock = SettingsPrimaryMutationLock(
                trustedContainerURL: container,
                systemCallHook: { call in
                    call == .syncContainer || call == .syncSettings ? code : nil
                }
            )
            if unsupported { XCTAssertNoThrow(try lock.withLock {}) }
            else { XCTAssertThrowsError(try lock.withLock {}) }
            let publication = SettingsRepositoryWriter(mutationLock: SettingsPrimaryMutationLock(
                trustedContainerURL: try directory(),
                publicationSystemCallHook: { call in
                    call == .syncTemporary || call == .syncSettings ? code : nil
                }
            )).commit(content(), expecting: .missing)
            if unsupported {
                guard case .committed = publication else { XCTFail("Unsupported sync: \(code)"); continue }
            } else {
                guard case .recoveryRequired = publication else { XCTFail("Real I/O error must fail"); continue }
            }
        }
    }

    func testFirstRunPreservesEmptyTruncatedAndOldPriorResidualsAndContinues() throws {
        let previousTarget = try SettingsMutation.setDefaultBaseStoragePath("/previous legacy value").applying(to: .defaults)
        for bytes in [Data(), Data(try SettingsDocumentCodec().encode(SettingsState.defaults.document(revision: .init(rawValue: 1))).prefix(80)),
                      Data(try SettingsDocumentCodec().encode(previousTarget.document(revision: .init(rawValue: 1))).dropLast(10)),
                      try SettingsDocumentCodec().encode(SettingsState.defaults.document(revision: .init(rawValue: 19)))] {
            let support = try directory()
            let container = support.appendingPathComponent("Parallax")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(container.path, 0o700), 0)
            try SettingsPrimaryMutationLock(trustedContainerURL: container).withLock {}
            let residual = container.appendingPathComponent("Settings/.settings.publish-2a")
            try bytes.write(to: residual)
            XCTAssertEqual(chmod(residual.path, 0o600), 0)
            guard case .ready = bootstrap(support) else { XCTFail("Interrupted first run must recover"); continue }
            let entries = try FileManager.default.contentsOfDirectory(
                at: container.appendingPathComponent("Settings/.settings.preserved"), includingPropertiesForKeys: nil
            )
            XCTAssertTrue(try entries.contains { url in
                guard url.lastPathComponent.hasPrefix(".settings.publish-") else { return false }
                return try Data(contentsOf: url) == bytes
            })
        }
    }

    func testFirstRunNeverMovesFutureUnsafeOrMalformedResiduals() throws {
        for (name, mode, bytes) in [
            (".settings.publish-2a", mode_t(0o600), Data("{\"schemaVersion\":2}".utf8)),
            (".settings.publish-not-ours", mode_t(0o600), Data()),
            (".settings.publish-2a", mode_t(0o644), Data()),
        ] {
            let support = try directory()
            let container = support.appendingPathComponent("Parallax")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(container.path, 0o700), 0)
            try SettingsPrimaryMutationLock(trustedContainerURL: container).withLock {}
            let path = container.appendingPathComponent("Settings/" + name)
            try bytes.write(to: path)
            XCTAssertEqual(chmod(path.path, mode), 0)
            guard case .recoveryRequired = bootstrap(support) else { XCTFail("Ambiguous residual must block"); continue }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testPriorUnlinkMustProveThePinnedDescriptorLostItsLastLink() throws {
        for failStat in [false, true] {
            let container = try directory()
            let prior = try seed(container)
            let residual = container.appendingPathComponent("Settings/.settings.publish-2a")
            let kept = container.appendingPathComponent("Settings/kept")
            let writer = SettingsRepositoryWriter(mutationLock: SettingsPrimaryMutationLock(
                trustedContainerURL: container,
                publicationSystemCallHook: { call in
                    if call == .removeDisplacedPrior, !failStat {
                        XCTAssertEqual(link(residual.path, kept.path), 0)
                    }
                    return call == .inspectRemovedPrior && failStat ? EIO : nil
                }, publicationNameSource: { 42 }
            ))
            guard case .committed(_, let residualEvidence) = writer.commit(
                content("light"), expecting: .version(prior.versionToken)
            ) else { return XCTFail("Cleanup cannot revoke durable publication") }
            XCTAssertEqual(residualEvidence, .possiblePreservedPath(name: ".settings.publish-2a"))
            if !failStat { XCTAssertEqual(try Data(contentsOf: kept), prior.originalBytes) }
        }
    }

    func testFirstRunPreservesMoreThanOneInventoryBatchOfOldPriors() throws {
        let support = try directory()
        let container = support.appendingPathComponent("Parallax")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(container.path, 0o700), 0)
        try SettingsPrimaryMutationLock(trustedContainerURL: container).withLock {}
        let bytes = try SettingsDocumentCodec().encode(SettingsState.defaults.document(revision: .init(rawValue: 9)))
        for index in 0..<65 {
            let path = container.appendingPathComponent("Settings/" + SettingsPublicationResidualNaming.generatedName(UInt64(index)))
            try bytes.write(to: path)
            XCTAssertEqual(chmod(path.path, index == 0 ? 0o400 : 0o600), 0)
        }
        guard case .ready = bootstrap(support) else { return XCTFail("Bounded batches must make progress") }
        let archived = try FileManager.default.contentsOfDirectory(
            at: container.appendingPathComponent("Settings/.settings.preserved"), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archived.count, 65)
        for path in archived { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }

    func testBootstrapPreservesACLReadError() throws {
        let result = SettingsRuntimeBootstrapper(
            applicationSupportURL: try directory(), legacyApplicationIdentifier: "audit.acl",
            legacyCaptureOverride: { SettingsLegacySnapshotClassifier.classify([:]) },
            containerACLHook: { _ in .failure(code: EACCES) }
        ).bootstrap()
        guard case .recoveryRequired(.container(.systemCall(let operation, let code))) = result else {
            return XCTFail("Expected the actual ACL read error: \(result)")
        }
        XCTAssertEqual(operation, "inspect settings container ACL")
        XCTAssertEqual(code, EACCES)
    }

    func testWriterInspectionPreservesLockAcquisitionError() throws {
        let writer = SettingsRepositoryWriter(mutationLock: SettingsPrimaryMutationLock(
            trustedContainerURL: try directory(), systemCallHook: { $0 == .openContainer ? EACCES : nil }
        ))
        guard case .unavailable(.mutationLock(.acquisition(.systemCall(let failure)))) = writer.inspect() else {
            return XCTFail("Expected original lock error")
        }
        XCTAssertEqual(failure.code, EACCES)
        XCTAssertEqual(failure.operation, "open trusted settings container")
    }

    func testNegativeDeviceNumberUsesBitPattern() {
        var status = stat()
        status.st_dev = -1
        XCTAssertEqual(SettingsPrimaryDescriptorSecurity.metadata(from: status).device, UInt64(UInt32.max))
    }
}

private func selfContent() -> SettingsContent {
    SettingsContent(profileTemplates: [], defaultBaseStoragePath: "", confirmBeforeLaunch: true,
                    automaticallyRecoverCrashedApps: true, appearance: "light", profileVisualIdentities: [])
}

private final class SettingsAuditOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { available = false }
        return available
    }
}
